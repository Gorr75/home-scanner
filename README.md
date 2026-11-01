# Home Scanner

Home Scanner measures a home with the iPhone LiDAR scanner and keeps the result on the device. You scan one room at a time, name it, and combine several rooms into a single floor. Each scan is stored as Apple's captured-room JSON plus a USDZ model. You can orbit the model, look at a top-down plan, drop device pins on it, and share the USDZ or a JSON layout.

There is no account and no cloud upload. Home Assistant is not connected. The data model and a `HomeStateProvider` seam are in place so a later build can show live entity state. The JSON contract is [docs/home-assistant.md](docs/home-assistant.md). Outdoor scanning is not in this version; see [docs/roadmap.md](docs/roadmap.md).

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
- Place, move, and delete device pins. Each pin has a name, a type, a 3D position, and an optional Home Assistant `entity_id` such as `light.kitchen`.

## Architecture

```text
HomeScanner.app       SwiftUI, RoomPlan, SceneKit
  Scan / store UI
  FloorPlanExtractor  CapturedRoom -> FloorPlan
  ScanArchive         encode, USDZ export, StructureBuilder
  HomeStore           observable wrapper
  PinBoard            asks a HomeStateProvider for mock states

RoomScanCore          Swift package, no UIKit and no RoomPlan
  Home, Room, FloorPlan, DevicePin
  HomeLayoutDocument  roomscan.home JSON
  HomeRepository      on-device folders
  HomeStateProvider   protocol
  MockHomeStateProvider
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

Not connected. Pins can store an `entity_id`. States shown in the app come from `MockHomeStateProvider` (kitchen light on, living room light off, a switch on, living room temperature 21.5 °C). Toggling a light or switch changes the mock for the session.

`UnconfiguredHomeAssistantClient` records where a future client would keep the base URL and the Keychain account for a long-lived access token. The token is not written into the home file.

See [docs/home-assistant.md](docs/home-assistant.md).

An experimental three.js viewer and Lovelace card live in [web/viewer](web/viewer/README.md). The card reads `/local/home_scanner/<room>/layout.json` and `model.glb`. The iOS upload and the `home_scanner` integration that write those files are separate.

## Tests

From the repo root:

```sh
swift test --package-path RoomScanCore
```

Covered: floor-plan geometry, the plan-to-screen mapping, safe relative paths, JSON export and rejection of an unknown format or version, pin edits, entity-id rules, the mock state provider, the unconfigured client, and saving/reloading homes on disk.

Not covered here: RoomPlan capture, USDZ loading in SceneKit, and the SwiftUI screens. Those need Xcode and, for scanning, a LiDAR device. The sample USDZ is generated by `scripts/make_sample_usdz.py` so the simulator has a model that matches the sample plan.

Xcode Cloud should use the shared `HomeScanner` scheme. `ci_scripts/ci_pre_xcodebuild.sh` runs the package tests on the Mac before `xcodebuild`. Scanning is not part of that job.

## Done and next

Done in v1:

- Single-room LiDAR scan, naming, and on-device save (captured JSON + USDZ)
- Multi-room combine through `StructureBuilder`
- Home list, SceneKit model (orbit/zoom), top-down plan, USDZ share, JSON export
- Graceful copy when LiDAR is missing, plus a sample apartment for the simulator
- Device pins with type, position, and optional `entity_id`
- `HomeStateProvider`, mock states, and a documented `roomscan.home` file
- Unit tests for the model and the export

Next:

- Run a scan on a LiDAR device and confirm the captured JSON round-trips and the USDZ opens
- Set a Development Team for `se.jansson.homescan`
- Carry pin positions through `StructureBuilder` alignment so they sit on the merged model
- `HomeAssistantClient`: base URL, long-lived token in the Keychain, REST plus WebSocket, live state and toggle on the pins
- Wire the iOS "Send to Home Assistant" upload to the `home_scanner` integration (`/config/www/home_scanner/<room>/`). The experimental card in `web/viewer` already reads that path.
- More than one floor, and editing walls after a scan
- Outdoor mode: an ARKit scene mesh, and an aerial orthophoto or drone image as a site-plan underlay. Not started. See [docs/roadmap.md](docs/roadmap.md).
