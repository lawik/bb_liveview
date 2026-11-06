// SPDX-FileCopyrightText: 2026 Lars Wikman
//
// SPDX-License-Identifier: Apache-2.0

/**
 * Pixel conversion from `BB.Message.Sensor.Image` encodings to canvas RGBA.
 *
 * Kept free of DOM APIs so it can be exercised from Node.
 */

// Byte offsets of red, green and blue within a pixel, in channels.
const LAYOUTS = {
  rgb8: { channels: 3, bytes: 1, r: 0, g: 1, b: 2 },
  rgba8: { channels: 4, bytes: 1, r: 0, g: 1, b: 2 },
  bgr8: { channels: 3, bytes: 1, r: 2, g: 1, b: 0 },
  bgra8: { channels: 4, bytes: 1, r: 2, g: 1, b: 0 },
  mono8: { channels: 1, bytes: 1, r: 0, g: 0, b: 0 },
  rgb16: { channels: 3, bytes: 2, r: 0, g: 1, b: 2 },
  rgba16: { channels: 4, bytes: 2, r: 0, g: 1, b: 2 },
  bgr16: { channels: 3, bytes: 2, r: 2, g: 1, b: 0 },
  bgra16: { channels: 4, bytes: 2, r: 2, g: 1, b: 0 },
  mono16: { channels: 1, bytes: 2, r: 0, g: 0, b: 0 },
  // Shown as greyscale rather than demosaiced.
  bayer_rggb8: { channels: 1, bytes: 1, r: 0, g: 0, b: 0 },
  bayer_bggr8: { channels: 1, bytes: 1, r: 0, g: 0, b: 0 },
  bayer_gbrg8: { channels: 1, bytes: 1, r: 0, g: 0, b: 0 },
  bayer_grbg8: { channels: 1, bytes: 1, r: 0, g: 0, b: 0 },
};

export function isSupportedEncoding(encoding) {
  return Object.prototype.hasOwnProperty.call(LAYOUTS, encoding);
}

/**
 * Bytes a frame needs: every row but the last is `step` long, and the last
 * only needs its pixels.
 */
export function requiredBytes({ width, height, step, encoding }) {
  const layout = LAYOUTS[encoding];
  if (!layout || width === 0 || height === 0) return 0;
  return (height - 1) * step + width * layout.channels * layout.bytes;
}

/**
 * Convert `src` (a Uint8Array of the sensor's pixels) into `out`, a
 * width × height × 4 RGBA buffer such as `ImageData.data`.
 *
 * 16-bit channels are reduced to their high byte. Alpha is always opaque: a
 * camera tile should show its pixels whatever the source's alpha says.
 *
 * Returns false, leaving `out` untouched, for an unknown encoding or a
 * buffer too short for the stated geometry.
 */
export function convertToRGBA(src, out, { width, height, step, encoding, is_bigendian }) {
  const layout = LAYOUTS[encoding];
  if (!layout) return false;
  if (src.length < requiredBytes({ width, height, step, encoding })) return false;
  if (out.length < width * height * 4) return false;

  const { channels, bytes } = layout;
  const pixelBytes = channels * bytes;
  // For 16-bit channels, the byte holding the most significant bits.
  const high = bytes === 2 && !is_bigendian ? 1 : 0;
  const r = layout.r * bytes + high;
  const g = layout.g * bytes + high;
  const b = layout.b * bytes + high;

  let o = 0;
  for (let y = 0; y < height; y++) {
    let i = y * step;
    for (let x = 0; x < width; x++) {
      out[o] = src[i + r];
      out[o + 1] = src[i + g];
      out[o + 2] = src[i + b];
      out[o + 3] = 255;
      o += 4;
      i += pixelBytes;
    }
  }

  return true;
}

/** Decode base64 into a Uint8Array, natively where the browser can. */
export function decodeBase64(data) {
  if (typeof Uint8Array.fromBase64 === "function") {
    return Uint8Array.fromBase64(data);
  }

  const binary = atob(data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}
