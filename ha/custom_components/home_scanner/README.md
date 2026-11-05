# Home Scanner for Home Assistant

The iPhone app uploads a floor plan to this integration. Each upload is stored where Home Assistant already serves static files:

```text
/config/www/home_scanner/<id>/layout.json
/config/www/home_scanner/<id>/model.glb
/config/www/home_scanner/<id>/model.usdz   # optional RoomPlan model
```

Those files are available in the browser and to a Lovelace card at:

```text
/local/home_scanner/<id>/layout.json
/local/home_scanner/<id>/model.glb
```

`<id>` is the home UUID, and again for each room UUID. A room folder's `layout.json` is a `roomscan.home` document containing that one room. The card in `web/viewer` should read `layout.json` and `model.glb` from the room folder.

A successful upload fires `home_scanner_layout_updated` with `room`, `path`, and `files`.

The iPhone calls:

- `GET /api/home_scanner/health` with `Authorization: Bearer <long-lived token>`
- `POST /api/home_scanner/upload/<id>` as multipart form data. Parts are named `file` and the filenames are `layout.json`, `model.glb`, and optionally `model.usdz`.

## Install

Home Assistant 2024.1 or newer.

### Manual copy

Copy this folder to your config directory:

```text
<config>/custom_components/home_scanner/
```

The folder must contain `manifest.json`. Restart Home Assistant.

Then either:

1. Settings → Devices & services → Add integration → Home Scanner → Submit.
2. Or add this to `configuration.yaml` and restart again:

```yaml
home_scanner:
```

### HACS

This repository keeps the integration under `ha/custom_components/home_scanner` so it can live next to the iOS app. A `custom_components` link at the repository root points at that folder, which is the layout HACS expects.

1. HACS → Integrations → Custom repositories.
2. Add `https://github.com/Gorr75/home-scanner` as category **Integration**.
3. Download **Home Scanner** and restart.
4. Add the integration from Settings → Devices & services.

If HACS does not list it, use the manual copy. The files are the same.

## Dashboard

Create a Lovelace view with path `home-scanner` so the iPhone can open it with `homeassistant://navigate/lovelace/home-scanner`.

Install the card from `web/home-scanner-card/README.md`, then:

```yaml
title: Home
views:
  - title: Floor
    path: home-scanner
    cards:
      - type: custom:home-scanner-card
        title: Home Scanner
```

The card reads `/local/home_scanner/<id>/layout.json` and `model.glb`. After an upload the integration rewrites `/config/www/home_scanner/index.json` and serves the same list at `GET /api/home_scanner/rooms`. A card config can also name the slugs itself.

An existing iframe can keep using `/local/home_scanner/viewer.html`. The copy in `web/viewer/viewer.html` is the one in this repo. It accepts `?slug=`, `?room=`, or `?id=`.

The long-lived access token is created in your Home Assistant profile. It stays in the iPhone Keychain. Do not put it in `layout.json` or in the card config.

## Zip fallback

The app can also share a `.zip` with the same `home_scanner/<id>/` paths. Unzip it into `/config/www/` so the files land in `/config/www/home_scanner/<id>/`.
