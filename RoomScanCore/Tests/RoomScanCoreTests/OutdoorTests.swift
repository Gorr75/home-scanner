import XCTest
@testable import RoomScanCore

final class OutdoorTests: XCTestCase {
    func testClipDropsVerticesBeyondFiveMeters() {
        let mesh = TriangleMesh(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 6, y: 0, z: 0)
            ],
            faces: [
                MeshFace(a: 0, b: 1, c: 2),
                MeshFace(a: 0, b: 1, c: 3)
            ]
        )
        let clipped = MeshRange.clipped(mesh)
        XCTAssertEqual(clipped.vertices.count, 3)
        XCTAssertEqual(clipped.faces.count, 1)
        XCTAssertFalse(clipped.vertices.contains { $0.x > 5 })
    }

    func testOBJRoundTripAndFootprint() {
        let mesh = SampleSite.shedMesh()
        let decoded = MeshOBJ.decode(MeshOBJ.encode(mesh))
        XCTAssertEqual(decoded?.vertices.count, mesh.vertices.count)
        XCTAssertEqual(decoded?.faces.count, mesh.faces.count)
        let shape = MeshRange.footprint(mesh)
        XCTAssertEqual(shape.corners[0].x, 0, accuracy: 1e-9)
        XCTAssertEqual(shape.corners[1].x, 4, accuracy: 1e-9)
        XCTAssertEqual(shape.corners[2].z, 3, accuracy: 1e-9)
        XCTAssertEqual(shape.height, 2.4, accuracy: 1e-9)
        let groundReach = mesh.vertices.map { Vec3(x: $0.x, y: 0, z: $0.z).length }.max() ?? 0
        XCTAssertLessThanOrEqual(groundReach, MeshRange.lidarMeters)
    }

    func testPlacementRotatesARoomOntoTheSite() {
        let room = SampleApartment.make().room(id: SampleApartment.kitchenID)!
        let placement = SitePlacement(subject: .room(room.id), origin: Vec3(x: 10, y: 0, z: 5), yaw: .pi / 2)
        let local = Vec3(x: 2, y: 0, z: 0)
        let world = SiteLayout.apply(local, placement: placement)
        XCTAssertEqual(world.x, 10, accuracy: 1e-9)
        XCTAssertEqual(world.z, 7, accuracy: 1e-9)
        let footprint = SiteLayout.roomFootprint(room)
        XCTAssertEqual(footprint.count, 4)
    }

    func testUnderlayScaleAndVersionTwoExport() throws {
        let underlay = SiteUnderlay(
            image: "site/underlay.jpg",
            pixelWidth: 1000,
            pixelHeight: 500,
            widthMeters: 40,
            heightMeters: 20,
            georeference: Georeference(latitude: 59.3293, longitude: 18.0686, headingDegrees: 12)
        )
        XCTAssertEqual(underlay.metersPerPixel, 0.04, accuracy: 1e-9)
        var home = SampleApartment.make()
        home.outdoorZones = [SampleSite.shedZone()]
        home.site = Site(
            underlay: underlay,
            placements: SiteLayout.defaultPlacements(rooms: home.rooms, zones: home.outdoorZones)
        )
        let document = HomeLayoutDocument(home: home)
        XCTAssertEqual(document.version, 2)
        let decoded = try HomeLayoutDocument.decode(try document.encode())
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.home.outdoorZones.map(\.name), ["Shed"])
        XCTAssertEqual(decoded.home.site?.underlay?.georeference?.latitude ?? 0, 59.3293, accuracy: 1e-6)
        XCTAssertEqual(decoded.home.site?.placements.count, 3)
        let text = try XCTUnwrap(String(data: try document.encode(), encoding: .utf8))
        XCTAssertTrue(text.contains("\"outdoor_zones\""))
        XCTAssertTrue(text.contains("\"outdoor_zone\""))
        XCTAssertTrue(text.contains("\"heading_degrees\""))
        XCTAssertFalse(text.contains("outdoorZones"))
    }

    func testVersionOneSampleStillOmitsOutdoorKeys() throws {
        let data = try HomeLayoutDocument(home: SampleApartment.make()).encode()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"version\" : 1"))
        XCTAssertFalse(text.contains("outdoor"))
        let decoded = try HomeLayoutDocument.decode(data)
        XCTAssertTrue(decoded.home.outdoorZones.isEmpty)
        XCTAssertNil(decoded.home.site)
    }

    func testRepositoryStoresMeshAndUnderlay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outdoor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try HomeRepository(root: root)
        let home = try repo.createHome(named: "Yard")
        let saved = try repo.addOutdoorZone(homeId: home.id, name: "North facade", kind: .facade, mesh: SampleSite.shedMesh())
        let zone = try XCTUnwrap(saved.outdoorZones.first)
        XCTAssertEqual(zone.kind, .facade)
        let obj = try Data(contentsOf: repo.fileURL(homeId: home.id, relative: try XCTUnwrap(zone.assets.obj)))
        XCTAssertNotNil(MeshOBJ.decode(String(decoding: obj, as: UTF8.self)))
        let withPhoto = try repo.importUnderlay(
            homeId: home.id,
            image: Data([0xFF, 0xD8, 0xFF]),
            pixelWidth: 200,
            pixelHeight: 100,
            widthMeters: 20,
            georeference: Georeference(latitude: 1, longitude: 2, headingDegrees: 90)
        )
        XCTAssertEqual(withPhoto.site?.underlay?.heightMeters ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(HomeLayoutDocument.version(for: withPhoto), 2)
        let placed = try repo.updateSite(homeId: home.id) { site in
            site.placements = [SitePlacement(subject: .outdoorZone(zone.id), origin: Vec3(x: 3, y: 0, z: 4), yaw: 0)]
        }
        XCTAssertEqual(placed.site?.placements.count, 1)
        let removed = try repo.deleteOutdoorZone(homeId: home.id, zoneId: zone.id)
        XCTAssertTrue(removed.outdoorZones.isEmpty)
        XCTAssertTrue(removed.site?.placements.isEmpty == true)
    }
}
