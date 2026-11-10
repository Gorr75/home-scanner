import XCTest
@testable import RoomScanCore

final class ViewpointAndPlateTests: XCTestCase {
    func testSampleJSONOmitsFloorAndViewpoint() throws {
        let text = try XCTUnwrap(String(data: try HomeLayoutDocument(home: SampleApartment.make()).encode(), encoding: .utf8))
        XCTAssertFalse(text.contains("\"viewpoint\""))
        XCTAssertFalse(text.contains("\"field_of_view\""))
        XCTAssertFalse(text.contains("\n    \"floor\""))
    }

    func testFloorAndViewpointRoundTrip() throws {
        var home = SampleApartment.make()
        let viewpoint = CameraViewpoint(
            position: Vec3(x: 1.25, y: 1.6, z: 4),
            target: Vec3(x: 1.8, y: 1.2, z: 1.6),
            fieldOfView: 42
        )
        home.rooms[0].floor = 0
        home.rooms[0].viewpoint = viewpoint
        home.rooms[1].floor = 1
        let decoded = try HomeLayoutDocument.decode(try HomeLayoutDocument(home: home).encode())
        XCTAssertEqual(decoded.home.rooms[0].floor, 0)
        let saved = try XCTUnwrap(decoded.home.rooms[0].viewpoint)
        XCTAssertEqual(saved.position.x, viewpoint.position.x, accuracy: 1e-4)
        XCTAssertEqual(saved.position.y, viewpoint.position.y, accuracy: 1e-4)
        XCTAssertEqual(saved.target.z, viewpoint.target.z, accuracy: 1e-4)
        XCTAssertEqual(saved.fieldOfView, 42, accuracy: 1e-9)
        XCTAssertEqual(decoded.home.rooms[1].floor, 1)
        XCTAssertNil(decoded.home.rooms[1].viewpoint)
        let text = try XCTUnwrap(String(data: try HomeLayoutDocument(home: decoded.home).encode(), encoding: .utf8))
        XCTAssertTrue(text.contains("\"floor\" : 0"))
        XCTAssertTrue(text.contains("\"field_of_view\" : 42"))
        XCTAssertFalse(text.contains("\"viewpoint\" : null"))
    }

    func testMissingFloorStillDecodes() throws {
        let encoded = try HomeLayoutDocument(home: SampleApartment.make()).encode()
        let decoded = try HomeLayoutDocument.decode(encoded)
        XCTAssertTrue(decoded.home.rooms.allSatisfy { $0.floor == nil && $0.viewpoint == nil })
    }

    func testRoomsGroupByFloorAndKeepOrder() {
        let rooms = [
            room("Loft", floor: 1),
            room("Hall", floor: nil),
            room("Kitchen", floor: 0),
            room("Study", floor: 1)
        ]
        let groups = FloorGrouping.groups(in: rooms)
        XCTAssertEqual(groups.map(\.level), [0, 1, nil])
        XCTAssertEqual(groups[0].rooms.map(\.name), ["Kitchen"])
        XCTAssertEqual(groups[1].rooms.map(\.name), ["Loft", "Study"])
        XCTAssertEqual(groups[2].rooms.map(\.name), ["Hall"])
        XCTAssertEqual(FloorGrouping.label(for: 0), "Floor 0")
        XCTAssertEqual(FloorGrouping.label(for: nil), "No floor")
        XCTAssertEqual(FloorGrouping.groups(in: []).map(\.level), [])
    }

