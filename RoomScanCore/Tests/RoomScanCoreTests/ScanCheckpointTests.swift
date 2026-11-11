import XCTest
@testable import RoomScanCore

final class ScanCheckpointTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCheckpointRoundTripUsesSnakeCaseAndDefaultsMissingFields() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let sectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let space = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let homeID = UUID(uuidString: "00000000-0000-0000-0000-000000000033")!
        let checkpointID = UUID(uuidString: "00000000-0000-0000-0000-000000000034")!
        let checkpoint = ScanCheckpoint(
            id: checkpointID,
            homeId: homeID,
            mode: .wholeFloor,
            phase: .scanning,
            startedAt: started,
            updatedAt: started.addingTimeInterval(12),
            floor: 1,
            sections: [
                ScanCheckpointSection(
                    id: sectionID,
                    name: "Kitchen",
                    capturedRoom: "sections/\(sectionID.uuidString).captured.json",
                    finished: false,
                    floor: 1,
                    spaceId: space,
                    sharesHomeMap: true
                )
            ],
            worldMap: ScanCheckpoint.worldMapFilename,
            relocalized: true
        )
        let data = try checkpoint.encode()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"roomscan.checkpoint\""))
        XCTAssertTrue(text.contains("\"home_id\""))
        XCTAssertTrue(text.contains("\"captured_room\""))
        XCTAssertTrue(text.contains("\"shares_home_map\""))
        XCTAssertFalse(text.contains("homeId"))
        let decoded = try ScanCheckpoint.decode(data)
        XCTAssertEqual(decoded, checkpoint)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "relocalized")
        object.removeValue(forKey: "floor")
        object.removeValue(forKey: "room_name_draft")
        object["note_from_a_newer_app"] = "ignored"
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let older = try ScanCheckpoint.decode(legacy)
        XCTAssertFalse(older.relocalized)
        XCTAssertNil(older.floor)
        XCTAssertNil(older.roomNameDraft)
        XCTAssertEqual(older.sections.count, 1)
        XCTAssertEqual(older.sections[0].floor, 1)
    }

    func testCheckpointRejectsUnknownFormatAndVersion() throws {
        let checkpoint = sampleCheckpoint(phase: .interrupted)
        let data = try checkpoint.encode()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["format"] = "other.checkpoint"
        let wrongFormat = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ScanCheckpoint.decode(wrongFormat)) { error in
            guard case ScanCheckpointError.unknownFormat("other.checkpoint") = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        object["format"] = ScanCheckpoint.formatIdentifier
        object["version"] = 2
        let wrongVersion = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ScanCheckpoint.decode(wrongVersion)) { error in
            guard case ScanCheckpointError.unsupportedVersion(2) = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testRecoveryDetectsTheNewestInterruptedScan() {
        let older = sampleCheckpoint(phase: .interrupted, updatedAt: Date(timeIntervalSince1970: 10), sections: 1)
        var saved = sampleCheckpoint(phase: .saved, updatedAt: Date(timeIntervalSince1970: 50), sections: 1)
        saved = ScanCheckpoint(
            id: UUID(),
            homeId: saved.homeId,
            mode: .singleRoom,
            phase: .saved,
            startedAt: saved.startedAt,
            updatedAt: Date(timeIntervalSince1970: 50),
            sections: saved.sections
        )
        let newest = sampleCheckpoint(phase: .scanning, updatedAt: Date(timeIntervalSince1970: 40), sections: 2)
        let mapOnly = ScanCheckpoint(
            id: UUID(),
            homeId: newest.homeId,
            mode: .extendHome,
            phase: .interrupted,
            startedAt: newest.startedAt,
            updatedAt: Date(timeIntervalSince1970: 20),
            worldMap: ScanCheckpoint.worldMapFilename
        )
        let empty = ScanCheckpoint(
            id: UUID(),
            homeId: newest.homeId,
            mode: .singleRoom,
            phase: .scanning,
            startedAt: newest.startedAt,
            updatedAt: Date(timeIntervalSince1970: 80)
        )
        XCTAssertFalse(empty.needsRecovery)
        XCTAssertFalse(saved.needsRecovery)
        XCTAssertTrue(mapOnly.needsRecovery)
        XCTAssertTrue(mapOnly.worldMap != nil)
        XCTAssertFalse(mapOnly.hasCapturedRoom)

        let offer = ScanRecovery.offer(from: [older, saved, newest, mapOnly, empty]) { id in
            id == newest.homeId ? "Kitchen" : nil
        }
        XCTAssertEqual(offer?.checkpoint.id, newest.id)
        XCTAssertEqual(offer?.canResume, true)
        XCTAssertEqual(offer?.canSave, true)
        XCTAssertEqual(
            offer?.summary,
            "A scan of Kitchen was still open. 2 room snapshots are on this iPhone."
        )

        let missingHome = ScanRecovery.offer(from: [mapOnly]) { _ in nil }
        XCTAssertEqual(missingHome?.canResume, false)
        XCTAssertEqual(missingHome?.canSave, false)
        XCTAssertEqual(
            missingHome?.summary,
            "A scan was interrupted, and that home is no longer on this iPhone."
        )
        XCTAssertEqual(
            ScanRecovery.summary(checkpoint: mapOnly, homeName: "Loft"),
            "A scan of Loft was still open. The place lock is saved."
        )
    }

    func testStoreWritesAtomicallyAndSkipsACheckpointWithNoPayload() throws {
        let store = try ScanCheckpointStore(root: root)
        let captured = Data("{\"walls\":[]}".utf8)
        var checkpoint = sampleCheckpoint(phase: .scanning, sections: 1)
        let relative = try XCTUnwrap(checkpoint.sections.first?.capturedRoom)
        checkpoint.worldMap = ScanCheckpoint.worldMapFilename
        _ = try store.save(checkpoint, payloads: [
            relative: captured,
            ScanCheckpoint.worldMapFilename: Data("world-map".utf8)
        ])
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        XCTAssertFalse(leftovers.contains { $0.contains(".tmp") })

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(try store.data(loaded[0].id, relative: relative), captured)
        XCTAssertEqual(try store.data(loaded[0].id, relative: ScanCheckpoint.worldMapFilename), Data("world-map".utf8))

        var replaced = loaded[0]
        replaced.phase = .interrupted
        replaced.updatedAt = replaced.updatedAt.addingTimeInterval(5)
        _ = try store.save(replaced)
        let again = store.loadAll()
        XCTAssertEqual(again.first?.phase, .interrupted)
        XCTAssertEqual(try store.data(replaced.id, relative: relative), captured)

        let offer = store.recoveryOffer(homeName: { _ in "Ground floor" })
        XCTAssertEqual(offer?.checkpoint.sections.count, 1)
        XCTAssertNotNil(offer?.checkpoint.worldMap)

        try store.discard(replaced.id)
        XCTAssertTrue(store.loadAll().isEmpty)

        var dangling = sampleCheckpoint(phase: .scanning, sections: 1)
        dangling.worldMap = "missing.arworldmap"
        _ = try store.save(dangling)
        XCTAssertNil(store.recoveryOffer(homeName: { _ in "Ground floor" }))
    }

    func testGuardrailsCheckpointOnHeatBatteryAndLowStorage() {
        let calm = ScanGuardAdvice.evaluate(ScanConditions(
            thermal: .nominal,
            batteryFraction: 0.8,
            isCharging: false,
            freeBytes: ScanGuardAdvice.lowStorageBytes + 1
        ))
        XCTAssertEqual(calm.level, .ok)
        XCTAssertFalse(calm.checkpointNow)
        XCTAssertNil(calm.storageWarning)
        XCTAssertNil(calm.message)

        let fair = ScanGuardAdvice.evaluate(ScanConditions(
            thermal: .fair,
            batteryFraction: nil,
            isCharging: false,
            freeBytes: nil
        ))
        XCTAssertEqual(fair.level, .ok)
        XCTAssertFalse(fair.checkpointNow)

        let hot = ScanGuardAdvice.evaluate(ScanConditions(
            thermal: .serious,
            batteryFraction: 0.5,
            isCharging: false,
            freeBytes: nil
        ))
        XCTAssertEqual(hot.level, .caution)
        XCTAssertTrue(hot.checkpointNow)
        XCTAssertEqual(hot.message, ScanGuardAdvice.hotMessage)

        let tooHot = ScanGuardAdvice.evaluate(ScanConditions(
            thermal: .critical,
            batteryFraction: 0.5,
            isCharging: true,
            freeBytes: nil
        ))
        XCTAssertEqual(tooHot.level, .stop)
        XCTAssertEqual(tooHot.message, ScanGuardAdvice.tooHotMessage)

        let low = ScanGuardAdvice.evaluate(ScanConditions(
            thermal: .nominal,
            batteryFraction: ScanGuardAdvice.lowBatteryFraction,
            isCharging: false,
            freeBytes: nil
        ))
        XCTAssertEqual(low.level, .caution)
        XCTAssertTrue(low.checkpointNow)
        XCTAssertEqual(low.message, ScanGuardAdvice.batteryMessage)

        let charging = ScanGuardAdvice.evaluate(ScanConditions(
            thermal: .nominal,
            batteryFraction: 0.05,
            isCharging: true,
            freeBytes: nil
        ))
        XCTAssertEqual(charging.level, .ok)
        XCTAssertFalse(charging.checkpointNow)

        let empty = ScanGuardAdvice.evaluate(ScanConditions(
            thermal: .serious,
            batteryFraction: ScanGuardAdvice.criticalBatteryFraction,
            isCharging: false,
            freeBytes: nil
        ))
        XCTAssertEqual(empty.level, .stop)
        XCTAssertTrue(empty.checkpointNow)
        XCTAssertEqual(empty.message, "\(ScanGuardAdvice.hotMessage) \(ScanGuardAdvice.batteryEmptyMessage)")

        let storage = ScanGuardAdvice.evaluate(ScanConditions(
            thermal: .nominal,
            batteryFraction: nil,
            isCharging: false,
            freeBytes: ScanGuardAdvice.lowStorageBytes - 1
        ))
        XCTAssertEqual(storage.storageWarning, ScanGuardAdvice.storageMessage)
        XCTAssertTrue(storage.checkpointNow)
        XCTAssertEqual(storage.level, .ok)
    }

    func testRelocalizedJoinKeepsAnchorPlacementAndCarriedDetails() throws {
        var kitchen = box(name: "Kitchen", x: 0, z: 0, width: 4, depth: 3)
        kitchen.floor = 0
        kitchen.furniture = [PlacedFurniture.placed(catalogId: "sofa", x: 1, z: 1)]
        kitchen.viewpoint = CameraViewpoint(
            position: Vec3(x: 2, y: 1.6, z: 6),
            target: Vec3(x: 2, y: 1, z: 1.5)
        )
        let pin = DevicePin.placed(in: kitchen.id, kind: .light, x: 1.2, z: 0.8, name: "Pendant")
        let anchor = RoomPlacement(
            roomId: kitchen.id,
            yaw: 0.4,
            translation: Vec3(x: 2, y: 0, z: 3),
            snapped: true
        )
        var bedroom = box(name: "Bedroom", x: 4.2, z: 0, width: 3, depth: 3)
        bedroom.floor = 0
        let join = ScanCoordinates.join(
            existing: [kitchen],
            incoming: [bedroom],
            incomingMatchAnchors: true,
            incomingShareSpace: false,
            anchorRoomId: kitchen.id,
            anchorRoomIds: [kitchen.id],
            existingPlacements: [anchor]
        )
        let placed = try XCTUnwrap(join.placements.first { $0.roomId == bedroom.id })
        XCTAssertEqual(placed.yaw, anchor.yaw, accuracy: 1e-9)
        XCTAssertEqual(placed.translation.x, anchor.translation.x, accuracy: 1e-9)
        XCTAssertEqual(placed.translation.z, anchor.translation.z, accuracy: 1e-9)
        XCTAssertEqual(join.placements.first { $0.roomId == kitchen.id }?.translation, anchor.translation)
        XCTAssertFalse(join.coordinatesAreUnified)
        XCTAssertFalse(join.usedAlignmentFallback)
        XCTAssertEqual(kitchen.floor, 0)
        XCTAssertEqual(kitchen.furniture?.count, 1)
        let viewpoint = try XCTUnwrap(kitchen.viewpoint)
        XCTAssertEqual(viewpoint.position.z, 6, accuracy: 1e-9)

        let rigid = placed.transform
        let movedPin = rigid.applying(pin.position)
        let movedFurniture = try XCTUnwrap(kitchen.furniture?.first).transformed(by: rigid)
        let movedCamera = viewpoint.transformed(by: rigid)
        let before = kitchen.viewpoint?.region(of: pin.position, aspect: 1.2)
        let after = movedCamera.region(of: movedPin, aspect: 1.2)
        XCTAssertEqual(before?.x ?? -1, after?.x ?? -2, accuracy: 1e-5)
        XCTAssertEqual(before?.y ?? -1, after?.y ?? -2, accuracy: 1e-5)
        XCTAssertEqual(movedFurniture.position.x, rigid.applying(Vec3(x: 1, y: 0, z: 1)).x, accuracy: 1e-6)
        XCTAssertEqual(movedFurniture.yaw, 0.4, accuracy: 1e-9)
        XCTAssertEqual(movedPin.y, pin.position.y, accuracy: 1e-9)
        let roundTrip = rigid.inverse().applying(movedPin)
        XCTAssertEqual(roundTrip.x, pin.position.x, accuracy: 1e-6)
        XCTAssertEqual(roundTrip.z, pin.position.z, accuracy: 1e-6)
    }

    func testRelocalizedRoomParksASameFloorScanThatIsOutsideTheMap() throws {
        let kitchen = box(name: "Kitchen", x: 0, z: 0, width: 4, depth: 3)
        var hallway = box(name: "Hallway", x: 0, z: 0, width: 2, depth: 3)
        hallway.floor = 0
        var upstairs = box(name: "Landing", x: 0, z: 0, width: 4, depth: 3)
        upstairs.floor = 1
        var bedroom = box(name: "Bedroom", x: 4.2, z: 0, width: 3, depth: 3)
        bedroom.floor = 0
        let join = ScanCoordinates.join(
            existing: [kitchen, hallway, upstairs],
            incoming: [bedroom],
            incomingMatchAnchors: true,
            incomingShareSpace: false,
            anchorRoomId: kitchen.id,
            anchorRoomIds: [kitchen.id],
            existingPlacements: []
        )
        XCTAssertFalse(join.coordinatesAreUnified)
        XCTAssertFalse(join.usedAlignmentFallback)
        let parked = try XCTUnwrap(join.placements.first { $0.roomId == hallway.id })
        XCTAssertGreaterThan(parked.translation.x, 4)
        let bedroomPlacement = try XCTUnwrap(join.placements.first { $0.roomId == bedroom.id })
        XCTAssertTrue(bedroomPlacement.transform.isNearIdentity)
        let upstairsPlacement = try XCTUnwrap(join.placements.first { $0.roomId == upstairs.id })
        XCTAssertTrue(upstairsPlacement.transform.isNearIdentity)
        XCTAssertEqual(upstairs.floor, 1)
    }

    func testSharedSessionOnAnEmptyHomeStaysUnified() {
        let kitchen = box(name: "Kitchen", x: 0, z: 0, width: 4, depth: 3, doorAtX: 4)
        let living = box(name: "Living room", x: 4, z: 0, width: 5, depth: 3, doorAtX: 4)
        let join = ScanCoordinates.join(
            existing: [],
            incoming: [kitchen, living],
            incomingMatchAnchors: false,
            incomingShareSpace: true,
            anchorRoomId: nil,
            anchorRoomIds: [],
            existingPlacements: []
        )
        XCTAssertTrue(join.coordinatesAreUnified)
        XCTAssertFalse(join.usedAlignmentFallback)
        XCTAssertTrue(join.placements.isEmpty)
        XCTAssertEqual(join.storedAlignment.placements.count, 0)
        let point = Vec3(x: 1, y: 0, z: 1)
        let other = Vec3(x: 5, y: 0, z: 1)
        XCTAssertEqual(other.x - point.x, 4, accuracy: 1e-9)
    }

    func testFailedRelocalizationKeepsExistingPlacementAndSeatsTheNewRoom() throws {
        var kitchen = box(name: "Kitchen", x: 0, z: 0, width: 3.6, depth: 3.2, doorAtX: 3.6)
        kitchen.floor = 0
        let anchor = RoomPlacement(
            roomId: kitchen.id,
            yaw: 0,
            translation: Vec3(x: 10, y: 0, z: 0),
            snapped: false
        )
        var living = box(name: "Living room", x: 0, z: 0, width: 5.2, depth: 4, doorAtX: 0)
        living.floor = 0
        var upstairs = box(name: "Landing", x: 0, z: 0, width: 3, depth: 3)
        upstairs.floor = 1
        let join = ScanCoordinates.join(
            existing: [kitchen, upstairs],
            incoming: [living],
            incomingMatchAnchors: false,
            incomingShareSpace: false,
            anchorRoomId: kitchen.id,
            anchorRoomIds: [kitchen.id],
            existingPlacements: [anchor]
        )
        XCTAssertTrue(join.usedAlignmentFallback)
        XCTAssertFalse(join.coordinatesAreUnified)
        let kept = try XCTUnwrap(join.placements.first { $0.roomId == kitchen.id })
        XCTAssertEqual(kept.translation.x, 10, accuracy: 1e-9)
        XCTAssertEqual(kept.yaw, 0, accuracy: 1e-9)
        let seated = try XCTUnwrap(join.placements.first { $0.roomId == living.id })
        XCTAssertGreaterThan(seated.translation.x, 12)
        XCTAssertEqual(upstairs.floor, 1)
        XCTAssertEqual(kitchen.floor, 0)
        let upstairsPlacement = try XCTUnwrap(join.placements.first { $0.roomId == upstairs.id })
        XCTAssertTrue(upstairsPlacement.transform.isNearIdentity)
    }

    func testGroupFallbackAppliesOneTransformSoRelativeRoomsStayPut() throws {
        let kitchen = box(name: "Kitchen", x: 0, z: 0, width: 3.6, depth: 3.2, doorAtX: 3.6)
        let living = box(name: "Living room", x: 0, z: 0, width: 5.2, depth: 4, doorAtX: 0)
        let dining = box(name: "Dining room", x: 6, z: 0, width: 3, depth: 3)
        let join = ScanCoordinates.join(
            existing: [kitchen],
            incoming: [living, dining],
            incomingMatchAnchors: false,
            incomingShareSpace: true,
            anchorRoomId: kitchen.id,
            anchorRoomIds: [],
            existingPlacements: []
        )
        XCTAssertTrue(join.usedAlignmentFallback)
        let livingPlacement = try XCTUnwrap(join.placements.first { $0.roomId == living.id })
        let diningPlacement = try XCTUnwrap(join.placements.first { $0.roomId == dining.id })
        XCTAssertEqual(livingPlacement.yaw, diningPlacement.yaw, accuracy: 1e-9)
        XCTAssertEqual(livingPlacement.translation.x, diningPlacement.translation.x, accuracy: 1e-9)
        XCTAssertEqual(livingPlacement.translation.z, diningPlacement.translation.z, accuracy: 1e-9)
        let origin = Vec3(x: 1, y: 0, z: 1)
        let far = Vec3(x: 7, y: 0, z: 1)
        let movedOrigin = livingPlacement.transform.applying(origin)
        let movedFar = diningPlacement.transform.applying(far)
        XCTAssertEqual(movedFar.x - movedOrigin.x, far.x - origin.x, accuracy: 1e-6)
        XCTAssertEqual(movedFar.z - movedOrigin.z, far.z - origin.z, accuracy: 1e-6)
    }

    func testGroupNudgeKeepsTheGapBetweenRooms() throws {
        let living = box(name: "Living room", x: 0, z: 0, width: 4, depth: 2)
        let dining = box(name: "Dining room", x: 6, z: 0, width: 4, depth: 2)
        let placements = [living, dining].map {
            RoomPlacement(roomId: $0.id, yaw: 0, translation: .zero, snapped: false)
        }
        let turned = ScanCoordinates.nudgeGroup(
            placements: placements,
            rooms: [living, dining],
            yaw: .pi / 2,
            translation: .zero
        )
        let livingCenter = FloorPlanGeometry.bounds(of: living.floorPlan).center
        let diningCenter = FloorPlanGeometry.bounds(of: dining.floorPlan).center
        let movedLiving = try XCTUnwrap(turned.first { $0.roomId == living.id }).transform.applying(livingCenter)
        let movedDining = try XCTUnwrap(turned.first { $0.roomId == dining.id }).transform.applying(diningCenter)
        let before = diningCenter - livingCenter
        let after = movedDining - movedLiving
        XCTAssertEqual(after.horizontalLength, before.horizontalLength, accuracy: 1e-6)
        XCTAssertEqual((movedLiving.x + movedDining.x) / 2, (livingCenter.x + diningCenter.x) / 2, accuracy: 1e-6)
        XCTAssertEqual((movedLiving.z + movedDining.z) / 2, (livingCenter.z + diningCenter.z) / 2, accuracy: 1e-6)
    }

    func testNudgeRotatesAroundTheDisplayedCenterThenSlides() throws {
        let room = box(name: "Office", x: 0, z: 0, width: 4, depth: 2)
        let center = FloorPlanGeometry.bounds(of: room.floorPlan).center
        var placement = RoomPlacement(roomId: room.id, yaw: 0, translation: Vec3(x: 10, y: 0, z: -2), snapped: true)
        placement = ScanCoordinates.nudge(placement: placement, plan: room.floorPlan, yaw: .pi / 2, translation: .zero)
        let turned = placement.transform.applying(center)
        let expected = Vec3(x: center.x + 10, y: center.y, z: center.z - 2)
        XCTAssertEqual(turned.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(turned.z, expected.z, accuracy: 1e-6)
        XCTAssertFalse(placement.snapped)
        let slid = ScanCoordinates.nudge(
            placement: placement,
            plan: room.floorPlan,
            yaw: 0,
            translation: Vec3(x: 0.5, y: 0, z: -0.25)
        )
        let moved = slid.transform.applying(center)
        XCTAssertEqual(moved.x, expected.x + 0.5, accuracy: 1e-6)
        XCTAssertEqual(moved.z, expected.z - 0.25, accuracy: 1e-6)

        let overview = ScanCoordinates.overview(rooms: [room], placements: [slid])
        let wall = try XCTUnwrap(overview.walls.first)
        let original = try XCTUnwrap(room.floorPlan.walls.first { $0.id == wall.id })
        XCTAssertEqual(wall.start.x, slid.transform.applying(original.start).x, accuracy: 1e-6)
        XCTAssertEqual(wall.start.z, slid.transform.applying(original.start).z, accuracy: 1e-6)
    }

    func testWorldMapAndFloorSurviveReloadWithoutTouchingFurnitureOrPins() throws {
        let homes = root.appendingPathComponent("homes", isDirectory: true)
        let repo = try HomeRepository(root: homes)
        let created = try repo.createHome(named: "Ground", now: Date(timeIntervalSince1970: 20))
        var kitchen = box(name: "Kitchen", x: 0, z: 0, width: 3, depth: 3)
        kitchen.floor = 0
        kitchen.furniture = [PlacedFurniture.placed(catalogId: "chair", x: 1, z: 1)]
        kitchen.viewpoint = CameraViewpoint(position: Vec3(x: 0, y: 1.5, z: 4), target: Vec3(x: 1, y: 1, z: 1))
        let saved = try repo.addRooms(
            homeId: created.id,
            drafts: [
                CapturedRoomDraft(
                    id: kitchen.id,
                    name: kitchen.name,
                    floor: kitchen.floor,
                    floorPlan: kitchen.floorPlan,
                    capturedJSON: Data("room".utf8),
                    usdz: Data("model".utf8),
                    createdAt: kitchen.createdAt
                )
            ],
            now: Date(timeIntervalSince1970: 20)
        )
        var pinned = saved
        pinned.rooms[0].furniture = kitchen.furniture
        pinned.rooms[0].viewpoint = kitchen.viewpoint
        pinned.upsertPin(DevicePin.placed(in: kitchen.id, kind: .light, x: 1, z: 1, name: "Lamp"))
        _ = try repo.save(pinned)
        let mapped = try repo.writeWorldMap(
            homeId: created.id,
            data: Data("arworld".utf8),
            roomIds: [kitchen.id],
            anchorRoomId: kitchen.id,
            now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(mapped.worldMap?.roomIds, [kitchen.id])
        XCTAssertEqual(repo.worldMapData(in: mapped), Data("arworld".utf8))

        let bare = try HomeLayoutDocument(home: SampleApartment.make()).encode()
        let bareText = try XCTUnwrap(String(data: bare, encoding: .utf8))
        XCTAssertFalse(bareText.contains("world_map"))
        let withMap = try HomeLayoutDocument.decode(try HomeLayoutDocument(home: mapped).encode()).home
        XCTAssertEqual(withMap.worldMap?.anchorRoomId, kitchen.id)
        let storedRoom = try XCTUnwrap(withMap.room(id: kitchen.id))
        XCTAssertEqual(storedRoom.floor, 0)
        XCTAssertEqual(storedRoom.furniture?.count, 1)
        XCTAssertEqual(try XCTUnwrap(storedRoom.viewpoint).position.y, 1.5, accuracy: 1e-6)
        XCTAssertEqual(withMap.pins.count, 1)

        let nudged = ScanCoordinates.nudge(
            placement: RoomPlacement(roomId: kitchen.id, yaw: 0, translation: .zero, snapped: false),
            plan: kitchen.floorPlan,
            yaw: 0.2,
            translation: Vec3(x: 0.1, y: 0, z: 0)
        )
        let aligned = try repo.updateAlignment(
            homeId: created.id,
            placements: [nudged],
            overlaps: [],
            coordinatesAreUnified: false,
            shellWasRebuilt: true,
            overview: ScanCoordinates.overview(rooms: [kitchen], placements: [nudged]),
            roomIds: [kitchen.id],
            now: Date(timeIntervalSince1970: 40)
        )
        let reloaded = try HomeRepository(root: homes)
        let room = try XCTUnwrap(reloaded.homes.first?.room(id: kitchen.id))
        XCTAssertEqual(room.floor, 0)
        XCTAssertEqual(room.furniture?.count, 1)
        XCTAssertEqual(try XCTUnwrap(room.viewpoint).target.x, 1, accuracy: 1e-6)
        XCTAssertEqual(reloaded.homes.first?.pins.first?.name, "Lamp")
        XCTAssertEqual(reloaded.homes.first?.structure?.placements?.first?.yaw ?? 0, nudged.yaw, accuracy: 1e-6)
        XCTAssertEqual(aligned.structure?.shellWasRebuilt, true)
        XCTAssertNil(aligned.structure?.usdz)

        let removed = try reloaded.deleteRoom(homeId: created.id, roomId: kitchen.id)
        XCTAssertNil(removed.worldMap)
        XCTAssertTrue(removed.pins.isEmpty)
    }

    private func sampleCheckpoint(
        phase: ScanCheckpointPhase,
        updatedAt: Date = Date(timeIntervalSince1970: 10),
        sections: Int = 1
    ) -> ScanCheckpoint {
        let homeID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let id = UUID()
        let space = UUID()
        let built = (0..<sections).map { index in
            let sectionID = UUID()
            return ScanCheckpointSection(
                id: sectionID,
                name: "Room \(index + 1)",
                capturedRoom: "sections/\(sectionID.uuidString).captured.json",
                finished: false,
                floor: 0,
                spaceId: space
            )
        }
        return ScanCheckpoint(
            id: id,
            homeId: homeID,
            mode: .singleRoom,
            phase: phase,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: updatedAt,
            sections: built
        )
    }

    private func box(
        name: String,
        x: Double,
        z: Double,
        width: Double,
        depth: Double,
        doorAtX: Double? = nil
    ) -> Room {
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
            id: UUID(),
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
}
