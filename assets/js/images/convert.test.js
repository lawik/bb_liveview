// SPDX-FileCopyrightText: 2026 Lars Wikman
//
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { convertToRGBA, decodeBase64, isSupportedEncoding, requiredBytes } from "./convert.js";

const convert = (bytes, frame) => {
  const out = new Uint8ClampedArray(frame.width * frame.height * 4);
  const ok = convertToRGBA(Uint8Array.from(bytes), out, frame);
  return { ok, out: Array.from(out) };
};

describe("convertToRGBA", () => {
  test("rgb8 copies channels and makes alpha opaque", () => {
    const { ok, out } = convert([1, 2, 3, 4, 5, 6], { width: 2, height: 1, step: 6, encoding: "rgb8" });
    assert.ok(ok);
    assert.deepEqual(out, [1, 2, 3, 255, 4, 5, 6, 255]);
  });

  test("rgba8 ignores the source alpha", () => {
    const { out } = convert([1, 2, 3, 0], { width: 1, height: 1, step: 4, encoding: "rgba8" });
    assert.deepEqual(out, [1, 2, 3, 255]);
  });

  test("bgr8 and bgra8 swap red and blue", () => {
    assert.deepEqual(convert([3, 2, 1], { width: 1, height: 1, step: 3, encoding: "bgr8" }).out, [1, 2, 3, 255]);
    assert.deepEqual(convert([3, 2, 1, 9], { width: 1, height: 1, step: 4, encoding: "bgra8" }).out, [1, 2, 3, 255]);
  });

  test("mono8 and bayer spread one channel to grey", () => {
    assert.deepEqual(convert([7, 200], { width: 2, height: 1, step: 2, encoding: "mono8" }).out, [7, 7, 7, 255, 200, 200, 200, 255]);
    assert.deepEqual(convert([9], { width: 1, height: 1, step: 1, encoding: "bayer_rggb8" }).out, [9, 9, 9, 255]);
  });

  test("16-bit channels keep the high byte, honouring endianness", () => {
    const little = convert([0x34, 0x12], { width: 1, height: 1, step: 2, encoding: "mono16", is_bigendian: false });
    assert.deepEqual(little.out, [0x12, 0x12, 0x12, 255]);

    const big = convert([0x12, 0x34], { width: 1, height: 1, step: 2, encoding: "mono16", is_bigendian: true });
    assert.deepEqual(big.out, [0x12, 0x12, 0x12, 255]);

    const rgb = convert([0, 1, 0, 2, 0, 3], { width: 1, height: 1, step: 6, encoding: "rgb16", is_bigendian: false });
    assert.deepEqual(rgb.out, [1, 2, 3, 255]);

    const bgra = convert([0, 3, 0, 2, 0, 1, 0, 0], { width: 1, height: 1, step: 8, encoding: "bgra16", is_bigendian: false });
    assert.deepEqual(bgra.out, [1, 2, 3, 255]);
  });

  test("row padding beyond width is skipped using step", () => {
    // 1x2 mono8 with two bytes of padding per row.
    const { out } = convert([10, 0, 0, 20], { width: 1, height: 2, step: 3, encoding: "mono8" });
    assert.deepEqual(out, [10, 10, 10, 255, 20, 20, 20, 255]);
  });

  test("rejects short data and unknown encodings", () => {
    assert.equal(convert([1, 2], { width: 1, height: 1, step: 3, encoding: "rgb8" }).ok, false);
    assert.equal(convert([1, 2, 3], { width: 1, height: 1, step: 3, encoding: "yuv422" }).ok, false);
  });
});

test("requiredBytes doesn't need padding after the last row", () => {
  assert.equal(requiredBytes({ width: 2, height: 3, step: 8, encoding: "rgb8" }), 2 * 8 + 6);
  assert.equal(requiredBytes({ width: 0, height: 3, step: 8, encoding: "rgb8" }), 0);
});

test("isSupportedEncoding covers every BB image encoding", () => {
  for (const encoding of [
    "rgb8", "rgba8", "rgb16", "rgba16", "bgr8", "bgra8", "bgr16", "bgra16",
    "mono8", "mono16", "bayer_rggb8", "bayer_bggr8", "bayer_gbrg8", "bayer_grbg8",
  ]) {
    assert.ok(isSupportedEncoding(encoding), encoding);
  }
  assert.equal(isSupportedEncoding("toString"), false);
});

test("decodeBase64 round-trips bytes", () => {
  const bytes = [0, 1, 127, 128, 254, 255];
  assert.deepEqual(Array.from(decodeBase64(Buffer.from(bytes).toString("base64"))), bytes);
});
