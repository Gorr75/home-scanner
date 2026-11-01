import Foundation
import RoomPlan
import RoomScanCore
import simd

/// Pulls a top-down plan out of a RoomPlan result.
/// Surfaces lie on their local XY plane: X is width, Y is height, facing +Z.
enum FloorPlanExtractor {
    static func floorPlan(from room: CapturedRoom) -> FloorPlan {
        FloorPlan(
            walls: room.walls.compactMap(wall),
            openings: room.doors.compactMap { opening($0, kind: .door) }
                + room.windows.compactMap { opening($0, kind: .window) }
                + room.openings.compactMap { opening($0, kind: .opening) },
            floors: room.floors.map(floorPolygon),
            objects: room.objects.map(object)
        )
    }

    static func floorPlan(from structure: CapturedStructure) -> FloorPlan {
        FloorPlan(
            walls: structure.walls.compactMap(wall),
            openings: structure.doors.compactMap { opening($0, kind: .door) }
                + structure.windows.compactMap { opening($0, kind: .window) }
                + structure.openings.compactMap { opening($0, kind: .opening) },
            floors: structure.floors.map(floorPolygon),
            objects: structure.objects.map(object)
        )
    }

    private static func wall(_ surface: CapturedRoom.Surface) -> WallSegment? {
        guard surface.dimensions.x > 0.01, surface.dimensions.y > 0.01 else { return nil }
        let pose = pose(from: surface.transform)
        return FloorPlanGeometry.wall(
            center: pose.translation,
            axisX: pose.axisX,
            width: Double(surface.dimensions.x),
            height: Double(surface.dimensions.y),
            thickness: Double(max(surface.dimensions.z, 0.02)),
            id: surface.identifier,
            confidence: confidence(surface.confidence)
        )
    }

    private static func opening(_ surface: CapturedRoom.Surface, kind: OpeningKind) -> Opening? {
        guard surface.dimensions.x > 0.01, surface.dimensions.y > 0.01 else { return nil }
        let pose = pose(from: surface.transform)
        return Opening(
            id: surface.identifier,
            kind: kind,
            center: pose.translation,
            width: Double(surface.dimensions.x),
            height: Double(surface.dimensions.y),
            yaw: FloorPlanGeometry.yaw(axisX: pose.axisX),
            confidence: confidence(surface.confidence)
        )
    }

    private static func floorPolygon(_ surface: CapturedRoom.Surface) -> FloorPolygon {
        let pose = pose(from: surface.transform)
        let corners: [Vec3]
        if surface.polygonCorners.count >= 3 {
            corners = surface.polygonCorners.map { pose.applying(vec($0)) }
        } else {
            corners = FloorPlanGeometry.rectangleCorners(
                width: Double(surface.dimensions.x),
                height: Double(surface.dimensions.y),
                transform: pose
            )
        }
        return FloorPolygon(id: surface.identifier, corners: corners)
    }

    private static func object(_ object: CapturedRoom.Object) -> PlacedObject {
        let pose = pose(from: object.transform)
        return PlacedObject(
            id: object.identifier,
            category: categoryName(object.category),
            center: pose.translation,
            dimensions: Vec3(
                x: Double(object.dimensions.x),
                y: Double(object.dimensions.y),
                z: Double(object.dimensions.z)
            ),
            yaw: FloorPlanGeometry.yaw(axisX: pose.axisX),
            confidence: confidence(object.confidence)
        )
    }

    private static func pose(from matrix: simd_float4x4) -> Transform {
        Transform(
            axisX: vec(matrix.columns.0),
            axisY: vec(matrix.columns.1),
            axisZ: vec(matrix.columns.2),
            translation: vec(matrix.columns.3)
        )
    }

    private static func vec(_ value: simd_float4) -> Vec3 {
        Vec3(x: Double(value.x), y: Double(value.y), z: Double(value.z))
    }

    private static func vec(_ value: simd_float3) -> Vec3 {
        Vec3(x: Double(value.x), y: Double(value.y), z: Double(value.z))
    }

    private static func confidence(_ value: CapturedRoom.Confidence) -> ScanConfidence {
        switch value {
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        @unknown default: return .low
        }
    }

    private static func categoryName(_ category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage: return "storage"
        case .refrigerator: return "refrigerator"
        case .stove: return "stove"
        case .bed: return "bed"
        case .sink: return "sink"
        case .washerDryer: return "washer_dryer"
        case .toilet: return "toilet"
        case .bathtub: return "bathtub"
        case .oven: return "oven"
        case .dishwasher: return "dishwasher"
        case .table: return "table"
        case .sofa: return "sofa"
        case .chair: return "chair"
        case .fireplace: return "fireplace"
        case .television: return "television"
        case .stairs: return "stairs"
        @unknown default: return "unknown"
        }
    }
}
