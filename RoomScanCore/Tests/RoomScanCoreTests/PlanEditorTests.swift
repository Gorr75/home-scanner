import XCTest
@testable import RoomScanCore

final class PlanEditorTests: XCTestCase {
    func testRoomBoxHasEightHandlesOnTheMeasuredCorners() throws {
        let plan = kitchen()
        let box = try XCTUnwrap(PlanEditor.box(of: plan))
        XCTAssertEqual(box.minU, 0, accuracy: 1e-9)
        XCTAssertEqual(box.maxU, 3.6, accuracy: 1e-9)
        XCTAssertEqual(box.minV, 0, accuracy: 1e-9)
        XCTAssertEqual(box.maxV, 3.2, accuracy: 1e-9)
        XCTAssertEqual(PlanHandle.all.count, 8)
        let east = box.point(.edge(.maxU))
        XCTAssertEqual(east.x, 3.6, accuracy: 1e-9)
        XCTAssertEqual(east.z, 1.6, accuracy: 1e-9)
        let corner = box.point(.corner(.minUMinV))
        XCTAssertEqual(corner.x, 0, accuracy: 1e-9)
        XCTAssertEqual(corner.z, 0, accuracy: 1e-9)
        XCTAssertTrue(PlanEditor.contains(x: 1, z: 1, in: plan))
        XCTAssertFalse(PlanEditor.contains(x: 5, z: 1, in: plan))
    }

