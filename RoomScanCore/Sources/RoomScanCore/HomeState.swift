import Foundation

public struct EntitySnapshot: Equatable, Sendable, Codable {
    public var entityId: String
    public var state: String
    public var domain: String
    public var unit: String?
    public var friendlyName: String?

    public init(
        entityId: String,
        state: String,
        domain: String,
        unit: String? = nil,
        friendlyName: String? = nil
    ) {
        self.entityId = entityId
        self.state = state
        self.domain = domain
        self.unit = unit
        self.friendlyName = friendlyName
    }

    public static let toggleableDomains: Set<String> = ["light", "switch", "fan"]

    public var isToggleable: Bool {
        Self.toggleableDomains.contains(domain)
    }

    public var isOn: Bool {
        state == "on"
    }

    public var displayState: String {
        if let unit, !unit.isEmpty {
            return "\(state) \(unit)"
        }
        return state.replacingOccurrences(of: "_", with: " ")
    }
}

public enum EntityAction: String, Codable, Sendable {
    case turnOn = "turn_on"
    case turnOff = "turn_off"
    case toggle
}

public enum HomeStateError: Error, Equatable, Sendable {
    case notConfigured
    case notToggleable(String)
    case invalidEntityId(String)
}

extension HomeStateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Home Assistant is not connected."
        case .notToggleable(let entityId):
            return "\(entityId) can't be toggled from here."
        case .invalidEntityId(let raw):
            return "\(raw) is not a Home Assistant entity id. Use the form light.kitchen."
        }
    }
}

/// Live device state. v1 ships `MockHomeStateProvider`. A later client can
/// implement this with the Home Assistant REST and WebSocket APIs.
public protocol HomeStateProvider: Sendable {
    func snapshot(for entityId: String) async throws -> EntitySnapshot
    func snapshots(for entityIds: [String]) async throws -> [EntitySnapshot]
    func perform(_ action: EntityAction, entityId: String) async throws -> EntitySnapshot
}

extension HomeStateProvider {
    public func snapshots(for entityIds: [String]) async throws -> [EntitySnapshot] {
        var results: [EntitySnapshot] = []
        for entityId in entityIds {
            results.append(try await snapshot(for: entityId))
        }
        return results
    }
}

/// Stand-in states so pins can show on/off and a temperature before a real
/// Home Assistant connection exists. Remembers toggles for the session.
public actor MockHomeStateProvider: HomeStateProvider {
    public static let sampleSeed: [EntitySnapshot] = [
        EntitySnapshot(entityId: "light.kitchen", state: "on", domain: "light", friendlyName: "Kitchen light"),
        EntitySnapshot(entityId: "light.living_room", state: "off", domain: "light", friendlyName: "Living room light"),
        EntitySnapshot(entityId: "switch.living_room", state: "on", domain: "switch", friendlyName: "Living room switch"),
        EntitySnapshot(
            entityId: "sensor.living_room_temperature",
            state: "21.5",
            domain: "sensor",
            unit: "°C",
            friendlyName: "Living room temperature"
        )
    ]

    private var states: [String: EntitySnapshot]

    public init(seed: [EntitySnapshot] = MockHomeStateProvider.sampleSeed) {
        var map: [String: EntitySnapshot] = [:]
        for item in seed {
            map[item.entityId] = item
        }
        states = map
    }

    public func snapshot(for entityId: String) async throws -> EntitySnapshot {
        let id = try Self.requireID(entityId)
        if let existing = states[id] {
            return existing
        }
        let created = Self.placeholder(for: id)
        states[id] = created
        return created
    }

    public func perform(_ action: EntityAction, entityId: String) async throws -> EntitySnapshot {
        var current = try await snapshot(for: entityId)
        guard current.isToggleable else {
            throw HomeStateError.notToggleable(current.entityId)
        }
        switch action {
        case .turnOn:
            current.state = "on"
        case .turnOff:
            current.state = "off"
        case .toggle:
            current.state = current.state == "on" ? "off" : "on"
        }
        states[current.entityId] = current
        return current
    }

    private static func requireID(_ raw: String) throws -> String {
        switch EntityIDRules.check(raw) {
        case .valid(let id):
            return id
        case .unset, .invalid:
            throw HomeStateError.invalidEntityId(raw)
        }
    }

    private static func placeholder(for entityId: String) -> EntitySnapshot {
        let domain = String(entityId.split(separator: ".").first ?? "unknown")
        let state = EntitySnapshot.toggleableDomains.contains(domain) ? "off" : "unknown"
        return EntitySnapshot(entityId: entityId, state: state, domain: domain)
    }
}

/// Placeholder for the client that does not exist yet.
/// A future implementation would keep `baseURL` (for example `http://homeassistant.local:8123`)
/// and read a long-lived access token from the Keychain account named here.
/// The token must not be written into the home JSON.
public struct UnconfiguredHomeAssistantClient: HomeStateProvider, Sendable {
    public static let keychainService = "se.jansson.homescan.homeassistant"
    public static let tokenAccount = "access-token"

    public var baseURL: URL?
    public var tokenAccount: String

    public init(baseURL: URL? = nil, tokenAccount: String = UnconfiguredHomeAssistantClient.tokenAccount) {
        self.baseURL = baseURL
        self.tokenAccount = tokenAccount
    }

    public func snapshot(for entityId: String) async throws -> EntitySnapshot {
        throw HomeStateError.notConfigured
    }

    public func perform(_ action: EntityAction, entityId: String) async throws -> EntitySnapshot {
        throw HomeStateError.notConfigured
    }
}
