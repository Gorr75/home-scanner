import Foundation

/// Snaps a tap to a wall corner or a wall or floor edge. Points farther than `threshold` stay put.
public enum MeasureSnap {
    public static let threshold = 0.30

    public static func point(_ raw: Vec3, in plan: FloorPlan, threshold: Double = MeasureSnap.threshold) -> Vec3 {
        var bestCorner: (point: Vec3, distance: Double)?
        var bestEdge: (point: Vec3, distance: Double)?
        func considerCorner(_ candidate: Vec3) {
            let distance = (candidate - raw).length
            if bestCorner == nil || distance < bestCorner!.distance - 1e-9 {
                bestCorner = (candidate, distance)
            }
        }
        func considerEdge(_ candidate: Vec3) {
            let distance = (candidate - raw).length
            if bestEdge == nil || distance < bestEdge!.distance - 1e-9 {
                bestEdge = (candidate, distance)
            }
        }
        for wall in plan.walls {
            let height = max(wall.height, 0)
            let bottomStart = wall.start
            let bottomEnd = wall.end
            let topStart = Vec3(x: wall.start.x, y: wall.start.y + height, z: wall.start.z)
            let topEnd = Vec3(x: wall.end.x, y: wall.end.y + height, z: wall.end.z)
            for corner in [bottomStart, bottomEnd, topStart, topEnd] {
                considerCorner(corner)
            }
            for (start, end) in [(bottomStart, bottomEnd), (topStart, topEnd), (bottomStart, topStart), (bottomEnd, topEnd)] {
                considerEdge(closest(raw, segmentStart: start, segmentEnd: end))
            }
        }
        for floor in plan.floors where floor.corners.count >= 2 {
            for corner in floor.corners {
                considerCorner(corner)
            }
            for index in floor.corners.indices {
                let start = floor.corners[index]
                let end = floor.corners[(index + 1) % floor.corners.count]
                considerEdge(closest(raw, segmentStart: start, segmentEnd: end))
            }
        }
        if let bestCorner, bestCorner.distance <= threshold {
            return bestCorner.point
        }
        if let bestEdge, bestEdge.distance <= threshold {
            return bestEdge.point
        }
        return raw
    }

    public static func label(from start: Vec3, to end: Vec3) -> String {
        "\(ObjectLabels.meters((end - start).length)) m"
    }

    static func closest(_ point: Vec3, segmentStart: Vec3, segmentEnd: Vec3) -> Vec3 {
        let span = segmentEnd - segmentStart
        let lengthSquared = span.dot(span)
        guard lengthSquared > 1e-12 else { return segmentStart }
        let t = min(1, max(0, (point - segmentStart).dot(span) / lengthSquared))
        return segmentStart + span.scaled(t)
    }
}
