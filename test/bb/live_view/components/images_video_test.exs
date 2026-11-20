# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.ImagesVideoTest do
  @moduledoc """
  Tests for the `Images` component's video tiles: attaching to
  `BB.LiveView.VideoSource`s while active, relaying WebRTC signaling, and
  recovering when a stream ends.

  Each test gets its own robot registry, with `FakeVideoSource`s in it and,
  where signaling matters, a `FakeSink` in place of the WebRTC sink.
  """

  use BB.LiveView.ConnCase

  import Phoenix.LiveViewTest

  alias BB.LiveView.FakeSink
  alias BB.LiveView.FakeVideoSource
  alias BB.LiveView.ImagesHostLive
  alias BB.Message.Sensor.Image
  alias ExWebRTC.ICECandidate
  alias ExWebRTC.SessionDescription

  @camera [:sensor, :base_link, :camera]
  @mast [:sensor, :mast, :camera]
  @depth [:sensor, :mast, :depth]
  @metadata %{codec: :h264, width: 640, height: 480, framerate: 30}

  setup do
    robot = Module.concat(__MODULE__, "Robot#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :unique, name: BB.Process.registry_name(robot)})
    %{robot: robot}
  end

  defp source!(robot, path \\ @camera, metadata \\ @metadata) do
    start_supervised!(
      {FakeVideoSource, robot: robot, path: path, metadata: metadata, test: self()}
    )
  end

  # Long polls and no quick-restart guard unless a test asks, so attaches
  # only happen when the test expects them.
  defp mount_host(conn, robot, session \\ %{}) do
    defaults = %{
      "robot_module" => robot,
      "active" => true,
      "video_poll_ms" => 60_000,
      "min_session_ms" => 0
    }

    live_isolated(conn, ImagesHostLive, session: Map.merge(defaults, session))
  end

  defp sessions(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(".bb-video-tile")
    |> Enum.map(fn tile -> tile |> Floki.attribute("data-session") |> List.first() end)
  end

  defp tile_id(view, label) do
    view
    |> element(".bb-video-tile", label)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("id")
    |> List.first()
  end

  # The viewer closes a signaling just after the source hears about it.
  defp assert_closed(signaling) do
    ref = Process.monitor(signaling.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  defp image(encoding) do
    step = %{rgb8: 6, mono8: 2}[encoding]

    {:ok, message} =
      Image.new(:camera,
        width: 2,
        height: 2,
        encoding: encoding,
        step: step,
        data: :binary.copy(<<0>>, step * 2)
      )

    message
  end

  defp inject(view, path, message) do
    send(view.pid, {:inject, path, message})
    render(view)
    render(view)
  end

  describe "attaching" do
    test "attaches to every source only once active", %{conn: conn, robot: robot} do
      camera = source!(robot, @camera)
      mast = source!(robot, @mast, %{codec: :vp8})

      {:ok, view, _html} = mount_host(conn, robot, %{"active" => false})

      refute_receive {FakeVideoSource, :attached, _source, _signaling}, 50
      refute has_element?(view, ".bb-video-tile")

      send(view.pid, {:set_active, true})

      assert_receive {FakeVideoSource, :attached, ^camera, camera_signaling}
      assert_receive {FakeVideoSource, :attached, ^mast, mast_signaling}
      assert Process.alive?(camera_signaling.pid)
      assert camera_signaling != mast_signaling

      assert has_element?(view, ".bb-video-tile", "base_link.camera")
      assert has_element?(view, ".bb-video-tile", "640×480 · h264 · 30 fps")
      assert has_element?(view, ".bb-video-tile", "mast.camera")
      assert has_element?(view, ".bb-video-tile video[muted][autoplay][playsinline]")
      assert sessions(view) == ["1", "2"]
    end

    test "detaches when deactivated and attaches afresh when active again",
         %{conn: conn, robot: robot} do
      camera = source!(robot)
      {:ok, view, _html} = mount_host(conn, robot)
      assert_receive {FakeVideoSource, :attached, ^camera, first}

      send(view.pid, {:set_active, false})

      assert_receive {FakeVideoSource, :detached, ^camera, ^first}
      assert_closed(first)
      assert FakeVideoSource.attached(camera) == []
      # The tile stays, without a session, so its peer connection closes.
      assert sessions(view) == [nil]

      send(view.pid, {:set_active, true})

      assert_receive {FakeVideoSource, :attached, ^camera, second}
      assert second != first
      assert sessions(view) == ["2"]
    end

    test "picks up a source that registers later", %{conn: conn, robot: robot} do
      {:ok, view, _html} = mount_host(conn, robot, %{"video_poll_ms" => 50})
      refute has_element?(view, ".bb-video-tile")

      camera = source!(robot)

      assert_receive {FakeVideoSource, :attached, ^camera, _signaling}, 1_000
      eventually(fn -> has_element?(view, ".bb-video-tile", "base_link.camera") end)
    end

    test "doesn't poll while inactive", %{conn: conn, robot: robot} do
      {:ok, _view, _html} = mount_host(conn, robot, %{"active" => false, "video_poll_ms" => 20})
      source!(robot)

      refute_receive {FakeVideoSource, :attached, _source, _signaling}, 200
    end

    test "shows a failed attach and retries it on the next poll", %{conn: conn, robot: robot} do
      camera = source!(robot)
      :ok = FakeVideoSource.refuse(camera, {:error, :no_camera})

      {:ok, view, _html} = mount_host(conn, robot, %{"video_poll_ms" => 50})

      assert_receive {FakeVideoSource, :attach_refused, ^camera, refused}
      assert_closed(refused)
      assert has_element?(view, ".bb-video-error", "unavailable (no_camera)")
      assert sessions(view) == [nil]

      :ok = FakeVideoSource.refuse(camera, :ok)

      assert_receive {FakeVideoSource, :attached, ^camera, _signaling}, 1_000
      eventually(fn -> not has_element?(view, ".bb-video-error") end)
    end
  end

  describe "when a stream ends" do
    test "attaches again with a fresh signaling on :ended", %{conn: conn, robot: robot} do
      camera = source!(robot)
      {:ok, view, _html} = mount_host(conn, robot)
      assert_receive {FakeVideoSource, :attached, ^camera, first}

      :ok = FakeVideoSource.end_stream(camera, first)

      assert_receive {FakeVideoSource, :attached, ^camera, second}
      assert second != first
      assert_closed(first)
      # A new session, so the browser starts a new peer connection.
      assert sessions(view) == ["2"]
    end

    test "waits for the next poll when a stream ends straight away",
         %{conn: conn, robot: robot} do
      camera = source!(robot)

      {:ok, _view, _html} =
        mount_host(conn, robot, %{"min_session_ms" => 60_000, "video_poll_ms" => 1_000})

      assert_receive {FakeVideoSource, :attached, ^camera, first}

      :ok = FakeVideoSource.end_stream(camera, first)

      # Well inside the poll interval, which started at mount.
      refute_receive {FakeVideoSource, :attached, ^camera, _signaling}, 300
      assert_receive {FakeVideoSource, :attached, ^camera, _signaling}, 2_500
    end

    test "survives the sink exiting abnormally, and attaches again",
         %{conn: conn, robot: robot} do
      camera = source!(robot)
      {:ok, view, _html} = mount_host(conn, robot)
      assert_receive {FakeVideoSource, :attached, ^camera, first}

      # What Membrane.WebRTC.Sink does when ICE fails. The signaling exits
      # with the same reason, which a link would pass on to the LiveView.
      first |> FakeSink.start() |> FakeSink.stop({:shutdown, :connection_failed})

      assert_receive {FakeVideoSource, :attached, ^camera, second}
      assert second != first
      assert Process.alive?(view.pid)
      assert sessions(view) == ["2"]
    end

    test "removes the tile when the source exits", %{conn: conn, robot: robot} do
      source!(robot)
      {:ok, view, _html} = mount_host(conn, robot)
      assert_receive {FakeVideoSource, :attached, _camera, signaling}

      :ok = stop_supervised({FakeVideoSource, @camera})

      eventually(fn -> not has_element?(view, ".bb-video-tile") end)
      assert_closed(signaling)
      assert has_element?(view, ".bb-images-empty")
    end

    test "the source forgets a viewer whose LiveView exits", %{conn: conn, robot: robot} do
      Process.flag(:trap_exit, true)
      camera = source!(robot)
      {:ok, view, _html} = mount_host(conn, robot)
      assert_receive {FakeVideoSource, :attached, ^camera, signaling}
      signaling_ref = Process.monitor(signaling.pid)

      Process.exit(view.pid, :kill)

      assert_receive {:DOWN, ^signaling_ref, :process, _pid, _reason}
      eventually(fn -> FakeVideoSource.attached(camera) == [] end)
    end
  end

  describe "signaling" do
    setup %{conn: conn, robot: robot} do
      camera = source!(robot)
      {:ok, view, _html} = mount_host(conn, robot)
      assert_receive {FakeVideoSource, :attached, ^camera, signaling}

      %{view: view, sink: FakeSink.start(signaling), tile: tile_id(view, "base_link.camera")}
    end

    test "pushes the sink's offer and candidates to the tile's hook",
         %{view: view, sink: sink, tile: tile} do
      FakeSink.signal(sink, %SessionDescription{type: :offer, sdp: "v=0\r\noffer"})

      assert_push_event(view, "bb_video_signal", %{
        tile: ^tile,
        session: 1,
        type: "sdp_offer",
        data: %{"type" => "offer", "sdp" => "v=0\r\noffer"}
      })

      FakeSink.signal(sink, %ICECandidate{
        candidate: "candidate:1 1 UDP 2122260223 192.168.1.10 50000 typ host",
        sdp_mid: "0",
        sdp_m_line_index: 0,
        username_fragment: "ufrag"
      })

      assert_push_event(view, "bb_video_signal", %{
        tile: ^tile,
        session: 1,
        type: "ice_candidate",
        data: %{"candidate" => "candidate:1 1 UDP " <> _, "sdpMid" => "0", "sdpMLineIndex" => 0}
      })
    end

    test "passes the browser's answer and candidates to the sink",
         %{view: view, sink: sink, tile: tile} do
      images = with_target(view, "#images")

      render_hook(images, "video_signal", %{
        tile: tile,
        session: 1,
        type: "sdp_answer",
        data: %{type: "answer", sdp: "v=0\r\nanswer"}
      })

      assert_receive {FakeSink, ^sink, %SessionDescription{type: :answer, sdp: "v=0\r\nanswer"}}

      candidate = "candidate:2 1 udp 2113937151 192.168.1.20 60000 typ host"

      render_hook(images, "video_signal", %{
        tile: tile,
        session: 1,
        type: "ice_candidate",
        data: %{candidate: candidate, sdpMid: "0", sdpMLineIndex: 0, usernameFragment: "u"}
      })

      assert_receive {FakeSink, ^sink, %ICECandidate{candidate: ^candidate, sdp_mid: "0"}}
    end

    test "drops browser messages for another session or of the wrong shape",
         %{view: view, sink: sink, tile: tile} do
      images = with_target(view, "#images")
      answer = %{type: "answer", sdp: "v=0\r\nanswer"}

      for payload <- [
            %{tile: tile, session: 0, type: "sdp_answer", data: answer},
            %{tile: "images-video-elsewhere", session: 1, type: "sdp_answer", data: answer},
            %{tile: tile, session: 1, type: "sdp_offer", data: %{type: "offer", sdp: "v=0"}},
            %{tile: tile, session: 1, type: "sdp_answer", data: %{type: "bogus", sdp: "v=0"}},
            %{tile: tile, session: 1, type: "ice_candidate", data: %{candidate: "candidate:x"}},
            %{tile: tile, session: 1, type: "ice_candidate", data: nil},
            %{tile: tile}
          ] do
        render_hook(images, "video_signal", payload)
      end

      refute_receive {FakeSink, ^sink, _message}, 100
      assert Process.alive?(view.pid)
    end

    test "drops the sink's messages once the tile has moved on",
         %{view: view, sink: sink} do
      send(view.pid, {:set_active, false})
      render(view)

      FakeSink.signal(sink, %SessionDescription{type: :offer, sdp: "v=0\r\nlate"})

      refute_push_event(view, "bb_video_signal", %{}, 100)
    end
  end

  describe "image tiles" do
    test "hides the image tile of a path with a video source, until it goes",
         %{conn: conn, robot: robot} do
      source!(robot, @camera)
      {:ok, view, _html} = mount_host(conn, robot, %{"push_interval_ms" => 1})
      assert_receive {FakeVideoSource, :attached, _camera, _signaling}

      inject(view, @camera, image(:rgb8))
      inject(view, @depth, image(:mono8))

      assert has_element?(view, "canvas[id^='images-canvas-mast-depth-']")
      refute has_element?(view, "canvas[id^='images-canvas-base_link-camera-']")
      assert_push_event(view, "bb_image_frame", %{encoding: "mono8"})
      refute_push_event(view, "bb_image_frame", %{encoding: "rgb8"}, 50)

      :ok = stop_supervised({FakeVideoSource, @camera})

      eventually(fn -> has_element?(view, "canvas[id^='images-canvas-base_link-camera-']") end)
      assert_push_event(view, "bb_image_frame", %{encoding: "rgb8"})
    end
  end
end