    func testOrbitMatchesModelViewerSphericalCoordinates() {
        let camera = CameraViewpoint(
            position: Vec3(x: 0, y: 2, z: 5),
            target: Vec3(x: 0, y: 1, z: 0),
            fieldOfView: 48
        )
        let orbit = camera.orbit()
        XCTAssertEqual(orbit.theta, 0, accuracy: 1e-9)
        XCTAssertEqual(orbit.radius, (1 + 25).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(orbit.phi, ViewpointTrig.acos(1 / orbit.radius), accuracy: 1e-9)
        XCTAssertEqual(orbit.fieldOfView, 48, accuracy: 1e-9)
        let shifted = camera.orbit(offsetX: 4, offsetZ: -1)
        XCTAssertEqual(shifted.target.x, 4, accuracy: 1e-9)
        XCTAssertEqual(shifted.target.z, -1, accuracy: 1e-9)
        XCTAssertEqual(shifted.theta, 0, accuracy: 1e-9)
    }

    func testRegionProjectsTheLookTargetToTheMiddle() {
        let camera = CameraViewpoint(
            position: Vec3(x: 0, y: 1, z: 5),
            target: Vec3(x: 0, y: 1, z: 0),
            fieldOfView: 90
        )
        let center = camera.region(of: camera.target, aspect: 1)
        XCTAssertEqual(center?.x ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(center?.y ?? -1, 0.5, accuracy: 1e-6)
        let right = camera.region(of: Vec3(x: 1, y: 1, z: 0), aspect: 1, spread: 0.45)
        XCTAssertEqual(right?.x ?? -1, 0.6, accuracy: 1e-6)
        XCTAssertEqual(right?.y ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertNil(camera.region(of: Vec3(x: 0, y: 1, z: 6), aspect: 1))
        XCTAssertNil(camera.region(of: camera.position, aspect: 1))
    }

    func testDefaultFramingLooksIntoTheRoom() {
        let room = SampleApartment.make().rooms[0]
        let camera = CameraViewpoint.framed(on: room.floorPlan)
        XCTAssertEqual(camera.fieldOfView, 48, accuracy: 1e-9)
        XCTAssertGreaterThan(camera.position.z, camera.target.z)
        XCTAssertGreaterThan(camera.position.y, camera.target.y)
        XCTAssertNotNil(camera.region(of: camera.target, aspect: PlateLayout.aspect))
    }

    func testPlateManifestListsLightsAndSkipsOtherPins() throws {
        let home = SampleApartment.make()
        let living = try XCTUnwrap(home.rooms.first { $0.id == SampleApartment.livingRoomID })
        let manifest = PlateCatalog.manifest(for: living, pins: home.pins(in: living.id))
        XCTAssertEqual(manifest.format, "home_scanner.plates")
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.day.base, "plates/day/base.jpg")
        XCTAssertEqual(manifest.night.base, "plates/night/base.jpg")
        XCTAssertEqual(manifest.day.lights.map(\.entityId), ["light.living_room"])
        XCTAssertEqual(manifest.night.lights.map(\.file), manifest.day.lights.map { light in
            light.file.replacingOccurrences(of: "/day/", with: "/night/")
        })
        XCTAssertNotNil(manifest.day.lights[0].region)
        let encoded = try manifest.encode()
        let decoded = try PlateManifest.decode(encoded)
        XCTAssertEqual(try PlateManifest.decode(try decoded.encode()), decoded)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"entity_id\" : \"light.living_room\""))
        XCTAssertFalse(text.contains("switch.living_room"))
    }

    func testPlateFilesRequireBothBasesAndRejectOddNames() throws {
        let home = SampleApartment.make()
        let kitchen = home.rooms[0]
        let pin = try XCTUnwrap(home.pins(in: kitchen.id).first { $0.kind == .light })
        XCTAssertTrue(PlatePaths.isUploadName(PlatePaths.manifest))
        XCTAssertTrue(PlatePaths.isUploadName(PlatePaths.base(.day)))
        XCTAssertTrue(PlatePaths.isUploadName(PlatePaths.light(pin.id, .night)))
        XCTAssertTrue(PlatePaths.isUploadName("layout.json"))
        XCTAssertFalse(PlatePaths.isUploadName("plates/../layout.json"))
        XCTAssertFalse(PlatePaths.isUploadName("plates/day/not-a-uuid.png"))
        XCTAssertFalse(PlatePaths.isUploadName("plates/day/base.png"))

        let images = [
            PlatePaths.base(.day): Data("day".utf8),
            PlatePaths.base(.night): Data("night".utf8),
            PlatePaths.light(pin.id, .day): Data("d".utf8),
            PlatePaths.light(pin.id, .night): Data("n".utf8)
        ]
        let files = try PlateCatalog.files(for: kitchen, pins: home.pins(in: kitchen.id), images: images)
        XCTAssertEqual(files.map(\.filename), [
            "plates/manifest.json",
            "plates/day/base.jpg",
            "plates/night/base.jpg",
            PlatePaths.light(pin.id, .day),
            PlatePaths.light(pin.id, .night)
        ])
        let manifest = try PlateManifest.decode(files[0].data)
        XCTAssertEqual(manifest.day.lights.count, 1)
        XCTAssertEqual(manifest.roomId, kitchen.id)

        var missingNight = images
        missingNight.removeValue(forKey: PlatePaths.base(.night))
        XCTAssertTrue(try PlateCatalog.files(for: kitchen, pins: home.pins(in: kitchen.id), images: missingNight).isEmpty)

        var package = try XCTUnwrap(try HomeExport.packages(for: home).first { $0.slug == kitchen.id.uuidString })
        XCTAssertTrue(package.plates.isEmpty)
        package = package.withPlates(files)
        XCTAssertEqual(package.files.prefix(3).map(\.filename), ["layout.json", "model.glb", "plates/manifest.json"])
        XCTAssertTrue(package.zipEntries.contains { $0.path == "home_scanner/\(kitchen.id.uuidString)/plates/day/base.jpg" })
    }

    func testNightPlatesFollowTheDaylightPhase() {
        XCTAssertEqual(PlateVariant.forPhase(.night), .night)
        XCTAssertEqual(PlateVariant.forPhase(.day), .day)
        XCTAssertEqual(PlateVariant.forPhase(.sunrise), .day)
        XCTAssertEqual(PlateVariant.forPhase(.sunset), .day)
        let night = DaylightMath.tint(sample: SunSample(state: "below_horizon"), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(night?.phase, .night)
        XCTAssertEqual(PlateVariant.forPhase(night?.phase ?? .day), .night)
    }

    private func room(_ name: String, floor: Int?) -> Room {
        Room(
            id: UUID(),
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            floorPlan: FloorPlan(),
            floor: floor
        )
    }
}
