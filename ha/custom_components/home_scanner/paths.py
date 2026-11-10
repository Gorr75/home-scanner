"""Safe paths under /config/www/home_scanner/<room>/."""

from __future__ import annotations

import os
import re

_SLUG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,80}$")
_UUID = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
_PLATE = re.compile(
    rf"^plates/(manifest\.json|(?:day|night)/base\.jpg|(?:day|night)/{_UUID}\.png)$"
)
FIXED_UPLOADS = ("layout.json", "model.glb", "model.usdz")


def safe_slug(room: str) -> str | None:
    if not isinstance(room, str):
        return None
    if _SLUG.fullmatch(room) is None:
        return None
    return room


def accepted_upload_name(name: object) -> bool:
    """layout.json, the models, and the photo-plate paths. Nothing with `..`."""
    if not isinstance(name, str):
        return False
    if name in FIXED_UPLOADS:
        return True
    return _PLATE.fullmatch(name) is not None


def upload_destination(folder: str, name: str) -> str:
    """Return the file path for one accepted upload name, or raise ValueError."""
    if not accepted_upload_name(name):
        raise ValueError("unsafe file")
    root = os.path.realpath(folder)
    dest = os.path.realpath(os.path.join(root, name))
    if os.path.commonpath([root, dest]) != root or dest == root:
        raise ValueError("unsafe file")
    return dest


def destination_dir(config_dir: str, slug: str) -> str:
    """Return the folder for one room, or raise ValueError."""
    if safe_slug(slug) is None:
        raise ValueError("unsafe room")
    root = os.path.realpath(os.path.join(config_dir, "www", "home_scanner"))
    dest = os.path.realpath(os.path.join(root, slug))
    if os.path.commonpath([root, dest]) != root:
        raise ValueError("unsafe room")
    return dest
