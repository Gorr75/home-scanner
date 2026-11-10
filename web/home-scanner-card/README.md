# Home Scanner Lovelace card

The card lists rooms uploaded by the iPhone app and opens the floor plan or `model.glb` for the one you pick. It does not replace `viewer.html`. An existing iframe dashboard can keep using that file.

Each upload is still the same contract, plus optional photo plates:

```text
/local/home_scanner/<slug>/layout.json
/local/home_scanner/<slug>/model.glb
/local/home_scanner/<slug>/model.usdz    # optional
/local/home_scanner/<slug>/plates/       # optional day and night plates
```

`<slug>` is the home UUID or the room UUID. Prefer a room slug when the pins should sit on that room's model. `layout.json` is a `roomscan.home` version 1 document and never contains a token.

## Install

Home Assistant 2024.1 or newer. Copy one file into the config `www` directory:

```text
/config/www/community/home-scanner-card/home-scanner-card.js
```

The source in this repo is `web/home-scanner-card/home-scanner-card.js`.

Add a Lovelace resource. In the UI: Settings → Dashboards → Resources → Add resource.

- URL: `/local/community/home-scanner-card/home-scanner-card.js`
- Type: JavaScript module

Or in YAML:

```yaml
lovelace:
  resources:
    - url: /local/community/home-scanner-card/home-scanner-card.js
      type: module
```

Restart Home Assistant if the resource does not appear, then add the card to the view whose path is `home-scanner` (the app opens `homeassistant://navigate/lovelace/home-scanner` after an upload).

### Where the room list comes from

The card tries these, in order:

1. `rooms` or `slug` in the card config, when you set them.
2. `GET /api/home_scanner/rooms` on the signed-in dashboard session. The `home_scanner` integration scans `/config/www/home_scanner/` and refreshes `index.json`.
3. `/local/home_scanner/index.json`, which the integration rewrites after each upload.

`index.json` looks like:

```json
{
  "format": "home_scanner.index",
  "version": 1,
  "rooms": [
    {
      "slug": "ROOM-UUID",
      "name": "Kitchen",
      "path": "/local/home_scanner/ROOM-UUID/",
      "files": ["layout.json", "model.glb"]
    }
  ]
}
```

A folder shows up when it contains `layout.json`. A one-room file is titled with that room's name. A whole-home file is titled with the home name.

## Card config

Discover whatever has been uploaded:

```yaml
type: custom:home-scanner-card
title: Home Scanner
```

Or pin the folders yourself. This works even when the integration has not written an index yet (for example a zip unpacked into `www`):

```yaml
type: custom:home-scanner-card
title: Kitchen
rooms:
  - slug: YOUR-ROOM-UUID
    name: Kitchen
```

`slug: YOUR-ROOM-UUID` on its own is the one-room form.

Plan is drawn from `layout.json` (floors, walls, pins). 3D loads `model.glb`. Photo composites plates from `plates/manifest.json` instead of loading the model: a lights-off base, then one plate per light with `mix-blend-mode: screen`. Opacity follows brightness and the colour follows the light's colour. Tap a light region, or a plan pin, to toggle it through the dashboard session. The long-lived token stays on the iPhone. Do not put it in the card config.

`view: plan`, `view: model`, or `view: photo` picks the tab a wall tablet opens on. The default is the plan.

When a room has `floor` in the layout, the card shows a floor picker. A multi-room layout also lists the rooms on that floor and aims the 3D camera at the room's `viewpoint` (`camera-orbit` and `camera-target`). Photo mode for a whole-home folder loads plates from that room's own folder, `/local/home_scanner/<room-id>/plates/`. A one-room folder uses the plates uploaded beside its layout. Day and night plates follow `sun.sun` with the same mapping as the 3D tint: the night phase uses the night set, and sunrise, sunset, and day use the day set.

A room list in the card config can set `floor` too, which groups those folders:

```yaml
type: custom:home-scanner-card
title: Home
view: photo
rooms:
  - slug: KITCHEN-UUID
    name: Kitchen
    floor: 0
  - slug: LOFT-UUID
    name: Loft
    floor: 1
```

The plan and the model take a daylight tint from `sun.sun` (elevation, then next rising and setting, then above or below the horizon). If that entity is missing, the card uses this device's clock, with sunrise at 06:00 and sunset at 18:00. Light pins keep the colour Home Assistant reports, so a lamp still reads when the room is dim.

The 3D tab uses [`<model-viewer>`](https://modelviewer.dev/). Put `model-viewer.min.js` (a module build) next to `home-scanner-card.js` if Home Assistant cannot fetch it. Without that script the plan tab still works.

Pins are drawn on the model only when the layout is one room, or `structure.coordinates_are_unified` is true. Otherwise open the room slug. The same rule is in `web/viewer/README.md`.

## Existing iframe

If a dashboard already points at `/local/home_scanner/viewer.html`, leave that file in place or replace it with `web/viewer/viewer.html` from this repo. The page reads `?slug=`, `?room=`, or `?id=`, and lists rooms from `index.json` when the query is empty. The Lovelace card does not require that file.
