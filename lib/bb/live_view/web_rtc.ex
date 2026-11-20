# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.WebRTC do
  @moduledoc false
  # The dashboard's end of `Membrane.WebRTC.Signaling`, the browser's peer.
  #
  # membrane_webrtc_plugin is optional, so nothing here may be called unless
  # `available?/0` says it's loaded. Availability is checked at run time
  # rather than by compiling one of two versions of this module: the type
  # checker would see a constant, and warn about dead branches in callers in
  # whichever build lacks or has the plugin.

  @compile {:no_warn_undefined, Membrane.WebRTC.Signaling}

  alias Membrane.WebRTC.Signaling

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Signaling)

  @doc """
  Starts a signaling with the calling process registered as the browser's
  peer, exchanging JSON-shaped messages.

  The signaling is not linked to the caller. It stops with the sink's exit
  reason when the sink goes down, and a sink that fails its connection exits
  with `{:shutdown, :connection_failed}`, so a link would take the LiveView
  down with it. It still stops when the caller exits, because it monitors its
  peers. Callers monitor it to learn that the stream ended.
  """
  @spec open() :: struct()
  def open do
    # `Signaling.start/0` would avoid the link, but only exists from 0.26.5.
    signaling = Signaling.new()
    Process.unlink(signaling.pid)
    :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())
    signaling
  end

  @spec pid(struct()) :: pid()
  def pid(%{pid: pid}), do: pid

  @doc "Sends the browser's SDP answer or ICE candidate to the sink."
  @spec signal(struct(), String.t(), map()) :: :ok
  def signal(signaling, type, data) do
    Signaling.signal(signaling, %{"type" => type, "data" => data})
  end

  @spec close(struct()) :: :ok
  def close(%{pid: pid}) do
    # Usually already stopping: the sink's removal stops it too.
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end
end
