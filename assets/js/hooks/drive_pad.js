// SPDX-FileCopyrightText: 2026 Lars Wikman
//
// SPDX-License-Identifier: Apache-2.0

import { DIRECTIONS, Held, command, directionForCode } from "../drive/state.js";

/**
 * Hold-to-drive for the Drive widget (BB.LiveView.Components.Drive).
 *
 * While the widget is in control (`data-in-control`), held arrow/WASD keys
 * and presses on the on-screen pad push a `"drive"` event with the throttle
 * and turn, immediately on a change and then `data-rate` times a second, and
 * a `"drive_stop"` once nothing is held.
 *
 * The ticks are the dead man's switch: they stop when this page goes away,
 * so the robot's drive functions should only keep it moving briefly after
 * each one. Losing focus, hiding the tab or releasing control all let go.
 */
export const DrivePad = {
  mounted() {
    this.held = new Held();
    this.timer = null;
    this.driving = false;

    this.onKeyDown = (event) => this.keyDown(event);
    this.onKeyUp = (event) => this.keyUp(event);
    this.onPointerDown = (event) => this.pointerDown(event);
    this.onPointerUp = (event) => this.pointerUp(event);
    this.onBlur = () => this.releaseAll();
    this.onVisibility = () => document.hidden && this.releaseAll();
    this.onContextMenu = (event) => event.target.closest("[data-drive-key]") && event.preventDefault();

    window.addEventListener("keydown", this.onKeyDown);
    window.addEventListener("keyup", this.onKeyUp);
    window.addEventListener("blur", this.onBlur);
    document.addEventListener("visibilitychange", this.onVisibility);
    // Releases are watched on the window: a finger can slide off the pad.
    this.el.addEventListener("pointerdown", this.onPointerDown);
    window.addEventListener("pointerup", this.onPointerUp);
    window.addEventListener("pointercancel", this.onPointerUp);
    // A long press on a touch screen would otherwise open a context menu.
    this.el.addEventListener("contextmenu", this.onContextMenu);

    this.syncPad();
  },

  updated() {
    if (!this.inControl()) this.releaseAll();
    this.syncPad();
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown);
    window.removeEventListener("keyup", this.onKeyUp);
    window.removeEventListener("blur", this.onBlur);
    document.removeEventListener("visibilitychange", this.onVisibility);
    window.removeEventListener("pointerup", this.onPointerUp);
    window.removeEventListener("pointercancel", this.onPointerUp);
    this.stopTimer();
  },

  inControl() {
    return this.el.dataset.inControl === "true";
  },

  rate() {
    return Number.parseInt(this.el.dataset.rate, 10) || 20;
  },

  keyDown(event) {
    if (!this.inControl() || event.ctrlKey || event.metaKey || event.altKey) return;
    if (isTyping(event.target)) return;

    const direction = directionForCode(event.code);
    if (!direction) return;

    // Arrow keys would otherwise scroll the page.
    event.preventDefault();
    if (event.repeat) return;

    this.held.press(`key:${event.code}`, direction);
    this.changed();
  },

  keyUp(event) {
    if (this.held.release(`key:${event.code}`)) {
      event.preventDefault();
      this.changed();
    }
  },

  pointerDown(event) {
    const button = event.target.closest("[data-drive-key]");
    if (!button || !this.inControl()) return;

    event.preventDefault();
    this.held.press(`pointer:${event.pointerId}`, button.dataset.driveKey);
    this.changed();
  },

  pointerUp(event) {
    if (this.held.release(`pointer:${event.pointerId}`)) this.changed();
  },

  changed() {
    this.syncPad();

    if (this.held.any) {
      this.tick();
      if (!this.timer) this.timer = setInterval(() => this.tick(), 1000 / this.rate());
    } else {
      this.stopDriving();
    }
  },

  tick() {
    this.driving = true;
    this.pushEventTo(this.el, "drive", command(this.held.directions));
  },

  stopDriving() {
    this.stopTimer();

    if (this.driving) {
      this.driving = false;
      this.pushEventTo(this.el, "drive_stop", {});
    }
  },

  stopTimer() {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  },

  releaseAll() {
    this.held.clear();
    this.syncPad();
    this.stopDriving();
  },

  // The pad is `phx-update="ignore"`, so its state is set here.
  syncPad() {
    const enabled = this.inControl();
    const held = this.held.directions;

    for (const direction of DIRECTIONS) {
      const button = this.el.querySelector(`[data-drive-key="${direction}"]`);
      if (!button) continue;

      button.disabled = !enabled;
      button.toggleAttribute("data-held", held.has(direction));
    }
  },
};

function isTyping(target) {
  return Boolean(target?.closest?.("input, textarea, select, [contenteditable='true']"));
}
