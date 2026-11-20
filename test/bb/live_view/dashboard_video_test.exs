# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.DashboardVideoTest do
  @moduledoc """
  The dashboard's side of video sources: the Images tab attaches while it's
  showing, and `DashboardLive` forwards signaling, `:ended` and monitor
  messages to the component.
  """

  use BB.LiveView.ConnCase

  import Phoenix.LiveViewTest

  alias BB.LiveView.FakeSink
  alias BB.LiveView.FakeVideoSource
  alias BB.LiveView.TestRobot
  alias ExWebRTC.SessionDescription

  @camera [:sensor, :base_link, :camera]

  setup do
    start_supervised!({Registry, keys: :unique, name: BB.Process.registry_name(TestRobot)})

    camera =
      start_supervised!(
        {FakeVideoSource,
         robot: TestRobot, path: @camera, metadata: %{codec: :h264}, test: self()}
      )

    %{camera: camera}
  end

  defp open_dashboard(conn) do
    {:ok, view, _html} = live(conn, "/robot")
    # Widgets render once the robot data has loaded.
    render(view)
    view
  end

  defp select_tab(view, label) do
    view |> element(".bb-vis-tabs .bb-tab", label) |> render_click()
  end

  test "attaches while the Images tab shows, and relays signaling",
       %{conn: conn, camera: camera} do
    view = open_dashboard(conn)
    refute_receive {FakeVideoSource, :attached, _source, _signaling}, 100

    select_tab(view, "Images")

    assert_receive {FakeVideoSource, :attached, ^camera, signaling}
    assert has_element?(view, "#vis-tab-images .bb-video-tile[phx-hook=VideoTile]", "h264")

    FakeSink.signal(FakeSink.start(signaling), %SessionDescription{type: :offer, sdp: "v=0"})
    assert_push_event(view, "bb_video_signal", %{type: "sdp_offer", session: 1})

    select_tab(view, "3D")

    assert_receive {FakeVideoSource, :detached, ^camera, ^signaling}
  end

  test "attaches again when the stream ends", %{conn: conn, camera: camera} do
    view = open_dashboard(conn)
    select_tab(view, "Images")
    assert_receive {FakeVideoSource, :attached, ^camera, first}

    # Past the guard against sources that fail straight after attaching.
    Process.sleep(1_100)
    :ok = FakeVideoSource.end_stream(camera, first)

    assert_receive {FakeVideoSource, :attached, ^camera, second}
    assert second != first
  end

  test "drops the tile when the source exits", %{conn: conn} do
    view = open_dashboard(conn)
    select_tab(view, "Images")
    assert_receive {FakeVideoSource, :attached, _camera, _signaling}

    :ok = stop_supervised({FakeVideoSource, @camera})
    render(view)

    refute has_element?(view, ".bb-video-tile")
  end
end
