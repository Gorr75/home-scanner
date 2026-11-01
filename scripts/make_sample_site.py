#!/usr/bin/env python3
"""Aerial-style sample underlay for the site plan. Not a real orthophoto."""

import os
import struct
import zlib

SIZE = 512
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "RoomScan", "Resources", "SampleSite.png")
FACADE = os.path.join(ROOT, "RoomScan", "Resources", "SampleFacade.png")


def color(x, y):
    grass = (126, 148, 96)
    roof = (120, 92, 74)
    patio = (196, 176, 140)
    path = (168, 160, 142)
    shed = (90, 96, 88)
    drive = (150, 146, 138)
    pixel = grass
    # House roof, north of center. Image y grows south, matching a north-up orthophoto.
    if 170 <= x <= 330 and 150 <= y <= 280:
        pixel = roof
    if 210 <= x <= 300 and 280 <= y <= 360:
        pixel = patio
    if 240 <= x <= 275 and 360 <= y <= 500:
        pixel = path
    if 60 <= x <= 150 and 400 <= y <= 470:
        pixel = drive
    if 390 <= x <= 470 and 170 <= y <= 250:
        pixel = shed
    # North arrow in the north-west corner.
    if 40 <= x <= 48 and 36 <= y <= 90:
        pixel = (40, 44, 38)
    if 32 <= x <= 56 and 28 <= y <= 44 and abs(x - 44) <= (y - 24):
        pixel = (40, 44, 38)
    return pixel


def facade_color(x, y, width, height):
    board = (148, 116, 78) if (y // 16) % 2 == 0 else (132, 102, 68)
    if 70 <= x <= width - 70 and 28 <= y <= height - 36:
        return (186, 206, 214)
    return board


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png(path, width, height, pixel):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixel(x, y))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)
    return len(png)


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    site = write_png(OUT, SIZE, SIZE, color)
    print(f"wrote {OUT} ({site} bytes)")
    facade = write_png(FACADE, 256, 128, lambda x, y: facade_color(x, y, 256, 128))
    print(f"wrote {FACADE} ({facade} bytes)")


if __name__ == "__main__":
    main()
