# Home Assistant layout format

Home Scanner does not talk to Home Assistant in this version. It stores the shape of a home and the devices you place in it, and it can export that as one JSON document. A later Home Assistant integration or Lovelace card can read the file. A later app build can fill in live states through the `HomeStateProvider` seam described below.

Nothing in the file is a credential. Do not put a long-lived access token, a base URL password, or any other secret in this JSON.

## File

- Format id: `roomscan.home`
- Version: `1`
- Encoding: UTF-8 JSON
- Dates: ISO 8601, UTC (`2026-01-01T00:00:00Z`)
- Keys: `snake_case`
- Numbers: meters, quantized to 0.0001 m (0.1 mm) on write
- Ids: UUID strings

Readers must reject a different `format` or `version`. Do not guess.

The on-device file is `Documents/Homes/<home-id>/home.json` (visible in the Files app). Share sheet export uses the same bytes and the name `<Home name>.roomscan.json`.

A full example, the bundled sample apartment, is [`examples/sample-apartment.roomscan.json`](examples/sample-apartment.roomscan.json).

## Coordinates

Right-handed, Y up, meters. This is the same space as ARKit, RoomPlan, and the USDZ export.

- `x` and `z` are the floor.
- `y` is height. `0` is the floor of that scan.
- `yaw` is radians around Y. `0` means an opening's width, or an object's width (`dimensions.x`), runs along +X. Positive yaw turns toward +Z.
- Wall `start` and `end` are the base of the wall centerline, not the inner face.

Each LiDAR scan starts at its own origin. Pins use that room's coordinates. After **Combine into one floor**, RoomPlan's `StructureBuilder` writes an aligned shell (`structure.overview_floor_plan` and `structure.usdz`). That shell is a different coordinate space. v1 does **not** move existing pins into it, and `structure.coordinates_are_unified` stays `false` for a real combine. The sample apartment is authored as one space, so its flag is `true` and pins line up with every room.

## Document

```json
{
  "format": "roomscan.home",
  "version": 1,
  "home": {
    "id": "UUID",
    "name": "Ground floor",
    "created_at": "2026-01-01T00:00:00Z",
    "updated_at": "2026-01-01T00:00:00Z",
    "rooms": [],
    "pins": [],
    "structure": null
  }
}
```

### `home.rooms[]`

| Field | Meaning |
| --- | --- |
| `id` | Stable room id. Pins refer to it with `room_id`. |
| `name` | "Kitchen", "Living room", … |
| `created_at` | When the room was saved. |
| `floor_plan` | Walls, openings, floors, and objects in that room's scan space. |
| `assets.usdz` | Optional path relative to the home folder, for example `rooms/<id>.usdz`. |
| `assets.captured_room` | Optional path of Apple's encoded `CapturedRoom` JSON. |

`assets` is `{}` when the room has no sidecar files. Paths inside it are for this phone. An integration that only draws the plan and the pins can ignore them. Reject any path that is absolute or contains `..`.

### `floor_plan`

| Field | Meaning |
| --- | --- |
| `walls[]` | `id`, `start`, `end`, `height`, `thickness`, `confidence` |
| `openings[]` | `id`, `kind` (`door`, `window`, `opening`), `center`, `width`, `height`, `yaw`, `confidence` |
| `floors[]` | `id`, `corners` (polygon on the floor plane, at least 3 points) |
| `objects[]` | `id`, `category`, `center`, `dimensions` (`x` width, `y` height, `z` depth), `yaw`, `confidence` |

`confidence` is `high`, `medium`, or `low`. It is omitted when the geometry was not produced by a scan (the sample apartment). Readers should also accept `null`.

`category` is a stable token taken from RoomPlan when a scan exists (`sofa`, `table`, `refrigerator`, `washer_dryer`, …). It is not a Home Assistant domain.

### `home.pins[]`

A pin is a device the person placed. It is not a Home Assistant device until `entity_id` is set.

