# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.DashboardLiveTest do
  use BB.LiveView.FeatureCase

  describe "dashboard layout" do
    test "shows robot name in header", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has("h1", text: "TestRobot")
    end

    test "shows connection status", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-connection-status")
    end

    test "displays all widget sections", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-widget-title", text: "Safety")
      |> assert_has(".bb-widget-title", text: "Commands")
      |> assert_has(".bb-widget-title", text: "Visualisation")
      |> assert_has(".bb-widget-title", text: "Joint Control")
      |> assert_has(".bb-widget-title", text: "Event Stream")
      |> assert_has(".bb-widget-title", text: "Parameters")
    end

    test "uses grid layout structure", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-dashboard-grid")
      |> assert_has(".bb-dashboard-sidebar")
      |> assert_has(".bb-dashboard-main-area")
      |> assert_has(".bb-dashboard-bottom")
    end

    test "shows dashboard content after loading", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-dashboard-content")
    end
  end

  describe "widget integration" do
    test "safety widget shows status and controls", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-safety")
      |> assert_has(".bb-safety-indicator")
      |> assert_has(".bb-safety-text")
      |> assert_has("button", text: "Arm")
      |> assert_has("button", text: "Disarm")
    end

    test "joint control widget shows armed status", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-joint-control")
      |> assert_has(".bb-armed-badge")
    end

    test "event stream widget is interactive", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-event-stream")
      |> assert_has("button", text: "Pause")
      |> assert_has("button", text: "Clear")
    end

    test "command widget renders", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-command")
    end

    test "visualisation widget has hook attached", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-visualisation")
      |> assert_has("[phx-hook=Visualisation]")
    end

    test "parameters widget renders", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-parameters")
    end
  end

  describe "visualisation tabs" do
    test "starts on the 3D tab with the images panel hidden", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-vis-tabs .bb-tab.active", text: "3D")
      |> assert_has(".bb-vis-tabs .bb-tab", text: "Images")
      |> refute_has("#vis-tab-3d[hidden]")
      |> assert_has("#vis-tab-images[hidden]")
    end

    test "switching to Images hides the 3D view without removing it", %{conn: conn} do
      conn
      |> visit("/robot")
      |> click_button("Images")
      |> assert_has(".bb-vis-tabs .bb-tab.active", text: "Images")
      |> assert_has("#vis-tab-3d[hidden] [phx-hook=Visualisation]")
      |> refute_has("#vis-tab-images[hidden]")
      |> assert_has("#vis-tab-images [phx-hook=ImageGrid]")
      |> click_button("3D")
      |> assert_has(".bb-vis-tabs .bb-tab.active", text: "3D")
      |> assert_has("#vis-tab-images[hidden]")
    end
  end

  describe "all widgets render correctly" do
    test "renders exactly 6 widgets", %{conn: conn} do
      conn
      |> visit("/robot")
      |> assert_has(".bb-widget", count: 6)
    end
  end
end
