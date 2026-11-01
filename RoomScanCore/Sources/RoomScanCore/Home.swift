import Foundation

public enum DeviceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case light
    case `switch`
    case sensor
    case climate
    case cover
    case fan
    case mediaPlayer = "media_player"
    case lock
    case other

    public var label: String {
        switch self {
        case .light: return "Light"
        case .switch: return "Switch"
        case .sensor: return "Sensor"
        case .climate: return "Climate"
        case .cover: return "Cover"
        case .fan: return "Fan"
        case .mediaPlayer: return "Media player"
        case .lock: return "Lock"
        case .other: return "Other"
        }
    }

    /// Typical mounting height in meters, used when a pin is first placed.
    public var defaultHeight: Double {
        switch self {
        case .light: return 2.35
        case .fan: return 2.2
        case .sensor, .climate: return 1.45
        case .switch, .lock, .cover: return 1.15
        case .mediaPlayer, .other: return 1.2
        }
    }

    public var symbolName: String {
        switch self {
        case .light: return "lightbulb"
        case .switch: return "switch.2"
        case .sensor: return "waveform.path.ecg"
        case .climate: return "thermometer.medium"
        case .cover: return "rectangle.split.3x1"
        case .fan: return "fanblades"
        case .mediaPlayer: return "play.rectangle"
        case .lock: return "lock"
        case .other: return "mappin"
        }
    }
}

/// A device marker in a room. `entityId` is optional until the pin is linked
/// to Home Assistant. Positions are meters in that room's scan space.
public struct DevicePin: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var roomId: UUID?
    public var name: String
    public var kind: DeviceKind
    public var entityId: String?
    public var position: Vec3

    public init(
        id: UUID,
        roomId: UUID?,
        name: String,
        kind: DeviceKind,
        entityId: String?,
        position: Vec3
    ) {
        self.id = id
        self.roomId = roomId
        self.name = name
        self.kind = kind
        self.entityId = entityId
        self.position = position
    }

    public static func placed(
        in roomId: UUID,
        kind: DeviceKind,
        x: Double,
        z: Double,
        name: String? = nil
    ) -> DevicePin {
        DevicePin(
            id: UUID(),
            roomId: roomId,
            name: name ?? kind.label,
            kind: kind,
            entityId: nil,
            position: Vec3(x: x, y: kind.defaultHeight, z: z)
        )
    }

    public func moved(x: Double, z: Double) -> DevicePin {
        var copy = self
        copy.position = Vec3(x: x, y: position.y, z: z)
        return copy
    }

    public func moved(to position: Vec3) -> DevicePin {
        var copy = self
        copy.position = position
        return copy
    }
}

public struct RoomAssets: Codable, Equatable, Sendable {
    /// Path relative to the home directory, for example `rooms/<id>.usdz`.
    public var usdz: String?
    /// Apple's encoded `CapturedRoom`, relative to the home directory.
    public var capturedRoom: String?

    public init(usdz: String? = nil, capturedRoom: String? = nil) {
        self.usdz = usdz
        self.capturedRoom = capturedRoom
    }
}

public struct Room: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var floorPlan: FloorPlan
    public var assets: RoomAssets

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        floorPlan: FloorPlan,
        assets: RoomAssets = RoomAssets()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.floorPlan = floorPlan
        self.assets = assets
    }
}

/// A merged multi-room result. Pins stay in each room's scan space unless
/// `coordinatesAreUnified` is true (the bundled sample is authored that way).
public struct StructureLink: Codable, Equatable, Sendable {
    public var builtAt: Date
    public var roomIds: [UUID]
    public var coordinatesAreUnified: Bool
    public var usdz: String?
    public var capturedStructure: String?
    public var overviewFloorPlan: FloorPlan?

    public init(
        builtAt: Date,
        roomIds: [UUID],
        coordinatesAreUnified: Bool,
        usdz: String? = nil,
        capturedStructure: String? = nil,
        overviewFloorPlan: FloorPlan? = nil
    ) {
        self.builtAt = builtAt
        self.roomIds = roomIds
        self.coordinatesAreUnified = coordinatesAreUnified
        self.usdz = usdz
        self.capturedStructure = capturedStructure
        self.overviewFloorPlan = overviewFloorPlan
    }
}

public struct Home: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var rooms: [Room]
    public var pins: [DevicePin]
    public var structure: StructureLink?
    public var outdoorZones: [OutdoorZone]
    public var site: Site?

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        rooms: [Room],
        pins: [DevicePin],
        structure: StructureLink? = nil,
        outdoorZones: [OutdoorZone] = [],
        site: Site? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rooms = rooms
        self.pins = pins
        self.structure = structure
        self.outdoorZones = outdoorZones
        self.site = site
    }

    public func room(id: UUID) -> Room? {
        rooms.first { $0.id == id }
    }

    public func pins(in roomId: UUID) -> [DevicePin] {
        pins.filter { $0.roomId == roomId }
    }

    public var coordinatesAreUnified: Bool {
        rooms.count <= 1 || structure?.coordinatesAreUnified == true
    }

    public mutating func upsertPin(_ pin: DevicePin) {
        if let index = pins.firstIndex(where: { $0.id == pin.id }) {
            pins[index] = pin
        } else {
            pins.append(pin)
        }
    }

    public mutating func deletePin(id: UUID) {
        pins.removeAll { $0.id == id }
    }

    public mutating func deleteRoom(id: UUID) {
        rooms.removeAll { $0.id == id }
        pins.removeAll { $0.roomId == id }
        site?.placements.removeAll { placement in
            if case .room(let roomID) = placement.subject {
                return roomID == id
            }
            return false
        }
    }

    public mutating func deleteOutdoorZone(id: UUID) {
        outdoorZones.removeAll { $0.id == id }
        site?.placements.removeAll { placement in
            if case .outdoorZone(let zoneID) = placement.subject {
                return zoneID == id
            }
            return false
        }
    }

    public func outdoorZone(id: UUID) -> OutdoorZone? {
        outdoorZones.first { $0.id == id }
    }

    public var hasWallTextures: Bool {
        if rooms.contains(where: { $0.floorPlan.walls.contains(where: { $0.texture != nil }) }) {
            return true
        }
        return outdoorZones.contains { $0.walls.contains { $0.texture != nil } }
    }
}

extension Home: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case rooms
        case pins
        case structure
        case outdoorZones
        case site
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        rooms = try container.decode([Room].self, forKey: .rooms)
        pins = try container.decode([DevicePin].self, forKey: .pins)
        structure = try container.decodeIfPresent(StructureLink.self, forKey: .structure)
        outdoorZones = try container.decodeIfPresent([OutdoorZone].self, forKey: .outdoorZones) ?? []
        site = try container.decodeIfPresent(Site.self, forKey: .site)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(rooms, forKey: .rooms)
        try container.encode(pins, forKey: .pins)
        try container.encodeIfPresent(structure, forKey: .structure)
        if !outdoorZones.isEmpty {
            try container.encode(outdoorZones, forKey: .outdoorZones)
        }
        try container.encodeIfPresent(site, forKey: .site)
    }
}
