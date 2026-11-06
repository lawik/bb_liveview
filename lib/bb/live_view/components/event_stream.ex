# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.EventStream do
  @moduledoc """
  LiveComponent for displaying a live stream of BB messages.

  Shows real-time messages from the robot's PubSub with:
  - Timestamps and path information
  - Message type and summary
  - Pause/Resume functionality
  - Clear messages
  - Click to expand message details
  """
  use Phoenix.LiveComponent

  alias Phoenix.LiveView.JS

  @max_messages 100
  @default_flush_interval_ms 500
  @default_debounce_window_ms 1000
  @max_string_bytes 200

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> stream(:messages, [])
     |> assign(
       paused: false,
       message_count: 0,
       pending: [],
       last_seen: %{},
       flush_scheduled: false,
       flush_interval_ms: @default_flush_interval_ms,
       debounce_window_ms: @default_debounce_window_ms
     )}
  end

  @impl Phoenix.LiveComponent
  def update(%{event: {:new_message, path, message}}, socket) do
    cond do
      socket.assigns.paused ->
        {:ok, socket}

      debounced?(path, message, socket.assigns.last_seen, socket.assigns.debounce_window_ms) ->
        {:ok, socket}

      true ->
        key = debounce_key(path, message)
        now = System.monotonic_time(:millisecond)
        msg_data = format_message(path, message)

        socket =
          socket
          |> assign(:pending, [msg_data | socket.assigns.pending])
          |> assign(:last_seen, Map.put(socket.assigns.last_seen, key, now))
          |> schedule_flush()

        {:ok, socket}
    end
  end

  def update(%{event: :flush}, socket) do
    pending = socket.assigns.pending

    socket =
      pending
      |> Enum.reverse()
      |> Enum.reduce(socket, fn msg, acc ->
        stream_insert(acc, :messages, msg, at: 0, limit: @max_messages)
      end)
      |> assign(
        :message_count,
        min(socket.assigns.message_count + length(pending), @max_messages)
      )
      |> assign(:pending, [])
      |> assign(:flush_scheduled, false)

    {:ok, socket}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="bb-event-stream">
      <div class="bb-event-toolbar">
        <div class="bb-event-controls">
          <button
            type="button"
            class={"bb-button #{if @paused, do: "bb-button-success", else: "bb-button-warning"}"}
            phx-click="toggle_pause"
            phx-target={@myself}
          >
            {if @paused, do: "Resume", else: "Pause"}
          </button>
          <button
            type="button"
            class="bb-button bb-button-outline"
            phx-click="clear"
            phx-target={@myself}
          >
            Clear
          </button>
          <span class="bb-event-count">{@message_count} messages</span>
        </div>
      </div>

      <div class="bb-event-list">
        <div :if={@message_count == 0} class="bb-empty-state">
          <p class="bb-empty-state-message">
            {if @paused, do: "Paused - no new messages", else: "Waiting for messages..."}
          </p>
        </div>

        <div id={"#{@id}-messages"} phx-update="stream">
          <div
            :for={{dom_id, msg} <- @streams.messages}
            id={dom_id}
            class="bb-event-message"
            phx-click={JS.toggle(to: "##{dom_id} .bb-event-payload")}
          >
            <div class="bb-event-header">
              <span class="bb-event-timestamp">{msg.timestamp}</span>
              <span class="bb-event-path">{msg.path}</span>
              <span class="bb-event-type">{msg.short_type}</span>
              <span :if={msg.summary} class="bb-event-summary">{msg.summary}</span>
            </div>

            <div class="bb-event-payload" style="display: none;">
              <div class="bb-event-full-type">{msg.type}</div>
              <div class="bb-event-fields">
                <div :for={field <- msg.fields} class="bb-event-field">
                  <span class="bb-event-field-name">{field.name}:</span>
                  <span class="bb-event-field-value">{field.value}</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, not socket.assigns.paused)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> stream(:messages, [], reset: true)
     |> assign(message_count: 0, pending: [])}
  end

  defp debounce_key(path, message), do: {path, message.payload.__struct__}

  defp debounced?(path, message, last_seen, window_ms) do
    case Map.get(last_seen, debounce_key(path, message)) do
      nil -> false
      last -> System.monotonic_time(:millisecond) - last < window_ms
    end
  end

  defp schedule_flush(%{assigns: %{flush_scheduled: true}} = socket), do: socket

  defp schedule_flush(socket) do
    Phoenix.LiveView.send_update_after(
      __MODULE__,
      [id: socket.assigns.id, event: :flush],
      socket.assigns.flush_interval_ms
    )

    assign(socket, :flush_scheduled, true)
  end

  defp format_message(path, message) do
    timestamp_str =
      message.wall_time
      |> DateTime.from_unix!(:nanosecond)
      |> Calendar.strftime("%H:%M:%S.%f")
      |> String.slice(0, 12)

    payload_struct = message.payload
    type_name = payload_struct.__struct__ |> Module.split() |> Enum.join(".")

    %{
      id: System.unique_integer([:positive]),
      timestamp: timestamp_str,
      path: format_path(path),
      type: type_name,
      short_type: short_type_name(payload_struct.__struct__),
      summary: format_payload_summary(payload_struct),
      fields: format_payload_fields(payload_struct)
    }
  end

  defp format_path(path) do
    Enum.map_join(path, ".", &format_path_element/1)
  end

  defp format_path_element(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_path_element(ref) when is_reference(ref), do: inspect(ref)
  defp format_path_element(other), do: inspect(other)

  defp short_type_name(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp format_payload_summary(payload) do
    case payload do
      %BB.Message.Sensor.JointState{names: names} ->
        "#{length(names)} joint(s)"

      %BB.Message.Actuator.Command.Position{position: pos} ->
        format_value(pos)

      %BB.StateMachine.Transition{from: from, to: to} ->
        "#{from} → #{to}"

      _ ->
        nil
    end
  end

  defp format_payload_fields(payload) do
    payload
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {key, value} ->
      %{
        name: Atom.to_string(key),
        value: format_value(value)
      }
    end)
  end

  defp format_value([]), do: "[]"

  defp format_value(value) when is_list(value) do
    cond do
      Enum.all?(value, &is_number/1) ->
        values = Enum.map_join(value, ", ", &format_number/1)
        "[#{values}]"

      Enum.all?(value, &is_atom/1) ->
        values = Enum.map_join(value, ", ", &Atom.to_string/1)
        "[#{values}]"

      true ->
        inspect(value, limit: 10)
    end
  end

  defp format_value(value) when is_float(value), do: format_number(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  # Payloads can carry raw bytes (an image's pixel data, say). Rendered as-is
  # they bloat the diff, and invalid UTF-8 makes the socket's JSON encoding
  # raise, so only short printable text is shown verbatim.
  defp format_value(value) when is_binary(value) and byte_size(value) <= @max_string_bytes do
    if String.printable?(value), do: value, else: byte_summary(value)
  end

  defp format_value(value) when is_binary(value) do
    prefix = value |> binary_part(0, @max_string_bytes) |> valid_utf8_prefix()

    if String.printable?(prefix), do: prefix <> "…", else: byte_summary(value)
  end

  defp format_value(value), do: inspect(value, limit: 10)

  defp byte_summary(value), do: "<<#{byte_size(value)} bytes>>"

  # Cutting at a byte offset can split a multi-byte character; drop the
  # partial one rather than calling the whole string binary.
  defp valid_utf8_prefix(bytes) do
    case :unicode.characters_to_binary(bytes) do
      {:incomplete, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
      {:error, _valid, _rest} -> bytes
    end
  end

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 3)
  defp format_number(n), do: Integer.to_string(n)
end
