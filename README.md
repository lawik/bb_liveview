<!--
SPDX-FileCopyrightText: 2025 James Harton

SPDX-License-Identifier: Apache-2.0
-->

<img src="https://github.com/beam-bots/bb/blob/main/logos/beam_bots_logo.png?raw=true" alt="Beam Bots Logo" width="250" />

# BB.LiveView

[![CI](https://github.com/beam-bots/bb_liveview/actions/workflows/ci.yml/badge.svg)](https://github.com/beam-bots/bb_liveview/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Hex version badge](https://img.shields.io/hexpm/v/bb_liveview.svg)](https://hex.pm/packages/bb_liveview)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/bb_liveview)
[![REUSE status](https://api.reuse.software/badge/github.com/beam-bots/bb_liveview)](https://api.reuse.software/info/github.com/beam-bots/bb_liveview)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/beam-bots/bb_liveview)

Interactive LiveView dashboard for [Beam Bots](https://github.com/beam-bots/bb) robots. Mount a fully-featured control interface into any Phoenix application with a single line of code.

## Features

- **Safety Controls** - Arm/disarm robot with visual state indicators
- **Joint Control** - Real-time sliders for all movable joints with position feedback
- **3D Visualisation** - Interactive Three.js view with orbit controls showing live robot pose
- **Images** - A tab beside the 3D view with live feeds from every sensor publishing `BB.Message.Sensor.Image`
- **Event Stream** - Monitor PubSub messages with filtering and pause/resume
- **Command Execution** - Dynamic forms for robot commands based on DSL definitions
- **Parameter Editor** - View and modify runtime parameters with type-specific controls

## Installation

Add `bb_liveview` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bb_liveview, "~> 0.3.4"}
  ]
end
```

## Quick Start

### 1. Add the dashboard route

In your Phoenix router, import the macro and mount the dashboard:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import BB.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser
    bb_dashboard "/robot", robot: MyApp.Robot
  end
end
```

### 2. Serve the bundled assets

Add the static plug to your endpoint, **before** `Plug.Session`:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # ... other plugs ...

  # Add this BEFORE Plug.Session
  plug Plug.Static,
    at: "/__bb_assets__",
    from: {:bb_liveview, "priv/static"},
    gzip: false

  plug Plug.Session, ...
  plug MyAppWeb.Router
end
```

### 3. Start your robot supervisor

Ensure your robot's supervision tree is started in your application:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # ... other children ...
      %{
        id: BB.Supervisor,
        start: {BB.Supervisor, :start_link, [MyApp.Robot]}
      },
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### 4. Visit the dashboard

Navigate to `http://localhost:4000/robot` to see your robot dashboard.

## Multiple Robots

Mount multiple dashboards for different robots:

```elixir
scope "/" do
  pipe_through :browser
  bb_dashboard "/arm", robot: MyApp.ArmRobot
  bb_dashboard "/base", robot: MyApp.MobileBase
end
```

## Configuration Options

The `bb_dashboard/2` macro accepts the following options:

| Option | Required | Description |
|--------|----------|-------------|
| `:robot` | Yes | The robot module (must `use BB`) |

## Dashboard Components

### Safety Widget

Displays the robot's safety state and provides arm/disarm controls:

- **Disarmed** (grey) - Robot is safe, no motion possible
- **Armed** (green) - Robot is ready to accept commands
- **Error** (red) - Safety system detected an issue, requires force disarm

### Joint Control

Shows all movable joints with:

- Current position (degrees for revolute, mm for prismatic)
- Target slider with min/max limits from joint definition
- "SIM" badge for joints without hardware actuators
- Controls disabled when robot is disarmed

### 3D Visualisation

Interactive Three.js renderer showing:

- Robot geometry from visual definitions (boxes, cylinders, spheres)
- Real-time joint position updates via forward kinematics
- Orbit controls (drag to rotate, scroll to zoom, right-drag to pan)
- Reset View button to restore default camera position

### Images

A tab beside the 3D view showing live feeds from image sensors:

- One tile per sensor publishing `BB.Message.Sensor.Image` under `[:sensor | path]`, discovered automatically
- Path, resolution, encoding and measured frame rate for each feed
- 8- and 16-bit RGB/BGR(A) and mono encodings (Bayer shown as greyscale)
- Frames are only sent while the tab is open, at most 5 per second per sensor, newest first

### Event Stream

Real-time PubSub message monitor:

- Timestamp, path, message type, and payload preview
- Pause/Resume to freeze the stream
- Clear button to reset the message list
- Auto-scrolls to show newest messages

### Command Panel

Execute robot commands defined in the DSL:

- Tab navigation for multiple commands
- Dynamic form generation based on command arguments
- State-aware availability (respects allowed states)
- Result/error display after execution

### Parameters

View and edit runtime parameters:

- Grouped by parameter path
- Type-specific controls (toggles, sliders, text inputs)
- Real-time updates via PubSub
- Support for remote bridge parameters

## Styling

The dashboard uses bundled CSS with CSS custom properties for theming. The default theme uses neutral greys with accent colours for status indicators.

To customise, you can override the CSS custom properties in your own stylesheet:

```css
:root {
  --bb-primary: #your-color;
  --bb-success: #your-success-color;
  --bb-danger: #your-danger-color;
}
```

## Development

To run the development server with the test robot:

```bash
cd bb_liveview
mix deps.get
cd assets && npm install && cd ..
mix phx.server
```

Visit `http://localhost:4000` to see the dashboard with a simulated WidowX-200 style robot arm.

## Requirements

- Elixir ~> 1.19
- Phoenix LiveView ~> 1.0
- A robot module using the BB DSL

## Documentation

- [Your First Dashboard](https://hexdocs.pm/bb_liveview/01-your-first-dashboard.html) - getting started tutorial
- [Customise Dashboard Layout](https://hexdocs.pm/bb_liveview/customise-dashboard-layout.html) - creating custom layouts

Full API documentation is available at [HexDocs](https://hexdocs.pm/bb_liveview).
