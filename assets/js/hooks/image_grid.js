// SPDX-FileCopyrightText: 2026 Lars Wikman
//
// SPDX-License-Identifier: Apache-2.0

/**
 * LiveView hook that draws image sensor frames pushed by
 * `BB.LiveView.Components.Images` into their tiles' canvases.
 */

import { convertToRGBA, decodeBase64, isSupportedEncoding } from "../images/convert.js";

export const ImageGrid = {
  mounted() {
    // ImageData per canvas, reused while the frame size stays the same.
    this.buffers = new WeakMap();
    this.warned = new Set();

    this.handleEvent("bb_image_frame", (frame) => this.draw(frame));
  },

  draw(frame) {
    const canvas = document.getElementById(frame.canvas);
    if (!canvas || !this.el.contains(canvas)) return;

    if (!isSupportedEncoding(frame.encoding)) {
      this.warnOnce(`${frame.canvas}: unsupported encoding ${frame.encoding}`);
      return;
    }

    if (canvas.width !== frame.width) canvas.width = frame.width;
    if (canvas.height !== frame.height) canvas.height = frame.height;

    const ctx = canvas.getContext("2d");
    let image = this.buffers.get(canvas);
    if (!image || image.width !== frame.width || image.height !== frame.height) {
      image = ctx.createImageData(frame.width, frame.height);
      this.buffers.set(canvas, image);
    }

    if (!convertToRGBA(decodeBase64(frame.data), image.data, frame)) {
      this.warnOnce(`${frame.canvas}: frame data too short for ${frame.width}x${frame.height}`);
      return;
    }

    ctx.putImageData(image, 0, 0);
  },

  warnOnce(message) {
    if (this.warned.has(message)) return;
    this.warned.add(message);
    console.warn(`[bb_liveview] ${message}`);
  },
};
