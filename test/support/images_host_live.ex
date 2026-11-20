# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.ImagesHostLive do
  @moduledoc """
  Minimal LiveView used in tests to host `Images` in isolation with short
  push, stats and video poll intervals.

  Send `{:inject, path, message}` to the LiveView process to deliver an
  image the way `DashboardLive` does, and `{:set_active, boolean}` to switch
  the component's tab on or off. Video messages are forwarded to the
  component the way `DashboardLive` forwards them.
  """

  use Phoenix.LiveView

  alias BB.LiveView.Components.Images

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       active: Map.get(session, "active", true),
       robot_module: Map.get(session, "robot_module"),
       push_interval_ms: Map.get(session, "push_interval_ms", 200),
       stats_interval_ms: Map.get(session, "stats_interval_ms", 1000),
       video_poll_ms: Map.get(session, "video_poll_ms", 2000),
       min_session_ms: Map.get(session, "min_session_ms", 1000)
     )}
  end

  @impl Phoenix.LiveView
  def handle_info({:inject, path, message}, socket) do
    send_update(Images, id: "images", event: {:image, path, message})
    {:noreply, socket}
  end

  def handle_info({:set_active, active}, socket) do
    {:noreply, assign(socket, :active, active)}
  end

  def handle_info({:membrane_webrtc_signaling, _pid, _message, _metadata} = message, socket),
    do: forward_video_message(message, socket)

  def handle_info({BB.LiveView.VideoSource, :ended, _signaling} = message, socket),
    do: forward_video_message(message, socket)

  def handle_info({:DOWN, _ref, :process, _pid, _reason} = message, socket),
    do: forward_video_message(message, socket)

  defp forward_video_message(message, socket) do
    send_update(Images, id: "images", event: {:video, message})
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.live_component
      module={Images}
      id="images"
      active={@active}
      robot_module={@robot_module}
      push_interval_ms={@push_interval_ms}
      stats_interval_ms={@stats_interval_ms}
      video_poll_ms={@video_poll_ms}
      min_session_ms={@min_session_ms}
    />
    """
  end
end
