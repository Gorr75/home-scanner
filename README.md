# Home Scanner

Home Scanner measures a home with the iPhone LiDAR scanner and keeps the result on the device. You scan one room at a time, name it, and combine several rooms into a single floor. Each scan is stored as Apple's captured-room JSON plus a USDZ model. You can orbit the model, look at a top-down plan, drop device pins on it, and share the USDZ or a JSON layout.

There is no account. Scans stay on the iPhone until you send a floor plan to Home Assistant. Connect a base URL and a long-lived token in Settings (the token is stored in the Keychain). The JSON contract, the upload API, and install steps are in [docs/home-assistant.md](docs/home-assistant.md). Outdoor scanning is not in this version; see [docs/roadmap.md](docs/roadmap.md).

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
- On a device without LiDAR, the app explains that and still opens anything already saved, including the sample.
- Place, move, and delete device pins by tapping the 3D model or the floor plan. Each pin has a name, a type, a 3D position, and an optional Home Assistant `entity_id` such as `light.kitchen`.
- Connect Home Assistant in Settings, test the connection, and pick an entity from the server's list while editing a pin.
- Show live light, switch, and sensor readings on the pins. The app polls the REST API and subscribes to `state_changed` on the websocket.
- Send the layout and a model to Home Assistant, or share a `.zip` and a floor-plan PDF.
- Read furniture labels and dimensions, compare two scans, and lay a sensor heatmap over the plan.

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

Indoor RoomPlan is the only scan source today. A yard or facade would be a different source (an ARKit mesh, plus an aerial photo as a site underlay). That is described in the roadmap and is not implemented. Pins, the home document, and the state provider stay the shared model either way.

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
- A real combine writes an aligned shell. Pins stay in each room's original scan, because `StructureBuilder` does not report a per-pin transform. The app says so on the combined plan.

## Home Assistant

Until Settings has a base URL and a token, pins use `MockHomeStateProvider` (kitchen light on, living room light off, a switch on, living room temperature 21.5 °C). After you connect, `HomeAssistantClient` reads and toggles entities, and the 3D view labels each pin with its state.

**Send to Home Assistant** uploads `layout.json`, `model.glb`, and any RoomPlan `model.usdz` to `POST /api/home_scanner/upload/<id>`. The integration in `ha/custom_components/home_scanner/` stores them at `/config/www/home_scanner/<id>/`, which the card reads as `/local/home_scanner/<id>/layout.json` and `model.glb`. **Share a .zip** writes the same folders for AirDrop or Files. A successful upload can open `homeassistant://navigate/lovelace/home-scanner`.

The token is not written into the home file. Install steps are in [ha/custom_components/home_scanner/README.md](ha/custom_components/home_scanner/README.md). The file layout the web card should use is [web/viewer/README.md](web/viewer/README.md).

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

## Limits

- A real combine still does not move existing pins into the merged coordinate space. `structure.coordinates_are_unified` stays false. Use a room folder when a card should draw pins on that room's model.
- `model.glb` is built from the measured floor plan (walls, floors, openings, objects). It is not a conversion of the RoomPlan USDZ. The USDZ is uploaded beside it when the scan has one.
- The websocket and the upload need a reachable Home Assistant. This repo's tests use a scripted HTTP transport, not a live server.
- The PDF is a measured drawing (area, lengths, a wall sketch). It is not a snapshot of the SwiftUI canvas.
- The heatmap only uses readings that parse as numbers, so lights that are `on` or `off` are not heat sources.
- Outdoor mode is not started. See [docs/roadmap.md](docs/roadmap.md).

Xcode is not run in this environment. Review notes for the Xcode Cloud job (Swift 5, iOS 26 SDK): new files are inside the synchronized `RoomScan` group, so they join the target automatically. Keychain, SceneKit labels, and the PDF renderer are iOS-only and are not part of `swift test`. Local HTTP to Home Assistant depends on `NSAllowsLocalNetworking` and the local-network usage string in the generated Info.plist. The app icon was not changed.