| Field | Meaning |
| --- | --- |
| `id` | Stable pin id. |
| `room_id` | Room the pin belongs to, or `null`. |
| `name` | Label shown in the app. |
| `kind` | One of `light`, `switch`, `sensor`, `climate`, `cover`, `fan`, `media_player`, `lock`, `other`. |
| `entity_id` | Home Assistant id such as `light.kitchen`, or `null` if unlinked. |
| `position` | Device position in the room's scan space, in meters. `y` is the mounting height, not the floor. |

`entity_id` grammar, after trimming and lowercasing:

```text
domain.object_id
domain     = [a-z_][a-z0-9_]*
object_id  = [a-z_][a-z0-9_]*
```

Exactly one dot. `light.kitchen` and `binary_sensor.front_door` are valid. `light.kitchen.main` is not. The editor stores a canonical lowercase id when the text matches. A value that does not match is kept so it can be fixed, and the mock state provider will not query it.

### `home.structure`

Present after a multi-room combine, and on the sample apartment.

| Field | Meaning |
| --- | --- |
| `built_at` | When the shell was built. |
| `room_ids` | Rooms that were included, in input order. |
| `coordinates_are_unified` | `true` only when room plans and pins already share the shell's space. |
| `usdz` | Optional relative path of the merged model, usually `structure.usdz`. |
| `captured_structure` | Optional relative path of Apple's encoded `CapturedStructure`. |
| `overview_floor_plan` | Aligned walls and floors from `StructureBuilder`. Omit or `null` when there is no separate shell. |

## What a card would draw

1. Read `floor_plan` for the selected room, or `structure.overview_floor_plan` when showing the aligned shell.
2. Draw `floors`, then `walls`, then `openings`, then `objects`, in the XZ plane.
3. Draw each pin at `position.x`, `position.z`. Use `kind` for the icon and `entity_id` for state.
4. Do not draw room pins on top of `overview_floor_plan` unless `coordinates_are_unified` is true.

## Live state, later

The app talks to device state only through `HomeStateProvider` in the `RoomScanCore` package:

```swift
func snapshot(for entityId: String) async throws -> EntitySnapshot
func snapshots(for entityIds: [String]) async throws -> [EntitySnapshot]
func perform(_ action: EntityAction, entityId: String) async throws -> EntitySnapshot
```

`EntityAction` is `turn_on`, `turn_off`, or `toggle`.

`EntitySnapshot` is `entity_id`, `state`, `domain`, optional `unit`, and optional `friendly_name`. The mock treats `light`, `switch`, and `fan` as on/off. A temperature sensor is a reading (`21.5` with unit `°C`) and refuses toggle.

v1 always uses `MockHomeStateProvider`. The screen says the numbers are sample data on the phone.

`UnconfiguredHomeAssistantClient` is the empty stand-in for the real client. It holds:

- `baseURL`, for example `http://homeassistant.local:8123`
- `tokenAccount`, the Keychain account name

Suggested Keychain item, not implemented yet:

- service: `se.jansson.homescan.homeassistant`
- account: `access-token`
- secret: a Home Assistant long-lived access token

The client should map the protocol onto Home Assistant like this:

| Call | Home Assistant |
| --- | --- |
| `snapshot` | `GET {baseURL}/api/states/{entity_id}` with `Authorization: Bearer <token>` |
| `turn_on` / `turn_off` / `toggle` | `POST {baseURL}/api/services/{domain}/{action}` with body `{"entity_id": "<id>"}` |
| Push updates | WebSocket `{baseURL}/api/websocket`, authenticate with the token, then `subscribe_events` for `state_changed` |

Normalize cover and lock states in that client (`open` / `closed`, `locked` / `unlocked`). The mock does not pretend those domains toggle.

Settings for the base URL and token belong in that future client, not in `home.json`.

The format id stays `roomscan.home`. The app on the home screen is Home Scanner. Outdoor site plans are a later addition and are not part of this file yet. See [roadmap.md](roadmap.md).
