import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum Trig {
    static func cos(_ value: Double) -> Double {
        #if canImport(Darwin)
        Darwin.cos(value)
        #elseif canImport(Glibc)
        Glibc.cos(value)
        #else
        Musl.cos(value)
        #endif
    }

    static func sin(_ value: Double) -> Double {
        #if canImport(Darwin)
        Darwin.sin(value)
        #elseif canImport(Glibc)
        Glibc.sin(value)
        #else
        Musl.sin(value)
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

public struct AABB: Equatable, Sendable {
    public var min: Vec3
    public var max: Vec3

    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }

    public var center: Vec3 {
        Vec3(
            x: (min.x + max.x) / 2,
            y: (min.y + max.y) / 2,
            z: (min.z + max.z) / 2
        )
    }

    public var size: Vec3 {
        Vec3(x: max.x - min.x, y: max.y - min.y, z: max.z - min.z)
    }

    public func union(_ other: AABB) -> AABB {
        AABB(
            min: Vec3(
                x: Swift.min(min.x, other.min.x),
                y: Swift.min(min.y, other.min.y),
                z: Swift.min(min.z, other.min.z)
            ),
            max: Vec3(
                x: Swift.max(max.x, other.max.x),
                y: Swift.max(max.y, other.max.y),
                z: Swift.max(max.z, other.max.z)
            )
        )
    }

    public func translated(by offset: Vec3) -> AABB {
        AABB(min: min + offset, max: max + offset)
    }
}

public enum FloorPlanGeometry {
    public static func wall(
        center: Vec3,
        axisX: Vec3,
        width: Double,
        height: Double,
        thickness: Double,
        id: UUID,
        confidence: ScanConfidence? = nil
    ) -> WallSegment {
        let direction = axisX.flattened.normalized()
        let half = direction.scaled(abs(width) / 2)
        let baseY = center.y - height / 2
        return WallSegment(
            id: id,
            start: Vec3(x: center.x - half.x, y: baseY, z: center.z - half.z),
            end: Vec3(x: center.x + half.x, y: baseY, z: center.z + half.z),
            height: height,
            thickness: thickness,
            confidence: confidence
        )
    }

    /// Yaw of a width axis. Zero is +X, positive turns toward +Z.
    public static func yaw(axisX: Vec3) -> Double {
        Trig.atan2(axisX.z, axisX.x)
    }

    /// Local rectangle on the surface's XY plane, transformed into world space.
    /// RoomPlan surfaces lie on that plane: X is width, Y is height.
    public static func rectangleCorners(width: Double, height: Double, transform: Transform) -> [Vec3] {
        let halfWidth = width / 2
        let halfHeight = height / 2
        let local = [
            Vec3(x: -halfWidth, y: -halfHeight, z: 0),
            Vec3(x: halfWidth, y: -halfHeight, z: 0),
            Vec3(x: halfWidth, y: halfHeight, z: 0),
            Vec3(x: -halfWidth, y: halfHeight, z: 0)
        ]
        return local.map { transform.applying($0) }
    }

    public static func bounds(of plan: FloorPlan, furniture: [PlacedFurniture] = []) -> AABB {
        var points: [Vec3] = []
        for wall in plan.walls {
            points.append(wall.start)
            points.append(wall.end)
            points.append(Vec3(x: wall.start.x, y: wall.start.y + wall.height, z: wall.start.z))
            points.append(Vec3(x: wall.end.x, y: wall.end.y + wall.height, z: wall.end.z))
        }
        for floor in plan.floors {
            points.append(contentsOf: floor.corners)
        }
        for opening in plan.openings {
            points.append(opening.center)
        }
        for object in plan.objects {
            let halfY = object.dimensions.y / 2
            for corner in object.footprint {
                points.append(corner)
                points.append(Vec3(x: corner.x, y: object.center.y + halfY, z: corner.z))
                points.append(Vec3(x: corner.x, y: object.center.y - halfY, z: corner.z))
            }
        }
        for item in furniture {
            let size = FurnitureGeometry.worldSize(of: item)
            for corner in FurnitureGeometry.footprint(of: item) {
                points.append(corner)
                points.append(Vec3(x: corner.x, y: item.position.y + size.y, z: corner.z))
            }
        }
        guard let first = points.first else {
            return AABB(min: .zero, max: Vec3(x: 1, y: 1, z: 1))
        }
        return points.dropFirst().reduce(AABB(min: first, max: first)) { box, point in
            AABB(
                min: Vec3(
                    x: Swift.min(box.min.x, point.x),
                    y: Swift.min(box.min.y, point.y),
                    z: Swift.min(box.min.z, point.z)
                ),
                max: Vec3(
                    x: Swift.max(box.max.x, point.x),
                    y: Swift.max(box.max.y, point.y),
                    z: Swift.max(box.max.z, point.z)
                )
            )
        }
    }

    public static func bounds(of plans: [FloorPlan]) -> AABB {
        guard let first = plans.first else {
            return AABB(min: .zero, max: Vec3(x: 1, y: 1, z: 1))
        }
        return plans.dropFirst().reduce(bounds(of: first)) { partial, plan in
            partial.union(bounds(of: plan))
        }
    }
}

extension Opening {
    /// Endpoints of the opening along its width, at the center height.
    public var widthEndpoints: (start: Vec3, end: Vec3) {
        let direction = Vec3(x: Trig.cos(yaw), y: 0, z: Trig.sin(yaw))
        let half = direction.scaled(width / 2)
        return (center - half, center + half)
    }
}

extension PlacedObject {
    /// Floor-parallel corners after yaw. Local +X maps to `(cos yaw, 0, sin yaw)`.
    public var footprint: [Vec3] {
        let halfX = dimensions.x / 2
        let halfZ = dimensions.z / 2
        let local = [
            Vec3(x: -halfX, y: 0, z: -halfZ),
            Vec3(x: halfX, y: 0, z: -halfZ),
            Vec3(x: halfX, y: 0, z: halfZ),
            Vec3(x: -halfX, y: 0, z: halfZ)
        ]
        let cosine = Trig.cos(yaw)
        let sine = Trig.sin(yaw)
        return local.map { point in
            Vec3(
                x: center.x + point.x * cosine - point.z * sine,
                y: center.y,
                z: center.z + point.x * sine + point.z * cosine
            )
        }
    }
}

public struct RoomFrame: Equatable, Sendable, Identifiable {
    public var roomId: UUID
    public var offset: Vec3

    public init(roomId: UUID, offset: Vec3) {
        self.roomId = roomId
        self.offset = offset
    }

    public var id: UUID { roomId }
}

public enum FloorPlanLayout {
    /// Unmerged rooms each have their own scan origin. Lay those out in a row
    /// for display only. Unified rooms (one scan, or the sample) keep their coordinates.
    public static func frames(
        rooms: [Room],
        coordinatesAreUnified: Bool,
        gap: Double = 0.8
    ) -> [RoomFrame] {
        let floors = Set(rooms.map(\.floor))
        if floors.count <= 1 {
            return row(rooms, coordinatesAreUnified: coordinatesAreUnified, gap: gap)
        }
        // Each storey is laid out on its own, so a copied floor sits on the one below.
        // Unassigned rooms stay in their own group and are not treated as floor 0.
        let ordered = floors.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
        return ordered.flatMap { floor in
            row(rooms.filter { $0.floor == floor }, coordinatesAreUnified: coordinatesAreUnified, gap: gap)
        }
    }

    private static func row(
        _ rooms: [Room],
        coordinatesAreUnified: Bool,
        gap: Double
    ) -> [RoomFrame] {
        if coordinatesAreUnified || rooms.count <= 1 {
            return rooms.map { RoomFrame(roomId: $0.id, offset: .zero) }
        }
        var cursor = 0.0
        return rooms.map { room in
            let box = FloorPlanGeometry.bounds(of: room.floorPlan, furniture: room.placedFurniture)
            let offset = Vec3(x: cursor - box.min.x, y: 0, z: -box.min.z)
            cursor += max(box.size.x, 0.5) + gap
            return RoomFrame(roomId: room.id, offset: offset)
        }
    }
}

/// Maps the floor (X, Z) onto a view. Screen Y grows with +Z.
public struct PlanProjector: Equatable, Sendable {
    public var minX: Double
    public var minZ: Double
    public var metersToPoints: Double
    public var padding: Double
    public var viewWidth: Double
    public var viewHeight: Double
    public var userScale: Double
    public var userOffsetX: Double
    public var userOffsetY: Double

    public init(
        minX: Double,
        minZ: Double,
        metersToPoints: Double,
        padding: Double,
        viewWidth: Double,
        viewHeight: Double,
        userScale: Double,
        userOffsetX: Double,
        userOffsetY: Double
    ) {
        self.minX = minX
        self.minZ = minZ
        self.metersToPoints = metersToPoints
        self.padding = padding
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.userScale = userScale
        self.userOffsetX = userOffsetX
        self.userOffsetY = userOffsetY
    }

    public static func fitting(
        bounds: AABB,
        viewWidth: Double,
        viewHeight: Double,
        padding: Double = 28
    ) -> PlanProjector {
        let spanX = max(bounds.size.x, 0.001)
        let spanZ = max(bounds.size.z, 0.001)
        let usableWidth = max(viewWidth - padding * 2, 1)
        let usableHeight = max(viewHeight - padding * 2, 1)
        return PlanProjector(
            minX: bounds.min.x,
            minZ: bounds.min.z,
            metersToPoints: min(usableWidth / spanX, usableHeight / spanZ),
            padding: padding,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            userScale: 1,
            userOffsetX: 0,
            userOffsetY: 0
        )
    }

    public func screen(x: Double, z: Double) -> (x: Double, y: Double) {
        let fittedX = padding + (x - minX) * metersToPoints
        let fittedY = padding + (z - minZ) * metersToPoints
        let centerX = viewWidth / 2
        let centerY = viewHeight / 2
        let scale = userScale == 0 ? 1 : userScale
        return (
            x: (fittedX - centerX) * scale + centerX + userOffsetX,
            y: (fittedY - centerY) * scale + centerY + userOffsetY
        )
    }

    public func world(screenX: Double, screenY: Double) -> (x: Double, z: Double) {
        let centerX = viewWidth / 2
        let centerY = viewHeight / 2
        let scale = userScale == 0 ? 1 : userScale
        let fittedX = (screenX - userOffsetX - centerX) / scale + centerX
        let fittedY = (screenY - userOffsetY - centerY) / scale + centerY
        let meters = metersToPoints == 0 ? 1 : metersToPoints
        return (
            x: (fittedX - padding) / meters + minX,
            z: (fittedY - padding) / meters + minZ
        )
    }
}
