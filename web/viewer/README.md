# Home Scanner web viewer

Experimental three.js viewer for a Home Scanner export. It is the groundwork for a Home Assistant Lovelace card: orbit a room, see device pins, and read entity state.

No build step and no `npm install`. The page is static. three.js r0.170.0 (MIT) is vendored in `vendor/`. The example modules import `./three.module.js` directly, so the folder does not need an import map.

Two folders stay separate:

| Path | What it is |
| --- | --- |
| `/config/www/home-scanner/` | This viewer. The card, scripts, and the bundled sample. |
| `/config/www/home_scanner/<room>/` | Uploads from the `home_scanner` integration: `layout.json` and `model.glb`. Served at `/local/home_scanner/<room>/`. |

`home-scanner` (hyphen) is the card. `home_scanner` (underscore) is the scan data. A room folder name is a slug (`kitchen`, `living-room`), not a path.

## Play with the sample

From this directory:

```sh
python3 -m http.server 8765
```

Open `http://127.0.0.1:8765/`. The page loads `sample/sample-apartment.glb` and `sample/sample-apartment.roomscan.json`.

Drag to orbit, scroll to zoom, click a pin. The panel shows the pin's `entity_id`. Lights and switches toggle a mock state (kitchen light starts on, living room light starts off, the switch starts on). The temperature pin shows `21.5 °C` and does not toggle. That matches `MockHomeStateProvider` in the app.

Drop a `.glb` / `.gltf` and a `.roomscan.json` onto the page, or use the file buttons, to try your own export. Query params work too: `?model=room.glb&layout=home.roomscan.json`.

`card-preview.html` mounts the same Lovelace element against `sample-rooms/`, which is laid out like the integration's upload folder (two rooms, one shared sample model). The preview supplies fake entity states so the card can be tried without Home Assistant.

## Sample room

`scripts/make_sample_glb.py` reads the sample layout and writes the GLB: floors, walls, a door, a window, and furniture boxes (refrigerator, tables, sofa). Coordinates are meters, Y up, the same space as the pins.

```sh
python3 scripts/make_sample_glb.py
```

The layout file is a copy of `docs/examples/sample-apartment.roomscan.json` (`format` `roomscan.home`, `version` 1). The viewer rejects any other format or version.

## USDZ to GLB

The app shares USDZ. This viewer loads GLB. Convert with Blender 3.6 or newer:

```sh
python3 scripts/usdz_to_glb.py Kitchen.usdz /config/www/home_scanner/kitchen/model.glb
```

That command finds `blender` on `PATH` and re-invokes it. Or call Blender directly:

```sh
blender --background --python scripts/usdz_to_glb.py -- \
  Kitchen.usdz /config/www/home_scanner/kitchen/model.glb
```

The same export from the Blender UI: Import → Universal Scene Description, then Export → glTF 2.0 (`.glb`). On a Mac, Reality Converter exports GLB too. If `usd2gltf` is installed: `usd2gltf -i Kitchen.usdz -o model.glb`.

Copy the share-sheet `<Home name>.roomscan.json` to `layout.json` beside the GLB. The integration's "Send to Home Assistant" upload is expected to write both files itself; the script is for a manual drop.

## Install in Home Assistant

1. Copy this whole directory to `/config/www/home-scanner/` on the Home Assistant host. The card imports `js/` and `vendor/` by relative URL, so those files have to stay next to `home-scanner-card.js`.
2. Settings → Dashboards → ⋮ → Resources. Add:
   - URL: `/local/home-scanner/home-scanner-card.js?v=1`
   - Type: JavaScript module
3. Add the card. Bump `?v=` after you replace the files; Home Assistant caches the module.

```yaml
type: custom:home-scanner-card
room: kitchen
```

`room` is the folder under `/config/www/home_scanner/`. The card loads:

- `/local/home_scanner/kitchen/layout.json`
- `/local/home_scanner/kitchen/model.glb`

Leave `room` out and the card opens the first uploaded room. When more than one room exists it shows a picker. Discovery order:

1. `rooms:` in the card config, if you set it.
2. `GET /api/home_scanner/rooms` (what the integration can expose).
3. `/local/home_scanner/rooms.json` (what the integration can write).

`rooms.json` and the API use the same body:

```json
{
  "rooms": [
    { "id": "kitchen", "name": "Kitchen" },
    { "id": "living-room", "name": "Living room" }
  ]
}
```

`id` is the directory name. `name` is the picker label. A string entry is accepted too. Ids that contain `/` or `..` are ignored.

The card reads live states from `hass.states` and colours pins from them (light on glows, off is dim, a sensor shows its value and unit). Toggle calls `hass.callService(domain, "toggle", { entity_id })` for `light`, `switch`, and `fan`. Other domains show their state and do not toggle.

Until a room has been uploaded, you can point the card at the bundled sample instead:

```yaml
type: custom:home-scanner-card
layout: /local/home-scanner/sample/sample-apartment.roomscan.json
model: /local/home-scanner/sample/sample-apartment.glb
```

`example-card.yaml` has the same snippets. The standalone page keeps using the sample and the mock states either way.

## Checks

```sh
node --test scripts/logic.test.mjs
node scripts/render-check.mjs
```

The render check needs Chrome. It serves this folder, loads the sample, clicks a pin, toggles the living room light, and writes PNGs. Copies from that check are in `screenshots/`.

## Coordinates

Y is up. Units are meters. Pin positions in the layout are used as three.js positions, which matches ARKit, RoomPlan, and glTF. When `structure.coordinates_are_unified` is false the page says so: those pins are still in each room's own scan space.
