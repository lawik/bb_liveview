# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Drive do
  @schema Spark.Options.new!(
            publish: [
              type: {:tuple, [:atom, :atom]},
              required: true,
              doc:
                "`{module, function}` called as `function(robot, throttle, turn)` on every tick."
            ],
            stop: [
              type: {:tuple, [:atom, :atom]},
              required: true,
              doc: "`{module, function}` called as `function(robot)` when driving stops."
            ],
            rate: [
              type: :pos_integer,
              default: 20,
              doc: "Ticks per second while a drive key is held."
            ],
            throttle_scale: [
              type: {:or, [:float, :integer]},
              default: 1.0,
              doc: "Multiplies the throttle."
            ],
            turn_scale: [
              type: {:or, [:float, :integer]},
              default: 1.0,
              doc: "Multiplies the turn."
            ]
          )

  @moduledoc """
  Hold-to-drive for the dashboard: the `:drive` option of
  `BB.LiveView.Router.bb_dashboard/2`.

      bb_dashboard "/robot",
        robot: MyRobot,
        drive: [publish: {MyRobot.Drive, :tick}, stop: {MyRobot.Drive, :stop}]

  With it the dashboard gets a Drive widget. Once its user takes control, the
  arrow keys (or WASD) and an on-screen pad set a throttle (up/down) and a turn
  (left/right) of -1, 0 or 1, scaled by `:throttle_scale` and `:turn_scale`.
  While one is held, the browser asks for a tick `:rate` times a second and
  `publish` is called as `publish(robot, throttle, turn)`; when they are all
  let go, `stop(robot)` is called. Turn is positive to the left.

  This is the same contract as bb_tui's drive extension, so one pair of
  functions serves both.

  ## Making `publish` safe

  Ticks come from the browser, so they stop arriving if it hangs, loses its
  connection or is closed, and `stop` may then never be called. `publish`
  should leave the robot moving only for a short while (a few ticks' worth),
  so that it stops by itself when the ticks do. For example, by sending a
  velocity command with a duration:

      def tick(robot, throttle, _turn) do
        BB.Actuator.set_velocity(robot, :drive_motor, throttle * @max_speed, duration: 250)
      end

  ## Options

  #{Spark.Options.docs(@schema)}
  """

  require Logger

  defstruct [:publish, :stop, :rate, :throttle_scale, :turn_scale]

  @type t :: %__MODULE__{
          publish: {module(), atom()},
          stop: {module(), atom()},
          rate: pos_integer(),
          throttle_scale: number(),
          turn_scale: number()
        }

  @doc """
  Validates the `:drive` option, raising `Spark.Options.ValidationError` if
  it's malformed. Called when the router compiles.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    struct!(__MODULE__, Spark.Options.validate!(opts, @schema))
  end

  @doc "Whether the `publish` and `stop` functions exist."
  @spec available?(t()) :: boolean()
  def available?(%__MODULE__{publish: {pmod, pfun}, stop: {smod, sfun}}) do
    exported?(pmod, pfun, 3) and exported?(smod, sfun, 1)
  end

  @doc """
  Calls `publish` with the throttle and turn, each clamped to -1.0..1.0 and
  then scaled. Returns the values sent.
  """
  @spec tick(t(), module(), number(), number()) :: {float(), float()}
  def tick(%__MODULE__{} = drive, robot, throttle, turn) do
    throttle = clamp(throttle) * drive.throttle_scale
    turn = clamp(turn) * drive.turn_scale
    call(drive.publish, [robot, throttle, turn])
    {throttle, turn}
  end

  @doc "Calls `stop`."
  @spec stop(t(), module()) :: :ok
  def stop(%__MODULE__{} = drive, robot) do
    call(drive.stop, [robot])
    :ok
  end

  defp clamp(value) when is_number(value), do: value |> max(-1.0) |> min(1.0) |> Kernel.*(1.0)

  defp exported?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  # A failing drive function is the host's bug, not a reason to take the
  # dashboard down with it.
  defp call({module, function}, args) do
    apply(module, function, args)
  rescue
    error ->
      Logger.warning(
        "#{inspect(module)}.#{function}/#{length(args)} raised: #{Exception.message(error)}"
      )
  catch
    kind, reason ->
      Logger.warning(
        "#{inspect(module)}.#{function}/#{length(args)} failed: #{kind} #{inspect(reason)}"
      )
  end
end
