import XCTest
@testable import RoomScanCore

final class SiteSurveyTests: XCTestCase {
    func testSWEREF99TMRoundTripAndCentralMeridian() {
        let origin = SWEREF99TM.toGrid(latitude: 0, longitude: 15)
        XCTAssertEqual(origin.easting, 500_000, accuracy: 0.01)
        XCTAssertEqual(origin.northing, 0, accuracy: 0.01)
        let onMeridian = SWEREF99TM.toGrid(latitude: 60, longitude: 15)
        XCTAssertEqual(onMeridian.easting, 500_000, accuracy: 0.05)
        XCTAssertGreaterThan(onMeridian.northing, 6_600_000)
        XCTAssertLessThan(onMeridian.northing, 6_700_000)
        let stockholm = SWEREF99TM.toGrid(latitude: 59.3293, longitude: 18.0686)
        XCTAssertGreaterThan(stockholm.easting, 650_000)
        XCTAssertLessThan(stockholm.easting, 700_000)
        let back = SWEREF99TM.toGeographic(easting: stockholm.easting, northing: stockholm.northing)
        XCTAssertEqual(back.latitude, 59.3293, accuracy: 1e-6)
        XCTAssertEqual(back.longitude, 18.0686, accuracy: 1e-6)
    }

    func testGeoTIFFSWEREFScaleAndWorldFile() throws {
        let tiff = TIFFFixture.geotiff(
            width: 100,
            height: 80,
            scale: 0.25,
            tieEasting: 500_000,
            tieNorthing: 6_600_000
        )
        let placement = try XCTUnwrap(RasterGeoreference.geotiff(data: tiff, pixelWidth: 100, pixelHeight: 80))
        XCTAssertEqual(placement.epsg, 3006)
        XCTAssertEqual(placement.widthMeters, 25, accuracy: 1e-6)
        XCTAssertEqual(placement.heightMeters, 20, accuracy: 1e-6)
        XCTAssertEqual(placement.yaw, 0, accuracy: 1e-6)
        XCTAssertEqual(placement.metersPerPixel, 0.25, accuracy: 1e-9)
        let center = SWEREF99TM.toGeographic(easting: 500_012.5, northing: 6_599_990)
        XCTAssertEqual(placement.georeference?.latitude ?? 0, center.latitude, accuracy: 1e-6)
        XCTAssertEqual(placement.georeference?.longitude ?? 0, center.longitude, accuracy: 1e-6)
        XCTAssertTrue(placement.summary.contains("3006"))

        let world = """
        0.5
        0
        0
        -0.5
        100.25
        200.25
        """
        let fromWorld = try XCTUnwrap(RasterGeoreference.worldFile(world, pixelWidth: 4, pixelHeight: 2))
        XCTAssertEqual(fromWorld.widthMeters, 2, accuracy: 1e-6)
        XCTAssertEqual(fromWorld.heightMeters, 1, accuracy: 1e-6)
        XCTAssertNil(fromWorld.georeference)
        XCTAssertEqual(fromWorld.yaw, 0, accuracy: 1e-6)

        let degrees = """
        0.0001
        0
        0
        -0.0001
        18.0
        59.0
        """
        let geographic = try XCTUnwrap(RasterGeoreference.worldFile(degrees, pixelWidth: 1000, pixelHeight: 500))
        XCTAssertEqual(geographic.georeference?.longitude ?? 0, 18.04995, accuracy: 1e-5)
        XCTAssertEqual(geographic.georeference?.latitude ?? 0, 58.97505, accuracy: 1e-5)
        XCTAssertGreaterThan(geographic.widthMeters, 500)
    }

