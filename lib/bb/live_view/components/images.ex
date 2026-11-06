# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.Images do
  # Base64 plus JSON for a single 160x120 rgb8 frame costs a couple of dozen
  # milliseconds on a Raspberry Pi 3, so the cap is deliberately modest.
  @max_fps 5
  @stats_interval_ms 1000

  @moduledoc """
  LiveComponent showing the latest frame from every image sensor.

  Every path publishing a `BB.Message.Sensor.Image` under `[:sensor | path]`
  gets its own tile, discovered from the messages themselves, so several
  cameras show side by side. A tile follows its sensor if the frame size or
  encoding changes.

  Frames are only sent to the browser while the component is `active` (its
  tab is showing), and at most #{@max_fps} frames per second per sensor. A
  frame that arrives inside the throttle window replaces any unsent one, so
  the browser always gets the newest frame and never a backlog.

  Frames reach the `ImageGrid` hook as a `"bb_image_frame"` event:

      %{
        canvas: "images-canvas-base_link-camera-1x2y3z",
        width: 160,
        height: 120,
        step: 480,
        encoding: "rgb8",
        is_bigendian: false,
        data: "<base64 pixel data>"
      }
  """
  use Phoenix.LiveComponent

  alias BB.Message
  alias BB.Message.Sensor.Image

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       active: false,
       sensors: %{},
       push_interval_ms: div(1000, @max_fps),
       stats_interval_ms: @stats_interval_ms,
       # Not rendered: the newest message per path, the paths whose newest
       # frame hasn't been pushed yet, and per-path frame counters.
       latest: %{},
       dirty: MapSet.new(),
       counters: %{},
       flush_scheduled: false,
       stats_scheduled: false
     )}
  end

  @impl Phoenix.LiveComponent
  def update(%{event: {:image, path, %Message{payload: %Image{}} = message}}, socket) do
    {:ok,
     socket
     |> track(path, message)
     |> request_push(path)}
  end

  def update(%{event: :flush}, socket) do
    {:ok,
     socket
     |> assign(:flush_scheduled, false)
     |> flush()}
  end

  def update(%{event: :stats}, socket) do
    {:ok,
     socket
     |> assign(:stats_scheduled, false)
     |> refresh_stats(System.monotonic_time(:millisecond))
     |> schedule_stats()}
  end

  def update(assigns, socket) do
    was_active = socket.assigns.active
    socket = assign(socket, assigns)

    if socket.assigns.active and not was_active do
      {:ok,
       socket
       |> assign(:dirty, MapSet.new(Map.keys(socket.assigns.latest)))
       |> flush()
       |> schedule_stats()}
    else
      {:ok, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="bb-images" phx-hook="ImageGrid">
      <div :if={@sensors == %{}} class="bb-empty-state bb-images-empty">
        <p class="bb-empty-state-message">No image sensors yet</p>
        <p class="bb-empty-state-message bb-images-hint">
          Sensors publishing <code>BB.Message.Sensor.Image</code> appear here.
        </p>
      </div>

      <div :if={@sensors != %{}} class="bb-image-grid">
        <figure
          :for={sensor <- sorted_sensors(@sensors)}
          id={"#{@id}-tile-#{sensor.key}"}
          class="bb-image-tile"
        >
          <div class="bb-image-frame" style={"aspect-ratio: #{aspect_ratio(sensor)}"}>
            <canvas
              id={canvas_id(@id, sensor.key)}
              class="bb-image-canvas"
              phx-update="ignore"
              width={sensor.width}
              height={sensor.height}
            >
            </canvas>
          </div>
          <figcaption class="bb-image-caption">
            <span class="bb-image-label">{sensor.label}</span>
            <span class="bb-image-meta">
              {sensor.width}×{sensor.height} · {sensor.encoding} · {format_fps(sensor.fps)}
            </span>
          </figcaption>
        </figure>
      </div>
    </div>
    """
  end

  defp track(socket, path, %Message{payload: image} = message) do
    now = System.monotonic_time(:millisecond)
    {window_start, count} = Map.get(socket.assigns.counters, path, {now, 0})

    socket
    |> assign(:latest, Map.put(socket.assigns.latest, path, message))
    |> assign(:counters, Map.put(socket.assigns.counters, path, {window_start, count + 1}))
    |> put_sensor(path, image)
    |> refresh_stats(now, [path])
  end

  # Only touch `sensors` when something it renders has changed, so a steady
  # stream of frames doesn't re-render the tiles.
  defp put_sensor(socket, path, image) do
    sensors = socket.assigns.sensors
    meta = %{width: image.width, height: image.height, encoding: Atom.to_string(image.encoding)}

    case Map.fetch(sensors, path) do
      {:ok, sensor} ->
        if Map.take(sensor, [:width, :height, :encoding]) == meta do
          socket
        else
          assign(socket, :sensors, Map.put(sensors, path, Map.merge(sensor, meta)))
        end

      :error ->
        sensor =
          Map.merge(meta, %{key: sensor_key(path), label: sensor_label(path), fps: nil})

        assign(socket, :sensors, Map.put(sensors, path, sensor))
    end
  end

  defp request_push(%{assigns: %{active: false}} = socket, _path), do: socket

  defp request_push(socket, path) do
    socket = assign(socket, :dirty, MapSet.put(socket.assigns.dirty, path))

    if socket.assigns.flush_scheduled, do: socket, else: flush(socket)
  end

  defp flush(%{assigns: %{active: false}} = socket), do: assign(socket, :dirty, MapSet.new())

  defp flush(socket) do
    %{dirty: dirty, latest: latest} = socket.assigns

    if MapSet.size(dirty) == 0 do
      socket
    else
      dirty
      |> Enum.reduce(socket, fn path, acc -> push_frame(acc, path, Map.fetch!(latest, path)) end)
      |> assign(:dirty, MapSet.new())
      |> schedule_flush()
    end
  end

  defp push_frame(socket, path, %Message{payload: %Image{} = image}) do
    sensor = Map.fetch!(socket.assigns.sensors, path)

    push_event(socket, "bb_image_frame", %{
      canvas: canvas_id(socket.assigns.id, sensor.key),
      width: image.width,
      height: image.height,
      step: image.step,
      encoding: Atom.to_string(image.encoding),
      is_bigendian: image.is_bigendian == true,
      data: :base64.encode(image.data)
    })
  end

  defp schedule_flush(socket) do
    Phoenix.LiveView.send_update_after(
      __MODULE__,
      [id: socket.assigns.id, event: :flush],
      socket.assigns.push_interval_ms
    )

    assign(socket, :flush_scheduled, true)
  end

  # Ticks only while active, so a sensor that stops publishing drops to 0 fps
  # on screen instead of showing its last rate forever.
  defp schedule_stats(%{assigns: %{active: true, stats_scheduled: false}} = socket) do
    Phoenix.LiveView.send_update_after(
      __MODULE__,
      [id: socket.assigns.id, event: :stats],
      socket.assigns.stats_interval_ms
    )

    assign(socket, :stats_scheduled, true)
  end

  defp schedule_stats(socket), do: socket

  defp refresh_stats(socket, now, paths \\ nil) do
    %{counters: counters, sensors: sensors, stats_interval_ms: interval} = socket.assigns
    paths = paths || Map.keys(counters)

    {counters, sensors} =
      Enum.reduce(paths, {counters, sensors}, fn path, {counters, sensors} ->
        {window_start, count} = Map.fetch!(counters, path)
        elapsed = now - window_start

        if elapsed >= interval do
          fps = Float.round(count * 1000 / elapsed, 1)

          {Map.put(counters, path, {now, 0}), Map.update!(sensors, path, &Map.put(&1, :fps, fps))}
        else
          {counters, sensors}
        end
      end)

    socket = assign(socket, :counters, counters)

    if sensors == socket.assigns.sensors,
      do: socket,
      else: assign(socket, :sensors, sensors)
  end

  defp sorted_sensors(sensors), do: sensors |> Map.values() |> Enum.sort_by(& &1.label)

  defp canvas_id(component_id, key), do: "#{component_id}-canvas-#{key}"

  defp sensor_label([:sensor | path]) when path != [], do: sensor_label(path)
  defp sensor_label(path), do: Enum.map_join(path, ".", &path_segment/1)

  defp path_segment(segment) when is_atom(segment), do: Atom.to_string(segment)
  defp path_segment(segment), do: inspect(segment)

  # Readable, DOM-id safe, and unique per path even when two paths slug alike.
  defp sensor_key(path) do
    slug =
      path
      |> sensor_label()
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")

    hash = path |> :erlang.phash2() |> Integer.to_string(36) |> String.downcase()
    "#{slug}-#{hash}"
  end

  defp aspect_ratio(%{width: width, height: height}) when width > 0 and height > 0,
    do: "#{width} / #{height}"

  defp aspect_ratio(_sensor), do: "4 / 3"

  defp format_fps(nil), do: "– fps"
  defp format_fps(fps), do: "#{:erlang.float_to_binary(fps, decimals: 1)} fps"
end
