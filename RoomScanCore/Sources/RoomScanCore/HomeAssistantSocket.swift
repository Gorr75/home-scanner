import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HomeAssistantStreamUpdate: Sendable {
    case ready
    case state(EntitySnapshot)
}

public enum HomeAssistantSocketEvent: Equatable, Sendable {
    case authRequired
    case authOk
    case authInvalid(String)
    case result(id: Int, success: Bool)
    case stateChanged(EntitySnapshot)
    case ignored
}

public enum HomeAssistantSocketCodec {
    public static func authMessage(token: String) -> String {
        let object: [String: Any] = ["type": "auth", "access_token": token]
        return stringify(object) ?? #"{"type":"auth","access_token":""}"#
    }

    public static func subscribeStateChanges(id: Int) -> String {
        let object: [String: Any] = [
            "id": id,
            "type": "subscribe_events",
            "event_type": "state_changed"
        ]
        return stringify(object) ?? #"{"id":1,"type":"subscribe_events","event_type":"state_changed"}"#
    }

    public static func decode(_ text: String) -> HomeAssistantSocketEvent {
        decode(Data(text.utf8))
    }

    public static func decode(_ data: Data) -> HomeAssistantSocketEvent {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }
        switch object["type"] as? String {
        case "auth_required":
            return .authRequired
        case "auth_ok":
            return .authOk
        case "auth_invalid":
            let message = object["message"] as? String ?? "Home Assistant rejected the token."
            return .authInvalid(message)
        case "result":
            let id = object["id"] as? Int ?? 0
            let success = object["success"] as? Bool ?? false
            return .result(id: id, success: success)
        case "event":
            return stateChange(in: object) ?? .ignored
        default:
            return .ignored
        }
    }

    private static func stateChange(in object: [String: Any]) -> HomeAssistantSocketEvent? {
        guard let event = object["event"] as? [String: Any] else { return nil }
        guard (event["event_type"] as? String) == "state_changed" else { return nil }
        guard let data = event["data"] as? [String: Any] else { return nil }
        guard let newState = data["new_state"] as? [String: Any] else { return .ignored }
        guard let record = HomeAssistantDecoding.entity(from: newState) else { return .ignored }
        return .stateChanged(record.snapshot)
    }

    private static func stringify(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// WebSocket `/api/websocket` subscription for `state_changed`.
/// Reconnects until the token is rejected or the task is cancelled.
public final class HomeAssistantEventStream: @unchecked Sendable {
    private let endpoint: HomeAssistantEndpoint
    private let session: URLSession

    public init(endpoint: HomeAssistantEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func updates() -> AsyncThrowingStream<HomeAssistantStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(
                        onReady: { continuation.yield(.ready) },
                        onState: { continuation.yield(.state($0)) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func run(
        onReady: @escaping @Sendable () -> Void = {},
        onState: @escaping @Sendable (EntitySnapshot) -> Void
    ) async throws {
        while !Task.isCancelled {
            do {
                try await connectOnce(onReady: onReady, onState: onState)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let error as HomeAssistantClientError where error == .unauthorized {
                throw error
            } catch {
                if Task.isCancelled { return }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func connectOnce(
        onReady: @escaping @Sendable () -> Void,
        onState: @escaping @Sendable (EntitySnapshot) -> Void
    ) async throws {
        guard let url = endpoint.webSocketURL else {
            throw HomeAssistantClientError.invalidBaseURL
        }
        let token = endpoint.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw HomeAssistantClientError.emptyToken }
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await withTaskCancellationHandler {
            try await self.sessionLoop(task, token: token, onReady: onReady, onState: onState)
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func sessionLoop(
        _ task: URLSessionWebSocketTask,
        token: String,
        onReady: @escaping @Sendable () -> Void,
        onState: @escaping @Sendable (EntitySnapshot) -> Void
    ) async throws {
        let hello = try await receive(task)
        guard case .authRequired = hello else {
            throw HomeAssistantClientError.malformedResponse
        }
        try await task.send(.string(HomeAssistantSocketCodec.authMessage(token: token)))
        let auth = try await receive(task)
        switch auth {
        case .authOk:
            break
        case .authInvalid:
            throw HomeAssistantClientError.unauthorized
        default:
            throw HomeAssistantClientError.malformedResponse
        }
        try await task.send(.string(HomeAssistantSocketCodec.subscribeStateChanges(id: 1)))
        onReady()
        while !Task.isCancelled {
            let event = try await receive(task)
            if case .stateChanged(let snapshot) = event {
                onState(snapshot)
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) async throws -> HomeAssistantSocketEvent {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return HomeAssistantSocketCodec.decode(text)
        case .data(let data):
            return HomeAssistantSocketCodec.decode(data)
        @unknown default:
            return .ignored
        }
    }
}