    func testUncompressedTIFFPixels() throws {
        let data = TIFFFixture.rgb(width: 2, height: 1, pixels: [
            (255, 0, 0),
            (0, 255, 0)
        ])
        let decoded = try XCTUnwrap(UncompressedTIFF.decode(data))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 1)
        XCTAssertEqual(decoded.rgba[0], 255)
        XCTAssertEqual(decoded.rgba[4], 0)
        XCTAssertEqual(decoded.rgba[5], 255)
    }

    func testEXIFGPSAndGimbal() throws {
        let jpeg = EXIFFixture.jpeg(
            latitude: (59, 19, 45.48),
            longitude: (18, 4, 6.96),
            altitude: 32,
            direction: 184,
            focalLength: 6.72,
            focal35: 24
        )
        var tagged = jpeg
        tagged.append(contentsOf: Data("GimbalPitchDegree=\"-12.5\" RelativeAltitude=\"+8.20\" GimbalYawDegree=\"+20.0\"".utf8))
        let metadata = PhotoEXIF.read(tagged)
        XCTAssertEqual(metadata.latitude ?? 0, 59.3293, accuracy: 1e-4)
        XCTAssertEqual(metadata.longitude ?? 0, 18.0686, accuracy: 1e-4)
        XCTAssertEqual(metadata.altitudeMeters ?? 0, 32, accuracy: 1e-6)
        XCTAssertEqual(metadata.headingDegrees ?? 0, 184, accuracy: 1e-6)
        XCTAssertEqual(metadata.focalLengthMillimeters ?? 0, 6.72, accuracy: 1e-6)
        XCTAssertEqual(metadata.focalLength35mm ?? 0, 24, accuracy: 1e-6)
        XCTAssertEqual(metadata.pitchDegrees ?? 0, -12.5, accuracy: 1e-6)
        XCTAssertEqual(metadata.relativeAltitudeMeters ?? 0, 8.2, accuracy: 1e-6)
        XCTAssertEqual(metadata.cameraHeading ?? 0, 20, accuracy: 1e-6)
        XCTAssertTrue(metadata.hasLocation)
    }

    func testTwoPointScaleAndRoomAlignment() throws {
        let scaled = SiteSurvey.scale(
            pixelA: (0, 10),
            pixelB: (100, 10),
            pixelWidth: 200,
            pixelHeight: 100,
            distanceMeters: 20
        )
        XCTAssertEqual(scaled?.metersPerPixel ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(scaled?.widthMeters ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(scaled?.heightMeters ?? 0, 20, accuracy: 1e-9)

        let underlay = SiteUnderlay(pixelWidth: 100, pixelHeight: 50, widthMeters: 10, heightMeters: 5)
        let center = SiteSurvey.underlayPixel(world: .zero, underlay: underlay)
        XCTAssertEqual(center?.x ?? 0, 50, accuracy: 1e-6)
        XCTAssertEqual(center?.y ?? 0, 25, accuracy: 1e-6)
        let east = SiteSurvey.underlayPixel(world: Vec3(x: 5, y: 0, z: 0), underlay: underlay)
        XCTAssertEqual(east?.x ?? 0, 100, accuracy: 1e-6)
        let north = SiteSurvey.underlayPixel(world: Vec3(x: 0, y: 0, z: 2.5), underlay: underlay)
        XCTAssertEqual(north?.y ?? -1, 0, accuracy: 1e-6)

        let aligned = SiteSurvey.alignUnderlay(
            pixelA: (0, 25),
            pixelB: (100, 25),
            siteA: .zero,
            siteB: Vec3(x: 20, y: 0, z: 0),
            pixelWidth: 100,
            pixelHeight: 50
        )
        XCTAssertEqual(aligned?.widthMeters ?? 0, 20, accuracy: 1e-6)
        XCTAssertEqual(aligned?.center.x ?? -1, 10, accuracy: 1e-6)
        XCTAssertEqual(aligned?.yaw ?? 1, 0, accuracy: 1e-6)

        let placement = SiteSurvey.placementMatching(
            subject: .room(UUID()),
            localA: Vec3(x: 2, y: 0, z: 0),
            localB: Vec3(x: 4, y: 0, z: 0),
            siteA: Vec3(x: 10, y: 0, z: 7),
            siteB: Vec3(x: 10, y: 0, z: 5)
        )
        let world = SiteLayout.apply(Vec3(x: 2, y: 0, z: 0), placement: try XCTUnwrap(placement))
        XCTAssertEqual(world.x, 10, accuracy: 1e-6)
        XCTAssertEqual(world.z, 7, accuracy: 1e-6)
    }

    func testHomographyRoundTripAndFrontalSuggestion() throws {
        let corners = [
            UVPoint(u: 0.1, v: 0.8),
            UVPoint(u: 0.9, v: 0.75),
            UVPoint(u: 0.8, v: 0.15),
            UVPoint(u: 0.05, v: 0.2)
        ]
        let homography = try XCTUnwrap(PlaneHomography.wallToImage(corners: corners))
        let back = [
            homography.imagePoint(s: 0, t: 0),
            homography.imagePoint(s: 1, t: 0),
            homography.imagePoint(s: 1, t: 1),
            homography.imagePoint(s: 0, t: 1)
        ]
        for (got, want) in zip(back, corners) {
            XCTAssertEqual(got?.u ?? 0, want.u, accuracy: 1e-6)
            XCTAssertEqual(got?.v ?? 0, want.v, accuracy: 1e-6)
        }
        let full = try XCTUnwrap(PlaneHomography.wallToImage(corners: [
            UVPoint(u: 0, v: 1), UVPoint(u: 1, v: 1), UVPoint(u: 1, v: 0), UVPoint(u: 0, v: 0)
        ]))
        let middle = try XCTUnwrap(full.imagePoint(s: 0.5, t: 0.5))
        XCTAssertEqual(middle.u, 0.5, accuracy: 1e-6)
        XCTAssertEqual(middle.v, 0.5, accuracy: 1e-6)

        let wall = WallSegment(
            id: UUID(),
            start: Vec3(x: -2, y: 0, z: 0),
            end: Vec3(x: 2, y: 0, z: 0),
            height: 3,
            thickness: 0.2
        )
        let placement = SitePlacement(subject: .outdoorZone(UUID()), origin: .zero, yaw: 0)
        let camera = CameraPose(
            position: Vec3(x: 0, y: 1.5, z: -8),
            headingDegrees: 0,
            pitchDegrees: 0,
            focalLength35mm: 50,
            focalLengthMillimeters: nil,
            pixelWidth: 4000,
            pixelHeight: 3000
        )
        let suggestion = try XCTUnwrap(FacadeProjection.suggestCorners(wall: wall, placement: placement, camera: camera))
        XCTAssertTrue(suggestion.usedEquivalentFocalLength)
        XCTAssertEqual(suggestion.corners.count, 4)
        XCTAssertTrue(suggestion.corners.allSatisfy { $0.u > 0 && $0.u < 1 && $0.v > 0 && $0.v < 1 })
        XCTAssertLessThan(suggestion.corners[0].u, suggestion.corners[1].u)
        XCTAssertGreaterThan(suggestion.corners[0].v, suggestion.corners[3].v)
        let away = CameraPose(
            position: camera.position,
            headingDegrees: 180,
            pitchDegrees: 0,
            focalLength35mm: 50,
            focalLengthMillimeters: nil,
            pixelWidth: 4000,
            pixelHeight: 3000
        )
        XCTAssertNil(FacadeProjection.suggestCorners(wall: wall, placement: placement, camera: away))
    }

    func testShedSurveyFindsWallsAndGround() {
        let survey = MeshSurveyor.analyze(SampleSite.shedMesh())
        XCTAssertEqual(survey.ground.vertices.count, 4)
        XCTAssertEqual(survey.walls.count, 4)
        let lengths = survey.walls.map(\.length).sorted()
        XCTAssertEqual(lengths[0], 3, accuracy: 0.05)
        XCTAssertEqual(lengths[1], 3, accuracy: 0.05)
        XCTAssertEqual(lengths[2], 4, accuracy: 0.05)
        XCTAssertEqual(lengths[3], 4, accuracy: 0.05)
        XCTAssertEqual(survey.walls[0].height, 2.4, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(survey.buildingFootprint.count, 4)
        var area = 0.0
        let hull = survey.buildingFootprint
        for index in hull.indices {
            let next = hull[(index + 1) % hull.count]
            area += hull[index].x * next.z - next.x * hull[index].z
        }
        XCTAssertEqual(abs(area) / 2, 12, accuracy: 0.2)
    }

    func testWallTextureJSONMatchesIndoorAndOutdoor() throws {
        var home = SampleApartment.make()
        let texture = SurfaceTexture(
            image: "textures/kitchen-north.jpg",
            pixelWidth: 4032,
            pixelHeight: 3024,
            corners: [
                UVPoint(u: 0.12, v: 0.84),
                UVPoint(u: 0.80, v: 0.78),
                UVPoint(u: 0.74, v: 0.16),
                UVPoint(u: 0.10, v: 0.20)
            ]
        )
        home.rooms[0].floorPlan.walls[0].texture = texture
        XCTAssertEqual(HomeLayoutDocument.version(for: home), 2)
        let encoded = try HomeLayoutDocument(home: home).encode()
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"texture\""))
        XCTAssertTrue(text.contains("\"pixel_width\" : 4032"))
        XCTAssertTrue(text.contains("\"corners\""))
        XCTAssertFalse(text.contains("pixelWidth"))
        let decoded = try HomeLayoutDocument.decode(encoded)
        XCTAssertEqual(decoded.home.rooms[0].floorPlan.walls[0].texture?.corners.count, 4)
        XCTAssertEqual(decoded.home.rooms[0].floorPlan.walls[0].texture?.corners[0].u ?? 0, 0.12, accuracy: 1e-6)

        var outdoor = SampleApartment.make()
        var zone = SampleSite.shedZone()
        zone.walls[0].texture = texture
        outdoor.outdoorZones = [zone]
        let outdoorText = try XCTUnwrap(String(data: try HomeLayoutDocument(home: outdoor).encode(), encoding: .utf8))
        XCTAssertTrue(outdoorText.contains("\"walls\""))
        XCTAssertTrue(outdoorText.contains("\"texture\""))
        let outdoorDecoded = try HomeLayoutDocument.decode(try HomeLayoutDocument(home: outdoor).encode())
        XCTAssertEqual(outdoorDecoded.home.outdoorZones[0].walls[0].texture?.image, texture.image)
    }

    func testVersionTwoWithoutNewKeysStillDecodes() throws {
        var home = SampleApartment.make()
        home.outdoorZones = [SampleSite.shedZone()]
        home.site = Site(underlay: SiteUnderlay(
            image: "site/underlay.jpg",
            pixelWidth: 10,
            pixelHeight: 10,
            widthMeters: 40,
            heightMeters: 40
        ))
        let data = try HomeLayoutDocument(home: home).encode()
        let stripped = try stripNewOutdoorKeys(data)
        let decoded = try HomeLayoutDocument.decode(stripped)
        XCTAssertEqual(decoded.home.outdoorZones.count, 1)
        XCTAssertTrue(decoded.home.outdoorZones[0].walls.isEmpty)
        XCTAssertEqual(decoded.home.outdoorZones[0].groundVertexCount, 0)
        XCTAssertTrue(decoded.home.site?.overlays.isEmpty == true)
    }

    func testRepositoryKeepsWalkedMeshAndDroneOverlay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("site-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try HomeRepository(root: root)
        let home = try repo.createHome(named: "Lot")
        let far = TriangleMesh(
            vertices: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0), Vec3(x: 12, y: 1, z: 0)],
            faces: [MeshFace(a: 0, b: 1, c: 2)]
        )
        let saved = try repo.addOutdoorZone(homeId: home.id, name: "East wall", kind: .facade, mesh: far)
        XCTAssertEqual(saved.outdoorZones[0].meshVertexCount, 3)
        let shed = try repo.addOutdoorZone(homeId: home.id, name: "Shed", kind: .shed, mesh: SampleSite.shedMesh())
        let zone = try XCTUnwrap(shed.outdoorZones.last)
        XCTAssertEqual(zone.walls.count, 4)
        XCTAssertNotNil(zone.assets.terrain)
        let terrain = try Data(contentsOf: repo.fileURL(homeId: home.id, relative: try XCTUnwrap(zone.assets.terrain)))
        XCTAssertNotNil(MeshOBJ.decode(String(decoding: terrain, as: UTF8.self)))

        let withPhoto = try repo.importDroneOverlay(
            homeId: home.id,
            image: Data([0xFF, 0xD8, 0xFF]),
            fileExtension: "jpg",
            pixelWidth: 4000,
            pixelHeight: 3000,
            center: Vec3(x: 1, y: 8, z: 2),
            yaw: 0.4,
            widthMeters: 12,
            heightMeters: 9,
            georeference: Georeference(latitude: 59.33, longitude: 18.07, headingDegrees: 20),
            relativeAltitudeMeters: 8.2,
            focalLength35mm: 24,
            headingDegrees: 20,
            pitchDegrees: -12,
            note: "Facade photo."
        )
        XCTAssertEqual(withPhoto.site?.overlays.count, 1)
        let overlay = try XCTUnwrap(withPhoto.site?.overlays.first)
        let corners = [
            UVPoint(u: 0.1, v: 0.9),
            UVPoint(u: 0.9, v: 0.8),
            UVPoint(u: 0.85, v: 0.1),
            UVPoint(u: 0.08, v: 0.2)
        ]
        let textured = try repo.setFacadeTexture(
            homeId: home.id,
            zoneId: zone.id,
            wallId: zone.walls[0].id,
            imageRelativePath: overlay.image,
            pixelWidth: overlay.pixelWidth,
            pixelHeight: overlay.pixelHeight,
            corners: corners
        )
        XCTAssertEqual(textured.outdoorZones.last?.walls[0].texture?.corners.count, 4)
        let removed = try repo.deleteDroneOverlay(homeId: home.id, overlayId: overlay.id)
        XCTAssertTrue(removed.site?.overlays.isEmpty == true)
        let kept = try repo.fileURL(homeId: home.id, relative: overlay.image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testGPSOverlaySticksToTheUnderlay() {
        let underlay = SiteUnderlay(
            pixelWidth: 100,
            pixelHeight: 100,
            widthMeters: 40,
            heightMeters: 40,
            center: Vec3(x: 3, y: 0, z: -2),
            georeference: Georeference(latitude: 59.3293, longitude: 18.0686, headingDegrees: 0)
        )
        let overlay = DroneOverlay(
            image: "site/overlays/a.jpg",
            pixelWidth: 100,
            pixelHeight: 80,
            center: .zero,
            widthMeters: 8,
            heightMeters: 6,
            georeference: Georeference(latitude: 59.3293, longitude: 18.0696, headingDegrees: 10)
        )
        let moved = SiteUnderlay(
            pixelWidth: underlay.pixelWidth,
            pixelHeight: underlay.pixelHeight,
            widthMeters: underlay.widthMeters,
            heightMeters: underlay.heightMeters,
            center: Vec3(x: 10, y: 0, z: 4),
            georeference: underlay.georeference
        )
        let first = SiteGeodesy.overlayPosition(overlay, underlay: underlay)
        let second = SiteGeodesy.overlayPosition(overlay, underlay: moved)
        XCTAssertEqual(second.x - first.x, 7, accuracy: 1e-6)
        XCTAssertEqual(second.z - first.z, 6, accuracy: 1e-6)
        XCTAssertGreaterThan(first.x, underlay.center.x)
    }

    private func stripNewOutdoorKeys(_ data: Data) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var home = try XCTUnwrap(root["home"] as? [String: Any])
        var zones = try XCTUnwrap(home["outdoor_zones"] as? [[String: Any]])
        zones[0].removeValue(forKey: "walls")
        zones[0].removeValue(forKey: "building_footprint")
        zones[0].removeValue(forKey: "ground_vertex_count")
        if var assets = zones[0]["assets"] as? [String: Any] {
            assets.removeValue(forKey: "terrain")
            zones[0]["assets"] = assets
        }
        home["outdoor_zones"] = zones
        if var site = home["site"] as? [String: Any] {
            site.removeValue(forKey: "overlays")
            home["site"] = site
        }
        root["home"] = home
        return try JSONSerialization.data(withJSONObject: root)
    }
}

