# Roadmap

`main` is Home Scanner v0.1: indoor RoomPlan scans only. It builds on Xcode Cloud.

This branch adds the outdoor site plan on top of those compile fixes. The owner's orthophoto is not in the repo. **Sample yard** installs a drawn placeholder, a shed, and a stand-in facade photo so the flow can be opened in the simulator.

## What works

- Merge of `main`: Foundation import, `NSCoding` on the room capture controller, explicit `self` in the SceneKit hit test, used `try?` results, the development team, and an app icon with no alpha channel.
- Placeholder aerial, GeoTIFF geokeys (including Lantmäteriet SWEREF 99 TM, EPSG:3006), and a six-line world file. A plain photo can be scaled from two taps and a distance, and rotated by a bearing or the photo-rotation slider.
- Drone JPEG GPS, altitude, heading, focal length, and DJI gimbal yaw / pitch / relative altitude when those strings are in the file. The photo is placed on the plan from the site photo's latitude.
- ARKit scene reconstruction. Each mesh anchor is clipped to 5 m. The saved scan can extend further as you walk. The app derives facade planes, a building footprint, and a terrain mesh.
- Indoor rooms and outdoor scans dragged on the plan, or aligned by the longest wall. The room keeps its measured size.
- Facade texturing: four draggable corners on a drone photo, with a GPS suggestion when the scan is placed on a georeferenced underlay. The 3D view draws that mapping on the wall.
- Version 2 `roomscan.home` export. An indoor wall and an outdoor facade store the same `texture` object (`image`, pixel size, four UV corners). See [home-assistant.md](home-assistant.md).

`swift test --package-path RoomScanCore` covers the model. The iOS target still needs an Xcode build.

## Stubbed or approximate

- The bundled aerial is a drawing, not a survey, pinned near Stockholm so GPS math has an origin.
- GeoTIFF bitmaps are decoded by ImageIO, then by a small uncompressed-strip reader. Tiled JPEG or deflate tiles (common for Lantmäteriet downloads) may yield coordinates without pixels. The fallback is a JPEG or PNG plus a `.tfw`.
- EPSG codes other than 3006 and 4326 set the meter scale and do not become latitude and longitude.
- A world file's shear is dropped. Magnetic GPS headings are not converted to true north.
- If a drone photo has a focal length in millimetres but no 35 mm equivalent, corner suggestion assumes a 6.3 mm wide sensor. Absolute altitude is not used as camera height.
- The textured wall is a subdivided homography in SceneKit, not a custom shader.
- There is no indoor screen for putting a photo on a room wall. The JSON field is there so that screen can write the same object.
- Device pins still belong to indoor rooms. There is no live Home Assistant client, no pin move through `StructureBuilder`, and no second floor.

## Compile risks for the iOS 26 SDK

Swift language mode is 5.0 and the deployment target is iOS 17. This branch has not been opened in Xcode.

- `ARMeshAnchor` vertices are read only when the format is `float3`. A different format produces an empty chunk instead of a bad cast.
- Face indices are read only as 16-bit or 32-bit.
- `ARSessionDelegate` does not require `NSCoding`. The room capture controller still implements it, from `main`.
- ImageIO, not this repo, decides which compressed GeoTIFFs become bitmaps.
