# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.DriveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BB.LiveView.Drive
  alias BB.LiveView.DriveRobot

  @endpoint BB.LiveView.TestEndpoint

  setup do
    Process.register(self(), :drive_test_listener)
    start_supervised!(DriveRobot)
    {:ok, conn: build_conn()}
  end

  defp drive_view(conn) do
    {:ok, view, _html} = live(conn, "/drive_robot")
    # Let the dashboard finish loading.
    render(view)
    view
  end

  defp take_control(view) do
    view |> element("#drive button", "Take control") |> render_click()
    view
  end

  defp hook(view, event, params), do: view |> element("#drive") |> render_hook(event, params)

  test "only appears when the dashboard has a drive", %{conn: conn} do
    view = drive_view(conn)
    assert has_element?(view, "#drive")

    {:ok, plain, _html} = live(conn, "/robot")
    render(plain)
    refute has_element?(plain, "#drive")
  end

  test "ignores ticks until control is taken", %{conn: conn} do
    view = drive_view(conn)
    assert has_element?(view, "#drive[data-in-control=false]")

    hook(view, "drive", %{"throttle" => 1, "turn" => 0})
    refute_receive {:tick, _, _, _}
  end

  test "ticks call publish with the scaled, clamped command", %{conn: conn} do
    view = conn |> drive_view() |> take_control()
    assert has_element?(view, "#drive[data-in-control=true]")

    hook(view, "drive", %{"throttle" => 1, "turn" => -1})
    assert_receive {:tick, DriveRobot, 0.5, -1.0}

    # Out-of-range values are clamped before scaling.
    hook(view, "drive", %{"throttle" => -7, "turn" => 3})
    assert_receive {:tick, DriveRobot, -0.5, 1.0}

    assert render(view) =~ "throttle -0.50 · turn 1.00"
  end

  test "drive_stop and releasing control both call stop", %{conn: conn} do
    view = conn |> drive_view() |> take_control()

    hook(view, "drive_stop", %{})
    assert_receive {:stop, DriveRobot}

    view |> element("#drive button", "Release control") |> render_click()
    assert_receive {:stop, DriveRobot}
    assert has_element?(view, "#drive[data-in-control=false]")
  end

  test "malformed ticks are ignored", %{conn: conn} do
    view = conn |> drive_view() |> take_control()

    hook(view, "drive", %{"throttle" => "fast", "turn" => 0})
    refute_receive {:tick, _, _, _}
  end

  test "warns while the robot is disarmed", %{conn: conn} do
    view = conn |> drive_view() |> take_control()
    assert has_element?(view, ".bb-drive-warning", "disarmed")
  end

  describe "BB.LiveView.Drive" do
    test "new!/1 requires publish and stop" do
      assert_raise Spark.Options.ValidationError, fn -> Drive.new!(publish: {M, :f}) end
    end

    test "available?/1 checks the functions exist" do
      assert Drive.available?(
               Drive.new!(
                 publish: {BB.LiveView.DriveRecorder, :tick},
                 stop: {BB.LiveView.DriveRecorder, :stop}
               )
             )

      refute Drive.available?(
               Drive.new!(publish: {BB.LiveView.DriveRecorder, :nope}, stop: {Nope, :stop})
             )
    end
  end
end
