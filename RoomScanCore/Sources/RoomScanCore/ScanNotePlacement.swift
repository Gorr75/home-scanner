import Foundation

/// Maps a camera pose captured during a scan into the room after RoomPlan finishes.
/// `columns` is the column-major camera-to-world matrix from that session, the same
/// layout as `ScanCameraPose`. The note lands on the wall, floor, or object the camera faced.
public enum ScanNotePlacement {
    public static func position(columns: [Double], plan: FloorPlan, reach: Double = 6) -> Vec3? {
        guard columns.count == 16 else { return nil }
        let origin = Vec3(x: columns[12], y: columns[13], z: columns[14])
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite else { return nil }
        let forward = Vec3(x: -columns[8], y: -columns[9], z: -columns[10])
        let direction = forward.normalized(fallback: Vec3(x: 0, y: 0, z: -1))
        var best: (t: Double, point: Vec3)?
        func consider(_ hit: (t: Double, point: Vec3)?) {
            guard let hit, hit.t > 0.05, hit.t <= reach else { return }
            if best == nil || hit.t < best!.t {
                best = hit
            }
        }
        for wall in plan.walls {
            consider(wallHit(origin: origin, direction: direction, wall: wall))
        }
        for floor in plan.floors {
            consider(floorHit(origin: origin, direction: direction, floor: floor))
        }
        for object in plan.objects {
            consider(objectHit(origin: origin, direction: direction, object: object))
        }
        if let best { return best.point }
        let dropped = origin + direction.scaled(0.8)
        return Vec3(x: dropped.x, y: max(0, dropped.y), z: dropped.z)
    }

    static func wallHit(origin: Vec3, direction: Vec3, wall: WallSegment) -> (t: Double, point: Vec3)? {
        let along = Vec3(x: wall.end.x - wall.start.x, y: 0, z: wall.end.z - wall.start.z)
        let length = along.horizontalLength
        guard length > 1e-4 else { return nil }
        let axis = along.normalized()
        let normal = Vec3(x: -axis.z, y: 0, z: axis.x)
        let denominator = normal.dot(direction)
        guard abs(denominator) > 1e-6 else { return nil }
        let t = normal.dot(wall.start - origin) / denominator
        guard t > 0 else { return nil }
        let point = origin + direction.scaled(t)
        let relative = Vec3(x: point.x - wall.start.x, y: 0, z: point.z - wall.start.z)
        let alongDistance = relative.dot(axis)
        guard alongDistance >= -0.08, alongDistance <= length + 0.08 else { return nil }
        let base = min(wall.start.y, wall.end.y)
        guard point.y >= base - 0.08, point.y <= base + max(wall.height, 0) + 0.08 else { return nil }
        return (t, point)
    }

    static func floorHit(origin: Vec3, direction: Vec3, floor: FloorPolygon) -> (t: Double, point: Vec3)? {
        guard floor.corners.count >= 3, abs(direction.y) > 1e-6 else { return nil }
        let y = floor.corners.reduce(0) { $0 + $1.y } / Double(floor.corners.count)
        let t = (y - origin.y) / direction.y
        guard t > 0 else { return nil }
        let point = origin + direction.scaled(t)
        guard contains(point, polygon: floor.corners) else { return nil }
        return (t, point)
    }

    static func objectHit(origin: Vec3, direction: Vec3, object: PlacedObject) -> (t: Double, point: Vec3)? {
        let cosine = Trig.cos(-object.yaw)
        let sine = Trig.sin(-object.yaw)
        let delta = origin - object.center
        let localOrigin = Vec3(
            x: delta.x * cosine - delta.z * sine,
            y: delta.y,
            z: delta.x * sine + delta.z * cosine
        )
        let localDirection = Vec3(
            x: direction.x * cosine - direction.z * sine,
            y: direction.y,
            z: direction.x * sine + direction.z * cosine
        )
        let half = Vec3(
            x: max(object.dimensions.x, 0.02) / 2,
            y: max(object.dimensions.y, 0.02) / 2,
            z: max(object.dimensions.z, 0.02) / 2
        )
        guard let t = rayBox(origin: localOrigin, direction: localDirection, half: half) else { return nil }
        return (t, origin + direction.scaled(t))
    }

    private static func rayBox(origin: Vec3, direction: Vec3, half: Vec3) -> Double? {
        var near = 0.0
        var far = Double.greatestFiniteMagnitude
        let bounds = [(-half.x, half.x, origin.x, direction.x), (-half.y, half.y, origin.y, direction.y), (-half.z, half.z, origin.z, direction.z)]
        for (minimum, maximum, start, component) in bounds {
            if abs(component) < 1e-8 {
                if start < minimum || start > maximum { return nil }
                continue
            }
            var t1 = (minimum - start) / component
            var t2 = (maximum - start) / component
            if t1 > t2 { swap(&t1, &t2) }
            near = max(near, t1)
            far = min(far, t2)
            if near > far { return nil }
        }
        if near > 0.05 { return near }
        if far > 0.05 { return far }
        return nil
    }

    private static func contains(_ point: Vec3, polygon: [Vec3]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for corner in polygon {
            let crosses = (corner.z > point.z) != (previous.z > point.z)
            if crosses {
                let x = (previous.x - corner.x) * (point.z - corner.z) / (previous.z - corner.z) + corner.x
                if point.x < x { inside.toggle() }
            }
            previous = corner
        }
        return inside
    }
}
