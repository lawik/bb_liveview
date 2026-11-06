# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.VisualisationTest do
  use BB.LiveView.FeatureCase

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  alias BB.LiveView.PlanarRobot
  alias BB.Math.Transform2D
  alias BB.Message
  alias BB.Message.Sensor.Image
  alias BB.Message.Sensor.JointState
  alias BB.Robot.Runtime, as: RobotRuntime
  alias BB.Robot.State, as: RobotState

  describe "visualisation component" do
    test "renders visualisation container", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-visualisation")
    end

    test "has visualisation hook attached", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has("[phx-hook=Visualisation]")
    end
  end

  describe "multi-degree-of-freedom joints" do
    setup do
      start_supervised!(PlanarRobot)
      :ok
    end

    test "a planar joint's configuration renders as a pose", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/planar_robot")

      positions = rendered_positions(view)

      assert positions["shoulder"] == 0.0
      assert pose(positions["ground"]) == {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0}
    end

    test "a planar configuration is lifted through its plane normal", %{conn: conn} do
      set_ground(Transform2D.new(1.0, 2.0, :math.pi() / 2))

      {:ok, view, _html} = live(conn, "/planar_robot")

      assert pose(rendered_positions(view)["ground"]) ==
               {1.0, 2.0, 0.0, 0.0, 0.0, 0.707107, 0.707107}
    end

    test "a planar configuration is a pose when pushed to the client", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/planar_robot")

      {:ok, message} =
        Message.new(JointState, :simulated,
          names: [:ground],
          positions: [Transform2D.new(0.5, 0.0, 0.0)]
        )

      BB.publish(PlanarRobot, [:sensor, :simulated], message)

      assert_push_event(
        view,
        "positions_updated",
        %{positions: %{"ground" => %{xyz: %{x: x}, quat: %{w: w}}}},
        500
      )

      assert x == 0.5
      assert w == 1.0
    end
  end

  describe "image sensors" do
    setup do
      start_supervised!(PlanarRobot)
      :ok
    end

    test "Image messages from the robot reach the Images tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/planar_robot")

      {:ok, message} =
        Message.new(Image, :camera,
          width: 2,
          height: 1,
          encoding: :rgb8,
          step: 6,
          data: <<255, 0, 0, 0, 0, 255>>
        )

      BB.publish(PlanarRobot, [:sensor, :base_link, :camera], message)

      # Discovered while the 3D tab is showing, but not streamed until the
      # Images tab is.
      assert eventually(fn -> render(view) =~ "base_link.camera" end)
      refute_push_event(view, "bb_image_frame", %{}, 50)

      view |> element(".bb-vis-tabs button", "Images") |> render_click()

      expected = Base.encode64(<<255, 0, 0, 0, 0, 255>>)
      assert_push_event(view, "bb_image_frame", %{width: 2, height: 1, data: ^expected}, 500)

      # The event stream lists it too (after its 500 ms flush), without
      # dumping the pixels.
      assert eventually(fn -> has_element?(view, ".bb-event-field-value", "<<6 bytes>>") end, 100)
      assert String.valid?(render(view))
    end
  end

  defp eventually(fun, attempts \\ 20) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  defp set_ground(configuration) do
    :ok =
      PlanarRobot
      |> RobotRuntime.get_robot_state()
      |> RobotState.set_configuration(:ground, configuration)
  end

  defp rendered_positions(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute(".bb-visualisation", "data-positions")
    |> hd()
    |> Jason.decode!()
  end

  # Flattened and rounded, so a pose can be compared as a whole without
  # pattern matching on floats.
  defp pose(%{"xyz" => xyz, "quat" => quat}) do
    {round6(xyz["x"]), round6(xyz["y"]), round6(xyz["z"]), round6(quat["x"]), round6(quat["y"]),
     round6(quat["z"]), round6(quat["w"])}
  end

  defp round6(number), do: Float.round(number, 6)
end
