# Home Scanner viewer contract

The Lovelace card reads one folder per room (or per home) from Home Assistant's static www directory.

```text
/local/home_scanner/<id>/layout.json
/local/home_scanner/<id>/model.glb
```

`<id>` is a UUID. The iPhone uploads the home under the home id and each room under the room id. Prefer the room id when drawing one room: that `layout.json` is a `roomscan.home` version 1 document whose `home.rooms` array contains that room, and `model.glb` is in the same coordinate space as that room's pins (Y up, meters).

`model.usdz` may sit beside the GLB. It is the original RoomPlan model. The GLB is generated from the measured floor plan (floors, walls, openings, objects) so the card does not need a USD loader.

`layout.json` uses the format in [docs/home-assistant.md](../../docs/home-assistant.md). It never contains the Home Assistant token.

Optional: listen for the `home_scanner_layout_updated` event (`room`, `path`, `files`) and reload the card.
