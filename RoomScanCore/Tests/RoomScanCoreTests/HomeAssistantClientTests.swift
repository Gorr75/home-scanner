import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RoomScanCore

final class HomeAssistantClientTests: XCTestCase {
    func testNormalizeAcceptsHostPortAndStripsAPIPath() {
        let url = HomeAssistantURL.normalize("homeassistant.local:8123/api/")
        XCTAssertEqual(url?.absoluteString, "http://homeassistant.local:8123")
        let secure = HomeAssistantURL.normalize("HTTPS://HA.local/lovelace/0")
        XCTAssertEqual(secure?.scheme, "https")
        XCTAssertEqual(secure?.host, "ha.local")
        XCTAssertEqual(secure?.path, "")
        XCTAssertNil(HomeAssistantURL.normalize("   "))
        XCTAssertNil(HomeAssistantURL.normalize("ftp://files.local"))
        let stripped = HomeAssistantURL.normalize("http://user:secret@192.168.1.20:8123")
        XCTAssertEqual(stripped?.host, "192.168.1.20")
        XCTAssertEqual(stripped?.port, 8123)
        XCTAssertNil(stripped?.user)
    }

    func testEntitySearchRanksFriendlyNamesAndLimitsTheEmptyQuery() {
        let records = [
            HAEntityRecord(entityId: "light.kitchen", state: "on", domain: "light", friendlyName: "Kitchen spots"),
            HAEntityRecord(entityId: "sensor.kitchen_temperature", state: "21.5", domain: "sensor", friendlyName: "Kitchen", unit: "°C"),
            HAEntityRecord(entityId: "automation.morning", state: "on", domain: "automation", friendlyName: "Morning"),
            HAEntityRecord(entityId: "switch.kitchen_hood", state: "off", domain: "switch", friendlyName: "Hood")
        ]
        let kitchen = EntitySearch.rank(records, query: "kitch")
        XCTAssertEqual(kitchen.map(\.entityId), [
            "light.kitchen",
            "sensor.kitchen_temperature",
            "switch.kitchen_hood"
        ])
        let empty = EntitySearch.rank(records, query: "  ")
        XCTAssertFalse(empty.contains { $0.domain == "automation" })
        XCTAssertEqual(DeviceKind.forHomeAssistantDomain("binary_sensor"), .sensor)
        XCTAssertEqual(DeviceKind.forHomeAssistantDomain("media_player"), .mediaPlayer)
    }

    func testProbeParsesServerAndUploadEndpoint() async throws {
        let transport = ScriptedTransport { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api", "/api/":
                return HTTPResponse(statusCode: 200, data: Data(#"{"message":"API running."}"#.utf8))
            case "/api/config":
                return HTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"location_name":"House","version":"2026.4.0"}"#.utf8)
                )
            case "/api/home_scanner/health":
                return HTTPResponse(statusCode: 200, data: Data(#"{"ok":true}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, data: Data())
            }
        }
        let client = client(transport)
        let probe = try await client.probe()
        XCTAssertEqual(probe.locationName, "House")
        XCTAssertEqual(probe.version, "2026.4.0")
        XCTAssertTrue(probe.uploadEndpointInstalled)
        let authorization = try XCTUnwrap(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("Bearer "))
        XCTAssertFalse(authorization.contains("\n"))
    }

    func testProbeReportsMissingIntegrationWithoutFailingTheToken() async throws {
        let transport = ScriptedTransport { request in
            let path = request.url?.path ?? ""
            if path == "/api" || path == "/api/" {
                return HTTPResponse(statusCode: 200, data: Data(#"{"message":"API running."}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, data: Data(#"{"message":"not found"}"#.utf8))
        }
        let probe = try await client(transport).probe()
        XCTAssertFalse(probe.uploadEndpointInstalled)
        XCTAssertEqual(probe.message, "API running.")
    }

    func testUnauthorizedAndEntityRoundTrip() async throws {
        let states = Data(#"""
        [
          {
            "entity_id": "light.kitchen",
            "state": "on",
            "attributes": {"friendly_name": "Kitchen spots"}
          },
          {
            "entity_id": "sensor.living_room_temperature",
            "state": "21.5",
            "attributes": {"friendly_name": "Living room", "unit_of_measurement": "°C"}
          }
        ]
        """#.utf8)
        let transport = ScriptedTransport { request in
            let path = request.url?.path ?? ""
            if path == "/api" || path == "/api/" {
                return HTTPResponse(statusCode: 401, data: Data(#"{"message":"Unauthorized"}"#.utf8))
            }
            if path == "/api/states" {
                return HTTPResponse(statusCode: 200, data: states)
            }
            if path == "/api/states/light.kitchen" {
                return HTTPResponse(statusCode: 200, data: Data(#"""
                {"entity_id":"light.kitchen","state":"off","attributes":{"friendly_name":"Kitchen spots"}}
                """#.utf8))
            }
            if path == "/api/states/sensor.living_room_temperature" {
                return HTTPResponse(statusCode: 200, data: Data(#"""
                {"entity_id":"sensor.living_room_temperature","state":"21.5","attributes":{"unit_of_measurement":"°C"}}
                """#.utf8))
            }
            if path == "/api/services/light/toggle" {
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["entity_id"] as? String, "light.kitchen")
                return HTTPResponse(statusCode: 200, data: Data(#"""
                [{"entity_id":"light.kitchen","state":"off","attributes":{"friendly_name":"Kitchen spots"}}]
                """#.utf8))
            }
            return HTTPResponse(statusCode: 500, data: Data())
        }
        let client = client(transport)
        do {
            _ = try await client.probe()
            XCTFail("Expected the token to be rejected")
        } catch HomeAssistantClientError.unauthorized {
            // expected
        }

        let listed = try await client.listEntities()
        XCTAssertEqual(listed.map(\.friendlyName), ["Kitchen spots", "Living room"])
        let temperature = try XCTUnwrap(listed.last)
        XCTAssertEqual(temperature.snapshot.displayState, "21.5 °C")
        XCTAssertEqual(temperature.suggestedKind, .sensor)

        let snapshots = try await client.snapshots(for: ["Light.Kitchen", "sensor.missing"])
        XCTAssertEqual(snapshots.map(\.state), ["on", "unavailable"])

        let toggled = try await client.perform(.toggle, entityId: "light.kitchen")
        XCTAssertEqual(toggled.state, "off")

        do {
            _ = try await client.perform(.toggle, entityId: "sensor.living_room_temperature")
            XCTFail("Expected a sensor toggle to fail")
        } catch HomeStateError.notToggleable {
            // expected
        }
    }

    private func client(_ transport: ScriptedTransport) -> HomeAssistantClient {
        HomeAssistantClient(
            endpoint: HomeAssistantEndpoint(
                baseURL: URL(string: "http://homeassistant.local:8123")!,
                token: "test-token"
            ),
            transport: transport
        )
    }
}

final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    let handler: (URLRequest) throws -> HTTPResponse

    init(handler: @escaping (URLRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}
