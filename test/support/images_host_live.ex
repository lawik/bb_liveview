# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.ImagesHostLive do
  @moduledoc """
  Minimal LiveView used in tests to host `Images` in isolation with short
  push and stats intervals.

  Send `{:inject, path, message}` to the LiveView process to deliver an
  image the way `DashboardLive` does, and `{:set_active, boolean}` to switch
  the component's tab on or off.
  """

  use Phoenix.LiveView

  alias BB.LiveView.Components.Images

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       active: Map.get(session, "active", true),
       push_interval_ms: Map.get(session, "push_interval_ms", 200),
       stats_interval_ms: Map.get(session, "stats_interval_ms", 1000)
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

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.live_component
      module={Images}
      id="images"
      active={@active}
      push_interval_ms={@push_interval_ms}
      stats_interval_ms={@stats_interval_ms}
    />
    """
  end
end
