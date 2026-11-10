# Roadmap

Phone upload to Home Assistant is live. The app reads entity state over REST and a WebSocket, and the optional `home_scanner` integration accepts `GET /api/home_scanner/health` and `POST /api/home_scanner/upload/{room}`. Layouts land at `/local/home_scanner/<id>/layout.json`, `model.glb`, and an optional `model.usdz`.

## Guiding principle

The main purpose is exporting rooms and layouts to Home Assistant. The app stays fully useful on its own. Scanning, measuring, annotations, inventory, editing, furniture, walkthrough, and checklists work with no Home Assistant connection. Home Assistant adds live state, device control, and the Lovelace dashboard on top. Maintenance checklists export to Home Assistant to-dos when the phone is connected, and they work as in-app reminders otherwise.

The Lovelace card, live light colour in the 3D view, placing pins from areas, daylight by time of day, the v0.4 floor switcher, saved viewpoints, day and night plates, the photo-real tablet card, the furniture catalog, the multi-floor dollhouse, and the v0.5 plan editor are in the app. Sweet Home 3D export is deferred. Next, After that, and Later follow.

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

Done:

- **Floor switcher and a saved viewpoint per room.** A room can store an optional floor (a level, omitted until you set one) and a camera saved from the 3D view. The home screen groups rooms by that floor. **Save viewpoint** writes the current camera. The upload includes both in `layout.json`. The card shows a floor picker and opens each room on its saved camera.
- **Day and night plates switched by `sun.sun`.** The photo card uses the same daylight mapping as the 3D view. The `night` phase shows the night plates. Sunrise, sunset, and day show the day plates.
- **Photo-real card.** Photo mode composites a lights-off base plate and one plate per light with `mix-blend-mode: screen`. Opacity and colour follow the live Home Assistant brightness and colour. Tapping a light's region toggles that entity. The app renders the plates from the saved viewpoint (all lights off, then one light at a time, day and night) and uploads them to `/local/home_scanner/<id>/plates/` with `plates/manifest.json`. Plan and 3D stay available. `viewer.html` is unchanged.
- **Placeable furniture and decor.** A catalog of sofas, chairs, tables, beds, shelves, lamps, plants, rugs, a television, and a few more drops into the 3D view and the floor plan. Each item moves, rotates, and scales, and it can replace a RoomPlan box. Placements live on the room and travel in `layout.json`, `model.glb`, and `model.usdz`.

**Deferred.** Sweet Home 3D export (`.sh3d`). People who already use that floor-plan plugin can furnish there and keep its picture-elements workflow.

## v0.5

Done. RoomPlan still measures the room. These tools correct walls, doors, and windows by hand. They do not control devices. A split room keeps the floor it was cut from. Furniture stays in the half that contains it. Flooring, the saved viewpoint, and photo plates stay on the room.

- **A room is a box with eight handles.** Tap a room on the floor plan, then drag an edge or a corner. The walls resize around the measured plan, and doors and windows on a moved wall follow it.
- **Snap guides.** Dashed lines appear when a wall, door, or window lines up with another, and the edit snaps within a small threshold.
- **Split a room.** One button halves the room and inserts a door on the new wall, which turns one scanned volume into two.
- **Slide a door or window along its wall.** The opening stays on the wall and snaps when it meets another opening or a corner.
- **Copy an opening on the same wall.** The duplicate starts from the door or window you already placed.
- **Undo and redo.** The edit is saved in the home. Sending to Home Assistant writes that geometry into `layout.json` and `model.glb`.

## Multi-floor dollhouse

Done. Floors stack in one home, using the same optional `floor` integer the card already reads. A missing `floor` means the room is not on a storey yet. The plan has floor tabs and a faint ghost of the floor below. A new floor copies the one underneath, or starts as one room from that footprint, and writes the next `floor` index. Each room has a flooring material, and a scan photo still covers the floor when one was captured. In the dollhouse, walls fade as the camera approaches.

## Next

In this order:

1. **Measure and annotate on the scan.** Tap two points for a distance, then area and volume. Labels, photos, and notes pin to a spot in the room, such as a fuse box photo or a leak note. A photo can carry a dictated voice note, and the app positions that photo on the plan.
2. **Crash-safe scanning.** The scan saves incrementally during capture, so a failed scan keeps what was captured. The app warns before scanning when device storage is low.
3. **iCloud backup and sync.** Homes, scans, layouts, GLB and USDZ models, photos, annotations, and inventory sync through a CloudKit private database or an iCloud Drive container. The copy survives a new phone, restores on reinstall, and opens on an iPad or a Mac. The app ID needs an iCloud container entitlement.
   - **Follow-on: an iPad or Mac viewer.** The phone is the scanner, and other devices only need to open the same home.
