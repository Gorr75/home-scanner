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

    func testAPIStatusURLPreservesTrailingSlash() throws {
        XCTAssertEqual(HomeAssistantAPI.root, "/api/")
        let local = HomeAssistantEndpoint(
            baseURL: try XCTUnwrap(URL(string: "http://192.168.0.2:8123")),
            token: "token"
        )
        let status = try XCTUnwrap(local.url(path: HomeAssistantAPI.root))
        XCTAssertEqual(status.absoluteString, "http://192.168.0.2:8123/api/")
        XCTAssertTrue(status.hasDirectoryPath)
        let config = try XCTUnwrap(local.url(path: HomeAssistantAPI.config))
        XCTAssertEqual(config.absoluteString, "http://192.168.0.2:8123/api/config")
        let health = try XCTUnwrap(local.url(path: HomeAssistantAPI.integrationHealth))
        XCTAssertEqual(health.absoluteString, "http://192.168.0.2:8123/api/home_scanner/health")

        let nabu = HomeAssistantEndpoint(
            baseURL: try XCTUnwrap(URL(string: "https://example.ui.nabu.casa")),
            token: "token"
        )
        let remote = try XCTUnwrap(nabu.url(path: HomeAssistantAPI.root))
        XCTAssertEqual(remote.absoluteString, "https://example.ui.nabu.casa/api/")
    }

    func testProbeParsesServerAndUploadEndpoint() async throws {
        let transport = ScriptedTransport { request in
            switch Self.serverPath(request) {
            case "/api/", "/api":
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
        assertProbeRequestedAPIRoot(transport)
        let authorization = try XCTUnwrap(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("Bearer "))
        XCTAssertFalse(authorization.contains("\n"))
    }

    func testProbeReportsMissingIntegrationWithoutFailingTheToken() async throws {
        let transport = ScriptedTransport { request in
            let path = Self.serverPath(request)
            if path == "/api/" || path == "/api" {
                return HTTPResponse(statusCode: 200, data: Data(#"{"message":"API running."}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, data: Data(#"{"message":"not found"}"#.utf8))
        }
        let probe = try await client(transport).probe()
        XCTAssertFalse(probe.uploadEndpointInstalled)
        XCTAssertEqual(probe.message, "API running.")
        assertProbeRequestedAPIRoot(transport)
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
            let path = Self.serverPath(request)
            if path == "/api/" || path == "/api" {
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
            assertProbeRequestedAPIRoot(transport)
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

    func testBrightnessPosts255ScaleAndAreasComeFromTheTemplate() async throws {
        let transport = ScriptedTransport { request in
            let path = Self.serverPath(request)
            if path == "/api/states/light.kitchen" {
                return HTTPResponse(statusCode: 200, data: Data(#"""
                {"entity_id":"light.kitchen","state":"on","attributes":{"brightness":255,"rgb_color":[255,0,0]}}
                """#.utf8))
            }
            if path == "/api/services/light/turn_on" {
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["brightness"] as? Int, 128)
                return HTTPResponse(statusCode: 200, data: Data(#"""
                [{"entity_id":"light.kitchen","state":"on","attributes":{"brightness":128,"rgb_color":[255,0,0]}}]
                """#.utf8))
            }
            if path == "/api/services/light/turn_off" {
                return HTTPResponse(statusCode: 200, data: Data(#"""
                [{"entity_id":"light.kitchen","state":"off","attributes":{"friendly_name":"Kitchen"}}]
                """#.utf8))
            }
            if path == "/api/states/sensor.living_room_temperature" {
                return HTTPResponse(statusCode: 200, data: Data(#"""
                {"entity_id":"sensor.living_room_temperature","state":"21.5","attributes":{"unit_of_measurement":"°C"}}
                """#.utf8))
            }
            if path == "/api/template" {
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertTrue((json["template"] as? String)?.contains("area_name") == true)
                return HTTPResponse(
                    statusCode: 200,
                    data: Data("light.kitchen\tKitchen\nlight.hall\t\n".utf8)
                )
            }
            return HTTPResponse(statusCode: 404, data: Data())
        }
        let client = client(transport)
        let dimmed = try await client.setBrightness(0.5, entityId: "light.kitchen")
        XCTAssertEqual(dimmed.state, "on")
        XCTAssertEqual(dimmed.brightness ?? -1, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(dimmed.red ?? -1, 1, accuracy: 0.001)
        let off = try await client.setBrightness(0, entityId: "light.kitchen")
        XCTAssertEqual(off.state, "off")
        let areas = try await client.areaNamesByEntity()
        XCTAssertEqual(areas, ["light.kitchen": "Kitchen"])
        do {
            _ = try await client.setBrightness(0.4, entityId: "sensor.living_room_temperature")
            XCTFail("Expected a sensor to refuse brightness")
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

    private func assertProbeRequestedAPIRoot(
        _ transport: ScriptedTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            transport.requests.first?.url?.absoluteString,
            "http://homeassistant.local:8123/api/",
            file: file,
            line: line
        )
    }

    /// Path the scripted server matches. `URL.path` strips a trailing slash, so
    /// `http://host/api/` and `http://host/api` both report `/api`. The status
    /// route is recovered from the absolute URL.
    private static func serverPath(_ request: URLRequest) -> String {
        guard let url = request.url else { return "" }
        if url.absoluteString.hasSuffix("/api/") {
            return "/api/"
        }
        return url.path
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
