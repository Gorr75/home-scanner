"""Index of uploaded rooms under /config/www/home_scanner/."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone

from .paths import destination_dir, safe_slug

INDEX_FORMAT = "home_scanner.index"
INDEX_VERSION = 1
UPLOAD_FILES = ("layout.json", "model.glb", "model.usdz")


def display_name(layout: object, slug: str) -> str:
    """Prefer the only room's name, then the home name, then the folder slug."""
    if not isinstance(layout, dict):
        return slug
    home = layout.get("home")
    if not isinstance(home, dict):
        return slug
    rooms = home.get("rooms")
    if isinstance(rooms, list) and len(rooms) == 1 and isinstance(rooms[0], dict):
        name = rooms[0].get("name")
        if isinstance(name, str) and name.strip():
            return name.strip()
    name = home.get("name")
    if isinstance(name, str) and name.strip():
        return name.strip()
    return slug


def room_entry(slug: str, layout_bytes: bytes, files: list[str], updated_at: str) -> dict:
    try:
        layout = json.loads(layout_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        layout = None
    return {
        "slug": slug,
        "name": display_name(layout, slug),
        "path": f"/local/home_scanner/{slug}/",
        "files": list(files),
        "updated_at": updated_at,
    }


def scan_index(config_dir: str) -> dict:
    """Read each room folder. Does not follow a path that escapes www/home_scanner."""
    root = os.path.realpath(os.path.join(config_dir, "www", "home_scanner"))
    rooms: list[dict] = []
    if os.path.isdir(root):
        for name in sorted(os.listdir(root)):
            if safe_slug(name) is None:
                continue
            try:
                folder = destination_dir(config_dir, name)
            except ValueError:
                continue
            if not os.path.isdir(folder):
                continue
            layout_path = os.path.join(folder, "layout.json")
            if not os.path.isfile(layout_path):
                continue
            files = [filename for filename in UPLOAD_FILES if os.path.isfile(os.path.join(folder, filename))]
            try:
                with open(layout_path, "rb") as handle:
                    payload = handle.read()
                stamp = os.path.getmtime(layout_path)
            except OSError:
                continue
            updated = datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            rooms.append(room_entry(name, payload, files, updated))
    rooms.sort(key=lambda item: ((item.get("name") or "").lower(), item.get("slug") or ""))
    return {"format": INDEX_FORMAT, "version": INDEX_VERSION, "rooms": rooms}


def publish_index(config_dir: str) -> dict:
    """Rewrite /config/www/home_scanner/index.json from the folders on disk."""
    index = scan_index(config_dir)
    root = os.path.realpath(os.path.join(config_dir, "www", "home_scanner"))
    os.makedirs(root, exist_ok=True)
    target = os.path.join(root, "index.json")
    temporary = target + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(index, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, target)
    return index
