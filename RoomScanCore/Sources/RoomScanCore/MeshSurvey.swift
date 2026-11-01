import Foundation

/// Ground and facade measurements taken from one outdoor LiDAR mesh.
public struct MeshSurvey: Equatable, Sendable {
    public var ground: TriangleMesh
    /// Convex hull of the vertical faces, on the ground plane.
    public var buildingFootprint: [Vec3]
    public var walls: [WallSegment]

    public init(ground: TriangleMesh, buildingFootprint: [Vec3], walls: [WallSegment]) {
        self.ground = ground
        self.buildingFootprint = buildingFootprint
        self.walls = walls
    }
}

public enum MeshSurveyor {
    /// Splits a mesh into terrain (upward faces near the lowest band) and facade walls.
    /// Walls are the dominant vertical planes. The footprint is the hull of those planes.
    public static func analyze(_ mesh: TriangleMesh) -> MeshSurvey {
        guard let minY = mesh.vertices.map(\.y).min() else {
            return MeshSurvey(ground: TriangleMesh(vertices: [], faces: []), buildingFootprint: [], walls: [])
        }
        var groundFaces: [MeshFace] = []
        var vertical: [VerticalFace] = []
        for face in mesh.faces {
            guard let normal = normal(of: face, in: mesh) else { continue }
            if normal.y > 0.75 {
                let lowest = min(mesh.vertices[face.a].y, mesh.vertices[face.b].y, mesh.vertices[face.c].y)
                if lowest <= minY + 0.45 {
                    groundFaces.append(face)
                }
                continue
            }
            guard abs(normal.y) < 0.35 else { continue }
            let horizontal = Vec3(x: normal.x, y: 0, z: normal.z)
            let flat = horizontal.length
            guard flat > 0.5 else { continue }
            let unit = horizontal.scaled(1 / flat)
            let centroid = centroid(of: face, in: mesh)
            vertical.append(VerticalFace(
                face: face,
                normal: unit,
                offset: unit.x * centroid.x + unit.z * centroid.z,
                area: area(of: face, in: mesh),
                angle: Trig.atan2(unit.z, unit.x)
            ))
        }
        let ground = compact(mesh, faces: groundFaces)
        let walls = fitWalls(vertical, mesh: mesh)
        let footprint = hull(of: vertical, mesh: mesh)
        return MeshSurvey(ground: ground, buildingFootprint: footprint, walls: walls)
    }

    private struct VerticalFace {
        var face: MeshFace
        var normal: Vec3
        var offset: Double
        var area: Double
        var angle: Double
    }

    private struct Cluster {
        var normal: Vec3
        var offset: Double
        var area: Double
        var faces: [MeshFace]
    }

    private static func fitWalls(_ faces: [VerticalFace], mesh: TriangleMesh) -> [WallSegment] {
        var clusters: [Cluster] = []
        for face in faces {
            if let index = clusters.firstIndex(where: { cluster in
                let turn = Trig.atan2(Trig.sin(face.angle - angle(of: cluster.normal)), Trig.cos(face.angle - angle(of: cluster.normal)))
                return abs(turn) < 12 * Double.pi / 180 && abs(face.offset - cluster.offset) < 0.4
            }) {
                let count = Double(clusters[index].faces.count)
                let normal = (clusters[index].normal.scaled(count) + face.normal).scaled(1 / (count + 1))
                let flat = normal.horizontalLength
                clusters[index].normal = flat > 1e-6 ? normal.scaled(1 / flat) : face.normal
                clusters[index].offset = (clusters[index].offset * count + face.offset) / (count + 1)
                clusters[index].area += face.area
                clusters[index].faces.append(face.face)
            } else {
                clusters.append(Cluster(normal: face.normal, offset: face.offset, area: face.area, faces: [face.face]))
            }
        }
        return clusters
            .filter { $0.area >= 0.25 }
            .sorted { $0.area > $1.area }
            .prefix(6)
            .compactMap { wall(from: $0, mesh: mesh) }
    }

