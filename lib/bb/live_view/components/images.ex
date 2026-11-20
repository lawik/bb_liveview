# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.Images do
  # Base64 plus JSON for a single 160x120 rgb8 frame costs a couple of dozen
  # milliseconds on a Raspberry Pi 3, so the cap is deliberately modest.
  @max_fps 5
  @stats_interval_ms 1000
  # The robot's registry doesn't notify, so video sources are polled.
  @video_poll_ms 2000
  # A stream that ends sooner than this after attaching is retried on the
  # next poll rather than at once, so a source that fails straight away
  # isn't hammered.
  @min_session_ms 1000
  # Attaching blocks the LiveView, so don't wait long on a stuck source.
  @attach_timeout_ms 2000

  @moduledoc """
  LiveComponent showing the latest frame from every image sensor, and live
  video from every `BB.LiveView.VideoSource`.

  ## Images

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

  ## Video

  With membrane_webrtc_plugin loaded, each video source registered for
  `robot_module` gets a tile playing its stream over WebRTC, and a path with
  a video source gets no image tile. Without the plugin, video sources are
  ignored.

  While the component is `active` and connected, it lists the sources every
  #{@video_poll_ms} ms. It attaches to each with a fresh
  `Membrane.WebRTC.Signaling`, and detaches when it becomes inactive or the
  source goes away. When a stream ends, by `{BB.LiveView.VideoSource,
  :ended, signaling}` or by its signaling exiting, it attaches again with a
  new signaling. A failed attach is retried on the next poll.

  The component runs in the parent LiveView's process, so the parent has to
  forward these messages to it as `{:video, message}` events:

      def handle_info({:membrane_webrtc_signaling, _, _, _} = message, socket)
      def handle_info({BB.LiveView.VideoSource, :ended, _} = message, socket)
      def handle_info({:DOWN, _, :process, _, _} = message, socket)

      send_update(Images, id: "images", event: {:video, message})

  Each attach is a session, numbered per component. The tile's
  `data-session` attribute names the current one; the `VideoTile` hook
  starts a new `RTCPeerConnection` whenever it changes, and closes it when
  the attribute goes away. Signaling travels with the session, and messages
  for any other session are dropped at both ends:

      # server to hook, "bb_video_signal"
      %{
        tile: "images-video-base_link-camera-1x2y3z",
        session: 3,
        type: "sdp_offer" | "ice_candidate",
        data: %{"type" => "offer", "sdp" => "..."}
      }

      # hook to server, "video_signal"
      %{
        "tile" => "images-video-base_link-camera-1x2y3z",
        "session" => 3,
        "type" => "sdp_answer" | "ice_candidate",
        "data" => %{"candidate" => "...", "sdpMid" => "0", "sdpMLineIndex" => 0}
      }
  """
  use Phoenix.LiveComponent

  alias BB.LiveView.VideoSource
  alias BB.LiveView.WebRTC
  alias BB.Message
  alias BB.Message.Sensor.Image

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       active: false,
       robot_module: nil,
       sensors: %{},
       videos: %{},
       push_interval_ms: div(1000, @max_fps),
       stats_interval_ms: @stats_interval_ms,
       video_poll_ms: @video_poll_ms,
       min_session_ms: @min_session_ms,
       # Not rendered: the newest message per path, the paths whose newest
       # frame hasn't been pushed yet, and per-path frame counters.
       latest: %{},
       dirty: MapSet.new(),
       counters: %{},
       flush_scheduled: false,
       stats_scheduled: false,
       poll_scheduled: false,
       video_session: 0
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

  def update(%{event: :poll_videos}, socket) do
    {:ok,
     socket
     |> assign(:poll_scheduled, false)
     |> sync_videos()
     |> schedule_poll()}
  end

  def update(%{event: {:video, message}}, socket) do
    {:ok, handle_video_message(message, socket)}
  end

  def update(assigns, socket) do
    was_active = socket.assigns.active
    socket = assign(socket, assigns)

    cond do
      socket.assigns.active and not was_active ->
        socket = socket |> sync_videos() |> schedule_poll()

        {:ok,
         socket
         |> assign(:dirty, MapSet.new(Map.keys(socket.assigns.latest)))
         |> flush()
         |> schedule_stats()}

      was_active and not socket.assigns.active ->
        {:ok, detach_videos(socket)}

      true ->
        {:ok, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event(
        "video_signal",
        %{"tile" => tile, "session" => session, "type" => type, "data" => data},
        socket
      ) do
    video = find_video(socket, &(video_tile_id(socket.assigns.id, &1.key) == tile))

    if video && video.signaling && video.session == session && valid_signal?(type, data) do
      WebRTC.signal(video.signaling, type, data)
    end

    {:noreply, socket}
  end

  def handle_event("video_signal", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="bb-images" phx-hook="ImageGrid">
      <div :if={no_tiles?(@sensors, @videos)} class="bb-empty-state bb-images-empty">
        <p class="bb-empty-state-message">No image sensors yet</p>
        <p class="bb-empty-state-message bb-images-hint">
          Sensors publishing <code>BB.Message.Sensor.Image</code>
          and video sources appear here.
        </p>
      </div>

      <div :if={not no_tiles?(@sensors, @videos)} class="bb-image-grid">
        <figure
          :for={video <- sorted_videos(@videos)}
          id={video_tile_id(@id, video.key)}
          class="bb-image-tile bb-video-tile"
          phx-hook="VideoTile"
          data-session={video.session}
        >
          <div class="bb-image-frame" style={"aspect-ratio: #{aspect_ratio(video.metadata)}"}>
            <video
              id={"#{video_tile_id(@id, video.key)}-video"}
              class="bb-image-canvas bb-video"
              phx-update="ignore"
              autoplay
              muted
              playsinline
              disablepictureinpicture
            >
            </video>
          </div>
          <figcaption class="bb-image-caption">
            <span class="bb-image-label">{video.label}</span>
            <span class="bb-image-meta">{video_meta(video.metadata)}</span>
            <span class="bb-video-status">
              <span :if={video.error} class="bb-video-error">{video.error}</span>
              <span
                id={"#{video_tile_id(@id, video.key)}-state"}
                class="bb-video-state"
                data-role="video-state"
                phx-update="ignore"
              ></span>
              <span
                id={"#{video_tile_id(@id, video.key)}-fps"}
                class="bb-video-fps"
                data-role="video-fps"
                phx-update="ignore"
              ></span>
            </span>
          </figcaption>
        </figure>

        <figure
          :for={sensor <- sorted_sensors(@sensors, @videos)}
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
    if Map.has_key?(socket.assigns.videos, path) do
      socket
    else
      socket = assign(socket, :dirty, MapSet.put(socket.assigns.dirty, path))

      if socket.assigns.flush_scheduled, do: socket, else: flush(socket)
    end
  end

  defp flush(%{assigns: %{active: false}} = socket), do: assign(socket, :dirty, MapSet.new())

  defp flush(socket) do
    %{dirty: dirty, latest: latest, videos: videos} = socket.assigns
    paths = Enum.reject(dirty, &Map.has_key?(videos, &1))

    if paths == [] do
      assign(socket, :dirty, MapSet.new())
    else
      paths
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

  # Video

  defp video_enabled?(socket) do
    socket.assigns.active and socket.assigns.robot_module != nil and connected?(socket) and
      WebRTC.available?()
  end

  defp schedule_poll(%{assigns: %{poll_scheduled: false}} = socket) do
    if video_enabled?(socket) do
      Phoenix.LiveView.send_update_after(
        __MODULE__,
        [id: socket.assigns.id, event: :poll_videos],
        socket.assigns.video_poll_ms
      )

      assign(socket, :poll_scheduled, true)
    else
      socket
    end
  end

  defp schedule_poll(socket), do: socket

  # Brings the tiles in line with the registry: drops sources that are gone
  # or were restarted under a new pid, adds new ones, and attaches every tile
  # that isn't streaming.
  defp sync_videos(socket) do
    if video_enabled?(socket) do
      sources =
        socket.assigns.robot_module
        |> VideoSource.list()
        # The registry forgets an exited process a moment after its monitors fire.
        |> Enum.filter(&Process.alive?(&1.pid))

      socket = drop_stale_videos(socket, Map.new(sources, &{&1.path, &1.pid}))
      Enum.reduce(sources, socket, &put_source(&2, &1))
    else
      socket
    end
  end

  defp drop_stale_videos(socket, current) do
    Enum.reduce(socket.assigns.videos, socket, fn {path, video}, acc ->
      if Map.get(current, path) == video.pid, do: acc, else: remove_video(acc, path)
    end)
  end

  defp put_source(socket, %{path: path, pid: pid, metadata: metadata}) do
    video =
      case Map.fetch(socket.assigns.videos, path) do
        {:ok, video} ->
          %{video | metadata: metadata}

        :error ->
          %{
            path: path,
            key: sensor_key(path),
            label: sensor_label(path),
            pid: pid,
            metadata: metadata,
            monitor: Process.monitor(pid),
            session: nil,
            signaling: nil,
            signaling_pid: nil,
            signaling_monitor: nil,
            attached_at: nil,
            error: nil
          }
      end

    socket = put_video(socket, video)

    if video.session, do: socket, else: attach_video(socket, path)
  end

  defp attach_video(socket, path) do
    video = Map.fetch!(socket.assigns.videos, path)
    signaling = WebRTC.open()
    signaling_pid = WebRTC.pid(signaling)
    monitor = Process.monitor(signaling_pid)

    case VideoSource.attach(video.pid, signaling, @attach_timeout_ms) do
      :ok ->
        session = socket.assigns.video_session + 1

        socket
        |> assign(:video_session, session)
        |> put_video(%{
          video
          | session: session,
            signaling: signaling,
            signaling_pid: signaling_pid,
            signaling_monitor: monitor,
            attached_at: System.monotonic_time(:millisecond),
            error: nil
        })

      other ->
        Process.demonitor(monitor, [:flush])
        WebRTC.close(signaling)
        put_video(socket, %{video | error: describe_attach_error(other)})
    end
  end

  defp detach_videos(socket) do
    videos =
      Map.new(socket.assigns.videos, fn {path, video} ->
        {path, %{release_stream(video) | error: nil}}
      end)

    assign(socket, :videos, videos)
  end

  defp remove_video(socket, path) do
    video = Map.fetch!(socket.assigns.videos, path)
    Process.demonitor(video.monitor, [:flush])
    release_stream(video)
    socket = assign(socket, :videos, Map.delete(socket.assigns.videos, path))

    # Its image tile, if it has one, shows again.
    if Map.has_key?(socket.assigns.latest, path),
      do: request_push(socket, path),
      else: socket
  end

  # The source stopped streaming to this tile's signaling, or the signaling
  # exited with its sink: start over with a new one.
  defp restart_video(socket, video) do
    lasted = System.monotonic_time(:millisecond) - video.attached_at
    quick? = lasted < socket.assigns.min_session_ms
    socket = put_video(socket, release_stream(video))

    if quick? or not video_enabled?(socket),
      do: socket,
      else: attach_video(socket, video.path)
  end

  defp release_stream(%{signaling: nil} = video), do: video

  defp release_stream(video) do
    Process.demonitor(video.signaling_monitor, [:flush])
    VideoSource.detach(video.pid, video.signaling, @attach_timeout_ms)
    WebRTC.close(video.signaling)

    %{
      video
      | session: nil,
        signaling: nil,
        signaling_pid: nil,
        signaling_monitor: nil,
        attached_at: nil
    }
  end

  defp handle_video_message({:membrane_webrtc_signaling, pid, message, _metadata}, socket) do
    with %{"type" => type, "data" => data} <- message,
         %{session: session} = video when session != nil <-
           find_video(socket, &(&1.signaling_pid == pid)) do
      push_event(socket, "bb_video_signal", %{
        tile: video_tile_id(socket.assigns.id, video.key),
        session: session,
        type: type,
        data: data
      })
    else
      _ -> socket
    end
  end

  defp handle_video_message({VideoSource, :ended, signaling}, socket) do
    case find_video(socket, &(&1.signaling != nil and &1.signaling == signaling)) do
      nil -> socket
      video -> restart_video(socket, video)
    end
  end

  defp handle_video_message({:DOWN, ref, :process, _pid, _reason}, socket) do
    cond do
      video = find_video(socket, &(&1.monitor == ref)) -> remove_video(socket, video.path)
      video = find_video(socket, &(&1.signaling_monitor == ref)) -> restart_video(socket, video)
      true -> socket
    end
  end

  defp handle_video_message(_message, socket), do: socket

  # Only assign when something changed, so polling doesn't re-render tiles.
  defp put_video(socket, video) do
    videos = socket.assigns.videos

    if Map.get(videos, video.path) == video,
      do: socket,
      else: assign(socket, :videos, Map.put(videos, video.path, video))
  end

  defp find_video(socket, fun) do
    socket.assigns.videos |> Map.values() |> Enum.find(fun)
  end

  # Only what the plugin's JSON conversion accepts, so a bad message can't
  # crash the signaling.
  defp valid_signal?("sdp_answer", %{"type" => "answer", "sdp" => sdp}) when is_binary(sdp),
    do: true

  defp valid_signal?("ice_candidate", %{"candidate" => candidate} = data)
       when is_binary(candidate),
       do: Map.has_key?(data, "sdpMid") and Map.has_key?(data, "sdpMLineIndex")

  defp valid_signal?(_type, _data), do: false

  defp describe_attach_error({:error, {:exit, {reason, _call}}}) when is_atom(reason),
    do: "unavailable (#{reason})"

  defp describe_attach_error({:error, reason}) when is_atom(reason),
    do: "unavailable (#{reason})"

  defp describe_attach_error(_other), do: "unavailable"

  # Sources describe themselves, so only well-typed fields are shown.
  defp video_meta(metadata) do
    [meta_size(metadata), meta_codec(metadata), meta_framerate(metadata)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp meta_size(%{width: w, height: h}) when is_integer(w) and is_integer(h), do: "#{w}×#{h}"
  defp meta_size(_metadata), do: nil

  defp meta_codec(%{codec: codec}) when is_binary(codec), do: codec

  defp meta_codec(%{codec: codec}) when is_atom(codec) and not is_nil(codec),
    do: Atom.to_string(codec)

  defp meta_codec(_metadata), do: nil

  defp meta_framerate(%{framerate: fps}) when is_number(fps), do: "#{fps} fps"
  defp meta_framerate(_metadata), do: nil

  defp no_tiles?(sensors, videos), do: videos == %{} and sorted_sensors(sensors, videos) == []

  defp sorted_videos(videos), do: videos |> Map.values() |> Enum.sort_by(& &1.label)

  defp sorted_sensors(sensors, videos) do
    sensors
    |> Enum.reject(fn {path, _sensor} -> Map.has_key?(videos, path) end)
    |> Enum.map(fn {_path, sensor} -> sensor end)
    |> Enum.sort_by(& &1.label)
  end

  defp video_tile_id(component_id, key), do: "#{component_id}-video-#{key}"

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

  defp aspect_ratio(%{width: width, height: height})
       when is_integer(width) and is_integer(height) and width > 0 and height > 0,
       do: "#{width} / #{height}"

  defp aspect_ratio(_sensor), do: "4 / 3"

  defp format_fps(nil), do: "– fps"
  defp format_fps(fps), do: "#{:erlang.float_to_binary(fps, decimals: 1)} fps"
end
