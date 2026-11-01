"""Safe paths under /config/www/home_scanner/<room>/."""

from __future__ import annotations

import os
import re

_SLUG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,80}$")


def safe_slug(room: str) -> str | None:
    if not isinstance(room, str):
        return None
    if _SLUG.fullmatch(room) is None:
        return None
    return room


def destination_dir(config_dir: str, slug: str) -> str:
    """Return the folder for one room, or raise ValueError."""
    if safe_slug(slug) is None:
        raise ValueError("unsafe room")
    root = os.path.realpath(os.path.join(config_dir, "www", "home_scanner"))
    dest = os.path.realpath(os.path.join(root, slug))
    if os.path.commonpath([root, dest]) != root:
        raise ValueError("unsafe room")
    return dest
