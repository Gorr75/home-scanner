import XCTest
@testable import RoomScanCore

final class RoomAlignmentTests: XCTestCase {
    func testStackedFootprintsOverlapAndSideBySideRoomsDoNot() {
        let anna = box(name: "Anna", x: 0, z: 0, width: 4, depth: 3.2)
        let shifted = anna.floorPlan.transformed(by: RigidYaw(
            yaw: 6 * .pi / 180,
            translation: Vec3(x: 0.15, y: 0, z: 0.08)
        ))
        let ratio = RoomFootprint.overlapRatio(anna.floorPlan, shifted)
        XCTAssertGreaterThan(ratio, 0.6)

        let beside = anna.floorPlan.transformed(by: RigidYaw(
            yaw: 0,
            translation: Vec3(x: 4, y: 0, z: 0)
        ))
        XCTAssertLessThan(RoomFootprint.overlapRatio(anna.floorPlan, beside), 0.05)
    }

    func testAlignmentTransformMovesAPinWithItsRoom() {
        let scan = box(name: "Bedroom", x: 0, z: 0, width: 3, depth: 4)
        let placed = RigidYaw(yaw: .pi / 2, translation: Vec3(x: 5, y: 0, z: 1))
        let fit = RoomAlignment.register(source: scan.floorPlan, target: scan.floorPlan.transformed(by: placed))
        XCTAssertEqual(fit.error, 0, accuracy: 0.05)
        XCTAssertEqual(fit.transform.translation.x, placed.translation.x, accuracy: 0.05)
        XCTAssertEqual(fit.transform.translation.z, placed.translation.z, accuracy: 0.05)

        let pin = DevicePin.placed(in: scan.id, kind: .light, x: 1, z: 0.4, name: "Lamp")
        let moved = RoomPlacement(
            roomId: scan.id,
            yaw: fit.transform.yaw,
            translation: fit.transform.translation,
            snapped: false
        ).applying(to: pin)
        let expected = placed.applying(pin.position)
        XCTAssertEqual(moved.position.x, expected.x, accuracy: 0.05)
        XCTAssertEqual(moved.position.y, pin.position.y, accuracy: 1e-9)
        XCTAssertEqual(moved.position.z, expected.z, accuracy: 0.05)
        let roundTrip = fit.transform.inverse().applying(moved.position)
        XCTAssertEqual(roundTrip.x, pin.position.x, accuracy: 0.05)
        XCTAssertEqual(roundTrip.z, pin.position.z, accuracy: 0.05)
    }

    func testDuplicateAnnaScansAreFlaggedAndOneIsHidden() {
        let first = box(name: "Anna", x: 0, z: 0, width: 4, depth: 3.2)
        let second = box(name: "Anna", x: 0, z: 0, width: 4, depth: 3.2)
        let slipped = RigidYaw(yaw: 6 * .pi / 180, translation: Vec3(x: 0.12, y: 0, z: 0.08))
        let result = RoomAlignment.align(
            rooms: [first, second],
            placedPlans: [first.floorPlan, second.floorPlan.transformed(by: slipped)]
        )
        XCTAssertEqual(result.overlaps.count, 1)
        XCTAssertEqual(result.overlaps.first?.kind, .duplicate)
        XCTAssertEqual(result.overlaps.first?.roomIds, [first.id, second.id])
        XCTAssertEqual(result.suppressedRoomIds, [second.id])
        XCTAssertFalse(result.suppressedRoomIds.contains(first.id))
        XCTAssertTrue(result.hidesMergedModel)
        XCTAssertGreaterThan(result.overlaps.first?.ratio ?? 0, 0.45)
    }

