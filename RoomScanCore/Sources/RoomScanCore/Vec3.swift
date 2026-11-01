import Foundation

/// Meters in a right-handed, Y-up space. Matches ARKit, RoomPlan, and USDZ.
public struct Vec3: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(x: 0, y: 0, z: 0)

    public var length: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    public var horizontalLength: Double {
        (x * x + z * z).squareRoot()
    }

    public func scaled(_ factor: Double) -> Vec3 {
        Vec3(x: x * factor, y: y * factor, z: z * factor)
    }

    public func dot(_ other: Vec3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    /// Drops the vertical component. Used when a wall's width axis should run along the floor.
    public var flattened: Vec3 {
        Vec3(x: x, y: 0, z: z)
    }

    public func normalized(fallback: Vec3 = Vec3(x: 1, y: 0, z: 0)) -> Vec3 {
        let magnitude = length
        guard magnitude > 1e-9 else { return fallback }
        return scaled(1 / magnitude)
    }

    public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    /// 0.1 mm. Keeps exported JSON stable and readable.
    public static func quantize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let scaled = (value * 10_000).rounded() / 10_000
        return scaled == 0 ? 0 : scaled
    }
}

extension Vec3: Codable {
    enum CodingKeys: String, CodingKey {
        case x, y, z
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        z = try container.decode(Double.self, forKey: .z)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.quantize(x), forKey: .x)
        try container.encode(Self.quantize(y), forKey: .y)
        try container.encode(Self.quantize(z), forKey: .z)
    }
}

@propertyWrapper
public struct Quantized: Hashable, Sendable {
    public var wrappedValue: Double

    public init(wrappedValue: Double) {
        self.wrappedValue = wrappedValue
    }
}

extension Quantized: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Vec3.quantize(wrappedValue))
    }
}

/// Affine transform stored as three axes plus a translation, in meters.
public struct Transform: Equatable, Sendable {
    public var axisX: Vec3
    public var axisY: Vec3
    public var axisZ: Vec3
    public var translation: Vec3

    public init(axisX: Vec3, axisY: Vec3, axisZ: Vec3, translation: Vec3) {
        self.axisX = axisX
        self.axisY = axisY
        self.axisZ = axisZ
        self.translation = translation
    }

    public static let identity = Transform(
        axisX: Vec3(x: 1, y: 0, z: 0),
        axisY: Vec3(x: 0, y: 1, z: 0),
        axisZ: Vec3(x: 0, y: 0, z: 1),
        translation: .zero
    )

    public func applying(_ local: Vec3) -> Vec3 {
        translation
            + axisX.scaled(local.x)
            + axisY.scaled(local.y)
            + axisZ.scaled(local.z)
    }
}
