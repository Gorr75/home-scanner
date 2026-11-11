import XCTest
@testable import RoomScanCore

final class ICloudLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSyncDefaultsOnOnlyWhenICloudIsAvailable() {
        XCTAssertTrue(ICloudSyncPreference.isEnabled(stored: nil, accountAvailable: true))
        XCTAssertFalse(ICloudSyncPreference.isEnabled(stored: nil, accountAvailable: false))
        XCTAssertFalse(ICloudSyncPreference.isEnabled(stored: false, accountAvailable: true))
        XCTAssertTrue(ICloudSyncPreference.isEnabled(stored: true, accountAvailable: false))
    }

    func testPhaseLabelsAndPriority() {
        XCTAssertEqual(ICloudSyncPhase.synced.label, "Synced")
        XCTAssertEqual(ICloudSyncPhase.uploading.label, "Uploading")
        XCTAssertEqual(ICloudSyncPhase.offline.label, "Offline")
        XCTAssertEqual(ICloudSyncPhase.notSignedIn.label, "Not signed in")

        XCTAssertEqual(ICloudSyncSignals(accountAvailable: false, networkAvailable: false).phase, .notSignedIn)
        XCTAssertEqual(ICloudSyncSignals(accountAvailable: true, networkAvailable: false, pendingUploadCount: 3).phase, .offline)
        XCTAssertEqual(ICloudSyncSignals(accountAvailable: true, networkAvailable: true, driveAvailable: false).phase, .offline)
        XCTAssertEqual(ICloudSyncSignals(accountAvailable: true, networkAvailable: true, uploadingCount: 1).phase, .uploading)
        XCTAssertEqual(ICloudSyncSignals(accountAvailable: true, networkAvailable: true, pendingUploadCount: 2).phase, .uploading)
        XCTAssertEqual(ICloudSyncSignals(accountAvailable: true, networkAvailable: true, downloadingCount: 1).phase, .uploading)
        XCTAssertEqual(ICloudSyncSignals(accountAvailable: true, networkAvailable: true).phase, .synced)
    }

    func testLastWriterWinsAndKeepsTheOlderFile() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_086_400)
        let current = RoomFileSnapshot(relativePath: "rooms/kitchen.usdz", modifiedAt: older, contents: Data("phone".utf8))
        let incoming = RoomFileSnapshot(relativePath: "rooms/kitchen.usdz", modifiedAt: newer, contents: Data("ipad".utf8))
        let resolution = RoomFileConflictResolver.choose(current: current, incoming: incoming)
        XCTAssertEqual(resolution.winner.contents, Data("ipad".utf8))
        XCTAssertEqual(resolution.loser?.contents, Data("phone".utf8))
        XCTAssertEqual(
            resolution.conflictCopyRelativePath,
            "conflicts/rooms/kitchen.usdz.\(RoomFileConflictResolver.stamp(older))"
        )

        let tie = RoomFileConflictResolver.choose(
            current: RoomFileSnapshot(relativePath: "home.json", modifiedAt: newer, contents: Data("cloud".utf8)),
            incoming: RoomFileSnapshot(relativePath: "home.json", modifiedAt: newer, contents: Data("phone".utf8))
        )
        XCTAssertEqual(tie.winner.contents, Data("cloud".utf8))
        XCTAssertEqual(tie.loser?.contents, Data("phone".utf8))

        let sameBytes = RoomFileConflictResolver.choose(
            current: RoomFileSnapshot(relativePath: "home.json", modifiedAt: older, contents: Data("same".utf8)),
            incoming: RoomFileSnapshot(relativePath: "home.json", modifiedAt: newer, contents: Data("same".utf8))
        )
        XCTAssertNil(sameBytes.loser)
        XCTAssertNil(sameBytes.conflictCopyRelativePath)
    }

    func testMigrationCopiesRoomFilesAndReloads() throws {
        let local = root.appendingPathComponent("Local", isDirectory: true)
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        let repository = try HomeRepository(root: local)
        let created = try repository.createHome(named: "Oak Street", now: Date(timeIntervalSince1970: 1_700_000_000))
        let plan = SampleApartment.make().room(id: SampleApartment.kitchenID)!.floorPlan
        _ = try repository.addRoom(
            homeId: created.id,
            name: "Kitchen",
            floorPlan: plan,
            capturedJSON: Data("captured".utf8),
            usdz: Data("usdz-model".utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let homeFolder = local.appendingPathComponent(created.id.uuidString, isDirectory: true)
        try write(homeFolder, "plates/day/base.jpg", "plate", at: Date(timeIntervalSince1970: 1_700_000_100))
        try write(homeFolder, "plates/manifest.json", "manifest", at: Date(timeIntervalSince1970: 1_700_000_100))
        try write(homeFolder, "worldmaps/kitchen.arworldmap", "world-map", at: Date(timeIntervalSince1970: 1_700_000_100))
        try write(homeFolder, "annotations/leak.jpg", "annotation", at: Date(timeIntervalSince1970: 1_700_000_100))
        try write(homeFolder, "textures/wall.jpg", "photo", at: Date(timeIntervalSince1970: 1_700_000_100))

        let report = try HomeLibraryMigrator.migrate(from: local, to: cloud)
        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertTrue(report.copied.contains { $0.hasSuffix("plates/day/base.jpg") })
        XCTAssertTrue(report.copied.contains { $0.hasSuffix("worldmaps/kitchen.arworldmap") })
        XCTAssertTrue(report.copied.contains { $0.hasSuffix("annotations/leak.jpg") })

        let restored = try HomeRepository(root: cloud)
        let home = try XCTUnwrap(restored.homes.first)
        XCTAssertEqual(home.name, "Oak Street")
        XCTAssertEqual(home.rooms.first?.name, "Kitchen")
        let usdz = try restored.contents(homeId: home.id, relative: try XCTUnwrap(home.rooms.first?.assets.usdz))
        XCTAssertEqual(usdz, Data("usdz-model".utf8))
        let cloudHome = cloud.appendingPathComponent(home.id.uuidString)
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("worldmaps/kitchen.arworldmap")), Data("world-map".utf8))
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("annotations/leak.jpg")), Data("annotation".utf8))
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("plates/day/base.jpg")), Data("plate".utf8))
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("textures/wall.jpg")), Data("photo".utf8))

        let again = try HomeLibraryMigrator.migrate(from: local, to: cloud)
        XCTAssertTrue(again.copied.isEmpty)
        XCTAssertTrue(again.conflicts.isEmpty)
        XCTAssertFalse(again.unchanged.isEmpty)
    }

    func testConflictsArePerFileAndCanBeChosen() throws {
        let local = root.appendingPathComponent("Local", isDirectory: true)
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        let home = UUID().uuidString
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_086_400)
        try write(local.appendingPathComponent(home), "rooms/kitchen.usdz", "phone-kitchen", at: older)
        try write(local.appendingPathComponent(home), "rooms/bedroom.usdz", "phone-bedroom", at: newer)
        try write(local.appendingPathComponent(home), "home.json", "phone-layout", at: older)
        try write(cloud.appendingPathComponent(home), "rooms/kitchen.usdz", "ipad-kitchen", at: newer)
        try write(cloud.appendingPathComponent(home), "rooms/bedroom.usdz", "ipad-bedroom", at: older)
        try write(cloud.appendingPathComponent(home), "home.json", "ipad-layout", at: newer)
        try write(cloud.appendingPathComponent(home), "rooms/ipad-only.txt", "keep-me", at: newer)

        let report = try HomeLibraryMigrator.migrate(from: local, to: cloud, now: newer)
        XCTAssertEqual(report.conflicts.sorted(), [
            "\(home)/home.json",
            "\(home)/rooms/bedroom.usdz",
            "\(home)/rooms/kitchen.usdz"
        ])

        let cloudHome = cloud.appendingPathComponent(home)
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("rooms/kitchen.usdz")), Data("ipad-kitchen".utf8))
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("rooms/bedroom.usdz")), Data("phone-bedroom".utf8))
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("home.json")), Data("ipad-layout".utf8))
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("rooms/ipad-only.txt")), Data("keep-me".utf8))

        let copies = try HomeLibraryMigrator.conflictCopies(in: cloud)
        XCTAssertEqual(copies.count, 3)
        let kitchen = try XCTUnwrap(copies.first { $0.originalRelativePath == "rooms/kitchen.usdz" })
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent(kitchen.copyRelativePath)), Data("phone-kitchen".utf8))
        let bedroom = try XCTUnwrap(copies.first { $0.originalRelativePath == "rooms/bedroom.usdz" })
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent(bedroom.copyRelativePath)), Data("ipad-bedroom".utf8))

        let repeated = try HomeLibraryMigrator.migrate(from: local, to: cloud, now: newer)
        XCTAssertEqual(repeated.conflicts.sorted(), [
            "\(home)/home.json",
            "\(home)/rooms/kitchen.usdz"
        ])
        XCTAssertEqual(try HomeLibraryMigrator.conflictCopies(in: cloud).count, 3)

        let pickedAt = Date(timeIntervalSince1970: 1_700_172_800)
        try HomeLibraryMigrator.adopt(kitchen, in: cloud, now: pickedAt)
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("rooms/kitchen.usdz")), Data("phone-kitchen".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudHome.appendingPathComponent(kitchen.copyRelativePath).path))
        let kitchenDate = try XCTUnwrap(LocalHomeDisk().modificationDate(of: cloudHome.appendingPathComponent("rooms/kitchen.usdz")))
        XCTAssertEqual(kitchenDate.timeIntervalSince1970, pickedAt.timeIntervalSince1970, accuracy: 1)

        try HomeLibraryMigrator.discard(bedroom, in: cloud)
        XCTAssertEqual(try Data(contentsOf: cloudHome.appendingPathComponent("rooms/bedroom.usdz")), Data("phone-bedroom".utf8))
        let remaining = try HomeLibraryMigrator.conflictCopies(in: cloud)
        XCTAssertEqual(remaining.map(\.originalRelativePath), ["home.json"])
    }

    func testAbsorbKeepsTheNewerRoomFile() throws {
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let home = UUID().uuidString
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_086_400)
        try write(library.appendingPathComponent(home), "rooms/kitchen.usdz", "current", at: newer)
        let incoming = root.appendingPathComponent("incoming.usdz")
        try Data("older-device".utf8).write(to: incoming)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: incoming.path)
        let conflicted = try HomeLibraryMigrator.absorb(
            incoming: incoming,
            relativePath: "rooms/kitchen.usdz",
            homeFolder: home,
            libraryRoot: library,
            now: newer
        )
        XCTAssertTrue(conflicted)
        let homeFolder = library.appendingPathComponent(home)
        XCTAssertEqual(try Data(contentsOf: homeFolder.appendingPathComponent("rooms/kitchen.usdz")), Data("current".utf8))
        let copies = try HomeLibraryMigrator.conflictCopies(in: library)
        let saved = try XCTUnwrap(copies.first)
        XCTAssertEqual(try Data(contentsOf: homeFolder.appendingPathComponent(saved.copyRelativePath)), Data("older-device".utf8))
    }

    func testEmptyLocalMigrationLeavesCloudHomes() throws {
        let local = root.appendingPathComponent("Local", isDirectory: true)
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try write(cloud.appendingPathComponent("existing"), "home.json", "already", at: Date(timeIntervalSince1970: 1_700_000_000))
        let report = try HomeLibraryMigrator.migrate(from: local, to: cloud)
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("existing/home.json")), Data("already".utf8))
    }

    func testAdoptRejectsAPathThatEscapesTheHome() throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        let home = UUID().uuidString
        try write(cloud.appendingPathComponent(home), "rooms/kitchen.usdz", "current", at: Date(timeIntervalSince1970: 1_700_000_000))
        let escaped = ConflictCopy(
            homeFolder: home,
            originalRelativePath: "../outside.txt",
            copyRelativePath: "conflicts/rooms/kitchen.usdz",
            winnerModifiedAt: Date(timeIntervalSince1970: 1_700_086_400),
            loserModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordedAt: Date(timeIntervalSince1970: 1_700_086_400)
        )
        XCTAssertThrowsError(try HomeLibraryMigrator.adopt(escaped, in: cloud)) { error in
            guard case HomeLibraryError.unsafePath = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
    }

    func testRemovingLocalHomeFoldersKeepsTheRoot() throws {
        let local = root.appendingPathComponent("Local", isDirectory: true)
        try write(local.appendingPathComponent(UUID().uuidString), "home.json", "home", at: Date(timeIntervalSince1970: 1_700_000_000))
        try HomeLibraryMigrator.removeHomeFolders(at: local)
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let left = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
        XCTAssertTrue(left.isEmpty)
    }

    private func write(_ home: URL, _ relative: String, _ text: String, at date: Date) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