    func testMisalignedNeighborSnapsOntoTheSharedWall() {
        let kitchen = box(name: "Kitchen", x: 0, z: 0, width: 4, depth: 3)
        let bedroom = box(name: "Bedroom", x: 0, z: 0, width: 3, depth: 3)
        let wrong = RigidYaw(yaw: 8 * .pi / 180, translation: Vec3(x: 3.55, y: 0, z: 0.15))
        let before = RoomFootprint.overlapRatio(
            kitchen.floorPlan,
            bedroom.floorPlan.transformed(by: wrong)
        )
        XCTAssertGreaterThan(before, 0.05)

        let result = RoomAlignment.align(
            rooms: [kitchen, bedroom],
            placedPlans: [kitchen.floorPlan, bedroom.floorPlan.transformed(by: wrong)]
        )
        let placement = result.placement(for: bedroom.id)
        let placed = bedroom.floorPlan.transformed(by: placement?.transform ?? .identity)
        let after = RoomFootprint.overlapRatio(kitchen.floorPlan, placed)
        XCTAssertLessThan(after, 0.12, "overlap \(before) was not snapped down, still \(after)")
        XCTAssertEqual(placement?.snapped, true)
        XCTAssertTrue(result.overlaps.isEmpty)
        let center = centroid(of: placed)
        XCTAssertGreaterThan(center.x, 4)
    }

    func testShellMatchSeparatesRoomsAndStacksOnlyTheDuplicate() {
        let kitchen = box(name: "Kitchen", x: 0, z: 0, width: 3.6, depth: 3.2, doorAtX: 3.6)
        let livingScan = box(name: "Living room", x: 0, z: 0, width: 5.2, depth: 4, doorAtX: 0)
        let livingPlaced = RigidYaw(yaw: 0, translation: Vec3(x: 3.6, y: 0, z: 0))
        let anna = box(name: "Anna", x: 0, z: 0, width: 3, depth: 3.5)
        let annaAgain = box(name: "Anna", x: 0, z: 0, width: 3, depth: 3.5)
        let annaPose = RigidYaw(yaw: 0, translation: Vec3(x: 10, y: 0, z: 0))
        let annaSlip = RigidYaw(yaw: 6 * .pi / 180, translation: Vec3(x: 10.12, y: 0, z: 0.1))
        let shell = merged([
            kitchen.floorPlan,
            livingScan.floorPlan.transformed(by: livingPlaced),
            anna.floorPlan.transformed(by: annaPose),
            annaAgain.floorPlan.transformed(by: annaSlip)
        ])
        let result = RoomAlignment.align(
            rooms: [kitchen, livingScan, anna, annaAgain],
            shell: shell
        )
        let living = result.placement(for: livingScan.id)?.transform ?? .identity
        XCTAssertEqual(living.translation.x, 3.6, accuracy: 0.15)
        XCTAssertEqual(living.yaw, 0, accuracy: 0.08)
        XCTAssertTrue(result.suppressedRoomIds.contains(annaAgain.id))
        XCTAssertFalse(result.suppressedRoomIds.contains(anna.id))
        XCTAssertFalse(result.suppressedRoomIds.contains(kitchen.id))
        XCTAssertFalse(result.suppressedRoomIds.contains(livingScan.id))
        XCTAssertEqual(result.overlaps.map(\.kind), [.duplicate])
        let duplicate = result.overlaps.first { $0.roomIds.contains(anna.id) && $0.roomIds.contains(annaAgain.id) }
        XCTAssertEqual(duplicate?.kind, .duplicate)
    }

    func testDoorwaysPlaceARoomOnTheFarSideOfTheSharedDoor() {
        let kitchen = box(name: "Kitchen", x: 0, z: 0, width: 3.6, depth: 3.2, doorAtX: 3.6)
        let living = box(name: "Living room", x: 0, z: 0, width: 5.2, depth: 4, doorAtX: 0)
        let result = RoomAlignment.align(rooms: [kitchen, living])
        let placement = result.placement(for: living.id)?.transform ?? .identity
        let placed = living.floorPlan.transformed(by: placement)
        XCTAssertLessThan(RoomFootprint.overlapRatio(kitchen.floorPlan, placed), 0.08)
        XCTAssertGreaterThan(centroid(of: placed).x, centroid(of: kitchen.floorPlan).x)
        let pin = DevicePin.placed(in: living.id, kind: .light, x: 1, z: 1, name: "Lamp")
        let moved = RoomPlacement(
            roomId: living.id,
            yaw: placement.yaw,
            translation: placement.translation,
            snapped: false
        ).applying(to: pin)
        XCTAssertEqual(moved.position.x, placement.applying(pin.position).x, accuracy: 1e-6)
        XCTAssertNotEqual(moved.position.x, pin.position.x, accuracy: 0.2)
    }

