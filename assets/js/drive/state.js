// SPDX-FileCopyrightText: 2026 Lars Wikman
//
// SPDX-License-Identifier: Apache-2.0

/**
 * Hold-to-drive state: which directions are held, and the command they make.
 * Pure, so it can be tested without a browser; the DrivePad hook owns the DOM.
 */

// By `KeyboardEvent.code`, the physical key, so WASD sits in the same place
// whatever the keyboard layout.
const KEY_DIRECTIONS = {
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  KeyW: "up",
  KeyS: "down",
  KeyA: "left",
  KeyD: "right",
};

export const DIRECTIONS = ["up", "down", "left", "right"];

/** The direction a key drives, or null. */
export function directionForCode(code) {
  return KEY_DIRECTIONS[code] ?? null;
}

/**
 * Throttle and turn for a set of held directions, each -1, 0 or 1. Turn is
 * positive to the left. Opposite directions cancel out.
 */
export function command(held) {
  const has = (direction) => (held.has(direction) ? 1 : 0);
  return {
    throttle: has("up") - has("down"),
    turn: has("left") - has("right"),
  };
}

/**
 * Tracks what is holding each direction: a key or a pointer on the pad. Two
 * sources can hold the same direction, and it's held until both let go.
 */
export class Held {
  constructor() {
    this.sources = new Map();
  }

  press(source, direction) {
    this.sources.set(source, direction);
  }

  /** Returns whether the source was holding anything. */
  release(source) {
    return this.sources.delete(source);
  }

  clear() {
    this.sources.clear();
  }

  get any() {
    return this.sources.size > 0;
  }

  get directions() {
    return new Set(this.sources.values());
  }
}
