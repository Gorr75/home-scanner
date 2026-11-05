import XCTest
@testable import RoomScanCore

final class LightAndPlacementTests: XCTestCase {
    func testBrightnessAndRGBComeFromAttributes() throws {
        let data = Data(#"""
        {"entity_id":"light.kitchen","state":"on","attributes":{"brightness":128,"rgb_color":[255,128,0],"friendly_name":"Kitchen spots"}}
        """#.utf8)
        let record = try XCTUnwrap(try HomeAssistantDecoding.records(from: data).first)
        XCTAssertEqual(record.brightness ?? -1, 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(record.red ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(record.green ?? -1, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(record.blue ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(record.snapshot.displayState, "on 50%")
    }

    func testHueAndKelvinFillColourWhenRGBIsMissing() {
        let hue = LightColorMath.hsChannels([0, 100])
        XCTAssertEqual(hue?.0 ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(hue?.1 ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(hue?.2 ?? -1, 0, accuracy: 0.001)

        let warm = LightColorMath.rgb(kelvin: 2700)
        let daylight = LightColorMath.rgb(kelvin: 6500)
        XCTAssertGreaterThan(warm.0, warm.2)
        XCTAssertGreaterThan(daylight.2, warm.2)

        let attributes: [String: Any] = ["color_temp_kelvin": 2700, "brightness": 255]
        let appearance = LightColorMath.appearance(from: attributes)
        XCTAssertEqual(appearance.brightness ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(appearance.red ?? -1, warm.0, accuracy: 0.001)
        XCTAssertNotNil(appearance.green)
    }

    func testSocketEventCarriesLightColour() {
        let event = """
        {"type":"event","event":{"event_type":"state_changed","data":{"new_state":{"entity_id":"light.kitchen","state":"on","attributes":{"brightness":255,"hs_color":[120,100]}}}}}
        """
        guard case .stateChanged(let snapshot) = HomeAssistantSocketCodec.decode(event) else {
            return XCTFail("Expected a state change")
        }
        XCTAssertEqual(snapshot.state, "on")
        XCTAssertEqual(snapshot.brightness ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.green ?? -1, 1, accuracy: 0.02)
        XCTAssertLessThan(snapshot.red ?? 1, 0.05)
    }

    func testAreaNamesRejectJSONAndKeepBlankAreasOut() throws {
        let text = Data("light.kitchen\tKitchen\nswitch.porch\t\nnot an id\tHall\n".utf8)
        let names = try HomeAssistantDecoding.areaNames(from: text)
        XCTAssertEqual(names, ["light.kitchen": "Kitchen"])
        XCTAssertThrowsError(try HomeAssistantDecoding.areaNames(from: Data(#"{"message":"no"}"#.utf8)))
    }

    func testMockBrightnessSurvivesAToggle() async throws {
        let provider = MockHomeStateProvider()
        let on = try await provider.snapshot(for: "light.kitchen")
        XCTAssertEqual(on.displayState, "on 80%")
        XCTAssertEqual(on.red ?? -1, 1, accuracy: 0.001)
        let dim = try await provider.setBrightness(0.25, entityId: "light.kitchen")
        XCTAssertEqual(dim.displayState, "on 25%")
        XCTAssertEqual(dim.red ?? -1, 1, accuracy: 0.001)
        let off = try await provider.perform(.toggle, entityId: "light.kitchen")
        XCTAssertEqual(off.state, "off")
        XCTAssertEqual(off.displayState, "off")
        let again = try await provider.perform(.toggle, entityId: "light.kitchen")
        XCTAssertEqual(again.displayState, "on 25%")
        do {
            _ = try await provider.setBrightness(0.5, entityId: "switch.living_room")
            XCTFail("Expected a switch to refuse brightness")
        } catch HomeStateError.notToggleable {
            // expected
        }
    }

    func testAutoPlaceUsesAreaThenNameAndLeavesLinkedPins() {
        let kitchenID = UUID(uuidString: "6F0C2A10-4B1E-4E0A-9C11-000000000010")!
        let livingID = UUID(uuidString: "6F0C2A10-4B1E-4E0A-9C11-000000000020")!
        let rooms = [
            makeRoom("Kitchen", id: kitchenID, width: 4, depth: 3),
            makeRoom("Living room", id: livingID, width: 5, depth: 4, originX: 6)
        ]
        let existing = DevicePin(
            id: UUID(uuidString: "6F0C2A10-4B1E-4E0A-9C11-000000000031")!,
            roomId: kitchenID,
            name: "Already here",
            kind: .light,
            entityId: "light.kitchen",
            position: Vec3(x: 1, y: 2.35, z: 1)
        )
        let candidates = [
            PinAutoPlace.Candidate(entityId: "light.kitchen", friendlyName: "Kitchen spots", domain: "light", areaName: "Kitchen"),
            PinAutoPlace.Candidate(entityId: "light.spots", friendlyName: "Spots", domain: "light", areaName: "Kitchen"),
            PinAutoPlace.Candidate(entityId: "switch.living_room_lamp", friendlyName: "Lamp", domain: "switch", areaName: nil),
            PinAutoPlace.Candidate(entityId: "light.alpha_beta", friendlyName: "Alpha Beta", domain: "light", areaName: nil),
            PinAutoPlace.Candidate(entityId: "automation.morning", friendlyName: "Morning", domain: "automation", areaName: "Kitchen")
        ]
        let extraRooms = rooms + [
            makeRoom("Alpha", id: UUID(), width: 3, depth: 3, originX: 20),
            makeRoom("Beta", id: UUID(), width: 3, depth: 3, originX: 24)
        ]
        var ids = [
            UUID(uuidString: "6F0C2A10-4B1E-4E0A-9C11-000000000041")!,
            UUID(uuidString: "6F0C2A10-4B1E-4E0A-9C11-000000000042")!
        ]
        let placed = PinAutoPlace.suggestions(
            rooms: extraRooms,
            candidates: candidates,
            existingPins: [existing],
            makeID: { ids.removeFirst() }
        )
        XCTAssertEqual(placed.map(\.entityId), ["light.spots", "switch.living_room_lamp"])
        XCTAssertEqual(placed.map(\.roomId), [kitchenID, livingID])
        XCTAssertEqual(placed[0].name, "Spots")
        XCTAssertEqual(placed[0].kind, .light)
        XCTAssertEqual(placed[0].position.y, DeviceKind.light.defaultHeight, accuracy: 0.0001)
        XCTAssertNotEqual(placed[0].position.x, existing.position.x)
        XCTAssertGreaterThan(placed[0].position.x, 0)
        XCTAssertLessThan(placed[0].position.x, 4)
        let first = PinAutoPlace.position(slot: 0, plan: rooms[0].floorPlan, kind: .light)
        let second = PinAutoPlace.position(slot: 1, plan: rooms[0].floorPlan, kind: .light)
        XCTAssertNotEqual(first.x, second.x)
    }

    func testAutoPlacePrefersTheCloserName() {
        let kitchen = makeRoom("Kitchen", id: UUID(), width: 4, depth: 3)
        let kitchenette = makeRoom("Kitchenette", id: UUID(), width: 2, depth: 2, originX: 8)
        let hallway = makeRoom("Hallway", id: UUID(), width: 1.2, depth: 4, originX: 12)
        let hall = makeRoom("Hall", id: UUID(), width: 2, depth: 2, originX: 16)
        let placed = PinAutoPlace.suggestions(
            rooms: [kitchenette, kitchen, hall, hallway],
            candidates: [
                PinAutoPlace.Candidate(entityId: "light.kitchen_spots", friendlyName: "Kitchen spots", domain: "light", areaName: nil),
                PinAutoPlace.Candidate(entityId: "light.hallway", friendlyName: "Hallway spots", domain: "light", areaName: nil)
            ],
            existingPins: [],
            makeID: { UUID() }
        )
        XCTAssertEqual(placed.first { $0.entityId == "light.kitchen_spots" }?.roomId, kitchen.id)
        XCTAssertEqual(placed.first { $0.entityId == "light.hallway" }?.roomId, hallway.id)
    }

    private func makeRoom(_ name: String, id: UUID, width: Double, depth: Double, originX: Double = 0) -> Room {
        Room(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            floorPlan: FloorPlan(floors: [
                FloorPolygon(id: UUID(), corners: [
                    Vec3(x: originX, y: 0, z: 0),
                    Vec3(x: originX + width, y: 0, z: 0),
                    Vec3(x: originX + width, y: 0, z: depth),
                    Vec3(x: originX, y: 0, z: depth)
                ])
            ])
        )
    }
}