    private static func wall(from cluster: Cluster, mesh: TriangleMesh) -> WallSegment? {
        var indices = Set<Int>()
        for face in cluster.faces {
            indices.insert(face.a)
            indices.insert(face.b)
            indices.insert(face.c)
        }
        let points = indices.compactMap { index -> Vec3? in
            guard mesh.vertices.indices.contains(index) else { return nil }
            return mesh.vertices[index]
        }
        guard points.count >= 3, let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let axis = Vec3(x: -cluster.normal.z, y: 0, z: cluster.normal.x)
        guard axis.horizontalLength > 0.5 else { return nil }
        let direction = axis.scaled(1 / axis.horizontalLength)
        let along = points.map { $0.x * direction.x + $0.z * direction.z }
        guard let minS = along.min(), let maxS = along.max(), maxS - minS >= 0.3, maxY - minY >= 0.3 else { return nil }
        let anchor = points[0]
        let anchorS = anchor.x * direction.x + anchor.z * direction.z
        let plane = cluster.normal.x * anchor.x + cluster.normal.z * anchor.z
        let correction = cluster.offset - plane
        let base = Vec3(
            x: anchor.x + cluster.normal.x * correction,
            y: minY,
            z: anchor.z + cluster.normal.z * correction
        )
        let start = Vec3(x: base.x + direction.x * (minS - anchorS), y: minY, z: base.z + direction.z * (minS - anchorS))
        let end = Vec3(x: base.x + direction.x * (maxS - anchorS), y: minY, z: base.z + direction.z * (maxS - anchorS))
        return WallSegment(
            id: UUID(),
            start: start,
            end: end,
            height: maxY - minY,
            thickness: 0.15,
            confidence: .medium
        )
    }

    private static func hull(of faces: [VerticalFace], mesh: TriangleMesh) -> [Vec3] {
        var points: [Vec3] = []
        var seen = Set<Int>()
        for face in faces {
            for index in [face.face.a, face.face.b, face.face.c] where seen.insert(index).inserted {
                guard mesh.vertices.indices.contains(index) else { continue }
                let vertex = mesh.vertices[index]
                points.append(Vec3(x: (vertex.x * 100).rounded() / 100, y: 0, z: (vertex.z * 100).rounded() / 100))
            }
        }
        return convexHull(points)
    }

    private static func convexHull(_ points: [Vec3]) -> [Vec3] {
        var seen: [HullPoint: Bool] = [:]
        var unique: [HullPoint] = []
        for point in points {
            let key = HullPoint(x: point.x, z: point.z)
            if seen[key] == nil {
                seen[key] = true
                unique.append(key)
            }
        }
        unique.sort { lhs, rhs in
            if lhs.x == rhs.x { return lhs.z < rhs.z }
            return lhs.x < rhs.x
        }
        guard unique.count >= 3 else {
            return unique.map { Vec3(x: $0.x, y: 0, z: $0.z) }
        }
        func turn(_ o: HullPoint, _ a: HullPoint, _ b: HullPoint) -> Double {
            (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
        }
        var lower: [HullPoint] = []
        for point in unique {
            while lower.count >= 2 && turn(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [HullPoint] = []
        for point in unique.reversed() {
            while upper.count >= 2 && turn(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return (lower + upper).map { Vec3(x: $0.x, y: 0, z: $0.z) }
    }

    private struct HullPoint: Hashable {
        var x: Double
        var z: Double
    }

    private static func compact(_ mesh: TriangleMesh, faces: [MeshFace]) -> TriangleMesh {
        var remap = Array(repeating: -1, count: mesh.vertices.count)
        var vertices: [Vec3] = []
        var kept: [MeshFace] = []
        for face in faces {
            let corners = [face.a, face.b, face.c].map { index -> Int in
                if remap[index] == -1 {
                    remap[index] = vertices.count
                    vertices.append(mesh.vertices[index])
                }
                return remap[index]
            }
            kept.append(MeshFace(a: corners[0], b: corners[1], c: corners[2]))
        }
        return TriangleMesh(vertices: vertices, faces: kept)
    }

    private static func normal(of face: MeshFace, in mesh: TriangleMesh) -> Vec3? {
        guard mesh.vertices.indices.contains(face.a),
              mesh.vertices.indices.contains(face.b),
              mesh.vertices.indices.contains(face.c)
        else { return nil }
        let ab = mesh.vertices[face.b] - mesh.vertices[face.a]
        let ac = mesh.vertices[face.c] - mesh.vertices[face.a]
        let cross = Vec3(
            x: ab.y * ac.z - ab.z * ac.y,
            y: ab.z * ac.x - ab.x * ac.z,
            z: ab.x * ac.y - ab.y * ac.x
        )
        let length = cross.length
        guard length > 1e-8 else { return nil }
        return cross.scaled(1 / length)
    }

    private static func centroid(of face: MeshFace, in mesh: TriangleMesh) -> Vec3 {
        (mesh.vertices[face.a] + mesh.vertices[face.b] + mesh.vertices[face.c]).scaled(1.0 / 3)
    }

    private static func area(of face: MeshFace, in mesh: TriangleMesh) -> Double {
        let ab = mesh.vertices[face.b] - mesh.vertices[face.a]
        let ac = mesh.vertices[face.c] - mesh.vertices[face.a]
        let cross = Vec3(
            x: ab.y * ac.z - ab.z * ac.y,
            y: ab.z * ac.x - ab.x * ac.z,
            z: ab.x * ac.y - ab.y * ac.x
        )
        return cross.length / 2
    }

    private static func angle(of normal: Vec3) -> Double {
        Trig.atan2(normal.z, normal.x)
    }
}
