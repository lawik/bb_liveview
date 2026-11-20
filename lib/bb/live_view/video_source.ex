# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.VideoSource do
  @moduledoc """
  Video streams the dashboard plays over WebRTC.

  A process that can stream video, typically a camera sensor, registers itself
  with `register/3` under the PubSub path its other messages use, e.g.
  `[:sensor, :base_link, :camera]`. The registration lives in the robot's own
  registry, so it goes away with the process.

  For each viewer, the dashboard creates a `Membrane.WebRTC.Signaling`,
  registers itself as the browser's peer on it, and asks the source to stream
  to it with `attach/2`. The source then adds a `Membrane.WebRTC.Sink` on that
  signaling, which sends the SDP offer, and keeps streaming until `detach/2`
  or until the viewer process exits. Sources should therefore monitor the
  process that attached.

  A signaling carries exactly one stream: it takes one sink, and the viewer
  never reuses it after `detach/2` or `:ended`. It belongs to the viewer, so
  a source shouldn't link to it or stop it.

  Any codec the browser can decode works. H.264 constrained baseline with
  `video_codec: :h264`, `tracks: [:video]` and frequent keyframes starts
  quickly everywhere, and on a LAN `ice_servers: []` skips STUN.

  ## Calls a source handles

  These arrive as `GenServer.call/3`s; a BB sensor gets them in its
  `handle_call/3`. The viewer waits on them, so reply straight away and set
  the stream up asynchronously.

    * `{BB.LiveView.VideoSource, :attach, signaling}`: start streaming to
      `signaling`. Reply `:ok`, or `{:error, reason}` if the source can't
      stream right now; the dashboard tries again a couple of seconds later.
    * `{BB.LiveView.VideoSource, :detach, signaling}`: stop. Reply `:ok`,
      also for a signaling the source doesn't know.

  ## Messages a source sends

    * `{BB.LiveView.VideoSource, :ended, signaling}`, to the process that
      attached, when the source stops streaming to `signaling` on its own
      (its pipeline restarted, or the sink's connection failed, say), so the
      viewer can attach again with a new signaling. The dashboard also takes
      the signaling exiting, which happens when its sink goes down, as the
      end of the stream.
  """

  @typedoc "Whatever the source wants to show about the stream."
  @type metadata :: %{
          optional(:codec) => atom(),
          optional(:width) => pos_integer(),
          optional(:height) => pos_integer(),
          optional(:framerate) => pos_integer()
        }

  @type source :: %{path: [atom()], pid: pid(), metadata: metadata()}

  @doc "Register the calling process as a video source at `path`."
  @spec register(module(), [atom()], metadata()) :: {:ok, pid()} | {:error, term()}
  def register(robot, path, metadata \\ %{}) when is_atom(robot) and is_list(path) do
    Registry.register(BB.Process.registry_name(robot), {__MODULE__, path}, metadata)
  end

  @doc """
  Replace the calling process's metadata for `path`, e.g. after its
  resolution changed. Viewers pick it up the next time they list sources.
  """
  @spec update(module(), [atom()], metadata()) :: :ok | :error
  def update(robot, path, metadata) when is_atom(robot) and is_list(path) do
    registry = BB.Process.registry_name(robot)

    case Registry.update_value(registry, {__MODULE__, path}, fn _ -> metadata end) do
      {_new, _old} -> :ok
      :error -> :error
    end
  end

  @doc "The robot's video sources, sorted by path. Empty if the robot isn't running."
  @spec list(module()) :: [source()]
  def list(robot) when is_atom(robot) do
    robot
    |> BB.Process.registry_name()
    |> Registry.select([{{{__MODULE__, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {path, pid, metadata} -> %{path: path, pid: pid, metadata: metadata} end)
    |> Enum.sort_by(& &1.path)
  rescue
    # No registry: the robot isn't running.
    ArgumentError -> []
  end

  @doc "Ask `source` to stream to `signaling` until detached or the caller exits."
  @spec attach(pid(), term(), timeout()) :: :ok | {:error, term()}
  def attach(source, signaling, timeout \\ 5_000) when is_pid(source) do
    GenServer.call(source, {__MODULE__, :attach, signaling}, timeout)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Stop `source` streaming to `signaling`."
  @spec detach(pid(), term(), timeout()) :: :ok
  def detach(source, signaling, timeout \\ 5_000) when is_pid(source) do
    GenServer.call(source, {__MODULE__, :detach, signaling}, timeout)
  catch
    # Already gone, so nothing to stop.
    :exit, _reason -> :ok
  end
end
