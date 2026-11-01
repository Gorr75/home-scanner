import XCTest
@testable import RoomScanCore

final class HomeStateTests: XCTestCase {
    func testMockToggleAndSensor() async throws {
        let provider = MockHomeStateProvider()
        let on = try await provider.snapshot(for: "light.kitchen")
        XCTAssertEqual(on.state, "on")
        XCTAssertTrue(on.isToggleable)
        let off = try await provider.perform(.toggle, entityId: "Light.Kitchen")
        XCTAssertEqual(off.state, "off")
        let again = try await provider.perform(.turnOn, entityId: "light.kitchen")
        XCTAssertEqual(again.state, "on")

        let temperature = try await provider.snapshot(for: "sensor.living_room_temperature")
        XCTAssertEqual(temperature.displayState, "21.5 °C")
        XCTAssertFalse(temperature.isToggleable)
        do {
            _ = try await provider.perform(.toggle, entityId: temperature.entityId)
            XCTFail("Expected the sensor toggle to fail")
        } catch let error as HomeStateError {
            XCTAssertEqual(error, .notToggleable(temperature.entityId))
        }
    }

    func testMockFillsInUnknownEntitiesAndRejectsGarbage() async throws {
        let provider = MockHomeStateProvider(seed: [])
        let created = try await provider.snapshot(for: "light.new_lamp")
        XCTAssertEqual(created.state, "off")
        XCTAssertEqual(created.domain, "light")
        let sensor = try await provider.snapshot(for: "sensor.hallway")
        XCTAssertEqual(sensor.state, "unknown")
        do {
            _ = try await provider.snapshot(for: "not an id")
            XCTFail("Expected an invalid id to fail")
        } catch HomeStateError.invalidEntityId {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testProviderSnapshotsAndUnconfiguredClient() async throws {
        let provider: any HomeStateProvider = MockHomeStateProvider()
        let snapshots = try await provider.snapshots(for: ["light.living_room", "switch.living_room"])
        XCTAssertEqual(snapshots.map(\.state), ["off", "on"])

        let client = UnconfiguredHomeAssistantClient(baseURL: URL(string: "http://homeassistant.local:8123"))
        do {
            _ = try await client.snapshot(for: "light.kitchen")
            XCTFail("Expected the unconfigured client to refuse")
        } catch HomeStateError.notConfigured {
            XCTAssertEqual(client.tokenAccount, UnconfiguredHomeAssistantClient.tokenAccount)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}
