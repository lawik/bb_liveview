// SPDX-FileCopyrightText: 2025 James Harton
// SPDX-License-Identifier: Apache-2.0

import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import { AutoScroll } from "./hooks/auto_scroll";
import { ImageGrid } from "./hooks/image_grid";
import { Visualisation } from "./hooks/visualisation";

const Hooks = {
  AutoScroll,
  ImageGrid,
  Visualisation,
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

liveSocket.connect();

window.liveSocket = liveSocket;

export { Hooks };
