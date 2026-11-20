# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Hooks.AssignDrive do
  @moduledoc """
  LiveView on_mount hook that assigns the dashboard's drive configuration
  (`BB.LiveView.Drive`, or `nil` without one) as `:drive`.

  Applied by the `bb_dashboard/2` router macro.
  """

  import Phoenix.Component

  @doc false
  def on_mount(drive, _params, _session, socket) do
    {:cont, assign(socket, :drive, drive)}
  end
end
