<!--
SPDX-FileCopyrightText: 2025 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

BB.LiveView is a Phoenix LiveView dashboard library for Beam Bots robots. It provides a self-contained, mountable dashboard with real-time robot control and visualisation.

## Architecture

### Router (`lib/bb/live_view/router.ex`)

Provides `bb_dashboard/2` macro that generates:
- Asset routes at `/__bb_assets__/*`
- LiveView route with robot module in session

### Dashboard (`lib/bb/live_view/dashboard_live.ex`)

Main LiveView that:
- Subscribes to robot PubSub channels (`:state_machine`, `:sensor`, `:param`)
- Routes messages to appropriate components via `send_update/3`
- Renders the dashboard layout with all widget components

### Components (`lib/bb/live_view/components/`)

Seven LiveComponents, each handling a specific concern:

| Component | File | Purpose |
|-----------|------|---------|
| Safety | `safety.ex` | Arm/disarm controls, safety state display |
| JointControl | `joint_control.ex` | Joint sliders with position feedback |
| Visualisation | `visualisation.ex` | 3D robot view (Three.js) |
| Images | `images.ex` | Image sensor feeds, in a tab beside the 3D view |
| EventStream | `event_stream.ex` | PubSub message monitor |
| Command | `command.ex` | Command execution forms |
| Parameters | `parameters.ex` | Runtime parameter editor |

### JavaScript (`assets/js/`)

- `app.js` - LiveView setup with hooks
- `hooks/visualisation.js` - Three.js integration hook
- `visualisation/` - Three.js scene builder and robot model

### Static Assets (`priv/static/`)

Pre-built CSS and JS bundles served by `BB.LiveView.Plugs.Static`.

## Common Commands

```bash
# Run all checks
mix check --no-retry

# Run tests
mix test
mix test path/to/test.exs:42

# Build assets
cd assets && npm run build && npm run build:css

# Run dev server
mix phx.server
```

## Key Patterns

### Component Updates

Components receive updates via `send_update/3` with an `:event` key:

```elixir
send_update(JointControl,
  id: "joint_control",
  event: {:positions_updated, positions}
)
```

Components handle these in their `update/2` callback:

```elixir
def update(%{event: {:positions_updated, positions}}, socket) do
  # Handle the event
  {:ok, socket}
end
```

### PubSub Integration

The dashboard subscribes to BB PubSub and forwards messages:

```elixir
# In mount
BB.subscribe(robot_module, [:sensor])

# In handle_info
def handle_info({:bb, [:sensor | _], %BB.Message{} = msg}, socket) do
  # Forward to relevant components
end
```

### JS Hook Communication

Server pushes events to JS hooks via `push_event/3`:

```elixir
{:ok, push_event(socket, "positions_updated", %{positions: data})}
```

JS hooks receive via `handleEvent`:

```javascript
this.handleEvent("positions_updated", ({ positions }) => {
  this.robot.setJointValues(positions);
});
```

### Direct Notifications for Responsiveness

For fast UI updates (e.g., slider → visualisation), bypass PubSub with direct messages:

```elixir
# In component
send(self(), {:joint_position_changed, positions})

# In parent LiveView
def handle_info({:joint_position_changed, positions}, socket) do
  send_update(Visualisation, id: "visualisation", event: {:positions_updated, positions})
  {:noreply, socket}
end
```

## Testing

Tests use `phoenix_test` for LiveView testing:

```elixir
defmodule BB.LiveView.SafetyTest do
  use BB.LiveView.FeatureCase

  test "shows disarmed state", %{conn: conn} do
    conn
    |> visit("/")
    |> assert_has("[data-role=safety-status]", text: "Disarmed")
  end
end
```

Test support files in `test/support/`:
- `feature_case.ex` - phoenix_test setup
- `test_robot.ex` - Mock robot for testing
- `test_endpoint.ex` - Test Phoenix endpoint
- `test_router.ex` - Test router with dashboard mounted

## Dev Server

The `dev/` directory contains a standalone development server:

- `dev/dev/application.ex` - Starts BB.Supervisor with test robot
- `dev/dev/test_robot.ex` - WidowX-200 style simulated robot
- `dev/dev_web/` - Phoenix endpoint and router

Run with `mix phx.server` (uses `Dev.Application` in dev environment).

## Asset Pipeline

Assets are built with esbuild:

```bash
cd assets
npm run build        # JS → priv/static/dashboard.js
npm run build:css    # CSS → priv/static/dashboard.css
```

Three.js is bundled into the main JS file (~1.1MB unminified).

## Dependencies

Key dependencies:
- `phoenix_live_view` - LiveView framework
- `bb` - Beam Bots core (robot DSL, runtime, PubSub)
- `jason` - JSON encoding for JS communication
- `three` (npm) - 3D visualisation

## File Locations

| What | Where |
|------|-------|
| Router macro | `lib/bb/live_view/router.ex` |
| Main LiveView | `lib/bb/live_view/dashboard_live.ex` |
| Components | `lib/bb/live_view/components/*.ex` |
| Shared components | `lib/bb/live_view/components.ex` |
| Layouts | `lib/bb/live_view/layouts.ex` |
| Static plug | `lib/bb/live_view/plugs/static.ex` |
| JS hooks | `assets/js/hooks/*.js` |
| Three.js code | `assets/js/visualisation/*.js` |
| CSS | `assets/css/dashboard.css` |
| Built assets | `priv/static/` |
| Dev server | `dev/` |

## Licensing headers

Every source file must carry an SPDX header — a `#`-style comment for code, an
HTML comment for Markdown, or a `<file>.license` sidecar for files that can't
hold comments (binaries, JSON, lockfiles). `mix check` runs `reuse lint` and
fails the build if one is missing.

When you create a new file, its `SPDX-FileCopyrightText` line must credit **the
user you are working for** — not you (the agent), and not this repo's original
author. Take their name from `git config user.name` (add their `user.email` if
you include one) and use the current year. Match the neighbouring files'
`SPDX-License-Identifier` (usually `Apache-2.0`):

```
SPDX-FileCopyrightText: <current year> <your user's name>

SPDX-License-Identifier: Apache-2.0
```

Never copy an existing file's copyright line onto a new file — that credits the
wrong person. When you only edit an existing file, leave its headers unchanged.
