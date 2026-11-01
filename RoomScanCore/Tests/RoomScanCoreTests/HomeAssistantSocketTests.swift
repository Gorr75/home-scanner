import XCTest
@testable import RoomScanCore

final class HomeAssistantSocketTests: XCTestCase {
    func testAuthAndSubscribeMessages() throws {
        let auth = HomeAssistantSocketCodec.authMessage(token: "test-token")
        let authJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(auth.utf8)) as? [String: Any])
        XCTAssertEqual(authJSON["type"] as? String, "auth")
        XCTAssertEqual(authJSON["access_token"] as? String, "test-token")

        let subscribe = HomeAssistantSocketCodec.subscribeStateChanges(id: 1)
        let subscribeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(subscribe.utf8)) as? [String: Any])
        XCTAssertEqual(subscribeJSON["type"] as? String, "subscribe_events")
        XCTAssertEqual(subscribeJSON["event_type"] as? String, "state_changed")
        XCTAssertEqual(subscribeJSON["id"] as? Int, 1)
    }

    func testDecodeAuthAndStateChanged() {
        XCTAssertEqual(
            HomeAssistantSocketCodec.decode(#"{"type":"auth_required","ha_version":"2026.4.0"}"#),
            .authRequired
        )
        XCTAssertEqual(
            HomeAssistantSocketCodec.decode(#"{"type":"auth_ok"}"#),
            .authOk
        )
        XCTAssertEqual(
            HomeAssistantSocketCodec.decode(#"{"type":"auth_invalid","message":"invalid"}"#),
            .authInvalid("invalid")
        )
        XCTAssertEqual(
            HomeAssistantSocketCodec.decode(#"{"id":1,"type":"result","success":true}"#),
            .result(id: 1, success: true)
        )

        let event = """
        {"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"sensor.living_room_temperature","new_state":{"entity_id":"sensor.living_room_temperature","state":"22.0","attributes":{"friendly_name":"Living room","unit_of_measurement":"°C"}}}}}
        """
        guard case .stateChanged(let snapshot) = HomeAssistantSocketCodec.decode(event) else {
            return XCTFail("Expected a state change")
        }
        XCTAssertEqual(snapshot.entityId, "sensor.living_room_temperature")
        XCTAssertEqual(snapshot.displayState, "22.0 °C")
        XCTAssertEqual(snapshot.domain, "sensor")

        let removed = #"{"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"light.kitchen","new_state":null}}}"#
        XCTAssertEqual(HomeAssistantSocketCodec.decode(removed), .ignored)
        XCTAssertEqual(HomeAssistantSocketCodec.decode("not-json"), .ignored)
    }

    func testWebSocketURLUsesWSSForHTTPS() throws {
        let secure = HomeAssistantEndpoint(
            baseURL: try XCTUnwrap(URL(string: "https://home.example")),
            token: "token"
        )
        XCTAssertEqual(secure.webSocketURL?.scheme, "wss")
        XCTAssertEqual(secure.webSocketURL?.path, "/api/websocket")
        let local = HomeAssistantEndpoint(
            baseURL: try XCTUnwrap(URL(string: "http://homeassistant.local:8123")),
            token: "token"
        )
        XCTAssertEqual(local.webSocketURL?.absoluteString, "ws://homeassistant.local:8123/api/websocket")
    }
}
