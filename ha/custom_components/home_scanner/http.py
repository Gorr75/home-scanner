"""Authenticated upload of a Home Scanner layout and model."""

from __future__ import annotations

import json
import logging
import os

from aiohttp import web
from homeassistant.components.http import HomeAssistantView
from homeassistant.core import HomeAssistant

from .const import ALLOWED_FILES, DOMAIN, EVENT_LAYOUT_UPDATED, MAX_BYTES
from .paths import destination_dir, safe_slug

_LOGGER = logging.getLogger(__name__)


def async_register(hass: HomeAssistant) -> None:
    """Register the health and upload views once."""
    data = hass.data.setdefault(DOMAIN, {})
    if data.get("views_registered"):
        return
    hass.http.register_view(HealthView())
    hass.http.register_view(UploadView())
    data["views_registered"] = True


class HealthView(HomeAssistantView):
    """GET /api/home_scanner/health — used by the app's Test connection button."""

    url = "/api/home_scanner/health"
    name = "api:home_scanner:health"
    requires_auth = True

    async def get(self, request: web.Request) -> web.Response:
        return self.json({"ok": True, "domain": DOMAIN})


class UploadView(HomeAssistantView):
    """POST /api/home_scanner/upload/{room} with multipart layout.json and model.glb."""

    url = "/api/home_scanner/upload/{room}"
    name = "api:home_scanner:upload"
    requires_auth = True

    async def post(self, request: web.Request, room: str) -> web.Response:
        slug = safe_slug(room)
        if slug is None:
            return self.json_message("Unsafe room name.", 400)

        hass: HomeAssistant = request.app["hass"]
        try:
            reader = await request.multipart()
        except Exception:  # noqa: BLE001 - aiohttp raises several types for a bad body
            return self.json_message("Expected a multipart upload.", 400)

        files: dict[str, bytes] = {}
        total = 0
        while True:
            part = await reader.next()
            if part is None:
                break
            filename = part.filename
            if filename not in ALLOWED_FILES:
                return self.json_message(
                    "Only layout.json, model.glb, and model.usdz are accepted.",
                    400,
                )
            payload = await _read_limited(part, MAX_BYTES - total)
            if payload is None:
                return web.Response(status=413, text="Upload is too large.")
            total += len(payload)
            files[filename] = payload

        if "layout.json" not in files:
            return self.json_message("layout.json is required.", 400)
        if not _is_json(files["layout.json"]):
            return self.json_message("layout.json is not JSON.", 400)

        try:
            written = await hass.async_add_executor_job(
                _write_files,
                hass.config.config_dir,
                slug,
                files,
            )
        except ValueError:
            return self.json_message("Unsafe room name.", 400)
        except OSError as err:
            _LOGGER.error("Could not store Home Scanner upload for %s: %s", slug, err)
            return self.json_message("Could not store the upload.", 500)

        local_path = f"/local/home_scanner/{slug}/"
        hass.bus.async_fire(
            EVENT_LAYOUT_UPDATED,
            {"room": slug, "path": local_path, "files": written},
        )
        _LOGGER.info("Stored Home Scanner layout for %s (%s)", slug, ", ".join(written))
        return self.json(
            {"ok": True, "room": slug, "files": written, "local_path": local_path}
        )


async def _read_limited(part, remaining: int) -> bytes | None:
    if remaining <= 0:
        return None
    chunks: list[bytes] = []
    size = 0
    while True:
        block = await part.read_chunk(65536)
        if not block:
            break
        size += len(block)
        if size > remaining:
            return None
        chunks.append(block)
    return b"".join(chunks)


def _is_json(payload: bytes) -> bool:
    try:
        json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    return True


def _write_files(config_dir: str, slug: str, files: dict[str, bytes]) -> list[str]:
    folder = destination_dir(config_dir, slug)
    os.makedirs(folder, exist_ok=True)
    written: list[str] = []
    for name in ALLOWED_FILES:
        payload = files.get(name)
        if payload is None:
            continue
        target = os.path.join(folder, name)
        temporary = target + ".tmp"
        with open(temporary, "wb") as handle:
            handle.write(payload)
        os.replace(temporary, target)
        written.append(name)
    return written
