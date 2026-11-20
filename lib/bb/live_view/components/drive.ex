# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.Drive do
  @moduledoc """
  LiveComponent for hold-to-drive; see `BB.LiveView.Drive`.

  Driving is off until the user takes control, so the arrow keys keep their
  usual job on the rest of the page. In control, the `DrivePad` hook turns
  held keys (arrows, or WASD by position on any keyboard layout) and presses
  on the on-screen pad into `"drive"` ticks, and a `"drive_stop"` when the
  last one is let go. Releasing control stops the robot too.
  """
  use Phoenix.LiveComponent

  alias BB.LiveView.Drive

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, in_control: false, throttle: 0.0, turn: 0.0)}
  end

  @impl Phoenix.LiveComponent
  def update(%{event: {:armed_changed, armed}}, socket) do
    {:ok, assign(socket, :armed, armed)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign_new(:available, fn -> Drive.available?(socket.assigns.drive) end)
     |> assign_new(:armed, fn -> armed?(socket.assigns.robot_module) end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="bb-drive"
      phx-hook="DrivePad"
      phx-target={@myself}
      data-in-control={to_string(@in_control)}
      data-rate={@drive.rate}
    >
      <div class="bb-drive-header">
        <button
          type="button"
          class={["bb-button", if(@in_control, do: "bb-button-danger", else: "bb-button-primary")]}
          phx-click="toggle_control"
          phx-target={@myself}
          disabled={not @available}
        >
          {if @in_control, do: "Release control", else: "Take control"}
        </button>
        <span class="bb-drive-hint">
          {if @in_control,
            do: "Hold the arrow keys or WASD, or the pad. Let go to stop.",
            else: "Take control to drive with the keyboard or the pad."}
        </span>
      </div>

      <div :if={not @available} class="bb-error-message" role="alert">
        <span class="bb-error-icon">!</span>
        <span>Drive functions not found: {format_mfa(@drive.publish, 3)}, {format_mfa(@drive.stop, 1)}</span>
      </div>

      <div :if={@in_control and not @armed} class="bb-drive-warning" role="status">
        The robot is disarmed: arm it to drive.
      </div>

      <%!-- The hook enables these and marks the held ones, so the server
            leaves them alone. --%>
      <div id={"#{@id}-pad"} class="bb-drive-pad" phx-update="ignore">
        <button
          :for={{key, class, label, symbol} <- pad_keys()}
          type="button"
          class={["bb-drive-key", class]}
          data-drive-key={key}
          aria-label={label}
          disabled
        >
          {symbol}
        </button>
      </div>

      <div class="bb-drive-readout">
        throttle {format_value(@throttle)} · turn {format_value(@turn)}
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_control", _params, %{assigns: %{in_control: true}} = socket) do
    Drive.stop(socket.assigns.drive, socket.assigns.robot_module)
    {:noreply, assign(socket, in_control: false, throttle: 0.0, turn: 0.0)}
  end

  def handle_event("toggle_control", _params, socket) do
    {:noreply, assign(socket, in_control: true, armed: armed?(socket.assigns.robot_module))}
  end

  def handle_event("drive", %{"throttle" => throttle, "turn" => turn}, socket)
      when is_number(throttle) and is_number(turn) do
    if socket.assigns.in_control do
      {throttle, turn} =
        Drive.tick(socket.assigns.drive, socket.assigns.robot_module, throttle, turn)

      {:noreply, assign(socket, throttle: throttle, turn: turn)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("drive", _params, socket), do: {:noreply, socket}

  def handle_event("drive_stop", _params, socket) do
    if socket.assigns.in_control do
      Drive.stop(socket.assigns.drive, socket.assigns.robot_module)
    end

    {:noreply, assign(socket, throttle: 0.0, turn: 0.0)}
  end

  defp pad_keys do
    [
      {"up", "bb-drive-up", "Forward", "▲"},
      {"left", "bb-drive-left", "Left", "◀"},
      {"down", "bb-drive-down", "Reverse", "▼"},
      {"right", "bb-drive-right", "Right", "▶"}
    ]
  end

  defp armed?(robot_module) do
    BB.Safety.armed?(robot_module)
  rescue
    _ -> false
  end

  defp format_value(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp format_mfa({module, function}, arity), do: "#{inspect(module)}.#{function}/#{arity}"
end
