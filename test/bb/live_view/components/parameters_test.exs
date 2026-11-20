# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.ParametersTest do
  use BB.LiveView.FeatureCase

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  alias BB.LiveView.ParameterRobot
  alias BB.Parameter

  describe "parameters component" do
    test "renders parameters container", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-parameters")
    end

    test "shows no parameters message when robot has no parameters", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-empty-state-message", text: "No parameters defined")
    end
  end

  describe "unit-typed parameters" do
    setup do
      start_supervised!(ParameterRobot)
      :ok
    end

    test "renders a bounded parameter as a slider over its magnitudes", %{conn: conn} do
      conn
      |> visit("/parameter_robot")
      |> assert_has(
        ~s([id="slider-motion.trim"] input[type="range"][min="-30"][max="30"][step="0.6"][value="0"])
      )
      |> assert_has(~s([id="slider-motion.trim"] .bb-unit-label), text: "degree")
    end

    test "renders an unbounded parameter as its magnitude", %{conn: conn} do
      conn
      |> visit("/parameter_robot")
      |> assert_has(~s(.bb-number-input input[value="0.5"]))
      |> assert_has(".bb-number-input .bb-unit-label", text: "meter")
    end

    test "shows a value stored in a compatible unit in the declared unit", %{conn: conn} do
      radians = Localize.Unit.new!(0.26, "radian")
      :ok = Parameter.set(ParameterRobot, [:motion, :trim], radians)

      degrees = Localize.Unit.convert!(radians, "degree")

      conn
      |> visit("/parameter_robot")
      |> assert_has(~s([id="slider-motion.trim"] input[value="#{degrees.value}"]))
      |> assert_has(~s([id="slider-motion.trim"] .bb-unit-label), text: "degree")
    end
  end

  # Every write goes through the rendered form rather than a hand-built payload,
  # because the parameter each input writes to is carried by the markup: a test
  # that supplies the path itself passes against inputs a browser can't use.
  describe "editing a parameter" do
    setup %{conn: conn} do
      start_supervised!(ParameterRobot)
      {:ok, view, _html} = live(conn, "/parameter_robot")
      %{view: view}
    end

    test "the slider writes the magnitude in the declared unit", %{view: view} do
      view
      |> form(~s([id="param-range-motion.trim"]), %{"value" => "20"})
      |> render_change()

      assert {:ok, %Localize.Unit{value: 20.0, name: "degree"}} =
               Parameter.get(ParameterRobot, [:motion, :trim])
    end

    test "the slider's number input writes the magnitude in the declared unit", %{view: view} do
      view
      |> form(~s([id="param-number-motion.trim"]), %{"value" => "15"})
      |> render_change()

      assert {:ok, %Localize.Unit{value: 15.0, name: "degree"}} =
               Parameter.get(ParameterRobot, [:motion, :trim])
    end

    test "an unbounded parameter's number input writes the magnitude", %{view: view} do
      view
      |> form(~s([id="param-number-motion.reach"]), %{"value" => "1.25"})
      |> render_change()

      assert {:ok, %Localize.Unit{value: 1.25, name: "meter"}} =
               Parameter.get(ParameterRobot, [:motion, :reach])
    end

    test "an integer slider writes an integer", %{view: view} do
      view
      |> form(~s([id="param-range-motion.taps"]), %{"value" => "12"})
      |> render_change()

      assert {:ok, 12} = Parameter.get(ParameterRobot, [:motion, :taps])
    end

    test "an atom input writes the atom", %{view: view} do
      view
      |> form(~s([id="param-atom-motion.profile"]), %{"value" => ":cubic"})
      |> render_change()

      assert {:ok, :cubic} = Parameter.get(ParameterRobot, [:motion, :profile])
    end

    test "an atom the runtime has never seen is refused, not crashed on", %{view: view} do
      html =
        view
        |> form(~s([id="param-atom-motion.profile"]), %{"value" => "not_a_known_profile"})
        |> render_change()

      assert html =~ "bb-error-message"
      assert {:ok, :linear} = Parameter.get(ParameterRobot, [:motion, :profile])
    end

    test "a text input writes the string", %{view: view} do
      view
      |> form(~s([id="param-text-motion.label"]), %{"value" => "shoulder"})
      |> render_change()

      assert {:ok, "shoulder"} = Parameter.get(ParameterRobot, [:motion, :label])
    end

    test "the toggle flips a boolean", %{view: view} do
      view
      |> element(~s(input[type="checkbox"][phx-value-path="motion.inverted"]))
      |> render_click()

      assert {:ok, true} = Parameter.get(ParameterRobot, [:motion, :inverted])
    end
  end

  # The widget re-renders from the change notification the runtime publishes,
  # not from what was typed, so these wait for that round trip.
  describe "showing a change" do
    setup %{conn: conn} do
      start_supervised!(ParameterRobot)
      {:ok, view, _html} = live(conn, "/parameter_robot")
      %{view: view}
    end

    test "moving a slider updates the number input beside it", %{view: view} do
      view
      |> form(~s([id="param-range-motion.gain"]), %{"value" => "0.8"})
      |> render_change()

      assert eventually(fn ->
               has_element?(view, ~s([id="param-number-motion.gain"] input[value="0.8"]))
             end)
    end

    test "a change made elsewhere updates the inputs", %{view: view} do
      :ok = Parameter.set(ParameterRobot, [:motion, :taps], 12)

      assert eventually(fn ->
               has_element?(view, ~s([id="param-range-motion.taps"] input[value="12"])) and
                 has_element?(view, ~s([id="param-number-motion.taps"] input[value="12"]))
             end)
    end

    test "a change to an unbounded parameter updates its number input", %{view: view} do
      :ok = Parameter.set(ParameterRobot, [:motion, :reach], Localize.Unit.new!(1.25, "meter"))

      assert eventually(fn ->
               has_element?(view, ~s([id="param-number-motion.reach"] input[value="1.25"]))
             end)
    end
  end

  describe "refused writes" do
    setup %{conn: conn} do
      start_supervised!(ParameterRobot)
      {:ok, view, _html} = live(conn, "/parameter_robot")
      %{view: view}
    end

    test "shows the refusal rather than swallowing it", %{view: view} do
      html =
        view
        |> form(~s([id="param-number-motion.trim"]), %{"value" => "45"})
        |> render_change()

      assert html =~ "less than or equal to 30 degree"
    end

    test "clears the refusal once a write is accepted", %{view: view} do
      selector = ~s([id="param-number-motion.trim"])

      view |> form(selector, %{"value" => "45"}) |> render_change()
      html = view |> form(selector, %{"value" => "15"}) |> render_change()

      refute html =~ "bb-error-message"
    end
  end

  defp eventually(fun, attempts \\ 20) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
