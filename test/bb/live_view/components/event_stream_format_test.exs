# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.EventStreamFormatTest do
  @moduledoc """
  Tests for how `EventStream` renders binary payload fields.
  """

  use BB.LiveView.ConnCase

  import Phoenix.LiveViewTest

  alias BB.LiveView.EventStreamHostLive
  alias BB.Message
  alias BB.Message.Sensor.Image

  @flush_interval_ms 10

  defmodule Note do
    @moduledoc false
    defstruct [:text]
  end

  defp mount_host(conn) do
    live_isolated(conn, EventStreamHostLive,
      session: %{"flush_interval_ms" => @flush_interval_ms, "debounce_window_ms" => 0}
    )
  end

  defp show(view, path, message) do
    send(view.pid, {:inject, path, message})
    Process.sleep(@flush_interval_ms * 3)
    render(view)
  end

  defp note(text),
    do: %Message{wall_time: System.os_time(:nanosecond), payload: %Note{text: text}}

  defp field_value(view, name) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(".bb-event-field")
    |> Enum.find_value(fn field ->
      if Floki.find(field, ".bb-event-field-name") |> Floki.text() == "#{name}:" do
        field |> Floki.find(".bb-event-field-value") |> Floki.text()
      end
    end)
  end

  test "summarises raw image data by size instead of rendering it", %{conn: conn} do
    {:ok, view, _html} = mount_host(conn)

    {:ok, message} =
      Image.new(:camera,
        width: 160,
        height: 120,
        encoding: :rgb8,
        step: 480,
        data: :crypto.strong_rand_bytes(57_600)
      )

    html = show(view, [:sensor, :camera], message)

    assert String.valid?(html)
    assert field_value(view, "data") == "<<57600 bytes>>"
    assert field_value(view, "encoding") == "rgb8"
  end

  test "summarises short non-printable binaries", %{conn: conn} do
    {:ok, view, _html} = mount_host(conn)

    show(view, [:sensor, :thing], note(<<0, 255, 1>>))

    assert field_value(view, "text") == "<<3 bytes>>"
  end

  test "renders short printable strings verbatim", %{conn: conn} do
    {:ok, view, _html} = mount_host(conn)

    show(view, [:sensor, :thing], note("hello, world"))

    assert field_value(view, "text") == "hello, world"
  end

  test "truncates long printable strings", %{conn: conn} do
    {:ok, view, _html} = mount_host(conn)

    show(view, [:sensor, :thing], note(String.duplicate("a", 1000)))

    assert field_value(view, "text") == String.duplicate("a", 200) <> "…"
  end

  test "truncation doesn't split a multi-byte character", %{conn: conn} do
    {:ok, view, _html} = mount_host(conn)

    # The 200-byte cut lands in the middle of an "é".
    html = show(view, [:sensor, :thing], note("a" <> String.duplicate("é", 150)))

    assert String.valid?(html)
    assert field_value(view, "text") == "a" <> String.duplicate("é", 99) <> "…"
  end
end