private enum TIFFFixture {
    static func geotiff(width: Int, height: Int, scale: Double, tieEasting: Double, tieNorthing: Double) -> Data {
        var keys: [UInt16] = [1, 1, 0, 3]
        keys += [1024, 0, 1, 1]
        keys += [1025, 0, 1, 1]
        keys += [3072, 0, 1, 3006]
        return classic(entries: [
            .short(256, [UInt16(width)]),
            .short(257, [UInt16(height)]),
            .double(33550, [scale, scale, 0]),
            .double(33922, [0, 0, 0, tieEasting, tieNorthing, 0]),
            .short(34735, keys)
        ])
    }

    static func rgb(width: Int, height: Int, pixels: [(UInt8, UInt8, UInt8)]) -> Data {
        var rgb = Data()
        for pixel in pixels {
            rgb.append(pixel.0)
            rgb.append(pixel.1)
            rgb.append(pixel.2)
        }
        let strip = DataBlob(rgb)
        return classic(entries: [
            .short(256, [UInt16(width)]),
            .short(257, [UInt16(height)]),
            .short(258, [8, 8, 8]),
            .short(259, [1]),
            .short(262, [2]),
            .long(273, [0]),
            .short(277, [3]),
            .long(278, [UInt32(height)]),
            .long(279, [UInt32(rgb.count)]),
            .short(284, [1])
        ], blobs: [strip]) { blobs in
            [273: blobs[0]]
        }
    }

