# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.ImagesTest do
  @moduledoc """
  Tests for the `Images` component: tile discovery, frame pushes, the
  throttle and the active-tab gating.

  The component is hosted in `BB.LiveView.ImagesHostLive` with short
  intervals so the throttle can be observed without waiting on the defaults.
  """

  use BB.LiveView.ConnCase

  import Phoenix.LiveViewTest

  alias BB.LiveView.ImagesHostLive
  alias BB.Message.Sensor.Image

  @push_interval_ms 50
  @camera [:sensor, :base_link, :camera]
  @depth [:sensor, :mast, :depth]

  defp mount_host(conn, session \\ %{}) do
    session = Map.merge(%{"push_interval_ms" => @push_interval_ms, "active" => true}, session)
    live_isolated(conn, ImagesHostLive, session: session)
  end

  defp image(opts \\ []) do
    width = Keyword.get(opts, :width, 2)
    height = Keyword.get(opts, :height, 2)
    encoding = Keyword.get(opts, :encoding, :rgb8)
    bytes_per_pixel = %{rgb8: 3, rgba8: 4, mono8: 1, mono16: 2}[encoding]
    step = width * bytes_per_pixel
    data = Keyword.get(opts, :data, :binary.copy(<<Keyword.get(opts, :fill, 0)>>, step * height))

    {:ok, message} =
      Image.new(:camera,
        width: width,
        height: height,
        encoding: encoding,
        step: step,
        data: data
      )

    message
  end

  defp inject(view, path, message) do
    send(view.pid, {:inject, path, message})
    settle(view)
  end

  # The host forwards an injected message with `send_update/3`, which queues
  # behind a render request that's already waiting. The first render flushes
  # that; the second sees the update applied.
  defp settle(view) do
    render(view)
    render(view)
  end

  describe "tiles" do
    test "shows an empty state before any image arrives", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      assert has_element?(view, ".bb-images-empty", "No image sensors yet")
      refute has_element?(view, ".bb-image-tile")
    end

    test "adds one tile per sensor path, labelled with its geometry", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, @camera, image(width: 4, height: 2))
      inject(view, @depth, image(width: 2, height: 2, encoding: :mono16))

      assert has_element?(view, ".bb-image-tile", "base_link.camera")
      assert has_element?(view, ".bb-image-tile", "4×2 · rgb8")
      assert has_element?(view, ".bb-image-tile", "mast.depth")
      assert has_element?(view, ".bb-image-tile", "2×2 · mono16")
      refute has_element?(view, ".bb-images-empty")
      assert view |> render() |> Floki.parse_document!() |> Floki.find("canvas") |> length() == 2
    end

    test "follows a sensor that changes size or encoding", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, @camera, image(width: 4, height: 2))
      inject(view, @camera, image(width: 2, height: 2, encoding: :mono8))

      assert has_element?(view, ".bb-image-tile", "2×2 · mono8")
      refute has_element?(view, ".bb-image-tile", "4×2")
      assert view |> render() |> Floki.parse_document!() |> Floki.find("canvas") |> length() == 1
    end

    test "reports the measured frame rate", %{conn: conn} do
      {:ok, view, _html} =
        mount_host(conn, %{"stats_interval_ms" => 100, "push_interval_ms" => 1})

      for _ <- 1..5, do: inject(view, @camera, image())
      Process.sleep(150)
      settle(view)

      assert view |> element(".bb-image-meta") |> render() =~ ~r/\d+\.\d fps/
    end
  end

  describe "pushing frames" do
    test "pushes a frame as base64 with its geometry", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)
      data = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12>>

      inject(view, @camera, image(data: data))

      expected = Base.encode64(data)

      assert_push_event(view, "bb_image_frame", %{
        canvas: "images-canvas-base_link-camera-" <> _hash,
        width: 2,
        height: 2,
        step: 6,
        encoding: "rgb8",
        is_bigendian: false,
        data: ^expected
      })
    end

    test "gives each sensor's frames its own canvas", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, @camera, image())
      inject(view, @depth, image(encoding: :mono8))

      assert_push_event(view, "bb_image_frame", %{canvas: camera_canvas, encoding: "rgb8"})
      assert_push_event(view, "bb_image_frame", %{canvas: depth_canvas, encoding: "mono8"})
      assert camera_canvas != depth_canvas
      assert has_element?(view, "canvas##{camera_canvas}")
      assert has_element?(view, "canvas##{depth_canvas}")
    end

    test "sends nothing while inactive", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn, %{"active" => false})

      inject(view, @camera, image())

      refute_push_event(view, "bb_image_frame", %{}, @push_interval_ms * 3)
      # The tile is still discovered, ready for when the tab is shown.
      assert has_element?(view, ".bb-image-tile", "base_link.camera")
    end

    test "sends the newest frame of each sensor on becoming active", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn, %{"active" => false})

      inject(view, @camera, image(fill: 1))
      inject(view, @camera, image(fill: 2))
      refute_push_event(view, "bb_image_frame", %{}, 10)

      send(view.pid, {:set_active, true})

      newest = Base.encode64(:binary.copy(<<2>>, 12))
      assert_push_event(view, "bb_image_frame", %{data: ^newest})
      refute_push_event(view, "bb_image_frame", %{}, @push_interval_ms * 3)
    end

    test "throttles a burst to the newest frame instead of queueing", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn, %{"push_interval_ms" => 200})

      for fill <- 1..5, do: inject(view, @camera, image(fill: fill))

      first = Base.encode64(:binary.copy(<<1>>, 12))
      last = Base.encode64(:binary.copy(<<5>>, 12))

      # The first frame goes straight out; the rest of the burst lands inside
      # the throttle window and collapses into one trailing push of the last.
      assert_push_event(view, "bb_image_frame", %{data: ^first})
      assert_push_event(view, "bb_image_frame", %{data: ^last}, 500)
      refute_push_event(view, "bb_image_frame", %{}, 300)
    end
  end
end
