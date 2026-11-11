# Home Scanner

Home Scanner measures a home with the iPhone LiDAR scanner and keeps the result on the device. You scan one room at a time, name it, and combine several rooms into a single floor. Each scan is stored as Apple's captured-room JSON plus a USDZ model. You can orbit the model, look at a top-down plan, drop device pins on it, and share the USDZ or a JSON layout.

There is no account. Scans stay on the iPhone until you send a floor plan to Home Assistant. Connect a base URL and a long-lived token in Settings (the token is stored in the Keychain). The JSON contract, the upload API, and install steps are in [docs/home-assistant.md](docs/home-assistant.md). What comes next is [ROADMAP.md](ROADMAP.md). Outdoor scanning is not in this version; the site-plan design is in [docs/roadmap.md](docs/roadmap.md).

Bundle id: `se.jansson.homescan`.

## Requirements

- Xcode 16 or later
- iOS 17 or later (RoomPlan's multi-room `StructureBuilder`)
- A physical iPhone or iPad Pro with LiDAR to scan
- The iOS Simulator can open saved homes and the bundled sample apartment. RoomPlan scanning does not run in the simulator.

## Run

1. Open `HomeScanner.xcodeproj`.
2. Select the HomeScanner scheme and target, then set your Development Team. The project uses automatic signing and does not pick a team for you.
3. On a LiDAR device: create a home, scan a room, name it, then scan the next room through the shared doorway and use **Combine into one floor**.
4. In the simulator: run the app and tap **Sample**. That installs a two-room apartment (kitchen and living room) with a USDZ model, a floor plan, and four device pins backed by mock states.

Scans are written under the app's Documents folder (`Homes/<id>/`), which the Files app can see.

## What you can do

- Scan with `RoomCaptureView` and name the room (Kitchen, Living room, and the rest).
- Build one floor from several captured rooms with `StructureBuilder`.
- Save each room's `CapturedRoom` JSON and USDZ, and the merged `CapturedStructure` when you combine.
- List homes, orbit and pinch-zoom the model in SceneKit, and pan a top-down plan.
- Share a USDZ, or share the home as `roomscan.home` JSON.
- Measure a distance on the 3D model or the floor plan by tapping two points. Corners and edges snap. Saving the measurement keeps it as a note on the room.
- Pin a note on a wall, the floor, or an object, with a photo, a voice recording, and an optional on-device transcript in Swedish or English. During a scan, Add note anchors that snapshot to the camera and places it in the room when you save.
- Keep an inventory for each room: scanned objects, catalog furniture, and items you add. Search the whole home, see totals, and share a CSV or an insurance PDF.
- On a device without LiDAR, the app explains that and still opens anything already saved, including the sample.
- Place, move, and delete device pins by tapping the 3D model or the floor plan. Each pin has a name, a type, a 3D position, and an optional Home Assistant `entity_id` such as `light.kitchen`.
- Connect Home Assistant in Settings, test the connection, and pick an entity from the server's list while editing a pin.
- Show live light, switch, and sensor readings on the pins. Lights use the entity colour and brightness. Tap a light, switch, or fan pin in the 3D view to toggle it, and dim a light from the bar under the model. The app polls the REST API and subscribes to `state_changed` on the websocket.
- Place unmatched devices into rooms from Home Assistant areas, friendly names, and entity ids. Pins you already linked stay where you put them.
- Send the layout and a model to Home Assistant, or share a `.zip` and a floor-plan PDF.
- Read furniture labels and dimensions, compare two scans, and lay a sensor heatmap over the plan.
- Project photos onto walls and floors. Capture frames during the scan, or bring in library, camera, and Files photos (including drone pictures), then drag the four corners. Textures are stored beside the home and baked into the GLB and USDZ sent to Home Assistant.

## Architecture

```text
HomeScanner.app       SwiftUI, RoomPlan, SceneKit
  Scan / store UI
  FloorPlanExtractor  CapturedRoom -> FloorPlan
  ScanArchive         encode, USDZ export, StructureBuilder
  HomeStore           observable wrapper
  PinBoard            asks a HomeStateProvider for mock or live states
  Settings            base URL plus Keychain token, entity search, test connection

RoomScanCore          Swift package, no UIKit and no RoomPlan
  Home, Room, FloorPlan, DevicePin
  HomeLayoutDocument  roomscan.home JSON
  HomeRepository      on-device folders
  HomeStateProvider   protocol
  MockHomeStateProvider
  HomeAssistantClient     REST, websocket events, upload
  UnconfiguredHomeAssistantClient
```

The HomeScanner target links the local package `RoomScanCore`. The package keeps its current name. Unit tests live there so they run with `swift test` and do not need a simulator.

Indoor RoomPlan is the only scan source today. A yard or facade would be a different source (an ARKit mesh, plus an aerial photo as a site underlay). That design is in [docs/roadmap.md](docs/roadmap.md) and is listed under Later in [ROADMAP.md](ROADMAP.md). It is not implemented. Pins, the home document, and the state provider stay the shared model either way.

SceneKit is the viewer: it loads a RoomPlan USDZ when one exists, and otherwise builds walls and floors from the measured plan. Orbit and zoom use SceneKit's camera controller. Pins are hit-tested in that scene and on the plan.

### On-device layout

```text
Documents/Homes/<home-uuid>/
  home.json
  rooms/<room-uuid>.captured.json
  rooms/<room-uuid>.usdz
  structure.captured.json
  structure.usdz
```

`home.json` is the interchange file. Apple's captured-room files are sidecars so a Home Assistant card does not have to parse RoomPlan's schema.

Coordinate notes that matter:

- Y is up. Units are meters. This matches ARKit and USDZ.
- A single scan, and the sample apartment, keep rooms and pins in one space.
- A real combine writes an aligned shell, then checks room footprints. A room that only misses its shared wall is snapped onto that wall. Two scans of the same room are flagged so one can be kept. Pins use that same move, so they stay in the room that moved.

## Home Assistant

Until Settings has a base URL and a token, pins use `MockHomeStateProvider` (kitchen light on, living room light off, a switch on, living room temperature 21.5 °C). After you connect, `HomeAssistantClient` reads and toggles entities, and the 3D view labels each pin with its state.

**Send to Home Assistant** uploads `layout.json`, `model.glb`, and any RoomPlan `model.usdz` to `POST /api/home_scanner/upload/<id>`. A room folder can also include photo plates under `plates/`. The integration in `ha/custom_components/home_scanner/` stores them at `/config/www/home_scanner/<id>/`, which the card reads as `/local/home_scanner/<id>/layout.json` and `model.glb`. **Share a .zip** writes the same folders for AirDrop or Files. A successful upload can open `homeassistant://navigate/lovelace/home-scanner`.

The Lovelace card is [web/home-scanner-card/home-scanner-card.js](web/home-scanner-card/home-scanner-card.js). It lists rooms from the integration index and opens the plan, `model.glb`, or photo plates. [web/viewer/viewer.html](web/viewer/viewer.html) is the static page an existing iframe at `/local/home_scanner/viewer.html` can use.

The token is not written into the home file. Install steps are in [ha/custom_components/home_scanner/README.md](ha/custom_components/home_scanner/README.md) and [web/home-scanner-card/README.md](web/home-scanner-card/README.md). The file layout is [web/viewer/README.md](web/viewer/README.md).

See [docs/home-assistant.md](docs/home-assistant.md).

## Tests

From the repo root:

```sh
swift test --package-path RoomScanCore
```

Covered: floor-plan geometry, the plan-to-screen mapping, safe relative paths, JSON export and rejection of an unknown format or version, pin edits, entity-id rules, the mock state provider, the unconfigured client, and saving/reloading homes on disk.

Not covered here: RoomPlan capture, USDZ loading in SceneKit, and the SwiftUI screens. Those need Xcode and, for scanning, a LiDAR device. The sample USDZ is generated by `scripts/make_sample_usdz.py` so the simulator has a model that matches the sample plan.

Xcode Cloud should use the shared `HomeScanner` scheme. `ci_scripts/ci_pre_xcodebuild.sh` runs the package tests on the Mac before `xcodebuild`. Scanning is not part of that job.

## Features

Kept from v0.1:

- Single-room LiDAR scan, naming, and on-device save (captured JSON + USDZ)
- Multi-room combine through RoomPlan `StructureBuilder` / `CapturedStructure`
- Home list, SceneKit model (orbit/zoom), top-down plan, USDZ share, JSON export
- Graceful copy when LiDAR is missing, plus a sample apartment for the simulator
- Device pins with type, position, and optional `entity_id`
- Unit tests for the model and the export (`swift test --package-path RoomScanCore`)

Added on top of that:

- Settings for the Home Assistant base URL and a long-lived token in the Keychain, with **Test connection**
- Tap a surface in the 3D model or the plan to place a pin, then pick an entity from the Home Assistant list
- Live state on the model and the plan (REST polling plus a `state_changed` websocket)
- **Send to Home Assistant**, a `.zip` share, and a companion-app link. The `home_scanner` integration is included
- Furniture labels and dimensions from RoomPlan categories
- Floor area, wall lengths, door widths, and a PDF export
- Re-scan diff: added, removed, and moved objects, with the option to replace the room
- A sensor heatmap interpolated across numeric pin readings
- Photo textures on walls and floors, including frames captured during the scan, with a four-corner fit baked into the GLB and USDZ

## Limits

- Each room file stays in that scan's coordinates. The home shell stores a placement per room and draws pins through it. `structure.coordinates_are_unified` stays false for a real combine. Use a room folder when a card should draw that room alone.
- `model.glb` is built from the measured floor plan (walls, floors, openings, objects). It is not a conversion of the RoomPlan USDZ. The USDZ is uploaded beside it when the scan has one.
- The websocket and the upload need a reachable Home Assistant. This repo's tests use a scripted HTTP transport, not a live server.
- The PDF is a measured drawing (area, lengths, a wall sketch). It is not a snapshot of the SwiftUI canvas.
- The heatmap only uses readings that parse as numbers, so lights that are `on` or `off` are not heat sources.
- Outdoor mode is not started. The feature list is [ROADMAP.md](ROADMAP.md). The site-plan design is in [docs/roadmap.md](docs/roadmap.md).

Xcode is not run in this environment. Review notes for the Xcode Cloud job (Swift 5, iOS 26 SDK): new files are inside the synchronized `RoomScan` group, so they join the target automatically. Keychain, SceneKit labels, and the PDF renderer are iOS-only and are not part of `swift test`. Local HTTP to Home Assistant depends on `NSAllowsLocalNetworking` and the local-network usage string in the generated Info.plist. The app icon was not changed.
