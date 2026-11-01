# Outdoor site plan

Feature order for the app lives in [ROADMAP.md](../ROADMAP.md). This note is only the outdoor design. It is not built.

## Outdoor mode

A yard, drive, or facade is not a RoomPlan room. A later version can add it as a second way to fill a home, without changing device pins or the `roomscan.home` envelope.

Two pieces:

- **Scene mesh.** A generic ARKit scene reconstruction, using the LiDAR mesh rather than RoomPlan's walls, doors, and furniture. The result is a site mesh the person can orbit, with the same pin placement as a room (a name, a type, an optional `entity_id`, and a position in meters, Y up).
- **Site-plan underlay.** Import an aerial orthophoto or a drone image and lay it in the XZ plane under that mesh. The person sets scale and origin so the photo lines up with the scan. The floor-plan view draws the image first, then pins.

What stays the same when this exists:

- A home is still the document. Rooms stay RoomPlan captures. An outdoor site would be another child of the home, not a fake room with invented walls.
- Pins keep `room_id` for indoor devices. A site pin would point at the site instead of a room.
- `HomeStateProvider` does not care whether a pin was placed indoors or outdoors.
- The JSON format gains an optional site and underlay. Readers of version 1 ignore unknown keys, but a site that must be drawn would be a new format version, not a silent change to version 1.

No ARKit mesh capture, no photo import, and no new JSON fields are in the app today.
