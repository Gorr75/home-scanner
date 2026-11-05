# Home Scanner viewer contract

The Lovelace card reads one folder per room (or per home) from Home Assistant's static www directory.

```text
/local/home_scanner/<id>/layout.json
/local/home_scanner/<id>/model.glb
```

`<id>` is a UUID. The iPhone uploads the home under the home id and each room under the room id. Prefer the room id when drawing one room: that `layout.json` is a `roomscan.home` version 1 document whose `home.rooms` array contains that room, and `model.glb` is in the same coordinate space as that room's pins (Y up, meters).

`model.usdz` may sit beside the GLB. It is the original RoomPlan model. The GLB is generated from the measured floor plan (floors, walls, openings, objects) so the card does not need a USD loader.

`layout.json` uses the format in [docs/home-assistant.md](../../docs/home-assistant.md). It never contains the Home Assistant token.

The Lovelace card is `web/home-scanner-card/home-scanner-card.js`. Install steps are in that folder's README. It lists rooms from `GET /api/home_scanner/rooms`, from `/local/home_scanner/index.json`, or from its own config, then draws the plan and loads `model.glb`.

`viewer.html` in this folder is the static page for a hand-wired iframe at `/local/home_scanner/viewer.html`. Copy it there if you want this repo's page. Open `?slug=<id>` (also `?room=` or `?id=`). With no query it lists `index.json`, which the integration writes after each upload. The card does not require this file, and copying it is optional if a dashboard already has its own viewer.

Optional: listen for the `home_scanner_layout_updated` event (`room`, `path`, `files`) and reload the card. The card also reloads a room when you pick it.
