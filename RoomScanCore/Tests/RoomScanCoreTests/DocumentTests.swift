import XCTest
@testable import RoomScanCore

final class DocumentTests: XCTestCase {
    func testSampleApartmentShape() {
        let home = SampleApartment.make()
        XCTAssertEqual(home.rooms.map(\.name), ["Kitchen", "Living room"])
        XCTAssertEqual(home.pins.map(\.entityId), [
            "light.kitchen",
            "light.living_room",
            "switch.living_room",
            "sensor.living_room_temperature"
        ])
        XCTAssertTrue(home.coordinatesAreUnified)
        XCTAssertEqual(home.structure?.usdz, "structure.usdz")
        let kitchen = FloorPlanGeometry.bounds(of: home.room(id: SampleApartment.kitchenID)!.floorPlan)
        XCTAssertEqual(kitchen.max.x, 3.6, accuracy: 1e-9)
        XCTAssertEqual(kitchen.max.z, 3.2, accuracy: 1e-9)
        for pin in home.pins(in: SampleApartment.kitchenID) {
            XCTAssertGreaterThanOrEqual(pin.position.x, kitchen.min.x - 0.05)
            XCTAssertLessThanOrEqual(pin.position.x, kitchen.max.x + 0.05)
        }
    }

    func testEncodeIsStableAndUsesSnakeCase() throws {
        let first = try HomeLayoutDocument(home: SampleApartment.make()).encode()
        let decoded = try HomeLayoutDocument.decode(first)
        let second = try HomeLayoutDocument(home: decoded.home).encode()
        XCTAssertEqual(first, second)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.contains("roomscan.home"))
        XCTAssertTrue(text.contains("\"entity_id\""))
        XCTAssertTrue(text.contains("\"floor_plan\""))
        XCTAssertTrue(text.contains("light.kitchen"))
        XCTAssertFalse(text.contains("entityId"))
        XCTAssertFalse(text.contains("floorPlan"))
        XCTAssertEqual(decoded.home.pins.count, 4)
        XCTAssertEqual(decoded.home.rooms[0].floorPlan.walls[0].height, 2.4, accuracy: 0.0001)
    }

    func testFixtureMatchesEncoder() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample-apartment.roomscan.json")
        let encoded = try HomeLayoutDocument(home: SampleApartment.make()).encode()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) || ProcessInfo.processInfo.environment["WRITE_FIXTURE"] == "1" {
            try encoded.write(to: url)
        }
        let existing = try Data(contentsOf: url)
        XCTAssertEqual(existing, encoded, "Sample JSON drifted. Re-run with WRITE_FIXTURE=1 if the change is intentional.")
        let documented = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/examples/sample-apartment.roomscan.json")
        let published = try Data(contentsOf: documented)
        XCTAssertEqual(published, encoded, "docs/examples/sample-apartment.roomscan.json is out of date.")
    }

    func testRejectsUnknownFormatAndVersion() throws {
        let encoded = try HomeLayoutDocument(home: SampleApartment.make()).encode()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["format"] = "other.home"
        let wrongFormat = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try HomeLayoutDocument.decode(wrongFormat)) { error in
            guard case HomeLayoutError.unknownFormat("other.home") = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }

        object["format"] = HomeLayoutDocument.formatIdentifier
        object["version"] = 2
        let wrongVersion = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try HomeLayoutDocument.decode(wrongVersion)) { error in
            guard case HomeLayoutError.unsupportedVersion(2) = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testPinEditsRoundTripThroughTheDocument() throws {
        var home = SampleApartment.make()
        let created = DevicePin.placed(in: SampleApartment.kitchenID, kind: .light, x: 1, z: 1, name: "Pendant")
        XCTAssertEqual(created.position.y, DeviceKind.light.defaultHeight, accuracy: 1e-9)
        home.upsertPin(created)
        var moved = created.moved(x: 2, z: 2.5)
        moved.entityId = "light.pendant"
        home.upsertPin(moved)
        XCTAssertEqual(home.pins(in: SampleApartment.kitchenID).count, 2)
        home.deleteRoom(id: SampleApartment.kitchenID)
        XCTAssertNil(home.room(id: SampleApartment.kitchenID))
        XCTAssertTrue(home.pins.allSatisfy { $0.roomId != SampleApartment.kitchenID })

        let decoded = try HomeLayoutDocument.decode(try HomeLayoutDocument(home: home).encode())
        XCTAssertEqual(decoded.home.rooms.map(\.name), ["Living room"])
        XCTAssertEqual(decoded.home.pins.count, 3)
    }

    func testEntityIDs() {
        XCTAssertEqual(EntityIDRules.check("  Light.Kitchen "), .valid("light.kitchen"))
        XCTAssertEqual(EntityIDRules.check("binary_sensor.front_door"), .valid("binary_sensor.front_door"))
        XCTAssertEqual(EntityIDRules.check("   "), .unset)
        XCTAssertEqual(EntityIDRules.check("light"), .invalid)
        XCTAssertEqual(EntityIDRules.check("light.kitchen.main"), .invalid)
        XCTAssertEqual(EntityIDRules.check("Light.Kitchen Lamp"), .invalid)
        XCTAssertTrue(EntityIDRules.isValid("switch.living_room"))
    }
}
