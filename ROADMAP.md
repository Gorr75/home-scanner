# Roadmap

This is the feature list after the current app. Nothing here is scheduled, and none of it is implemented in this change.

The groups come from products that already sit next to Home Assistant, and from a hand-drawn plan editor:

- [Vulpo Lumen](https://vulpo.app/features/lumen-3d), a Home Assistant companion with RoomPlan rooms. The 3D view, coloured lights, furniture catalog, dollhouse, and iCloud sync are Pro features there.
- [shmuelzon/home-assistant-floor-plan](https://github.com/shmuelzon/home-assistant-floor-plan), a Sweet Home 3D plugin that pre-renders picture-elements floor plans for Lovelace.
- The public plan-editor demo from 0xProbability (House Control on X): rooms drawn as boxes with handles, snap guides, and openings that slide along a wall. That pattern is geometry only. Device control stays with the Home Assistant work above.

## v0.3

The app already reads Home Assistant over REST and a WebSocket. v0.3 makes that room usable without the custom integration, and makes lights look like their entities.

- **Direct Home Assistant WebSocket mode.** A base URL and a long-lived token already drive live state, so the `home_scanner` integration stays optional and is only required to upload a layout or serve the card.
- **Lights drawn with real colour and brightness.** Pins show on/off text today, and the same state payload carries colour and brightness the 3D view can draw.
- **Daylight by time of day.** Once the room reacts to light colour, the clock can tint the scene without a second art pipeline.
- **Controls on the label in the scene.** Toggles already live on the pin sheet, and a tap on the label should dim a light or start media without leaving the model.
- **Lights grouped by room, icons placed from names and areas.** Entity ids are linked by hand today, and Home Assistant areas and friendly names can drop the first pins into the matching room.

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

## What we keep

These are already in Home Scanner, or designed for it, and they are the reason not to become a thin Lumen or Sweet Home 3D clone.

- **Home Assistant-native card and `roomscan.home` JSON.** The layout file and the optional `home_scanner` upload are the contract a Lovelace card reads at `/local/home_scanner/<id>/`.
- **Outdoor site plan and drone underlay.** Planned, and written up separately from indoor RoomPlan. See [docs/roadmap.md](docs/roadmap.md).
- **Photo textures.** Library, camera, Files, and in-scan frames project onto walls and floors and ship inside the GLB and USDZ.
- **Re-scan diff.** A second scan of a room marks objects added, removed, or moved.
- **Sensor heatmaps.** Numeric Home Assistant readings, such as temperature or signal level, interpolate across pin positions.
- **PDF floor plans.** Area in square metres, wall lengths, and door widths, on one measured page.