    private struct DataBlob {
        var bytes: Data
        init(_ bytes: Data) { self.bytes = bytes }
    }

    private enum Entry {
        case short(UInt16, [UInt16])
        case long(UInt16, [UInt32])
        case double(UInt16, [Double])
    }

    private static func classic(
        entries: [Entry],
        blobs: [DataBlob] = [],
        patch: (([Int]) -> [UInt16: Int])? = nil
    ) -> Data {
        var external = Data()
        var prepared: [(tag: UInt16, type: UInt16, count: UInt32, inline: UInt32, external: Data?)] = []
        for entry in entries {
            switch entry {
            case .short(let tag, let values):
                if values.count == 1 {
                    prepared.append((tag, 3, 1, UInt32(values[0]), nil))
                } else {
                    var bytes = Data()
                    for value in values { bytes.append(u16(value)) }
                    prepared.append((tag, 3, UInt32(values.count), 0, bytes))
                }
            case .long(let tag, let values):
                if values.count == 1 {
                    prepared.append((tag, 4, 1, values[0], nil))
                } else {
                    var bytes = Data()
                    for value in values { bytes.append(u32(value)) }
                    prepared.append((tag, 4, UInt32(values.count), 0, bytes))
                }
            case .double(let tag, let values):
                var bytes = Data()
                for value in values { bytes.append(double(value)) }
                prepared.append((tag, 12, UInt32(values.count), 0, bytes))
            }
        }
        let ifdCount = 2 + prepared.count * 12 + 4
        var cursor = 8 + ifdCount
        var blobOffsets: [Int] = []
        for blob in blobs {
            blobOffsets.append(cursor)
            cursor += blob.bytes.count
        }
        var valueOffsets: [Int] = []
        for item in prepared {
            if let bytes = item.external {
                valueOffsets.append(cursor)
                external.append(bytes)
                cursor += bytes.count
            } else {
                valueOffsets.append(0)
            }
        }
        var data = Data()
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        data.append(u32(8))
        data.append(u16(UInt16(prepared.count)))
        for (index, item) in prepared.enumerated() {
            data.append(u16(item.tag))
            data.append(u16(item.type))
            data.append(u32(item.count))
            if item.external != nil {
                data.append(u32(UInt32(valueOffsets[index])))
            } else {
                data.append(u32(item.inline))
            }
        }
        data.append(u32(0))
        for blob in blobs {
            data.append(blob.bytes)
        }
        data.append(external)
        if let patch {
            for (tag, offset) in patch(blobOffsets) {
                guard let index = prepared.firstIndex(where: { $0.tag == tag }) else { continue }
                let field = 8 + 2 + index * 12 + 8
                let bytes = u32(UInt32(offset))
                data.replaceSubrange(field..<(field + 4), with: bytes)
            }
        }
        return data
    }

