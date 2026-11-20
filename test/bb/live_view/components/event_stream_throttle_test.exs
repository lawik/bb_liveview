# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.EventStreamThrottleTest do
  @moduledoc """
  Tests for `EventStream`'s debounce + flush behaviour.

  Uses a tiny host LiveView (`BB.LiveView.EventStreamHostLive`) so the
  component can be mounted in isolation with short intervals; otherwise
  tests would have to wait the full production defaults.
  """

  use BB.LiveView.ConnCase

  import Phoenix.LiveViewTest

  alias BB.LiveView.EventStreamHostLive
  alias BB.Message
  alias BB.Message.Sensor.BatteryState
  alias BB.Message.Sensor.JointState

  @flush_interval_ms 20
  @debounce_window_ms 100

  defp mount_host(conn, opts \\ %{}) do
    session =
      Map.merge(
        %{
          "flush_interval_ms" => @flush_interval_ms,
          "debounce_window_ms" => @debounce_window_ms
        },
        opts
      )

    live_isolated(conn, EventStreamHostLive, session: session)
  end

  defp joint_state_message(position \\ 0.0) do
    %Message{
      wall_time: System.os_time(:nanosecond),
      payload: %JointState{names: [:joint1], positions: [position], velocities: [], efforts: []}
    }
  end

  defp battery_state_message do
    %Message{
      wall_time: System.os_time(:nanosecond),
      payload: %BatteryState{voltage: 12.0}
    }
  end

  defp inject(view, path, message), do: send(view.pid, {:inject, path, message})

  defp wait_for_flush, do: Process.sleep(@flush_interval_ms * 3)

  describe "flush" do
    test "buffers a new message until the flush interval elapses", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, [:sensor, :imu], joint_state_message())

      assert render(view) =~ "0 messages"

      wait_for_flush()

      assert render(view) =~ "1 messages"
    end

    test "batches multiple distinct messages into one render", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, [:sensor, :imu], joint_state_message())
      inject(view, [:sensor, :battery], battery_state_message())

      assert render(view) =~ "0 messages"

      wait_for_flush()

      assert render(view) =~ "2 messages"
    end

    test "schedules a fresh flush for messages arriving after the previous one fired",
         %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, [:sensor, :imu], joint_state_message())
      wait_for_flush()
      assert render(view) =~ "1 messages"

      inject(view, [:sensor, :battery], battery_state_message())
      wait_for_flush()
      assert render(view) =~ "2 messages"
    end
  end

  describe "debounce" do
    test "drops repeats of the same path + payload type within the window", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      for _ <- 1..5 do
        inject(view, [:sensor, :imu], joint_state_message())
      end

      wait_for_flush()

      assert render(view) =~ "1 messages"
    end

    test "lets different payload types from the same path through", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, [:sensor, :imu], joint_state_message())
      inject(view, [:sensor, :imu], battery_state_message())

      wait_for_flush()

      assert render(view) =~ "2 messages"
    end

    test "lets the same payload type from different paths through", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, [:sensor, :imu], joint_state_message())
      inject(view, [:sensor, :arm], joint_state_message())

      wait_for_flush()

      assert render(view) =~ "2 messages"
    end

    test "shows the newest repeat once the window closes", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      for position <- [0.1, 0.2, 0.3] do
        inject(view, [:sensor, :imu], joint_state_message(position))
      end

      wait_for_flush()
      assert render(view) =~ "1 messages"

      Process.sleep(@debounce_window_ms)
      wait_for_flush()

      html = render(view)
      assert html =~ "2 messages"
      assert html =~ "[0.100]"
      assert html =~ "[0.300]"
      refute html =~ "[0.200]"
    end

    test "a repeat held back while paused is dropped", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, [:sensor, :imu], joint_state_message(0.1))
      inject(view, [:sensor, :imu], joint_state_message(0.2))
      wait_for_flush()

      view |> element("button", "Pause") |> render_click()

      Process.sleep(@debounce_window_ms)
      wait_for_flush()

      html = render(view)
      assert html =~ "1 messages"
      refute html =~ "[0.200]"
    end

    test "accepts another message once the debounce window has elapsed", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      inject(view, [:sensor, :imu], joint_state_message())
      wait_for_flush()
      assert render(view) =~ "1 messages"

      Process.sleep(@debounce_window_ms)

      inject(view, [:sensor, :imu], joint_state_message())
      wait_for_flush()
      assert render(view) =~ "2 messages"
    end
  end

  describe "interaction with paused" do
    test "skips both buffering and debounce tracking when paused", %{conn: conn} do
      {:ok, view, _html} = mount_host(conn)

      view
      |> element("button", "Pause")
      |> render_click()

      inject(view, [:sensor, :imu], joint_state_message())
      wait_for_flush()

      assert render(view) =~ "0 messages"

      view
      |> element("button", "Resume")
      |> render_click()

      inject(view, [:sensor, :imu], joint_state_message())
      wait_for_flush()

      assert render(view) =~ "1 messages"
    end
  end
end
