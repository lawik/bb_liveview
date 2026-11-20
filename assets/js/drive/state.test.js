// SPDX-FileCopyrightText: 2026 Lars Wikman
//
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { Held, command, directionForCode } from "./state.js";

describe("directionForCode", () => {
  test("maps arrows and WASD", () => {
    assert.equal(directionForCode("ArrowUp"), "up");
    assert.equal(directionForCode("KeyA"), "left");
    assert.equal(directionForCode("KeyD"), "right");
    assert.equal(directionForCode("KeyS"), "down");
  });

  test("ignores other keys", () => {
    assert.equal(directionForCode("KeyQ"), null);
    assert.equal(directionForCode("Space"), null);
  });
});

describe("command", () => {
  test("nothing held is stopped", () => {
    assert.deepEqual(command(new Set()), { throttle: 0, turn: 0 });
  });

  test("up and left: forward, turning left (positive)", () => {
    assert.deepEqual(command(new Set(["up", "left"])), { throttle: 1, turn: 1 });
  });

  test("down and right: reverse, turning right", () => {
    assert.deepEqual(command(new Set(["down", "right"])), { throttle: -1, turn: -1 });
  });

  test("opposites cancel", () => {
    assert.deepEqual(command(new Set(["up", "down", "left", "right"])), { throttle: 0, turn: 0 });
  });
});

describe("Held", () => {
  test("a direction stays held until every source lets go", () => {
    const held = new Held();
    held.press("key:ArrowUp", "up");
    held.press("pointer:1", "up");

    held.release("key:ArrowUp");
    assert.deepEqual(held.directions, new Set(["up"]));

    held.release("pointer:1");
    assert.equal(held.any, false);
  });

  test("release reports whether the source held anything", () => {
    const held = new Held();
    held.press("key:KeyW", "up");
    assert.equal(held.release("key:KeyW"), true);
    assert.equal(held.release("key:KeyW"), false);
  });
});