4. **Extend a scan across sessions.** Add a room to an existing home later and auto-align it, with relocalization and shared anchors, reliably.
5. **Home inventory.** Each appliance or device keeps a model, a serial, a warranty date, and an attached receipt and manual. The record links to a Home Assistant device pin, so one pin shows live state and the warranty.

## After that

In this order:

6. **First-person walkthrough.** Walk the home at eye height, or follow a recorded camera path. The same view belongs on a tablet.
7. **Maintenance checklists.** A checklist is tied to a room or an item. It exports to Home Assistant to-dos when the phone is connected, and it works as an in-app reminder otherwise.
8. **Renovation calculator.** Paint, flooring, and wallpaper quantities come from the measured surfaces, with a rough cost estimate.
9. **Ceiling height, areas, and heat loss.** Each room records its ceiling height and its wall and window areas, with a rough heat-loss estimate. The figures stay on the room. When the phone is connected, that estimate can feed Home Assistant energy and heating.

## Later

These need another navigation model, a heavier renderer, or another device.

- **Gaussian splat capture from video.** A photo-real upgrade, built from a video of the room.
- **360° panoramas.** A full-circle photo of a room. This overlaps the first-person walkthrough.
- **Tap-the-walls scan.** A fallback for a dim or cluttered room where RoomPlan struggles. Tap the walls to draw the plan.
- **Bluetooth laser measure.** Optional Bosch and Leica support for exact wall lengths.
- **Ray tracing on capable devices, and export of a scene image.** The photo-real card needs stills, and a high-quality renderer is how those plates and a shareable picture get made.
- **Outdoor site plan.** A yard or facade stays a separate source: an ARKit mesh plus a drone or aerial photo as an underlay. The design is in [docs/roadmap.md](docs/roadmap.md).

## Where this list came from

The groups come from products that already sit next to Home Assistant, from phone scanners and floor-plan apps, and from a hand-drawn plan editor:

- [Vulpo Lumen](https://vulpo.app/features/lumen-3d), a Home Assistant companion with RoomPlan rooms. The 3D view, coloured lights, furniture catalog, dollhouse, and iCloud sync are Pro features there.
- [shmuelzon/home-assistant-floor-plan](https://github.com/shmuelzon/home-assistant-floor-plan), a Sweet Home 3D plugin that pre-renders picture-elements floor plans for Lovelace.
- [Polycam](https://apps.apple.com/us/app/polycam-3d-scanner-modeling/id1532482376), a phone 3D scanner. Reviews complain about broken scan extension and lost long scans. Crash-safe capture and extending a scan across sessions come from that. Gaussian splat capture from video is the photo-real upgrade it already ships.
- [magicplan](https://apps.apple.com/us/app/magicplan/id427424432), a measured floor-plan app. Measure and annotate, a walkthrough of the plan, 360° panoramas, and quantities for paint, flooring, and wallpaper are what it is used for.
- [RoomScan Pro](https://apps.apple.com/us/app/roomscan-pro-lidar-floor-plans/id1504050801), a LiDAR floor-plan app. Dictated voice notes on photos that land on the plan, ceiling height with wall and window areas, a per-room heat-loss estimate, a tap-the-walls mode for a hard room, and Bosch and Leica laser measures are what it already does.
- The public plan-editor demo from 0xProbability (House Control on X): rooms drawn as boxes with handles, snap guides, and openings that slide along a wall. That pattern is geometry only. Device control stays with the Home Assistant work above.

## What we keep

These are already in Home Scanner, or designed for it, and they are the reason not to become a thin Lumen or Sweet Home 3D clone.

- **Home Assistant-native card and `roomscan.home` JSON.** The layout file and the optional `home_scanner` upload are the contract. The card in `web/home-scanner-card/` reads `/local/home_scanner/<id>/`. `web/viewer/viewer.html` is the static page an existing iframe can keep using.
- **Outdoor site plan and drone underlay.** Planned, and written up separately from indoor RoomPlan. See [docs/roadmap.md](docs/roadmap.md).
- **Photo textures.** Library, camera, Files, and in-scan frames project onto walls and floors and ship inside the GLB and USDZ.
- **Re-scan diff.** A second scan of a room marks objects added, removed, or moved.
- **Sensor heatmaps.** Numeric Home Assistant readings, such as temperature or signal level, interpolate across pin positions.
- **PDF floor plans.** Area in square metres, wall lengths, and door widths, on one measured page.
