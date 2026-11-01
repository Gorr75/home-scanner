import XCTest
@testable import RoomScanCore

final class RepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("roomscan-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSaveReloadAndRoomFiles() throws {
        let now = SampleApartment.createdAt
        let repo = try HomeRepository(root: root)
        let created = try repo.createHome(named: "  Ground floor  ", now: now)
        XCTAssertEqual(created.name, "Ground floor")
        let plan = SampleApartment.make().room(id: SampleApartment.kitchenID)!.floorPlan
        let updated = try repo.addRoom(
            homeId: created.id,
            name: "Kitchen",
            floorPlan: plan,
            capturedJSON: Data("captured".utf8),
            usdz: Data("usdz".utf8),
            now: now
        )
        let room = try XCTUnwrap(updated.rooms.first)
        let captured = try Data(contentsOf: repo.fileURL(homeId: created.id, relative: try XCTUnwrap(room.assets.capturedRoom)))
        XCTAssertEqual(captured, Data("captured".utf8))
        let payloads = try repo.capturedPayloads(in: updated)
        XCTAssertEqual(payloads.count, 1)

        let reloaded = try HomeRepository(root: root)
        XCTAssertEqual(reloaded.homes.map(\.name), ["Ground floor"])
        XCTAssertEqual(reloaded.homes[0].rooms.first?.name, "Kitchen")
        XCTAssertEqual(reloaded.homes[0].rooms.first?.floorPlan.walls.count, plan.walls.count)

        XCTAssertThrowsError(try reloaded.fileURL(homeId: created.id, relative: "../nope")) { error in
            guard case HomeRepositoryError.unsafePath = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testDeleteRoomDropsPinsAndStructure() throws {
        let repo = try HomeRepository(root: root)
        let installed = try repo.installSampleApartment(usdz: Data("model".utf8))
        let again = try repo.installSampleApartment(usdz: Data("other".utf8))
        XCTAssertEqual(again.id, installed.id)
        let model = try Data(contentsOf: repo.fileURL(homeId: installed.id, relative: "structure.usdz"))
        XCTAssertEqual(model, Data("model".utf8))

        let removed = try repo.deleteRoom(homeId: installed.id, roomId: SampleApartment.kitchenID)
        XCTAssertEqual(removed.rooms.map(\.name), ["Living room"])
        XCTAssertNil(removed.structure)
        XCTAssertTrue(removed.pins.allSatisfy { $0.roomId == SampleApartment.livingRoomID })
        let structureURL = try repo.fileURL(homeId: installed.id, relative: "structure.usdz")
        XCTAssertFalse(FileManager.default.fileExists(atPath: structureURL.path))
    }

    func testAttachStructureAndSkipCorruptHomes() throws {
        let repo = try HomeRepository(root: root)
        let home = try repo.createHome(named: "Upstairs")
        let withRoom = try repo.addRoom(
            homeId: home.id,
            name: "Bedroom",
            floorPlan: .empty,
            capturedJSON: nil,
            usdz: nil
        )
        let roomId = try XCTUnwrap(withRoom.rooms.first?.id)
        let attached = try repo.attachStructure(
            homeId: home.id,
            capturedJSON: Data("{}".utf8),
            usdz: Data("merged".utf8),
            overview: FloorPlan(),
            roomIds: [roomId]
        )
        XCTAssertEqual(attached.structure?.coordinatesAreUnified, false)
        XCTAssertEqual(attached.structure?.roomIds, [roomId])
        XCTAssertNotNil(attached.structure?.overviewFloorPlan)

        let junk = root.appendingPathComponent("junk-home", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: junk.appendingPathComponent("home.json"))
        let reloaded = try HomeRepository(root: root)
        XCTAssertEqual(reloaded.homes.count, 1)
        XCTAssertEqual(reloaded.warnings.count, 1)

        let export = try reloaded.exportLayoutFile(for: attached)
        XCTAssertTrue(export.lastPathComponent.hasSuffix(".roomscan.json"))
        let document = try HomeLayoutDocument.decode(Data(contentsOf: export))
        XCTAssertEqual(document.home.name, "Upstairs")

        try reloaded.deleteHome(id: home.id)
        XCTAssertTrue(try HomeRepository(root: root).homes.isEmpty)
    }

    func testReplaceRoomKeepsPinsAndClearsStructure() throws {
        let repo = try HomeRepository(root: root)
        let home = try repo.createHome(named: "Loft")
        let withRoom = try repo.addRoom(
            homeId: home.id,
            name: "Studio",
            floorPlan: .empty,
            capturedJSON: Data("old".utf8),
            usdz: Data("old-model".utf8)
        )
        let roomId = try XCTUnwrap(withRoom.rooms.first?.id)
        var pinned = withRoom
        pinned.upsertPin(DevicePin.placed(in: roomId, kind: .light, x: 1, z: 1, name: "Lamp"))
        _ = try repo.save(pinned)
        _ = try repo.attachStructure(
            homeId: home.id,
            capturedJSON: Data("{}".utf8),
            usdz: Data("shell".utf8),
            overview: FloorPlan(),
            roomIds: [roomId]
        )
        let plan = SampleApartment.make().room(id: SampleApartment.kitchenID)!.floorPlan
        let replaced = try repo.replaceRoom(
            homeId: home.id,
            roomId: roomId,
            floorPlan: plan,
            capturedJSON: Data("new".utf8),
            usdz: Data("new-model".utf8)
        )
        let room = try XCTUnwrap(replaced.room(id: roomId))
        XCTAssertEqual(room.name, "Studio")
        XCTAssertEqual(room.floorPlan.objects.count, plan.objects.count)
        XCTAssertEqual(replaced.pins.count, 1)
        XCTAssertNil(replaced.structure)
        let captured = try Data(contentsOf: repo.fileURL(homeId: home.id, relative: try XCTUnwrap(room.assets.capturedRoom)))
        XCTAssertEqual(captured, Data("new".utf8))
    }
}
