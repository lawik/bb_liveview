# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.FakeVideoSource do
  @moduledoc """
  A `BB.LiveView.VideoSource` for tests.

  It registers for `:robot` at `:path` with `:metadata`, and reports to
  `:test` (the starting process by default):

    * `{FakeVideoSource, :attached, source, signaling}`
    * `{FakeVideoSource, :attach_refused, source, signaling}`
    * `{FakeVideoSource, :detached, source, signaling}`

  Like a real source it monitors each viewer and forgets it when it exits.
  It doesn't stream: tests that need signaling start a `FakeSink` on the
  attached signaling. `end_stream/2` sends the viewer `:ended`, and
  `refuse/2` makes attaches fail until set back to `:ok`.
  """
  use GenServer

  alias BB.LiveView.VideoSource

  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.put_new(opts, :test, self()))

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :path)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Sends the viewer of `signaling` `{VideoSource, :ended, signaling}`, as if the stream broke."
  def end_stream(source, signaling), do: GenServer.call(source, {:end_stream, signaling})

  @doc "Sets what attaches reply: `:ok` or `{:error, reason}`."
  def refuse(source, reply), do: GenServer.call(source, {:reply, reply})

  @doc "The signalings currently attached."
  def attached(source), do: GenServer.call(source, :attached)

  @impl GenServer
  def init(opts) do
    {:ok, _} =
      VideoSource.register(
        Keyword.fetch!(opts, :robot),
        Keyword.fetch!(opts, :path),
        Keyword.get(opts, :metadata, %{})
      )

    {:ok, %{test: Keyword.fetch!(opts, :test), reply: :ok, viewers: %{}}}
  end

  @impl GenServer
  def handle_call({VideoSource, :attach, signaling}, {pid, _tag}, %{reply: :ok} = state) do
    send(state.test, {__MODULE__, :attached, self(), signaling})
    viewer = %{pid: pid, monitor: Process.monitor(pid)}
    {:reply, :ok, put_in(state.viewers[signaling], viewer)}
  end

  def handle_call({VideoSource, :attach, signaling}, _from, state) do
    send(state.test, {__MODULE__, :attach_refused, self(), signaling})
    {:reply, state.reply, state}
  end

  def handle_call({VideoSource, :detach, signaling}, _from, state) do
    send(state.test, {__MODULE__, :detached, self(), signaling})
    {:reply, :ok, forget(state, signaling)}
  end

  def handle_call({:end_stream, signaling}, _from, state) do
    %{pid: pid} = Map.fetch!(state.viewers, signaling)
    send(pid, {VideoSource, :ended, signaling})
    {:reply, :ok, forget(state, signaling)}
  end

  def handle_call({:reply, reply}, _from, state), do: {:reply, :ok, %{state | reply: reply}}

  def handle_call(:attached, _from, state), do: {:reply, Map.keys(state.viewers), state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    viewers = Map.reject(state.viewers, fn {_signaling, viewer} -> viewer.monitor == ref end)
    {:noreply, %{state | viewers: viewers}}
  end

  defp forget(state, signaling) do
    case Map.pop(state.viewers, signaling) do
      {nil, _viewers} ->
        state

      {viewer, viewers} ->
        Process.demonitor(viewer.monitor, [:flush])
        %{state | viewers: viewers}
    end
  end
end

defmodule BB.LiveView.FakeSink do
  @moduledoc """
  Stands in for the `Membrane.WebRTC.Sink` on a signaling: it registers as
  the signaling's element, the way the real sink does, so the signaling stops
  with its exit reason.

  Messages from the browser's side reach `:test` as
  `{FakeSink, sink, message}`, with `message` an `ExWebRTC` struct.
  `signal/2` sends one the other way, and `stop/2` stops the sink with a
  reason.
  """

  alias Membrane.WebRTC.Signaling

  def start(signaling, test \\ self()) do
    parent = self()

    sink =
      spawn(fn ->
        :ok = Signaling.register_element(signaling)
        send(parent, {__MODULE__, :registered, self()})
        loop(signaling, test)
      end)

    receive do
      {__MODULE__, :registered, ^sink} -> sink
    after
      1_000 -> raise "fake sink didn't register"
    end
  end

  def signal(sink, message), do: send(sink, {:signal, message})

  def stop(sink, reason), do: send(sink, {:stop, reason})

  defp loop(signaling, test) do
    receive do
      {:membrane_webrtc_signaling, _pid, message, _metadata} ->
        send(test, {__MODULE__, self(), message})
        loop(signaling, test)

      {:signal, message} ->
        Signaling.signal(signaling, message)
        loop(signaling, test)

      {:stop, reason} ->
        exit(reason)
    end
  end
end
