# Roadmap

Phone upload to Home Assistant is live. The app reads entity state over REST and a WebSocket, and the optional `home_scanner` integration accepts `GET /api/home_scanner/health` and `POST /api/home_scanner/upload/{room}`. Layouts land at `/local/home_scanner/<id>/layout.json`, `model.glb`, and an optional `model.usdz`.

The Lovelace card, live light colour in the 3D view, placing pins from areas, and daylight by time of day are in the app. v0.4, v0.5, and Later are what remains.

## Now

Done, in this order:

1. **Lovelace Home Scanner card.** A custom card discovers rooms under `/local/home_scanner/` (an index written by the integration, `GET /api/home_scanner/rooms`, or an explicit list in the card config) and opens the 3D viewer for the selected folder. That replaces a hand-wired iframe dashboard. The upload contract is unchanged: `layout.json` and `model.glb` in each home or room folder. `viewer.html` remains a static page for an existing iframe.
2. **Live light colour and brightness in the app 3D view.** Pins use the colour and brightness already present on the Home Assistant state (`rgb_color`, `hs_color`, or colour temperature, plus `brightness`), not only on/off text. A tap on the in-scene label or pin toggles a light, switch, or fan. Dimming stays on the selection bar, which is the control that was already next to the model.
3. **Auto-place pins from areas and names.** Linking is still manual when you want it. When you ask, the app suggests pins in the room whose name matches the Home Assistant area, the friendly name, or the entity id. Pins you already linked stay where you put them.

Direct Home Assistant WebSocket mode from the old v0.3 list is already in the app. The integration stays optional and is only required to upload a layout or to publish the room index the card reads.

## v0.3

Done:

- **Daylight by time of day.** The charcoal 3D view tints its lights from Home Assistant `sun.sun` when the phone is connected (elevation, then `next_rising` / `next_setting`, then above or below the horizon). With no connection it uses the device clock and a location-free day, sunrise at 06:00 and sunset at 18:00. Sunrise and sunset are warm and low, midday is neutral and bright, and night is a dim blue. Lamps that are on keep their own colour and cast into the room, so they still read after dark. Settings has a toggle, on by default, and the model has a time slider for a preview. The Lovelace card applies the same tint from the dashboard's `sun.sun`.

## v0.4

v0.4 is the wall-tablet card and the path for people who furnish outside RoomPlan.

- **Photo-real card.** A tablet should blend a lights-off plate and one plate per light with CSS or a room overlay, instead of loading a full 3D model.
- **Day and night plates switched by `sun.sun`.** The same card can swap two pre-rendered sets when Home Assistant says the sun is down.
- **Floor switcher and a saved viewpoint per room.** Several rooms already scan into one home, and a tablet needs a floor picker and a camera for each room.
- **Placeable furniture and decor.** RoomPlan boxes are recognition, and a catalog with move, rotate, and scale is how a person furnishes after the scan.
- **Sweet Home 3D export (`.sh3d`).** People who already use that floor-plan plugin can furnish there and keep its picture-elements workflow.

## v0.5

v0.5 is a plan editor for geometry after the scan. RoomPlan still measures the room. These tools correct walls, doors, and windows by hand. They do not control devices.

- **A room is a box with eight handles.** Tap a room, then drag an edge or a corner so the walls resize around the measured plan instead of staying frozen after the scan.
- **Snap guides.** Dashed lines appear when a wall, door, or window lines up with another, so a hand edit meets the same grid the scan already implied.
- **Split a room.** One button halves the room and inserts a door on the new wall, which is the usual way to turn one scanned volume into two.
- **Slide a door or window along its wall.** The opening stays on the wall axis, and it snaps when it meets another opening or a corner.
- **Copy an opening on the same wall.** A second door or window should start as a duplicate of the one you already placed, not as a new scan.

## Later

These need another navigation model, a heavier renderer, or another device.

- **Multi-floor dollhouse.** More than one floor is a stack of plans you edit together, not another RoomPlan pass. Walls still fade as you approach.
  - **Floor tabs and a faint ghost of the floor below.** The plan you are editing sits on top of a dim copy of the floor underneath, so stairs and shafts stay aligned.
  - **A new floor starts from the one underneath.** Copy the floor below, or start from one big room using that footprint, instead of an empty canvas.
  - **A flooring material for each room.** A simple picker is enough. Photo textures stay for real surfaces captured in the scan.
- **Ray tracing on capable devices, and export of a scene image.** The photo-real card needs stills, and a high-quality renderer is how those plates and a shareable picture get made.
- **iCloud sync to an iPad or Mac viewer.** The phone is the scanner, and other devices only need to open the same home.
- **Outdoor site plan.** A yard or facade stays a separate source: an ARKit mesh plus a drone or aerial photo as an underlay. The design is in [docs/roadmap.md](docs/roadmap.md).

## Where this list came from

The groups come from products that already sit next to Home Assistant, and from a hand-drawn plan editor:

- [Vulpo Lumen](https://vulpo.app/features/lumen-3d), a Home Assistant companion with RoomPlan rooms. The 3D view, coloured lights, furniture catalog, dollhouse, and iCloud sync are Pro features there.
- [shmuelzon/home-assistant-floor-plan](https://github.com/shmuelzon/home-assistant-floor-plan), a Sweet Home 3D plugin that pre-renders picture-elements floor plans for Lovelace.
- The public plan-editor demo from 0xProbability (House Control on X): rooms drawn as boxes with handles, snap guides, and openings that slide along a wall. That pattern is geometry only. Device control stays with the Home Assistant work above.

## What we keep

These are already in Home Scanner, or designed for it, and they are the reason not to become a thin Lumen or Sweet Home 3D clone.

- **Home Assistant-native card and `roomscan.home` JSON.** The layout file and the optional `home_scanner` upload are the contract. The card in `web/home-scanner-card/` reads `/local/home_scanner/<id>/`. `web/viewer/viewer.html` is the static page an existing iframe can keep using.
- **Outdoor site plan and drone underlay.** Planned, and written up separately from indoor RoomPlan. See [docs/roadmap.md](docs/roadmap.md).
- **Photo textures.** Library, camera, Files, and in-scan frames project onto walls and floors and ship inside the GLB and USDZ.
- **Re-scan diff.** A second scan of a room marks objects added, removed, or moved.
- **Sensor heatmaps.** Numeric Home Assistant readings, such as temperature or signal level, interpolate across pin positions.
- **PDF floor plans.** Area in square metres, wall lengths, and door widths, on one measured page.
