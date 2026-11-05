import Foundation

public struct EntitySnapshot: Equatable, Sendable, Codable {
    public var entityId: String
    public var state: String
    public var domain: String
    public var unit: String?
    public var friendlyName: String?
    /// Home Assistant `brightness` scaled to 0...1. Lights only.
    public var brightness: Double?
    /// Colour channels 0...1, from `rgb_color`, `hs_color`, or colour temperature.
    public var red: Double?
    public var green: Double?
    public var blue: Double?
    /// `sun.sun` elevation in degrees. Nil for every other entity.
    public var elevation: Double?
    /// `sun.sun` `next_rising`. Nil for every other entity.
    public var nextRising: Date?
    /// `sun.sun` `next_setting`. Nil for every other entity.
    public var nextSetting: Date?

    public init(
        entityId: String,
        state: String,
        domain: String,
        unit: String? = nil,
        friendlyName: String? = nil,
        brightness: Double? = nil,
        red: Double? = nil,
        green: Double? = nil,
        blue: Double? = nil,
        elevation: Double? = nil,
        nextRising: Date? = nil,
        nextSetting: Date? = nil
    ) {
        self.entityId = entityId
        self.state = state
        self.domain = domain
        self.unit = unit
        self.friendlyName = friendlyName
        self.brightness = brightness
        self.red = red
        self.green = green
        self.blue = blue
        self.elevation = elevation
        self.nextRising = nextRising
        self.nextSetting = nextSetting
    }

    public static let toggleableDomains: Set<String> = ["light", "switch", "fan"]

    public var isToggleable: Bool {
        Self.toggleableDomains.contains(domain)
    }

    public var isOn: Bool {
        state == "on"
    }

    public var displayState: String {
        if domain == "light" {
            if state == "on", let brightness {
                let percent = Int((min(1, max(0, brightness)) * 100).rounded())
                return "on \(percent)%"
            }
            return state
        }
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

/// Live device state. `MockHomeStateProvider` is the stand-in until Settings
/// has a base URL and a Keychain token. `HomeAssistantClient` speaks REST.
public protocol HomeStateProvider: Sendable {
    func snapshot(for entityId: String) async throws -> EntitySnapshot
    func snapshots(for entityIds: [String]) async throws -> [EntitySnapshot]
    func perform(_ action: EntityAction, entityId: String) async throws -> EntitySnapshot
    /// Sets a light's brightness (0...1). `0` turns the light off. Other domains throw.
    func setBrightness(_ level: Double, entityId: String) async throws -> EntitySnapshot
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
        EntitySnapshot(
            entityId: "light.kitchen",
            state: "on",
            domain: "light",
            friendlyName: "Kitchen light",
            brightness: 0.8,
            red: 1,
            green: 0.72,
            blue: 0.35
        ),
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

    public func setBrightness(_ level: Double, entityId: String) async throws -> EntitySnapshot {
        var current = try await snapshot(for: entityId)
        guard current.domain == "light" else {
            throw HomeStateError.notToggleable(current.entityId)
        }
        let clamped = min(1, max(0, level))
        current.brightness = clamped
        current.state = clamped <= 0.004 ? "off" : "on"
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

    public func setBrightness(_ level: Double, entityId: String) async throws -> EntitySnapshot {
        throw HomeStateError.notConfigured
    }
}
