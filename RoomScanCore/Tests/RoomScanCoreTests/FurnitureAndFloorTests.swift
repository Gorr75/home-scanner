import XCTest
@testable import RoomScanCore

final class FurnitureAndFloorTests: XCTestCase {
    func testCatalogCoversTheRoadmapPiecesAndFitsItsBoxes() {
        let ids = Set(FurnitureCatalog.all.map(\.id))
        for id in ["sofa", "dining_chair", "armchair", "dining_table", "coffee_table", "bed", "bookshelf", "low_shelf", "floor_lamp", "table_lamp", "plant", "large_plant", "rug", "television", "wardrobe"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        for item in FurnitureCatalog.all {
            XCTAssertTrue(FurnitureCatalog.partsFit(item), "\(item.id) sticks out of its nominal box")
        }
        XCTAssertEqual(FurnitureCatalog.match(for: "sofa")?.id, "sofa")
        XCTAssertEqual(FurnitureCatalog.match(for: "chair")?.id, "dining_chair")
        XCTAssertEqual(FurnitureCatalog.match(for: "table")?.id, "dining_table")
        XCTAssertEqual(FurnitureCatalog.match(for: "bed")?.id, "bed")
        XCTAssertEqual(FurnitureCatalog.match(for: "television")?.id, "television")
        XCTAssertEqual(FurnitureCatalog.match(for: "storage")?.id, "wardrobe")
        XCTAssertNil(FurnitureCatalog.match(for: "refrigerator"))
    }

    func testPlacementRotatesScalesAndReplacesAScanBox() throws {
        let sofa = try XCTUnwrap(FurnitureCatalog.item(id: "sofa"))
        var home = SampleApartment.make()
        let scan = try XCTUnwrap(
            home.room(id: SampleApartment.livingRoomID)?.floorPlan.objects.first { $0.category == "sofa" }
        )
        let placed = try XCTUnwrap(home.replaceObject(id: scan.id, in: SampleApartment.livingRoomID, with: sofa.id))
        XCTAssertEqual(placed.replacesObjectId, scan.id)
        XCTAssertEqual(placed.position.y, scan.center.y - scan.dimensions.y / 2, accuracy: 1e-9)
        XCTAssertEqual(placed.scale.x, scan.dimensions.x / sofa.nominalSize.x, accuracy: 1e-6)
        XCTAssertEqual(placed.yaw, scan.yaw, accuracy: 1e-9)
        let room = try XCTUnwrap(home.room(id: SampleApartment.livingRoomID))
        XCTAssertFalse(room.visibleObjects.contains { $0.id == scan.id })
        XCTAssertEqual(room.visibleObjects.count, room.floorPlan.objects.count - 1)

        home.rotateFurniture(id: placed.id, by: .pi / 2)
        home.scaleFurniture(id: placed.id, by: 100)
        let grown = try XCTUnwrap(home.furnitureItem(id: placed.id)?.item)
        XCTAssertEqual(grown.scale.x, FurnitureCatalog.maximumScale, accuracy: 1e-9)
        home.scaleFurniture(id: grown.id, by: 0.0001)
        let shrunk = try XCTUnwrap(home.furnitureItem(id: grown.id)?.item)
        XCTAssertEqual(shrunk.scale.x, FurnitureCatalog.minimumScale, accuracy: 1e-9)

        let loose = PlacedFurniture.placed(catalogId: "plant", x: 1.2, z: 1.4)
        XCTAssertNotNil(home.upsertFurniture(loose, in: SampleApartment.kitchenID))
        home.moveFurniture(id: loose.id, x: 2, z: 2)
        let moved = try XCTUnwrap(home.furnitureItem(id: loose.id)?.item)
        XCTAssertEqual(moved.position.x, 2, accuracy: 1e-9)
        XCTAssertTrue(FurnitureGeometry.contains(x: 2, z: 2, placement: moved))
        XCTAssertFalse(FurnitureGeometry.contains(x: 8, z: 8, placement: moved))

        let turned = PlacedFurniture(
            id: UUID(),
            catalogId: "rug",
            position: Vec3(x: 0, y: 0, z: 0),
            yaw: .pi / 2
        )
        let footprint = FurnitureGeometry.footprint(of: turned)
        let spanX = (footprint.map(\.x).max() ?? 0) - (footprint.map(\.x).min() ?? 0)
        let spanZ = (footprint.map(\.z).max() ?? 0) - (footprint.map(\.z).min() ?? 0)
        XCTAssertEqual(spanX, 1.40, accuracy: 1e-6)
        XCTAssertEqual(spanZ, 2.00, accuracy: 1e-6)
    }

    func testLayoutKeepsLevelFloorNameAndFurnitureOptional() throws {
        let bare = try HomeLayoutDocument(home: SampleApartment.make()).encode()
        let bareText = try XCTUnwrap(String(data: bare, encoding: .utf8))
        XCTAssertFalse(bareText.contains("\"furniture\""))
        XCTAssertFalse(bareText.contains("\"level\""))
        XCTAssertFalse(bareText.contains("\"floor_name\""))
        XCTAssertFalse(bareText.contains("\"flooring\""))
        let decodedBare = try HomeLayoutDocument.decode(bare)
        XCTAssertNil(decodedBare.home.rooms[0].level)
        XCTAssertEqual(decodedBare.home.rooms[0].resolvedLevel, 0)
        XCTAssertTrue(decodedBare.home.rooms[0].placedFurniture.isEmpty)

        var home = SampleApartment.make()
        home.rooms[0].level = 0
        home.rooms[0].floorName = "Ground"
        home.rooms[0].flooring = .tile
        home.rooms[1].level = 1
        home.rooms[1].floorName = "Upstairs"
        let plant = PlacedFurniture.placed(catalogId: "plant", x: 6, z: 2)
        home.upsertFurniture(plant, in: SampleApartment.livingRoomID)
        let encoded = try HomeLayoutDocument(home: home).encode()
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"level\" : 0"))
        XCTAssertTrue(text.contains("\"level\" : 1"))
        XCTAssertTrue(text.contains("\"floor_name\" : \"Ground\""))
        XCTAssertTrue(text.contains("\"floor_name\" : \"Upstairs\""))
        XCTAssertTrue(text.contains("\"flooring\" : \"tile\""))
        XCTAssertTrue(text.contains("\"catalog_id\" : \"plant\""))
        let decoded = try HomeLayoutDocument.decode(encoded)
        XCTAssertEqual(decoded.home.room(id: SampleApartment.kitchenID)?.flooring, .tile)
        XCTAssertEqual(decoded.home.room(id: SampleApartment.livingRoomID)?.resolvedLevel, 1)
        XCTAssertEqual(decoded.home.furnitureItem(id: plant.id)?.item.catalogId, "plant")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bare) as? [String: Any])
        var homeObject = try XCTUnwrap(object["home"] as? [String: Any])
        var rooms = try XCTUnwrap(homeObject["rooms"] as? [[String: Any]])
        rooms[0].removeValue(forKey: "level")
        homeObject["rooms"] = rooms
        object["home"] = homeObject
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try HomeLayoutDocument.decode(legacy).home.rooms[0].resolvedLevel, 0)
    }

    func testCopiedFloorAndFootprint() throws {
        var home = SampleApartment.make()
        let originalWalls = Set(home.rooms.flatMap { $0.floorPlan.walls.map(\.id) })
        var sequence = 0
        let copies = home.addCopiedFloor(now: SampleApartment.createdAt) {
            sequence += 1
            return SampleApartment.id(0x80 + sequence)
        }
        XCTAssertEqual(copies.map(\.resolvedLevel), [1, 1])
        XCTAssertEqual(copies.map(\.floorName), ["Upstairs", "Upstairs"])
        XCTAssertEqual(copies.map(\.name), ["Kitchen", "Living room"])
        XCTAssertTrue(copies.allSatisfy { $0.floorPlan.objects.isEmpty && $0.placedFurniture.isEmpty })
        XCTAssertEqual(copies[0].floorPlan.walls.count, home.room(id: SampleApartment.kitchenID)?.floorPlan.walls.count)
        let copiedIDs = Set(copies.flatMap { $0.floorPlan.walls.map(\.id) })
        XCTAssertTrue(copiedIDs.isDisjoint(with: originalWalls))
        XCTAssertEqual(home.pins.count, 4)
        let summaries = FloorStack.summaries(in: home)
        XCTAssertEqual(summaries.map(\.level), [0, 1])
        XCTAssertEqual(summaries.map(\.name), ["Ground", "Upstairs"])

        var fresh = SampleApartment.make()
        let footprint = try XCTUnwrap(fresh.addFootprintFloor(now: SampleApartment.createdAt) {
            sequence += 1
            return SampleApartment.id(0x90 + sequence)
        })
        XCTAssertEqual(footprint.resolvedLevel, 1)
        XCTAssertEqual(footprint.floorPlan.walls.count, 4)
        let corners = try XCTUnwrap(footprint.floorPlan.floors.first?.corners)
        let minX = try XCTUnwrap(corners.map(\.x).min())
        let maxX = try XCTUnwrap(corners.map(\.x).max())
        let minZ = try XCTUnwrap(corners.map(\.z).min())
        let maxZ = try XCTUnwrap(corners.map(\.z).max())
        XCTAssertEqual(minX, 0, accuracy: 1e-9)
        XCTAssertEqual(maxX, 8.8, accuracy: 1e-9)
        XCTAssertEqual(minZ, 0, accuracy: 1e-9)
        XCTAssertEqual(maxZ, 4, accuracy: 1e-9)
        fresh.renameFloor(level: 1, to: "  Loft ")
        XCTAssertEqual(fresh.room(id: footprint.id)?.floorName, "Loft")
        XCTAssertEqual(FloorStack.summaries(in: fresh)[1].name, "Loft")
    }

    func testExportIncludesFurnitureAndStacksLevels() throws {
        var home = SampleApartment.make()
        let scan = try XCTUnwrap(
            home.room(id: SampleApartment.livingRoomID)?.floorPlan.objects.first { $0.category == "sofa" }
        )
        home.replaceObject(id: scan.id, in: SampleApartment.livingRoomID, with: "sofa")
        home.rooms[1].level = 1
        home.rooms[1].floorName = "Upstairs"
        home.rooms[0].flooring = .oak
        let packages = try HomeExport.packages(for: home, usdzFiles: ["structure.usdz": Data("scan-usdz".utf8)])
        let homePackage = try XCTUnwrap(packages.first)
        let layout = try XCTUnwrap(String(data: homePackage.layoutJSON, encoding: .utf8))
        XCTAssertTrue(layout.contains("\"catalog_id\" : \"sofa\""))
        XCTAssertTrue(layout.contains("\"level\" : 1"))
        XCTAssertTrue(layout.contains("\"flooring\" : \"oak\""))
        let glbJSON = try glTFJSON(homePackage.modelGLB)
        let materials = try XCTUnwrap(glbJSON["materials"] as? [[String: Any]])
        let names = materials.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains { $0.contains("furniture_sofa") })
        let maxY = try accessorMaxY(glbJSON)
        XCTAssertGreaterThan(maxY, 3)

        let usdz = try XCTUnwrap(homePackage.modelUSDZ)
        XCTAssertEqual(usdz.prefix(2), Data("PK".utf8))
        XCTAssertNotEqual(usdz, Data("scan-usdz".utf8))
        XCTAssertTrue(usdz.contains(Data("furniture_sofa".utf8)))
        XCTAssertTrue(usdz.contains(Data("UsdPreviewSurface".utf8)))

        let living = try XCTUnwrap(packages.first { $0.slug == SampleApartment.livingRoomID.uuidString })
        XCTAssertTrue(living.modelGLB.contains(Data("furniture_sofa".utf8)))
        XCTAssertTrue((living.modelUSDZ ?? Data()).contains(Data("furniture_sofa".utf8)))
    }

    func testRescanKeepsFreeFurnitureAndDropsMissingReplacements() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try HomeRepository(root: root)
        var home = try repo.installSampleApartment(usdz: Data("model".utf8))
        let scan = try XCTUnwrap(home.room(id: SampleApartment.livingRoomID)?.floorPlan.objects.first)
        home.replaceObject(id: scan.id, in: SampleApartment.livingRoomID, with: "sofa")
        let plant = PlacedFurniture.placed(catalogId: "plant", x: 7, z: 2)
        home.upsertFurniture(plant, in: SampleApartment.livingRoomID)
        _ = try repo.save(home)
        var plan = home.room(id: SampleApartment.livingRoomID)!.floorPlan
        plan.objects = []
        let replaced = try repo.replaceRoom(
            homeId: home.id,
            roomId: SampleApartment.livingRoomID,
            floorPlan: plan,
            capturedJSON: Data("{}".utf8),
            usdz: Data("new".utf8)
        )
        let furniture = try XCTUnwrap(replaced.room(id: SampleApartment.livingRoomID)?.placedFurniture)
        XCTAssertEqual(furniture.map(\.catalogId), ["plant"])
    }

    private func glTFJSON(_ data: Data) throws -> [String: Any] {
        let jsonLength = Int(readUInt32(data, offset: 12))
        let json = data.subdata(in: 20..<(20 + jsonLength))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private func accessorMaxY(_ json: [String: Any]) throws -> Double {
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        let heights = accessors.compactMap { accessor -> Double? in
            guard accessor["type"] as? String == "VEC3", let max = accessor["max"] as? [Any], max.count > 1 else {
                return nil
            }
            return (max[1] as? NSNumber)?.doubleValue
        }
        return heights.max() ?? 0
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
}
