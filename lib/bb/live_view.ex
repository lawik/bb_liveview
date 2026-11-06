# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView do
  @moduledoc """
  Interactive LiveView-based dashboard for Beam Bots-powered robots.

  BB.LiveView provides a self-contained dashboard that can be mounted into any
  Phoenix application with a single router macro.

  ## Quick Start

  1. Add `bb_liveview` to your dependencies in `mix.exs`:

      ```elixir
      def deps do
        [
          {:bb_liveview, "~> 0.1"}
        ]
      end
      ```

  2. Mount the dashboard in your router:

      ```elixir
      import BB.LiveView.Router

      scope "/" do
        pipe_through :browser
        bb_dashboard "/robot", robot: MyRobot
      end
      ```

  3. Visit `/robot` in your browser.

  ## Features

  The dashboard provides:

  - **Safety Controls**: Arm/disarm the robot with real-time status
  - **Joint Control**: Slider controls for all movable joints
  - **Event Stream**: Real-time PubSub message monitoring
  - **Command Execution**: Execute robot commands with dynamic forms
  - **3D Visualisation**: Interactive Three.js robot viewer
  - **Images**: Live feeds from every image sensor, in a tab beside the 3D view
  - **Parameters**: Edit robot parameters with type-aware inputs

  ## Multiple Robots

  You can mount multiple dashboards for different robots:

      bb_dashboard "/arm", robot: ArmRobot
      bb_dashboard "/base", robot: BaseRobot

  ## Authentication

  Protect the dashboard using standard Phoenix pipelines:

      pipeline :admin do
        plug MyApp.RequireAdmin
      end

      scope "/admin" do
        pipe_through [:browser, :admin]
        bb_dashboard "/robot", robot: MyRobot
      end
  """
end
