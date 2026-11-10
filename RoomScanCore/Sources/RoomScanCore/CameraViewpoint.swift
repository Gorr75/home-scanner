import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A saved orbit for one room. Position and target are meters, Y up, in that room's scan space.
public struct CameraViewpoint: Codable, Equatable, Sendable {
    public var position: Vec3
    public var target: Vec3
    @Quantized public var fieldOfView: Double

    public init(position: Vec3, target: Vec3, fieldOfView: Double = 48) {
        self.position = position
        self.target = target
        self.fieldOfView = fieldOfView
    }

    /// The framing the 3D view uses before anyone saves a camera.
    /// A little above and in front of the plan, matching the room model.
    public static func framed(on plan: FloorPlan) -> CameraViewpoint {
        let box = FloorPlanGeometry.bounds(of: plan)
        let center = box.center
        let span = max(box.size.x, box.size.z, 1.6)
        return CameraViewpoint(
            position: Vec3(
                x: center.x + span * 0.1,
                y: max(box.max.y, 1.2) + span * 0.7,
                z: center.z + span * 1.05
            ),
            target: Vec3(
                x: center.x,
                y: min(max(center.y, 0.4), 1.4),
                z: center.z
            ),
            fieldOfView: 48
        )
    }

    /// The same rigid move the align step applies to the room, its pins, and its furniture.
    public func transformed(by rigid: RigidYaw) -> CameraViewpoint {
        CameraViewpoint(
            position: rigid.applying(position),
            target: rigid.applying(target),
            fieldOfView: fieldOfView
        )
    }

    /// model-viewer orbit. `offsetX` / `offsetZ` slide a room camera onto a side-by-side home model.
    public func orbit(offsetX: Double = 0, offsetZ: Double = 0) -> CameraOrbit {
        let eye = Vec3(x: position.x + offsetX, y: position.y, z: position.z + offsetZ)
        let look = Vec3(x: target.x + offsetX, y: target.y, z: target.z + offsetZ)
        var delta = eye - look
        if delta.length < 1e-4 {
            delta = Vec3(x: 0, y: 0, z: 1)
        }
        let radius = max(delta.length, 0.05)
        let phi = ViewpointTrig.acos(min(1, max(-1, delta.y / radius)))
        let theta = ViewpointTrig.atan2(delta.x, delta.z)
        return CameraOrbit(theta: theta, phi: phi, radius: radius, target: look, fieldOfView: fieldOfView)
    }

    /// Where a device lands on a plate rendered from this camera. Nil when it is behind the lens or off the frame.
    /// `aspect` is width / height. `spread` is the world radius, in meters, used for the tap target.
    public func region(of point: Vec3, aspect: Double, spread: Double = 0.45) -> PlateRegion? {
        guard aspect > 0.05 else { return nil }
        let forward = (target - position).normalized(fallback: Vec3(x: 0, y: 0, z: -1))
        let worldUp = Vec3(x: 0, y: 1, z: 0)
        let side = forward.cross(worldUp)
        let right = side.length < 1e-4 ? Vec3(x: 1, y: 0, z: 0) : side.normalized()
        let up = right.cross(forward).normalized(fallback: worldUp)
        let relative = point - position
        let depth = relative.dot(forward)
        guard depth > 0.05 else { return nil }
        let fov = min(120, max(10, fieldOfView)) * .pi / 180
        let focal = 1 / max(ViewpointTrig.tan(fov / 2), 1e-4)
        let ndcX = (relative.dot(right) / depth) * (focal / aspect)
        let ndcY = (relative.dot(up) / depth) * focal
        let x = 0.5 + 0.5 * ndcX
        let y = 0.5 - 0.5 * ndcY
        guard x >= -0.15, x <= 1.15, y >= -0.15, y <= 1.15 else { return nil }
        let radius = min(0.18, max(0.035, (abs(spread) / depth) * focal / 2))
        return PlateRegion(x: x, y: y, radius: radius)
    }
}

public struct CameraOrbit: Equatable, Sendable {
    public var theta: Double
    public var phi: Double
    public var radius: Double
    public var target: Vec3
    public var fieldOfView: Double

    public init(theta: Double, phi: Double, radius: Double, target: Vec3, fieldOfView: Double) {
        self.theta = theta
        self.phi = phi
        self.radius = radius
        self.target = target
        self.fieldOfView = fieldOfView
    }
}

/// Rooms kept in their existing order inside each floor. Numbered floors come first, low to high.
public struct FloorGroup: Equatable, Sendable, Identifiable {
    public var level: Int?
    public var rooms: [Room]

    public var id: String { level.map(String.init) ?? "none" }

    public init(level: Int?, rooms: [Room]) {
        self.level = level
        self.rooms = rooms
    }
}

public enum FloorGrouping {
    /// Levels offered in the room menu. `0` is the ground floor.
    public static let selectable: [Int] = Array(-1...4)

    public static func groups(in rooms: [Room]) -> [FloorGroup] {
        var levels: [Int?] = []
        var buckets: [String: [Room]] = [:]
        for room in rooms {
            let key = key(for: room.floor)
            if buckets[key] == nil {
                levels.append(room.floor)
                buckets[key] = []
            }
            buckets[key, default: []].append(room)
        }
        let ordered = levels.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }
        return ordered.map { level in
            FloorGroup(level: level, rooms: buckets[key(for: level)] ?? [])
        }
    }

    public static func label(for level: Int?) -> String {
        guard let level else { return "No floor" }
        return "Floor \(level)"
    }

    private static func key(for level: Int?) -> String {
        level.map(String.init) ?? "none"
    }
}

extension Vec3 {
    func cross(_ other: Vec3) -> Vec3 {
        Vec3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }
}

enum ViewpointTrig {
    static func tan(_ value: Double) -> Double {
        #if canImport(Darwin)
        Darwin.tan(value)
        #elseif canImport(Glibc)
        Glibc.tan(value)
        #else
        Musl.tan(value)
        #endif
    }

    static func acos(_ value: Double) -> Double {
        #if canImport(Darwin)
        Darwin.acos(value)
        #elseif canImport(Glibc)
        Glibc.acos(value)
        #else
        Musl.acos(value)
        #endif
    }

    static func atan2(_ y: Double, _ x: Double) -> Double {
        #if canImport(Darwin)
        Darwin.atan2(y, x)
        #elseif canImport(Glibc)
        Glibc.atan2(y, x)
        #else
        Musl.atan2(y, x)
        #endif
    }
}