    private static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private static func double(_ value: Double) -> Data {
        var bits = value.bitPattern.littleEndian
        return Data(bytes: &bits, count: 8)
    }
}

private enum EXIFFixture {
    static func jpeg(
        latitude: (Int, Int, Double),
        longitude: (Int, Int, Double),
        altitude: Double,
        direction: Double,
        focalLength: Double,
        focal35: Int
    ) -> Data {
        var tiff = Data([0x49, 0x49, 0x2A, 0x00])
        tiff.append(u32(8))
        let ifd0 = 8
        tiff.append(u16(2))
        let gpsPointerField = tiff.count
        tiff.append(entry(tag: 0x8825, type: 4, count: 1, value: 0))
        let exifPointerField = tiff.count
        tiff.append(entry(tag: 0x8769, type: 4, count: 1, value: 0))
        tiff.append(u32(0))

        let gpsAt = tiff.count
        let lat = rationals([Double(latitude.0), Double(latitude.1), latitude.2])
        let lon = rationals([Double(longitude.0), Double(longitude.1), longitude.2])
        let alt = rational(altitude)
        let dir = rational(direction)
        tiff.append(u16(7))
        let latRef = tiff.count
        tiff.append(entry(tag: 1, type: 2, count: 2, value: ascii("N")))
        let latField = tiff.count
        tiff.append(entry(tag: 2, type: 5, count: 3, value: 0))
        let lonRef = tiff.count
        tiff.append(entry(tag: 3, type: 2, count: 2, value: ascii("E")))
        let lonField = tiff.count
        tiff.append(entry(tag: 4, type: 5, count: 3, value: 0))
        let altRef = tiff.count
        tiff.append(entry(tag: 5, type: 1, count: 1, value: 0))
        let altField = tiff.count
        tiff.append(entry(tag: 6, type: 5, count: 1, value: 0))
        let dirField = tiff.count
        tiff.append(entry(tag: 17, type: 5, count: 1, value: 0))
        tiff.append(u32(0))
        _ = (latRef, lonRef, altRef)

        func appendOffset(field: Int, payload: Data) {
            let offset = tiff.count
            poke(u32(UInt32(offset)), at: field + 8, into: &tiff)
            tiff.append(payload)
        }
        appendOffset(field: latField, payload: lat)
        appendOffset(field: lonField, payload: lon)
        appendOffset(field: altField, payload: alt)
        appendOffset(field: dirField, payload: dir)

        let exifAt = tiff.count
        let focal = rational(focalLength)
        tiff.append(u16(2))
        let focalField = tiff.count
        tiff.append(entry(tag: 0x920A, type: 5, count: 1, value: 0))
        tiff.append(entry(tag: 0xA405, type: 3, count: 1, value: UInt32(focal35)))
        tiff.append(u32(0))
        appendOffset(field: focalField, payload: focal)

        poke(u32(UInt32(gpsAt)), at: gpsPointerField + 8, into: &tiff)
        poke(u32(UInt32(exifAt)), at: exifPointerField + 8, into: &tiff)
        _ = ifd0

        var jpeg = Data([0xFF, 0xD8])
        var app1 = Data("Exif\0\0".utf8)
        app1.append(tiff)
        jpeg.append(0xFF)
        jpeg.append(0xE1)
        jpeg.append(u16BE(UInt16(app1.count + 2)))
        jpeg.append(app1)
        jpeg.append(contentsOf: [0xFF, 0xD9])
        return jpeg
    }

    private static func entry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        var data = Data()
        data.append(u16(tag))
        data.append(u16(type))
        data.append(u32(count))
        data.append(u32(value))
        return data
    }

    private static func ascii(_ text: String) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in text.utf8.enumerated() where index < 4 {
            value |= UInt32(byte) << (8 * index)
        }
        return value
    }

    private static func rational(_ value: Double) -> Data {
        var data = Data()
        data.append(u32(UInt32((value * 100).rounded())))
        data.append(u32(100))
        return data
    }

    private static func rationals(_ values: [Double]) -> Data {
        var data = Data()
        for value in values {
            data.append(rational(value))
        }
        return data
    }

    private static func poke(_ bytes: Data, at offset: Int, into data: inout Data) {
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func u16BE(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
