#!/usr/bin/env python3
"""Draw a 1024px floor-plan icon for the asset catalog."""

import os
import struct
import zlib

SIZE = 1024
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "RoomScan",
    "Assets.xcassets",
    "AppIcon.appiconset",
    "AppIcon.png",
)


def pixel(x, y):
    ink = (28, 25, 21)
    paper = (244, 240, 232)
    line = (196, 165, 116)
    accent = (31, 107, 90)
    # Rounded-rect mask.
    radius = 220
    dx = min(x, SIZE - 1 - x)
    dy = min(y, SIZE - 1 - y)
    if dx < radius and dy < radius:
        if (radius - dx) ** 2 + (radius - dy) ** 2 > radius ** 2:
            return (0, 0, 0, 0)
    color = ink

    def stroke(x0, y0, x1, y1, width, paint):
        # Distance from point to segment, in pixels.
        vx, vy = x1 - x0, y1 - y0
        length2 = vx * vx + vy * vy
        if length2 == 0:
            return None
        t = max(0, min(1, ((x - x0) * vx + (y - y0) * vy) / length2))
        px, py = x0 + t * vx, y0 + t * vy
        if (x - px) ** 2 + (y - py) ** 2 <= width ** 2:
            return paint
        return None

    walls = [
        (220, 280, 620, 280),
        (220, 280, 220, 760),
        (220, 760, 620, 760),
        (620, 280, 620, 760),
        (620, 280, 820, 280),
        (820, 280, 820, 820),
        (820, 820, 560, 820),
        (560, 820, 560, 760),
    ]
    for wall in walls:
        hit = stroke(*wall, 18, paper)
        if hit:
            color = hit
    door = stroke(620, 470, 620, 620, 26, ink)
    if door:
        color = door
    door_leaf = stroke(620, 470, 760, 470, 10, line)
    if door_leaf:
        color = door_leaf
    window = stroke(300, 280, 480, 280, 14, accent)
    if window:
        color = window
    # Pin.
    cx, cy, r = 470, 520, 28
    if (x - cx) ** 2 + (y - cy) ** 2 <= r ** 2:
        color = accent
    if (x - cx) ** 2 + (y - cy) ** 2 <= 10 ** 2:
        color = paper
    return (*color, 255)


def write_png(path):
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)
        for x in range(SIZE):
            raw.extend(pixel(x, y))
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", compressed) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(png)
    print(f"wrote {path} ({len(png)} bytes)")


if __name__ == "__main__":
    write_png(OUT)
