# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.TestRouter do
  @moduledoc """
  Test router for BB Dashboard integration tests.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  import Plug.Conn
  import Phoenix.Controller
  import BB.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BB.LiveView.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)
    bb_dashboard("/robot", robot: BB.LiveView.TestRobot)
    bb_dashboard("/command_robot", robot: BB.LiveView.CommandRobot)
    bb_dashboard("/joint_robot", robot: BB.LiveView.JointRobot)
    bb_dashboard("/planar_robot", robot: BB.LiveView.PlanarRobot)
    bb_dashboard("/parameter_robot", robot: BB.LiveView.ParameterRobot)

    bb_dashboard("/drive_robot",
      robot: BB.LiveView.DriveRobot,
      drive: [
        publish: {BB.LiveView.DriveRecorder, :tick},
        stop: {BB.LiveView.DriveRecorder, :stop},
        throttle_scale: 0.5
      ]
    )
  end
end
