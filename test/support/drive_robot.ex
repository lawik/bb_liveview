# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.DriveRobot do
  @moduledoc """
  A minimal robot mounted with a `:drive` option, for the Drive widget tests.
  """
  use BB

  settings do
    name(:drive_robot)
  end

  topology do
    link :base_link do
    end
  end
end

defmodule BB.LiveView.DriveRecorder do
  @moduledoc """
  Drive functions for the tests: each call is sent to the process registered
  as `:drive_test_listener`.
  """

  def tick(robot, throttle, turn), do: notify({:tick, robot, throttle, turn})
  def stop(robot), do: notify({:stop, robot})

  defp notify(message) do
    if pid = Process.whereis(:drive_test_listener), do: send(pid, message)
    :ok
  end
end
