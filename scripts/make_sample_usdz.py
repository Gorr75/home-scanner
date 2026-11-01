#!/usr/bin/env python3
"""Build the bundled sample apartment USDZ.

The measurements match RoomScanCore/Sources/RoomScanCore/SampleApartment.swift.
USDZ is an uncompressed, 64-byte-aligned zip with a single USDA payload.
"""

import os
import struct
import zlib

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "RoomScan",
    "Resources",
    "SampleApartment.usdz",
)


def box(name, x0, y0, z0, x1, y1, z1, color):
    points = [
        (x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
        (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1),
    ]
    faces = [
        (0, 1, 2, 3),
        (4, 7, 6, 5),
        (0, 4, 5, 1),
        (3, 2, 6, 7),
        (0, 3, 7, 4),
        (1, 5, 6, 2),
    ]
    indices = [index for face in faces for index in face]
    counts = [4] * len(faces)
    point_text = ", ".join(f"({p[0]}, {p[1]}, {p[2]})" for p in points)
    return f"""
    def Mesh "{name}"
    {{
        int[] faceVertexCounts = [{", ".join(str(c) for c in counts)}]
        int[] faceVertexIndices = [{", ".join(str(i) for i in indices)}]
        point3f[] points = [{point_text}]
        color3f[] primvars:displayColor = [({color[0]}, {color[1]}, {color[2]})]
        uniform token primvars:displayColor.interpolation = "constant"
        uniform token subdivisionScheme = "none"
        uniform bool doubleSided = 1
    }}
"""


def wall_box(name, x0, z0, x1, z1, height=2.4, thickness=0.12, color=(0.91, 0.88, 0.83)):
    dx, dz = x1 - x0, z1 - z0
    length = (dx * dx + dz * dz) ** 0.5
    if length < 1e-6:
        return ""
    px, pz = dx / length, dz / length
    nx, nz = -pz * thickness / 2, px * thickness / 2
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    hx, hz = px * length / 2, pz * length / 2
    corners = []
    for sx in (-1, 1):
        for sz in (-1, 1):
            corners.append((cx + sx * hx + sz * nx, cz + sx * hz + sz * nz))
    xs = [c[0] for c in corners]
    zs = [c[1] for c in corners]
    return box(name, min(xs), 0, min(zs), max(xs), height, max(zs), color)


def usda():
    plaster = (0.91, 0.88, 0.83)
    kitchen_floor = (0.93, 0.89, 0.80)
    living_floor = (0.86, 0.90, 0.86)
    wood = (0.62, 0.55, 0.46)
    door = (0.55, 0.35, 0.24)
    glass = (0.61, 0.75, 0.80)
    parts = [
        box("KitchenFloor", 0, -0.02, 0, 3.6, 0, 3.2, kitchen_floor),
        box("LivingFloor", 3.6, -0.02, 0, 8.8, 0, 4.0, living_floor),
        wall_box("KitchenSouth", 0, 0, 3.6, 0, color=plaster),
        wall_box("KitchenWest", 0, 0, 0, 3.2, color=plaster),
        wall_box("KitchenNorth", 0, 3.2, 3.6, 3.2, color=plaster),
        wall_box("KitchenEast", 3.6, 0, 3.6, 3.2, color=plaster),
        wall_box("LivingSouth", 3.6, 0, 8.8, 0, color=plaster),
        wall_box("LivingEast", 8.8, 0, 8.8, 4.0, color=plaster),
        wall_box("LivingNorth", 3.6, 4.0, 8.8, 4.0, color=plaster),
        wall_box("LivingWestStub", 3.6, 3.2, 3.6, 4.0, color=plaster),
        box("Door", 3.56, 0, 1.15, 3.64, 2.05, 2.05, door),
        box("Window", 5.3, 0.85, -0.02, 7.1, 2.15, 0.02, glass),
        box("Refrigerator", 0.1, 0, 2.35, 0.8, 1.8, 3.05, (0.82, 0.84, 0.86)),
        box("KitchenTable", 1.2, 0, 1.0, 2.4, 0.76, 1.8, wood),
        box("Sofa", 6.15, 0, 1.7, 7.05, 0.85, 3.9, (0.45, 0.38, 0.32)),
        box("CoffeeTable", 5.65, 0, 1.2, 6.75, 0.42, 1.8, wood),
    ]
    body = "\n".join(parts)
    return f"""#usda 1.0
(
    defaultPrim = "Apartment"
    metersPerUnit = 1
    upAxis = "Y"
    documentation = "Sample apartment for Home Scanner. Coordinates match SampleApartment.swift."
)

def Xform "Apartment"
{{
{body}
}}
"""


def pack_usdz(name, data):
    name_b = name.encode("utf-8")
    crc = zlib.crc32(data) & 0xFFFFFFFF
    base = 30 + len(name_b)
    pad = (64 - ((base + 4) % 64)) % 64
    extra = struct.pack("<HH", 1, pad) + (b"\0" * pad)
    extra_len = len(extra)
    data_off = 30 + len(name_b) + extra_len
    if data_off % 64 != 0:
        raise SystemExit(f"alignment failed: {data_off}")
    local = struct.pack(
        "<IHHHHHIIIHH",
        0x04034B50, 20, 0, 0, 0, 0, crc, len(data), len(data), len(name_b), extra_len,
    ) + name_b + extra + data
    central = struct.pack(
        "<IHHHHHHIIIHHHHHII",
        0x02014B50, 20, 20, 0, 0, 0, 0, crc, len(data), len(data),
        len(name_b), extra_len, 0, 0, 0, 0, 0,
    ) + name_b + extra
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(central), len(local), 0)
    return local + central + eocd


def main():
    payload = usda().encode("utf-8")
    blob = pack_usdz("SampleApartment.usda", payload)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as handle:
        handle.write(blob)
    print(f"wrote {OUT} ({len(blob)} bytes)")


if __name__ == "__main__":
    main()