    func testDraggingAnEdgeMovesThatWallAndTheOpeningsOnIt() throws {
        let plan = kitchen()
        let edited = PlanEditor.resize(
            plan,
            handle: .edge(.maxU),
            to: Vec3(x: 4.2, y: 0, z: 1)
        ).plan
        let east = try XCTUnwrap(edited.walls.first { $0.id == SampleApartment.id(0x14) })
        XCTAssertEqual(east.start.x, 4.2, accuracy: 1e-9)
        XCTAssertEqual(east.end.x, 4.2, accuracy: 1e-9)
        XCTAssertEqual(east.start.z, 0, accuracy: 1e-9)
        XCTAssertEqual(east.end.z, 3.2, accuracy: 1e-9)
        let west = try XCTUnwrap(edited.walls.first { $0.id == SampleApartment.id(0x12) })
        XCTAssertEqual(west.start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(west.end.x, 0, accuracy: 1e-9)
        let south = try XCTUnwrap(edited.walls.first { $0.id == SampleApartment.id(0x11) })
        XCTAssertEqual(south.end.x, 4.2, accuracy: 1e-9)
        XCTAssertEqual(south.start.x, 0, accuracy: 1e-9)
        let door = try XCTUnwrap(edited.openings.first)
        XCTAssertEqual(door.center.x, 4.2, accuracy: 1e-9)
        XCTAssertEqual(door.center.z, 1.6, accuracy: 1e-9)
        XCTAssertEqual(door.width, 0.9, accuracy: 1e-9)
        let fridge = try XCTUnwrap(edited.objects.first { $0.category == "refrigerator" })
        XCTAssertEqual(fridge.center.x, 0.45, accuracy: 1e-9)
        let floor = try XCTUnwrap(edited.floors.first)
        XCTAssertEqual(floor.corners.map(\.x).max() ?? 0, 4.2, accuracy: 1e-9)
    }

    func testDraggingACornerMovesTheTwoWallsThatMeetThere() throws {
        let edited = PlanEditor.resize(
            kitchen(),
            handle: .corner(.maxUMaxV),
            to: Vec3(x: 4, y: 0, z: 3.8)
        ).plan
        let east = try XCTUnwrap(edited.walls.first { $0.id == SampleApartment.id(0x14) })
        XCTAssertEqual(east.start.x, 4, accuracy: 1e-9)
        XCTAssertEqual(east.end.z, 3.8, accuracy: 1e-9)
        let north = try XCTUnwrap(edited.walls.first { $0.id == SampleApartment.id(0x13) })
        XCTAssertEqual(north.start.z, 3.8, accuracy: 1e-9)
        XCTAssertEqual(north.end.z, 3.8, accuracy: 1e-9)
        XCTAssertEqual(north.end.x, 4, accuracy: 1e-9)
        let door = try XCTUnwrap(edited.openings.first)
        XCTAssertEqual(door.center.x, 4, accuracy: 1e-9)
        XCTAssertEqual(door.center.z, 1.6, accuracy: 1e-9)
    }

    func testPartialWallFollowsTheCornerItTouches() throws {
        let living = SampleApartment.make().room(id: SampleApartment.livingRoomID)!.floorPlan
        let edited = PlanEditor.resize(
            living,
            handle: .edge(.maxV),
            to: Vec3(x: 6, y: 0, z: 4.5)
        ).plan
        let west = try XCTUnwrap(edited.walls.first { $0.id == SampleApartment.id(0x24) })
        XCTAssertEqual(west.start.z, 4.5, accuracy: 1e-9)
        XCTAssertEqual(west.end.z, 3.2, accuracy: 1e-9)
        XCTAssertEqual(west.start.x, 3.6, accuracy: 1e-9)
        let window = try XCTUnwrap(edited.openings.first)
        XCTAssertEqual(window.center.z, 0, accuracy: 1e-9)
        XCTAssertEqual(window.center.x, 6.2, accuracy: 1e-9)
    }

    func testOpeningOnAShortenedWallStaysOnTheSegment() throws {
        let plan = rectangularRoom(width: 4, depth: 3, windowAt: 3.5, windowWidth: 0.6)
        let edited = PlanEditor.resize(
            plan,
            handle: .edge(.maxU),
            to: Vec3(x: 3.2, y: 0, z: 1)
        ).plan
        let window = try XCTUnwrap(edited.openings.first { $0.kind == .window })
        XCTAssertEqual(window.center.x, 2.9, accuracy: 1e-9)
        XCTAssertEqual(window.center.z, 0, accuracy: 1e-9)
        XCTAssertEqual(window.width, 0.6, accuracy: 1e-9)
    }

    func testEdgeSnapsToAnotherWallAndReturnsAGuide() throws {
        let other = FloorPlan(walls: [
            WallSegment(
                id: UUID(),
                start: Vec3(x: 4, y: 0, z: 0),
                end: Vec3(x: 4, y: 0, z: 2),
                height: 2.4,
                thickness: 0.12
            )
        ])
        let snapped = PlanEditor.resize(
            kitchen(),
            handle: .edge(.maxU),
            to: Vec3(x: 4.05, y: 0, z: 1),
            against: [other],
            threshold: 0.08
        )
        let east = try XCTUnwrap(snapped.plan.walls.first { $0.id == SampleApartment.id(0x14) })
        XCTAssertEqual(east.start.x, 4, accuracy: 1e-9)
        let guide = try XCTUnwrap(snapped.guides.first)
        XCTAssertEqual(guide.start.x, 4, accuracy: 1e-9)
        XCTAssertEqual(guide.end.x, 4, accuracy: 1e-9)
        XCTAssertGreaterThan(abs(guide.end.z - guide.start.z), 1)

        let missed = PlanEditor.resize(
            kitchen(),
            handle: .edge(.maxU),
            to: Vec3(x: 4.3, y: 0, z: 1),
            against: [other],
            threshold: 0.08
        )
        let free = try XCTUnwrap(missed.plan.walls.first { $0.id == SampleApartment.id(0x14) })
        XCTAssertEqual(free.start.x, 4.3, accuracy: 1e-9)
        XCTAssertTrue(missed.guides.isEmpty)
    }

    func testResizeStopsAtTheMinimumSpan() throws {
        let edited = PlanEditor.resize(
            kitchen(),
            handle: .edge(.maxU),
            to: Vec3(x: 0.1, y: 0, z: 1)
        ).plan
        let east = try XCTUnwrap(edited.walls.first { $0.id == SampleApartment.id(0x14) })
        XCTAssertEqual(east.start.x, PlanEditor.minimumSpan, accuracy: 1e-9)
        let door = try XCTUnwrap(edited.openings.first)
        XCTAssertEqual(door.center.x, PlanEditor.minimumSpan, accuracy: 1e-9)
    }

    func testDoorSlidesAlongItsWallAndSnapsToAnOpeningAndACorner() throws {
        var plan = kitchen()
        plan.openings.append(
            Opening(
                id: UUID(),
                kind: .window,
                center: Vec3(x: 3.6, y: 1.5, z: 2.4),
                width: 0.4,
                height: 1.2,
                yaw: .pi / 2
            )
        )
        let slid = PlanEditor.slide(
            plan,
            openingID: SampleApartment.id(0x15),
            to: Vec3(x: 3.7, y: 1, z: 2.32),
            threshold: 0.08
        )
        let door = try XCTUnwrap(slid.plan.openings.first { $0.id == SampleApartment.id(0x15) })
        XCTAssertEqual(door.center.x, 3.6, accuracy: 1e-9)
        XCTAssertEqual(door.center.z, 2.4, accuracy: 1e-9)
        XCTAssertEqual(door.yaw, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(door.width, 0.9, accuracy: 1e-9)
        XCTAssertFalse(slid.guides.isEmpty)

        let flush = PlanEditor.slide(
            kitchen(),
            openingID: SampleApartment.id(0x15),
            to: Vec3(x: 3.6, y: 0, z: 2.7),
            threshold: 0.08
        )
        let flushed = try XCTUnwrap(flush.plan.openings.first)
        XCTAssertEqual(flushed.center.z, 2.75, accuracy: 1e-9)
        XCTAssertFalse(flush.guides.isEmpty)

        let clamped = PlanEditor.slide(
            kitchen(),
            openingID: SampleApartment.id(0x15),
            to: Vec3(x: 9, y: 0, z: 0.1)
        ).plan
        let stopped = try XCTUnwrap(clamped.openings.first)
        XCTAssertEqual(stopped.center.z, 0.45, accuracy: 1e-9)
        XCTAssertEqual(stopped.center.x, 3.6, accuracy: 1e-9)
    }

    func testCopyOpeningLandsOnTheSameWall() throws {
        let copy = try XCTUnwrap(PlanEditor.copyOpening(SampleApartment.id(0x15), in: kitchen(), newID: SampleApartment.id(0x19)))
        XCTAssertEqual(copy.openingID, SampleApartment.id(0x19))
        XCTAssertEqual(copy.plan.openings.count, 2)
        let original = try XCTUnwrap(copy.plan.openings.first { $0.id == SampleApartment.id(0x15) })
        let duplicate = try XCTUnwrap(copy.plan.openings.first { $0.id == SampleApartment.id(0x19) })
        XCTAssertEqual(original.center.z, 1.6, accuracy: 1e-9)
        XCTAssertEqual(duplicate.center.x, 3.6, accuracy: 1e-9)
        XCTAssertEqual(duplicate.center.z, 2.62, accuracy: 1e-9)
        XCTAssertEqual(duplicate.kind, .door)
        XCTAssertEqual(duplicate.width, original.width, accuracy: 1e-9)
        XCTAssertEqual(duplicate.yaw, original.yaw, accuracy: 1e-9)
    }

    func testSplitHalvesTheRoomAndInsertsADoor() throws {
        var nextID = 0x50
        let split = try XCTUnwrap(PlanEditor.split(kitchen()) {
            nextID += 1
            return SampleApartment.id(nextID)
        })
        XCTAssertEqual(split.axis, .u)
        XCTAssertEqual(split.mid, 1.8, accuracy: 1e-9)
        XCTAssertEqual(MeasurementMath.floorArea(of: split.kept), 5.76, accuracy: 1e-6)
        XCTAssertEqual(MeasurementMath.floorArea(of: split.created), 5.76, accuracy: 1e-6)

        XCTAssertTrue(split.kept.walls.contains { abs($0.start.x) < 1e-6 && abs($0.end.x) < 1e-6 })
        XCTAssertFalse(split.kept.walls.contains { abs($0.start.x - 3.6) < 1e-6 && abs($0.end.x - 3.6) < 1e-6 })
        XCTAssertTrue(split.created.walls.contains { abs($0.start.x - 3.6) < 1e-6 && abs($0.end.x - 3.6) < 1e-6 })

        let keptDoor = try XCTUnwrap(split.kept.openings.first { $0.kind == .door })
        let createdDivider = try XCTUnwrap(split.created.openings.first { abs($0.center.x - 1.8) < 1e-6 })
        XCTAssertEqual(keptDoor.center.x, 1.8, accuracy: 1e-9)
        XCTAssertEqual(keptDoor.center.z, 1.6, accuracy: 1e-9)
        XCTAssertEqual(keptDoor.width, 0.9, accuracy: 1e-9)
        XCTAssertEqual(createdDivider.center.x, 1.8, accuracy: 1e-9)
        XCTAssertEqual(createdDivider.width, 0.9, accuracy: 1e-9)
        XCTAssertNotEqual(keptDoor.id, createdDivider.id)

        let movedDoor = try XCTUnwrap(split.created.openings.first { abs($0.center.x - 3.6) < 1e-6 })
        XCTAssertEqual(movedDoor.center.z, 1.6, accuracy: 1e-9)
        XCTAssertFalse(split.kept.openings.contains { abs($0.center.x - 3.6) < 1e-6 })

        let fridge = try XCTUnwrap(split.kept.objects.first { $0.category == "refrigerator" })
        XCTAssertEqual(fridge.id, SampleApartment.id(0x17))
        XCTAssertFalse(split.created.objects.contains { $0.category == "refrigerator" })
        XCTAssertTrue(split.kept.objects.contains { $0.category == "table" })
        XCTAssertFalse(split.containsCreated(x: 1.8, z: 1.4))
        XCTAssertTrue(split.containsCreated(x: 2, z: 1))
    }

    func testSplitMovesPinsOnTheNewHalf() throws {
        let split = try XCTUnwrap(PlanEditor.split(kitchen()))
        let pins = [
            DevicePin(
                id: SampleApartment.id(0x31),
                roomId: SampleApartment.kitchenID,
                name: "Kitchen light",
                kind: .light,
                entityId: "light.kitchen",
                position: Vec3(x: 1.8, y: 2.35, z: 1.6)
            ),
            DevicePin(
                id: SampleApartment.id(0x32),
                roomId: SampleApartment.kitchenID,
                name: "Far light",
                kind: .light,
                entityId: nil,
                position: Vec3(x: 3, y: 2.35, z: 1)
            ),
            DevicePin(
                id: SampleApartment.id(0x33),
                roomId: SampleApartment.livingRoomID,
                name: "Other room",
                kind: .switch,
                entityId: nil,
                position: Vec3(x: 3, y: 1, z: 1)
            )
        ]
        let moved = PlanEditor.reassignedPins(
            pins,
            from: SampleApartment.kitchenID,
            to: SampleApartment.id(0x40),
            split: split
        )
        XCTAssertEqual(moved[0].roomId, SampleApartment.kitchenID)
        XCTAssertEqual(moved[1].roomId, SampleApartment.id(0x40))
        XCTAssertEqual(moved[2].roomId, SampleApartment.livingRoomID)
    }

    func testRotatedRoomResizesAlongItsOwnWalls() throws {
        let plan = rotatedRoom()
        let box = try XCTUnwrap(PlanEditor.box(of: plan))
        let destination = box.world(u: box.maxU + 0.5, v: (box.minV + box.maxV) / 2, y: 0)
        let edited = PlanEditor.resize(plan, handle: .edge(.maxU), to: destination).plan
        let editedBox = try XCTUnwrap(PlanEditor.box(of: edited))
        XCTAssertEqual(editedBox.maxU - editedBox.minU, box.width + 0.5, accuracy: 1e-6)
        XCTAssertEqual(editedBox.depth, box.depth, accuracy: 1e-6)
        XCTAssertEqual(editedBox.minU, box.minU, accuracy: 1e-6)
        let door = try XCTUnwrap(edited.openings.first)
        let doorU = editedBox.u(door.center)
        XCTAssertEqual(doorU, editedBox.maxU, accuracy: 1e-6)
    }

    func testUndoRestoresThePreviousRoomsAndRedoReapplies() {
        var history = PlanHistory()
        let original = PlanSnapshot(home: SampleApartment.make())
        history.record(original)
        var editedHome = SampleApartment.make()
        editedHome.rooms[0].floorPlan = PlanEditor.resize(
            editedHome.rooms[0].floorPlan,
            handle: .edge(.maxU),
            to: Vec3(x: 4.2, y: 0, z: 1)
        ).plan
        let edited = PlanSnapshot(home: editedHome)
        let restored = history.undo(current: edited)
        XCTAssertEqual(restored, original)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redo(current: original), edited)
        var empty = PlanHistory()
        XCTAssertNil(empty.undo(current: original))
    }

    func testEditedPlanPersistsAndExports() throws {
        var home = SampleApartment.make()
        let original = home.rooms[0].floorPlan
        let edited = PlanEditor.resize(
            original,
            handle: .edge(.maxU),
            to: Vec3(x: 4.2, y: 0, z: 1)
        ).plan
        home.rooms[0].floorPlan = edited
        home.structure?.overviewFloorPlan = FloorPlan(walls: [
            WallSegment(
                id: UUID(),
                start: .zero,
                end: Vec3(x: 1, y: 0, z: 0),
                height: 2,
                thickness: 0.1
            )
        ])

        let document = try HomeLayoutDocument.decode(try HomeLayoutDocument(home: home).encode())
        let wall = try XCTUnwrap(document.home.rooms[0].floorPlan.walls.first { $0.id == SampleApartment.id(0x14) })
        XCTAssertEqual(wall.start.x, 4.2, accuracy: 1e-4)
        let packages = try HomeExport.packages(for: home)
        let homeGLB = FloorPlanGLB.data(for: home.rooms.map { ($0.floorPlan, Vec3.zero) })
        XCTAssertEqual(glbMeshBytes(packages[0].modelGLB), glbMeshBytes(homeGLB))
        XCTAssertNotEqual(glbMeshBytes(packages[0].modelGLB), glbMeshBytes(FloorPlanGLB.data(for: original)))
        XCTAssertNotNil(glbMeshBytes(packages[0].modelGLB).range(of: floatBytes(4.2)))
        let kitchenDocument = try HomeLayoutDocument.decode(packages[1].layoutJSON)
        let exported = try XCTUnwrap(kitchenDocument.home.rooms[0].floorPlan.walls.first { $0.id == SampleApartment.id(0x14) })
        XCTAssertEqual(exported.end.x, 4.2, accuracy: 1e-4)
        XCTAssertEqual(glbMeshBytes(packages[1].modelGLB), glbMeshBytes(FloorPlanGLB.data(for: edited)))
        XCTAssertNotEqual(glbMeshBytes(packages[1].modelGLB), glbMeshBytes(FloorPlanGLB.data(for: original)))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-editor-\(UUID().uuidString)", isDirectory: true)
        let repository = try HomeRepository(root: root)
        let saved = try repository.createHome(named: "Edited", now: SampleApartment.createdAt)
        var toStore = home
        toStore.id = saved.id
        let stored = try repository.save(toStore, touch: false)
        let reloaded = try HomeRepository(root: root)
        let loaded = try XCTUnwrap(reloaded.homes.first { $0.id == stored.id })
        let reloadedWall = try XCTUnwrap(loaded.rooms[0].floorPlan.walls.first { $0.id == SampleApartment.id(0x14) })
        XCTAssertEqual(reloadedWall.start.x, 4.2, accuracy: 1e-4)
        try? FileManager.default.removeItem(at: root)
    }

    func testUnmergedHomeStillExportsTheOverviewShell() throws {
        var home = SampleApartment.make()
        home.structure?.coordinatesAreUnified = false
        let overview = FloorPlan(walls: [
            WallSegment(
                id: UUID(),
                start: .zero,
                end: Vec3(x: 2, y: 0, z: 0),
                height: 2,
                thickness: 0.1
            )
        ])
        home.structure?.overviewFloorPlan = overview
        let packages = try HomeExport.packages(for: home)
        XCTAssertEqual(glbMeshBytes(packages[0].modelGLB), glbMeshBytes(FloorPlanGLB.data(for: overview)))
        XCTAssertNotEqual(
            glbMeshBytes(packages[0].modelGLB),
            glbMeshBytes(FloorPlanGLB.data(for: home.rooms.map { ($0.floorPlan, Vec3.zero) }))
        )
    }

    private func glbMeshBytes(_ data: Data) -> Data {
        let jsonLength = Int(readUInt32(data, offset: 12))
        let header = 20 + jsonLength
        let binLength = Int(readUInt32(data, offset: header))
        return data.subdata(in: (header + 8)..<(header + 8 + binLength))
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    private func floatBytes(_ value: Float) -> Data {
        var le = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    private func kitchen() -> FloorPlan {
        SampleApartment.make().room(id: SampleApartment.kitchenID)!.floorPlan
    }

    private func rectangularRoom(width: Double, depth: Double, windowAt: Double, windowWidth: Double) -> FloorPlan {
        func wall(_ start: (Double, Double), _ end: (Double, Double)) -> WallSegment {
            WallSegment(
                id: UUID(),
                start: Vec3(x: start.0, y: 0, z: start.1),
                end: Vec3(x: end.0, y: 0, z: end.1),
                height: 2.4,
                thickness: 0.1
            )
        }
        return FloorPlan(
            walls: [
                wall((0, 0), (width, 0)),
                wall((width, 0), (width, depth)),
                wall((width, depth), (0, depth)),
                wall((0, depth), (0, 0))
            ],
            openings: [
                Opening(
                    id: UUID(),
                    kind: .window,
                    center: Vec3(x: windowAt, y: 1.4, z: 0),
                    width: windowWidth,
                    height: 1.2,
                    yaw: 0
                )
            ],
            floors: [
                FloorPolygon(
                    id: UUID(),
                    corners: [
                        Vec3(x: 0, y: 0, z: 0),
                        Vec3(x: width, y: 0, z: 0),
                        Vec3(x: width, y: 0, z: depth),
                        Vec3(x: 0, y: 0, z: depth)
                    ]
                )
            ]
        )
    }

    private func rotatedRoom() -> FloorPlan {
        let angle = 30.0 * Double.pi / 180
        let axisU = Vec3(x: Trig.cos(angle), y: 0, z: Trig.sin(angle))
        let axisV = Vec3(x: -Trig.sin(angle), y: 0, z: Trig.cos(angle))
        func world(u: Double, v: Double) -> Vec3 {
            Vec3(x: axisU.x * u + axisV.x * v, y: 0, z: axisU.z * u + axisV.z * v)
        }
        let corners = [
            world(u: -1, v: -0.5),
            world(u: 1, v: -0.5),
            world(u: 1, v: 0.5),
            world(u: -1, v: 0.5)
        ]
        let walls = (0..<4).map { index in
            WallSegment(
                id: UUID(),
                start: corners[index],
                end: corners[(index + 1) % 4],
                height: 2.4,
                thickness: 0.1
            )
        }
        let doorCenter = world(u: 1, v: 0)
        return FloorPlan(
            walls: walls,
            openings: [
                Opening(
                    id: UUID(),
                    kind: .door,
                    center: doorCenter,
                    width: 0.4,
                    height: 2,
                    yaw: Trig.atan2(axisV.z, axisV.x)
                )
            ],
            floors: [FloorPolygon(id: UUID(), corners: corners)]
        )
    }
}
