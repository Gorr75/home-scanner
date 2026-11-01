#!/usr/bin/env python3
"""Build a GLB from a roomscan.home layout.

The default input is the bundled sample apartment. Walls, floors, doors,
windows, and furniture boxes follow that file, in meters, Y up, so the model
lines up with device pins.

Usage:
    python3 scripts/make_sample_glb.py
    python3 scripts/make_sample_glb.py --layout path/layout.json --out path/model.glb
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LAYOUT = ROOT / "sample" / "sample-apartment.roomscan.json"
DEFAULT_OUT = ROOT / "sample" / "sample-apartment.glb"

PLASTER = (0.91, 0.88, 0.83)
DOOR = (0.55, 0.35, 0.24)
GLASS = (0.61, 0.75, 0.80, 0.45)
WOOD = (0.62, 0.55, 0.46)
SOFA = (0.45, 0.38, 0.32)
APPLIANCE = (0.82, 0.84, 0.86)

OBJECT_COLORS = {
    "refrigerator": APPLIANCE,
    "washer_dryer": APPLIANCE,
    "oven": APPLIANCE,
    "dishwasher": APPLIANCE,
    "sofa": SOFA,
    "chair": (0.50, 0.42, 0.36),
    "bed": (0.55, 0.58, 0.64),
    "table": WOOD,
    "storage": WOOD,
    "television": (0.18, 0.19, 0.20),
}


def srgb_to_linear(channel: float) -> float:
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def linear_rgba(color, alpha=1.0):
    rgb = color[:3]
    if len(color) == 4:
        alpha = color[3]
    return [srgb_to_linear(c) for c in rgb] + [alpha]


class GltfWriter:
    def __init__(self):
        self.materials = []
        self.material_ids = {}
        self.meshes = []
        self.nodes = []
        self.accessors = []
        self.buffer_views = []
        self.bin = bytearray()

    def material(self, name, color, metal=0.0, rough=0.9):
        if name in self.material_ids:
            return self.material_ids[name]
        rgba = linear_rgba(color)
        entry = {
            "name": name,
            "doubleSided": True,
            "pbrMetallicRoughness": {
                "baseColorFactor": [round(c, 5) for c in rgba],
                "metallicFactor": metal,
                "roughnessFactor": rough,
            },
        }
        if rgba[3] < 0.999:
            entry["alphaMode"] = "BLEND"
        index = len(self.materials)
        self.materials.append(entry)
        self.material_ids[name] = index
        return index

    def add_box(self, name, center, axes, sizes, material_index):
        """Axis box in a right-handed frame.

        `axes` is (au, av, an), each a unit vector. Sizes are full extents
        along those axes. The mesh is centered on `center`.
        """
        au, av, an = axes
        hx, hy, hz = (sizes[0] / 2, sizes[1] / 2, sizes[2] / 2)
        if hx < 1e-5 or hy < 1e-5 or hz < 1e-5:
            return

        def world(x, y, z):
            return (
                center[0] + x * au[0] + y * av[0] + z * an[0],
                center[1] + x * au[1] + y * av[1] + z * an[1],
                center[2] + x * au[2] + y * av[2] + z * an[2],
            )

        def normal(x, y, z):
            nx = x * au[0] + y * av[0] + z * an[0]
            ny = x * au[1] + y * av[1] + z * an[1]
            nz = x * au[2] + y * av[2] + z * an[2]
            length = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            return (nx / length, ny / length, nz / length)

        # Local winding matches an outward-facing box: +X, -X, +Y, -Y, +Z, -Z.
        faces = [
            ((1, 0, 0), [(hx, -hy, -hz), (hx, -hy, hz), (hx, hy, hz), (hx, hy, -hz)]),
            ((-1, 0, 0), [(-hx, -hy, hz), (-hx, -hy, -hz), (-hx, hy, -hz), (-hx, hy, hz)]),
            ((0, 1, 0), [(-hx, hy, hz), (hx, hy, hz), (hx, hy, -hz), (-hx, hy, -hz)]),
            ((0, -1, 0), [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, -hy, hz), (-hx, -hy, hz)]),
            ((0, 0, 1), [(-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]),
            ((0, 0, -1), [(hx, -hy, -hz), (-hx, -hy, -hz), (-hx, hy, -hz), (hx, hy, -hz)]),
        ]
        positions = []
        normals = []
        indices = []
        for local_normal, corners in faces:
            base = len(positions) // 3
            n = normal(*local_normal)
            for corner in corners:
                p = world(*corner)
                positions.extend(p)
                normals.extend(n)
            indices.extend((base, base + 1, base + 2, base, base + 2, base + 3))

        pos_view = self._view(struct.pack("<" + "f" * len(positions), *positions), 34962)
        nrm_view = self._view(struct.pack("<" + "f" * len(normals), *normals), 34962)
        idx_view = self._view(struct.pack("<" + "H" * len(indices), *indices), 34963)
        pos_acc = self._vec3_accessor(pos_view, len(positions) // 3, positions)
        nrm_acc = self._vec3_accessor(nrm_view, len(normals) // 3, normals)
        idx_acc = len(self.accessors)
        self.accessors.append(
            {
                "bufferView": idx_view,
                "componentType": 5123,
                "count": len(indices),
                "type": "SCALAR",
            }
        )
        mesh_index = len(self.meshes)
        self.meshes.append(
            {
                "name": name,
                "primitives": [
                    {
                        "attributes": {"POSITION": pos_acc, "NORMAL": nrm_acc},
                        "indices": idx_acc,
                        "material": material_index,
                    }
                ],
            }
        )
        self.nodes.append({"name": name, "mesh": mesh_index})

    def _view(self, blob: bytes, target: int) -> int:
        while len(self.bin) % 4:
            self.bin.append(0)
        offset = len(self.bin)
        self.bin.extend(blob)
        index = len(self.buffer_views)
        self.buffer_views.append(
            {
                "buffer": 0,
                "byteOffset": offset,
                "byteLength": len(blob),
                "target": target,
            }
        )
        return index

    def _vec3_accessor(self, view, count, flat):
        xs = flat[0::3]
        ys = flat[1::3]
        zs = flat[2::3]
        index = len(self.accessors)
        self.accessors.append(
            {
                "bufferView": view,
                "componentType": 5126,
                "count": count,
                "type": "VEC3",
                "min": [min(xs), min(ys), min(zs)],
                "max": [max(xs), max(ys), max(zs)],
            }
        )
        return index

    def pack(self) -> bytes:
        child_indexes = list(range(len(self.nodes)))
        root = len(self.nodes)
        self.nodes.append({"name": "Apartment", "children": child_indexes})
        document = {
            "asset": {
                "version": "2.0",
                "generator": "home-scanner make_sample_glb.py",
            },
            "scene": 0,
            "scenes": [{"name": "Apartment", "nodes": [root]}],
            "nodes": self.nodes,
            "meshes": self.meshes,
            "materials": self.materials,
            "accessors": self.accessors,
            "bufferViews": self.buffer_views,
            "buffers": [{"byteLength": len(self.bin)}],
        }
        json_blob = json.dumps(document, separators=(",", ":")).encode("utf-8")
        while len(json_blob) % 4:
            json_blob += b" "
        bin_blob = bytes(self.bin)
        while len(bin_blob) % 4:
            bin_blob += b"\0"
        length = 12 + 8 + len(json_blob) + 8 + len(bin_blob)
        header = struct.pack("<4sII", b"glTF", 2, length)
        json_chunk = struct.pack("<I4s", len(json_blob), b"JSON") + json_blob
        bin_chunk = struct.pack("<I4s", len(bin_blob), b"BIN\0") + bin_blob
        return header + json_chunk + bin_chunk


def floor_color(room_name: str):
    name = room_name.lower()
    if "kitchen" in name:
        return (0.93, 0.89, 0.80)
    if "living" in name:
        return (0.86, 0.90, 0.86)
    if "bed" in name:
        return (0.84, 0.80, 0.76)
    return (0.88, 0.86, 0.82)


def project_opening(wall, opening):
    start = wall["start"]
    end = wall["end"]
    dx = end["x"] - start["x"]
    dz = end["z"] - start["z"]
    length = math.hypot(dx, dz)
    if length < 1e-6:
        return None
    ux, uz = dx / length, dz / length
    nx, nz = -uz, ux
    center = opening["center"]
    vx = center["x"] - start["x"]
    vz = center["z"] - start["z"]
    t = vx * ux + vz * uz
    dist = abs(vx * nx + vz * nz)
    yaw = float(opening.get("yaw") or 0)
    width_dir = (math.cos(yaw), -math.sin(yaw))
    along = abs(width_dir[0] * ux + width_dir[1] * uz)
    half = float(opening["width"]) / 2 * max(along, 0.15)
    return {
        "t": t,
        "dist": dist,
        "length": length,
        "t0": t - half,
        "t1": t + half,
        "y0": float(center["y"]) - float(opening["height"]) / 2,
        "y1": float(center["y"]) + float(opening["height"]) / 2,
        "opening": opening,
        "ux": ux,
        "uz": uz,
        "nx": nx,
        "nz": nz,
    }


def subtract_holes(length, height, holes):
    solids = [(0.0, length, 0.0, height)]
    for t0, t1, y0, y1 in holes:
        nxt = []
        for s0, s1, sy0, sy1 in solids:
            if t1 <= s0 or t0 >= s1 or y1 <= sy0 or y0 >= sy1:
                nxt.append((s0, s1, sy0, sy1))
                continue
            if t0 > s0:
                nxt.append((s0, min(t0, s1), sy0, sy1))
            if t1 < s1:
                nxt.append((max(t1, s0), s1, sy0, sy1))
            overlap_t0 = max(s0, t0)
            overlap_t1 = min(s1, t1)
            if sy0 < y0:
                nxt.append((overlap_t0, overlap_t1, sy0, min(sy1, y0)))
            if sy1 > y1:
                nxt.append((overlap_t0, overlap_t1, max(sy0, y1), sy1))
        solids = [item for item in nxt if item[1] - item[0] > 1e-4 and item[3] - item[2] > 1e-4]
    return solids


def add_frame_box(writer, name, center, au, av, an, sizes, material):
    writer.add_box(name, center, (au, av, an), sizes, material)


def wall_frame(wall):
    start = wall["start"]
    end = wall["end"]
    dx = end["x"] - start["x"]
    dz = end["z"] - start["z"]
    length = math.hypot(dx, dz)
    ux, uz = dx / length, dz / length
    return {
        "start": start,
        "length": length,
        "height": float(wall.get("height") or 2.4),
        "thickness": float(wall.get("thickness") or 0.12),
        "au": (ux, 0.0, uz),
        "av": (0.0, 1.0, 0.0),
        "an": (-uz, 0.0, ux),
    }


def emit_wall(writer, wall, openings, plaster, door_mat, glass_mat):
    frame = wall_frame(wall)
    if frame["length"] < 1e-4:
        return
    ranked = []
    for opening in openings:
        projected = project_opening(wall, opening)
        if projected is None:
            continue
        thickness = frame["thickness"]
        if projected["dist"] > max(0.25, thickness + 0.08):
            continue
        if projected["t1"] < -0.02 or projected["t0"] > frame["length"] + 0.02:
            continue
        ranked.append(projected)
    holes = []
    for item in ranked:
        t0 = max(0.0, item["t0"])
        t1 = min(frame["length"], item["t1"])
        y0 = max(0.0, item["y0"])
        y1 = min(frame["height"], item["y1"])
        if t1 - t0 > 0.05 and y1 - y0 > 0.05:
            holes.append((t0, t1, y0, y1, item))
    solids = subtract_holes(frame["length"], frame["height"], [(h[0], h[1], h[2], h[3]) for h in holes])
    short = wall["id"].split("-")[-1][-4:]
    for index, (t0, t1, y0, y1) in enumerate(solids):
        center_t = (t0 + t1) / 2
        center = (
            frame["start"]["x"] + frame["au"][0] * center_t,
            (y0 + y1) / 2,
            frame["start"]["z"] + frame["au"][2] * center_t,
        )
        add_frame_box(
            writer,
            f"wall-{short}-{index}",
            center,
            frame["au"],
            frame["av"],
            frame["an"],
            (t1 - t0, y1 - y0, frame["thickness"]),
            plaster,
        )
    for item_index, (t0, t1, y0, y1, item) in enumerate(holes):
        kind = item["opening"].get("kind")
        if kind == "opening":
            continue
        inset = 0.03 if kind == "door" else 0.02
        slab_t0 = t0 + inset
        slab_t1 = t1 - inset
        slab_y0 = y0
        slab_y1 = y1 - inset
        if slab_t1 - slab_t0 < 0.05 or slab_y1 - slab_y0 < 0.05:
            continue
        center_t = (slab_t0 + slab_t1) / 2
        center = (
            frame["start"]["x"] + frame["au"][0] * center_t,
            (slab_y0 + slab_y1) / 2,
            frame["start"]["z"] + frame["au"][2] * center_t,
        )
        if kind == "window":
            add_frame_box(
                writer,
                f"window-{short}-{item_index}",
                center,
                frame["au"],
                frame["av"],
                frame["an"],
                (slab_t1 - slab_t0, slab_y1 - slab_y0, 0.02),
                glass_mat,
            )
        else:
            add_frame_box(
                writer,
                f"door-{short}-{item_index}",
                center,
                frame["au"],
                frame["av"],
                frame["an"],
                (slab_t1 - slab_t0, slab_y1 - slab_y0, frame["thickness"] + 0.04),
                door_mat,
            )


def emit_floor(writer, room, material):
    for floor in room["floor_plan"].get("floors") or []:
        corners = floor.get("corners") or []
        if len(corners) < 3:
            continue
        xs = [c["x"] for c in corners]
        zs = [c["z"] for c in corners]
        x0, x1 = min(xs), max(xs)
        z0, z1 = min(zs), max(zs)
        if x1 - x0 < 1e-3 or z1 - z0 < 1e-3:
            continue
        short = floor["id"].split("-")[-1][-4:]
        add_frame_box(
            writer,
            f"floor-{short}",
            ((x0 + x1) / 2, -0.02, (z0 + z1) / 2),
            (1, 0, 0),
            (0, 1, 0),
            (0, 0, 1),
            (x1 - x0, 0.04, z1 - z0),
            material,
        )


def emit_object(writer, obj, material):
    center = obj["center"]
    dims = obj["dimensions"]
    yaw = float(obj.get("yaw") or 0)
    au = (math.cos(yaw), 0.0, -math.sin(yaw))
    av = (0.0, 1.0, 0.0)
    an = (math.sin(yaw), 0.0, math.cos(yaw))
    category = obj.get("category") or "object"
    short = obj["id"].split("-")[-1][-4:]
    add_frame_box(
        writer,
        f"{category}-{short}",
        (center["x"], center["y"], center["z"]),
        au,
        av,
        an,
        (float(dims["x"]), float(dims["y"]), float(dims["z"])),
        material,
    )


def build(layout: dict) -> GltfWriter:
    if layout.get("format") != "roomscan.home" or layout.get("version") != 1:
        raise SystemExit("layout must be roomscan.home version 1")
    writer = GltfWriter()
    plaster = writer.material("plaster", PLASTER, rough=0.92)
    door_mat = writer.material("door", DOOR, rough=0.55)
    glass_mat = writer.material("glass", GLASS, rough=0.08)
    home = layout["home"]
    openings = []
    for room in home.get("rooms") or []:
        openings.extend(room.get("floor_plan", {}).get("openings") or [])
    for room in home.get("rooms") or []:
        plan = room.get("floor_plan") or {}
        floor_mat = writer.material(
            f"floor-{room['name'].lower().replace(' ', '-')}",
            floor_color(room.get("name") or ""),
            rough=0.86,
        )
        emit_floor(writer, room, floor_mat)
        for wall in plan.get("walls") or []:
            emit_wall(writer, wall, openings, plaster, door_mat, glass_mat)
        for obj in plan.get("objects") or []:
            category = obj.get("category") or "object"
            color = OBJECT_COLORS.get(category, WOOD)
            metal = 0.35 if category in {"refrigerator", "washer_dryer", "oven", "dishwasher"} else 0.0
            mat = writer.material(category, color, metal=metal, rough=0.45 if metal else 0.72)
            emit_object(writer, obj, mat)
    if not writer.meshes:
        raise SystemExit("layout produced no meshes")
    return writer


def verify(path: Path, payload: bytes):
    if payload[:4] != b"glTF":
        raise SystemExit("missing glTF magic")
    version, length = struct.unpack_from("<II", payload, 4)
    if version != 2 or length != len(payload):
        raise SystemExit(f"bad glb header version={version} length={length}")
    json_len = struct.unpack_from("<I", payload, 12)[0]
    document = json.loads(payload[20 : 20 + json_len])
    names = [node.get("name", "") for node in document["nodes"]]
    if not any(name.startswith("door-") for name in names):
        raise SystemExit("expected a door mesh")
    if not any(name.startswith("window-") for name in names):
        raise SystemExit("expected a window mesh")
    if not any(name.startswith("floor-") for name in names):
        raise SystemExit("expected a floor mesh")
    print(f"wrote {path} ({len(payload)} bytes, {len(document['meshes'])} meshes)")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layout", type=Path, default=DEFAULT_LAYOUT)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args(argv)
    layout = json.loads(args.layout.read_text())
    payload = build(layout).pack()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(payload)
    verify(args.out, payload)


if __name__ == "__main__":
    main(sys.argv[1:])
