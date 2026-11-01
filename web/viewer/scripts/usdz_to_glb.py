#!/usr/bin/env python3
"""Convert a Home Scanner USDZ export to a binary glTF (.glb).

RoomPlan writes USDZ. The web viewer and the Lovelace card load GLB.
Drop the result next to the layout file the integration serves:

    /config/www/home_scanner/<room>/model.glb
    /config/www/home_scanner/<room>/layout.json

Requires Blender 3.6 or newer (USD import and glTF export):

    python3 scripts/usdz_to_glb.py Kitchen.usdz /config/www/home_scanner/kitchen/model.glb

The Python command re-invokes Blender. You can also call Blender yourself:

    blender --background --python scripts/usdz_to_glb.py -- \\
        Kitchen.usdz /config/www/home_scanner/kitchen/model.glb

In the Blender UI: File → Import → Universal Scene Description (.usd/.usdz),
then File → Export → glTF 2.0 (.glb). Apple's Reality Converter on macOS
exports GLB as well.

If you already have usd2gltf installed, that works too:

    usd2gltf -i Kitchen.usdz -o model.glb
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


def arguments():
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1 :]
    return [arg for arg in sys.argv[1:] if not arg.startswith("-")]


def convert(src: Path, dst: Path):
    import bpy

    if not src.is_file():
        raise SystemExit(f"No such file: {src}")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.usd_import(filepath=str(src))
    dst.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(dst), export_format="GLB")
    if not dst.is_file():
        raise SystemExit(f"Blender did not write {dst}")
    print(f"wrote {dst} ({dst.stat().st_size} bytes)")


def main():
    args = arguments()
    if len(args) != 2:
        raise SystemExit(
            "Usage: python3 scripts/usdz_to_glb.py input.usdz output.glb\n"
            "Blender 3.6+ must be on PATH. See the script docstring for the manual export."
        )
    src, dst = Path(args[0]).expanduser(), Path(args[1]).expanduser()
    if not src.is_file():
        raise SystemExit(f"No such file: {src}")

    try:
        import bpy  # noqa: F401
    except ImportError:
        bpy = None

    if bpy is not None:
        convert(src, dst)
        return

    blender = shutil.which("blender")
    if not blender:
        raise SystemExit(
            "Blender is not on PATH, so this USDZ was not converted.\n"
            "Install Blender 3.6 or newer and run:\n"
            f"  blender --background --python {Path(__file__).name} -- {src} {dst}\n"
            "Or export GLB from Blender's UI (Import USD, Export glTF 2.0),\n"
            "or from Reality Converter on macOS, or with usd2gltf."
        )
    subprocess.check_call(
        [blender, "--background", "--python", str(Path(__file__).resolve()), "--", str(src), str(dst)]
    )


if __name__ == "__main__":
    main()
