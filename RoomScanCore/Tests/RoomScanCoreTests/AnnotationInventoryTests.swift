import XCTest
@testable import RoomScanCore

final class AnnotationInventoryTests: XCTestCase {
    func testOlderLayoutOmitsNotesAndInventory() throws {
        let decoded = try HomeLayoutDocument.decode(try HomeLayoutDocument(home: SampleApartment.make()).encode())
        XCTAssertTrue(decoded.home.rooms.allSatisfy { $0.annotations == nil && $0.inventory == nil })
        XCTAssertTrue(decoded.home.rooms.allSatisfy { $0.roomAnnotations.isEmpty && $0.inventoryItems.isEmpty })
        let text = try XCTUnwrap(String(data: try HomeLayoutDocument(home: decoded.home).encode(), encoding: .utf8))
        XCTAssertFalse(text.contains("\"annotations\""))
        XCTAssertFalse(text.contains("\"inventory\""))
    }

    func testAnnotationAndInventoryRoundTrip() throws {
        var home = SampleApartment.make()
        let noteID = SampleApartment.id(0x81)
        let itemID = SampleApartment.id(0x82)
        let bought = ISO8601DateFormatter().date(from: "2024-03-02T00:00:00Z")!
        var note = RoomAnnotation.note(at: Vec3(x: 1.2, y: 1.4, z: 0.4), text: "Fuse box", id: noteID)
        note.photo = MediaPaths.annotationPhoto(noteID)
        note.audio = MediaPaths.annotationAudio(noteID)
        note.transcript = "Säkringsskåpet sitter bakom dörren"
        let measurement = RoomAnnotation.measurement(
            from: Vec3(x: 0, y: 0, z: 0),
            to: Vec3(x: 3, y: 0, z: 0),
            id: SampleApartment.id(0x83)
        )
        home.upsertAnnotation(note, in: SampleApartment.kitchenID)
        home.upsertAnnotation(measurement, in: SampleApartment.kitchenID)
        home.upsertInventory(
            InventoryItem(
                id: itemID,
                name: "Fridge, left",
                category: "refrigerator",
                brand: "Bosch",
                model: "KGN",
                purchaseDate: bought,
                price: 899.5,
                serial: "SN-1",
                photos: [MediaPaths.inventoryPhoto(itemID, index: 1)],
                receipt: MediaPaths.inventoryReceipt(itemID),
                notes: "Warranty until 2027",
                position: Vec3(x: 0.4, y: 1, z: 0.4),
                objectId: SampleApartment.id(0x17),
                source: .detected
            ),
            in: SampleApartment.kitchenID
        )

        let encoded = try HomeLayoutDocument(home: home).encode()
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"annotations\""))
        XCTAssertTrue(text.contains("\"inventory\""))
        XCTAssertTrue(text.contains("notes/\(noteID.uuidString).jpg"))
        XCTAssertTrue(text.contains("notes/\(noteID.uuidString).m4a"))
        XCTAssertTrue(text.contains("\"transcript\""))
        XCTAssertTrue(text.contains("\"kind\" : \"measurement\""))
        XCTAssertTrue(text.contains("\"brand\" : \"Bosch\""))
        XCTAssertTrue(text.contains("\"model\" : \"KGN\""))
        XCTAssertTrue(text.contains("\"purchase_date\""))
        XCTAssertTrue(text.contains("inventory/\(itemID.uuidString)-receipt.jpg"))
        XCTAssertFalse(text.contains("entityId"))

        let decoded = try HomeLayoutDocument.decode(encoded).home
        let notes = decoded.annotations(in: SampleApartment.kitchenID)
        XCTAssertEqual(notes.count, 2)
        let restored = try XCTUnwrap(notes.first { $0.id == noteID })
        XCTAssertEqual(restored.text, "Fuse box")
        XCTAssertEqual(restored.photo, MediaPaths.annotationPhoto(noteID))
        XCTAssertEqual(restored.audio, MediaPaths.annotationAudio(noteID))
        XCTAssertEqual(restored.transcript, note.transcript)
        XCTAssertEqual(restored.kind, .note)
        let span = try XCTUnwrap(notes.first { $0.kind == .measurement }?.measurement)
        XCTAssertEqual(span.distance, 3, accuracy: 1e-9)
        let item = try XCTUnwrap(decoded.inventory(in: SampleApartment.kitchenID).first)
        XCTAssertEqual(item.brand, "Bosch")
        XCTAssertEqual(item.model, "KGN")
        XCTAssertEqual(item.price ?? 0, 899.5, accuracy: 0.001)
        XCTAssertEqual(item.serial, "SN-1")
        XCTAssertEqual(item.receipt, MediaPaths.inventoryReceipt(itemID))
        XCTAssertEqual(item.position?.x ?? 0, 0.4, accuracy: 1e-4)
        XCTAssertEqual(item.source, .detected)

        let bare = #"{"id":"\#(noteID.uuidString)","created_at":"2024-03-02T00:00:00Z","text":"Leak","position":{"x":1,"y":0,"z":1}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decodedBare = try decoder.decode(RoomAnnotation.self, from: Data(bare.utf8))
        XCTAssertEqual(decodedBare.kind, .note)
        XCTAssertEqual(decodedBare.text, "Leak")
        XCTAssertNil(decodedBare.photo)
    }

    func testAlignmentMovesAnnotationsAndInventoryWithTheRoom() {
        let rigid = RigidYaw(yaw: .pi / 2, translation: Vec3(x: 3, y: 0.2, z: -1))
        let note = RoomAnnotation.measurement(
            from: Vec3(x: 1, y: 0, z: 0.4),
            to: Vec3(x: 1, y: 2.4, z: 0.4),
            text: "Height"
        )
        let moved = note.transformed(by: rigid)
        XCTAssertEqual(moved.position.x, rigid.applying(note.position).x, accuracy: 1e-9)
        XCTAssertEqual(moved.position.z, rigid.applying(note.position).z, accuracy: 1e-9)
        let span = try! XCTUnwrap(moved.measurement)
        XCTAssertEqual(span.start.x, rigid.applying(note.measurement!.start).x, accuracy: 1e-9)
        XCTAssertEqual(span.end.y, rigid.applying(note.measurement!.end).y, accuracy: 1e-9)
        XCTAssertEqual(span.distance, note.measurement!.distance, accuracy: 1e-9)
        let restored = moved.transformed(by: rigid.inverse())
        XCTAssertEqual(restored.position.x, note.position.x, accuracy: 1e-6)
        XCTAssertEqual(restored.measurement?.end.z ?? 0, note.measurement!.end.z, accuracy: 1e-6)

        let item = InventoryItem(
            id: UUID(),
            name: "Sofa",
            category: "sofa",
            position: Vec3(x: 1, y: 0, z: 0.4),
            furnitureId: UUID(),
            source: .catalog
        )
        let movedItem = item.transformed(by: rigid)
        XCTAssertEqual(movedItem.position?.x ?? 0, rigid.applying(item.position!).x, accuracy: 1e-9)
        XCTAssertEqual(movedItem.furnitureId, item.furnitureId)
        let back = movedItem.transformed(by: rigid.inverse())
        XCTAssertEqual(back.position?.z ?? 0, item.position!.z, accuracy: 1e-6)
    }

    func testSnapUsesWallCornersAndEdges() {
        let plan = FloorPlan(walls: [
            WallSegment(
                id: UUID(),
                start: Vec3(x: 0, y: 0, z: 0),
                end: Vec3(x: 4, y: 0, z: 0),
                height: 2.4,
                thickness: 0.12
            )
        ])
        let corner = MeasureSnap.point(Vec3(x: 0.08, y: 0.05, z: 0.12), in: plan)
        XCTAssertEqual(corner.x, 0, accuracy: 1e-9)
        XCTAssertEqual(corner.z, 0, accuracy: 1e-9)
        let edge = MeasureSnap.point(Vec3(x: 2, y: 0.2, z: 0.15), in: plan)
        XCTAssertEqual(edge.x, 2, accuracy: 1e-6)
        XCTAssertEqual(edge.y, 0, accuracy: 1e-6)
        XCTAssertEqual(edge.z, 0, accuracy: 1e-6)
        let top = MeasureSnap.point(Vec3(x: 0.05, y: 2.3, z: 0.1), in: plan)
        XCTAssertEqual(top.y, 2.4, accuracy: 1e-6)
        let free = MeasureSnap.point(Vec3(x: 2, y: 1, z: 2), in: plan)
        XCTAssertEqual(free.z, 2, accuracy: 1e-9)
        XCTAssertEqual(MeasureSnap.label(from: .zero, to: Vec3(x: 3, y: 0, z: 0)), "3.00 m")
    }

    func testScanNoteLandsOnTheWallTheCameraFaces() {
        let plan = FloorPlan(
            walls: [
                WallSegment(id: UUID(), start: Vec3(x: 0, y: 0, z: 0), end: Vec3(x: 4, y: 0, z: 0), height: 2.4, thickness: 0.1)
            ],
            floors: [
                FloorPolygon(id: UUID(), corners: [
                    Vec3(x: 0, y: 0, z: 0), Vec3(x: 4, y: 0, z: 0), Vec3(x: 4, y: 0, z: 3), Vec3(x: 0, y: 0, z: 3)
                ])
            ],
            objects: [
                PlacedObject(
                    id: UUID(),
                    category: "sofa",
                    center: Vec3(x: 2, y: 0.4, z: 2),
                    dimensions: Vec3(x: 1.6, y: 0.8, z: 0.8),
                    yaw: 0
                )
            ]
        )
        var columns = Array(repeating: 0.0, count: 16)
        columns[0] = 1
        columns[5] = 1
        columns[10] = 1
        columns[12] = 2
        columns[13] = 1.5
        columns[14] = 1.2
        columns[15] = 1
        let hit = ScanNotePlacement.position(columns: columns, plan: plan)
        XCTAssertEqual(hit?.x ?? -1, 2, accuracy: 1e-6)
        XCTAssertEqual(hit?.y ?? -1, 1.5, accuracy: 1e-6)
        XCTAssertEqual(hit?.z ?? -1, 0, accuracy: 1e-6)

        columns[13] = 0.4
        columns[14] = 3
        let sofa = ScanNotePlacement.position(columns: columns, plan: plan)
        XCTAssertEqual(sofa?.x ?? 0, 2, accuracy: 0.05)
        XCTAssertEqual(sofa?.z ?? 0, 2.4, accuracy: 0.05)
        XCTAssertNil(ScanNotePlacement.position(columns: [1, 0, 0], plan: plan))
    }

    func testInventoryMergeSkipsReplacedObjectsAndDuplicates() {
        let objectID = UUID()
        let furnitureID = UUID()
        let plan = FloorPlan(objects: [
            PlacedObject(id: objectID, category: "sofa", center: Vec3(x: 1, y: 0.4, z: 1), dimensions: Vec3(x: 2, y: 0.8, z: 0.9), yaw: 0),
            PlacedObject(id: UUID(), category: "table", center: Vec3(x: 2, y: 0.4, z: 1), dimensions: Vec3(x: 1, y: 0.75, z: 0.6), yaw: 0)
        ])
        var room = Room(id: UUID(), name: "Living room", createdAt: Date(), floorPlan: plan)
        room.placedFurniture = [
            PlacedFurniture(id: furnitureID, catalogId: "sofa", position: Vec3(x: 1, y: 0, z: 1), yaw: 0, replacesObjectId: objectID)
        ]
        let manual = InventoryItem(id: UUID(), name: "Lamp", category: "lighting", source: .manual)
        let first = InventoryCatalog.merge(existing: [manual], room: room)
        XCTAssertEqual(first.count, 3)
        XCTAssertTrue(first.contains { $0.objectId != nil && $0.source == .detected && $0.name == "Table" })
        XCTAssertFalse(first.contains { $0.objectId == objectID })
        XCTAssertTrue(first.contains { $0.furnitureId == furnitureID && $0.source == .catalog })
        let again = InventoryCatalog.merge(existing: first, room: room)
        XCTAssertEqual(again.count, first.count)
    }

    func testInventoryTotalsAndCSV() throws {
        var home = SampleApartment.make()
        home.upsertInventory(
            InventoryItem(id: UUID(), name: "Oven, main", category: "oven", brand: "A", price: 10.126, serial: "A,1", notes: "keep", source: .manual),
            in: SampleApartment.kitchenID
        )
        home.upsertInventory(
            InventoryItem(id: UUID(), name: "Chair", category: "chair", price: 5, source: .detected),
            in: SampleApartment.livingRoomID
        )
        let totals = InventoryMath.homeTotal(in: home)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.pricedCount, 2)
        XCTAssertEqual(totals.totalPrice, 15.13, accuracy: 0.001)
        let rooms = InventoryMath.rooms(in: home)
        XCTAssertEqual(rooms[0].totals.count, 1)
        XCTAssertEqual(rooms[1].totals.count, 1)
        let csv = InventoryMath.csv(for: home)
        XCTAssertTrue(csv.hasPrefix("room,name,category,"))
        XCTAssertTrue(csv.contains("\"Oven, main\""))
        XCTAssertTrue(csv.contains("\"A,1\""))
        XCTAssertTrue(csv.contains("10.13"))
        XCTAssertEqual(InventoryMath.matching("chair", in: home).count, 1)
        XCTAssertEqual(InventoryMath.matching("Living", in: home).count, 1)
        XCTAssertTrue(InventoryMath.matching("missing", in: home).isEmpty)

        let encoded = try HomeLayoutDocument(home: home).encode()
        let decoded = try HomeLayoutDocument.decode(encoded).home
        XCTAssertEqual(InventoryMath.homeTotal(in: decoded).totalPrice, 15.13, accuracy: 0.001)
    }

    func testSplitMovesNotesAndInventoryWithTheHalf() throws {
        let kitchen = SampleApartment.make().room(id: SampleApartment.kitchenID)!
        let keptNote = RoomAnnotation.note(at: Vec3(x: 0.4, y: 1, z: 1.2), text: "West")
        let movedNote = RoomAnnotation.measurement(
            from: Vec3(x: 3.0, y: 0, z: 0.4),
            to: Vec3(x: 3.0, y: 2.4, z: 0.4),
            text: "East wall"
        )
        var room = kitchen
        room.roomAnnotations = [keptNote, movedNote]
        room.inventoryItems = [
            InventoryItem(id: UUID(), name: "West shelf", category: "storage", position: Vec3(x: 0.5, y: 1, z: 1), source: .manual),
            InventoryItem(id: UUID(), name: "East lamp", category: "lighting", position: Vec3(x: 3.1, y: 1.2, z: 1.5), source: .manual)
        ]
        let parts = try XCTUnwrap(PlanEditor.splitRoom(room, newID: UUID(), name: "Kitchen 2", createdAt: room.createdAt))
        XCTAssertEqual(parts.kept.roomAnnotations.map(\.text), ["West"])
        XCTAssertEqual(parts.created.roomAnnotations.map(\.text), ["East wall"])
        XCTAssertEqual(parts.created.roomAnnotations.first?.measurement?.distance ?? 0, 2.4, accuracy: 1e-6)
        XCTAssertEqual(parts.kept.inventoryItems.map(\.name), ["West shelf"])
        XCTAssertEqual(parts.created.inventoryItems.map(\.name), ["East lamp"])
    }

    func testExportCarriesNoteAndInventoryFiles() throws {
        var home = SampleApartment.make()
        let noteID = UUID()
        var note = RoomAnnotation.note(at: Vec3(x: 1, y: 1, z: 1), text: "Leak", id: noteID)
        note.photo = MediaPaths.annotationPhoto(noteID)
        note.audio = "../secrets.m4a"
        home.upsertAnnotation(note, in: SampleApartment.kitchenID)
        let photo = Data("jpeg".utf8)
        let audio = Data("audio".utf8)
        let packages = try HomeExport.packages(for: home, media: [
            note.photo!: photo,
            note.audio!: audio
        ])
        let kitchen = try XCTUnwrap(packages.first { $0.slug == SampleApartment.kitchenID.uuidString })
        XCTAssertEqual(kitchen.media.map(\.filename), [note.photo!])
        XCTAssertEqual(kitchen.media.first?.data, photo)
        XCTAssertEqual(kitchen.media.first?.mimeType, "image/jpeg")
        XCTAssertTrue(kitchen.files.contains { $0.filename == note.photo })
        let homePackage = try XCTUnwrap(packages.first)
        XCTAssertEqual(Array(homePackage.files.prefix(2).map(\.filename)), ["layout.json", "model.glb"])
        XCTAssertTrue(homePackage.files.contains { $0.filename == note.photo })
        let layout = try XCTUnwrap(String(data: kitchen.layoutJSON, encoding: .utf8))
        XCTAssertTrue(layout.contains("Leak"))
        XCTAssertTrue(layout.contains(note.photo!))
    }
}
