# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Router do
  @moduledoc """
  Provides router helpers for mounting the BB Dashboard.

  ## Usage

  In your Phoenix router:

      import BB.LiveView.Router

      scope "/" do
        pipe_through :browser
        bb_dashboard "/robot", robot: MyRobot
      end

  The dashboard can be mounted multiple times at different paths for different robots:

      bb_dashboard "/arm", robot: ArmRobot
      bb_dashboard "/base", robot: BaseRobot

  ## Options

    * `:robot` - Required. The robot module to control. Must define a `robot/0` function.
    * `:drive` - Optional. Adds a Drive widget for hold-to-drive with the
      keyboard or an on-screen pad. See `BB.LiveView.Drive`.

  ## Authentication

  Protect the dashboard using standard Phoenix pipelines:

      pipeline :admin do
        plug MyAppWeb.RequireAdmin
      end

      scope "/admin" do
        pipe_through [:browser, :admin]
        bb_dashboard "/robot", robot: MyRobot
      end
  """

  @doc """
  Defines routes for mounting the BB Dashboard at the given path.

  See the module documentation for usage examples.
  """
  defmacro bb_dashboard(path, opts) do
    quote bind_quoted: binding() do
      robot = Keyword.fetch!(opts, :robot)

      drive =
        case Keyword.fetch(opts, :drive) do
          {:ok, drive_opts} -> BB.LiveView.Drive.new!(drive_opts)
          :error -> nil
        end

      scope path, alias: false, as: false do
        import Phoenix.LiveView.Router, only: [live: 3, live: 4, live_session: 3]

        # Asset routes
        get(
          "/__bb_assets__/:file",
          BB.LiveView.Plugs.Static,
          :call,
          as: :bb_dashboard_asset,
          private: %{bb_dashboard_asset: true}
        )

        live_session :"bb_dashboard_#{robot}",
          on_mount: [
            {BB.LiveView.Hooks.AssignRobot, robot},
            {BB.LiveView.Hooks.AssignDrive, drive}
          ],
          root_layout: {BB.LiveView.Layouts, :root} do
          live("/", BB.LiveView.DashboardLive, :index)
        end
      end
    end
  end
end
