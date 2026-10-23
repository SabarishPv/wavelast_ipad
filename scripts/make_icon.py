#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 WaveLast contributors
"""Generates WaveLast's original app icon (1024x1024 PNG) with the Python
standard library only: a deep-indigo-to-teal gradient with three white
sine waves. Run: python3 scripts/make_icon.py <output.png>"""

import math
import struct
import sys
import zlib

SIZE = 1024
DEEP = (20, 31, 69)
TEAL = (33, 158, 179)


def lerp(a, b, t):
    return a + (b - a) * t


def pixel(x, y):
    t = (x + y) / (2 * (SIZE - 1))
    r, g, b = (lerp(DEEP[i], TEAL[i], t) for i in range(3))
    # Three waves of decreasing amplitude, anti-aliased by distance.
    for k, (amp, freq, phase, width, alpha) in enumerate([
        (110, 2.0, 0.0, 34, 1.0),
        (80, 2.0, 0.9, 22, 0.75),
        (55, 2.0, 1.8, 14, 0.5),
    ]):
        cy = SIZE * 0.5 + (k - 1) * 120
        wy = cy + amp * math.sin(2 * math.pi * freq * x / SIZE + phase)
        d = abs(y - wy)
        cover = max(0.0, min(1.0, (width / 2 + 1 - d)))
        a = cover * alpha
        r, g, b = lerp(r, 255, a), lerp(g, 255, a), lerp(b, 255, a)
    return int(r), int(g), int(b)


def png(path):
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)
        for x in range(SIZE):
            raw.extend(pixel(x, y))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


if __name__ == "__main__":
    png(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
