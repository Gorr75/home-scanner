#!/usr/bin/env python3
"""Aerial-style sample underlay for the site plan. Not a real orthophoto."""

import os
import struct
import zlib

SIZE = 512
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "RoomScan",
    "Resources",
    "SampleSite.png",
)


def color(x, y):
    grass = (126, 148, 96)
    roof = (120, 92, 74)
    patio = (196, 176, 140)
    path = (168, 160, 142)
    shed = (90, 96, 88)
    pixel = grass
    # House roof near the center-left.
    if 180 <= x <= 320 and 200 <= y <= 320:
        pixel = roof
    # Patio south of the house.
    if 200 <= x <= 340 and 330 <= y <= 400:
        pixel = patio
    # Path.
    if 250 <= x <= 280 and 400 <= y <= 490:
        pixel = path
    # Shed at the east edge.
    if 390 <= x <= 460 and 180 <= y <= 280:
        pixel = shed
    return pixel


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def main():
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)
        for x in range(SIZE):
            r, g, b = color(x, y)
            raw.extend((r, g, b))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as handle:
        handle.write(png)
    print(f"wrote {OUT} ({len(png)} bytes)")


if __name__ == "__main__":
    main()