    func testSameRoomNameGetsDistinctKeepLabels() {
        let earlier = box(name: "Anna", x: 0, z: 0, width: 3, depth: 3)
        let later = box(name: "Anna", x: 4, z: 0, width: 3, depth: 3)
        let home = Home(
            id: UUID(),
            name: "Untitled home",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            rooms: [earlier, later],
            pins: []
        )
        let overlap = RoomOverlap(roomIds: [earlier.id, later.id], kind: .duplicate, ratio: 0.8)
        XCTAssertEqual(overlap.choices(in: home).map(\.title), [
            "Keep the earlier Anna",
            "Keep the later Anna"
        ])
    }

    func testOldStructureWithoutPlacementsStillDecodes() throws {
        let json = """
        {"format":"roomscan.home","version":1,"home":{
          "id":"6F0C2A10-4B1E-4E0A-9C11-000000000099",
          "name":"Old",
          "created_at":"2026-01-01T00:00:00Z",
          "updated_at":"2026-01-01T00:00:00Z",
          "rooms":[],
          "pins":[],
          "structure":{
            "built_at":"2026-01-01T00:00:00Z",
            "room_ids":[],
            "coordinates_are_unified":false
          }
        }}
        """
        let document = try HomeLayoutDocument.decode(Data(json.utf8))
        XCTAssertNil(document.home.structure?.placements)
        XCTAssertNil(document.home.structure?.overlaps)
        XCTAssertEqual(RoomAlignment.applied(to: document.home).placements.count, 0)
    }

    private func box(
        name: String,
        x: Double,
        z: Double,
        width: Double,
        depth: Double,
        doorAtX: Double? = nil
    ) -> Room {
        let id = UUID()
        func wall(_ start: (Double, Double), _ end: (Double, Double)) -> WallSegment {
            WallSegment(
                id: UUID(),
                start: Vec3(x: start.0, y: 0, z: start.1),
                end: Vec3(x: end.0, y: 0, z: end.1),
                height: 2.4,
                thickness: 0.12
            )
        }
        var openings: [Opening] = []
        if let doorAtX {
            let onEast = abs(doorAtX - (x + width)) < 0.01
            openings.append(Opening(
                id: UUID(),
                kind: .door,
                center: Vec3(x: doorAtX, y: 1.05, z: z + depth / 2),
                width: 0.9,
                height: 2.1,
                yaw: onEast || abs(doorAtX - x) < 0.01 ? .pi / 2 : 0
            ))
        }
        return Room(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            floorPlan: FloorPlan(
                walls: [
                    wall((x, z), (x + width, z)),
                    wall((x + width, z), (x + width, z + depth)),
                    wall((x + width, z + depth), (x, z + depth)),
                    wall((x, z + depth), (x, z))
                ],
                openings: openings,
                floors: [
                    FloorPolygon(
                        id: UUID(),
                        corners: [
                            Vec3(x: x, y: 0, z: z),
                            Vec3(x: x + width, y: 0, z: z),
                            Vec3(x: x + width, y: 0, z: z + depth),
                            Vec3(x: x, y: 0, z: z + depth)
                        ]
                    )
                ]
            )
        )
    }

    private func merged(_ plans: [FloorPlan]) -> FloorPlan {
        FloorPlan(
            walls: plans.flatMap(\.walls),
            openings: plans.flatMap(\.openings),
            floors: plans.flatMap(\.floors),
            objects: plans.flatMap(\.objects)
        )
    }

    private func centroid(of plan: FloorPlan) -> Vec3 {
        let corners = RoomFootprint.polygon(of: plan)
        let sum = corners.reduce(Vec3.zero) { $0 + $1 }
        return sum.scaled(1 / Double(max(corners.count, 1)))
    }
}
