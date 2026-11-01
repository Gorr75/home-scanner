import Foundation

public struct ImagePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Camera-to-world transform captured with an in-app photo.
/// `columns` is a column-major 4×4 matrix. Intrinsics match the stored image.
public struct ScanCameraPose: Codable, Equatable, Sendable {
    public var columns: [Double]
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var imageWidth: Double
    public var imageHeight: Double
    /// True when the pose shares the scan's coordinate space.
    public var matchesScan: Bool

    public init(
        columns: [Double],
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double,
        imageWidth: Double,
        imageHeight: Double,
        matchesScan: Bool
    ) {
        self.columns = columns
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.matchesScan = matchesScan
    }
}

public enum TexturedSurfaceKind: String, Codable, Equatable, Sendable {
    case wall
    case floor
}

/// A photo projected onto one wall or floor. Image bytes live beside the home, not in `home.json`.
public struct SurfaceTexture: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var surfaceId: UUID
    public var kind: TexturedSurfaceKind
    /// Path relative to the home folder, for example `textures/<id>.jpg`.
    public var imagePath: String
    /// Image points, origin top-left, order: bottom-left, bottom-right, top-right, top-left of the surface.
    public var corners: [ImagePoint]
    public var pose: ScanCameraPose?

    public init(
        id: UUID,
        surfaceId: UUID,
        kind: TexturedSurfaceKind,
        imagePath: String,
        corners: [ImagePoint],
        pose: ScanCameraPose? = nil
    ) {
        self.id = id
        self.surfaceId = surfaceId
        self.kind = kind
        self.imagePath = imagePath
        self.corners = corners
        self.pose = pose
    }
}

public struct TextureLibrary: Codable, Equatable, Sendable {
    public var photos: [SurfaceTexture]

    public init(photos: [SurfaceTexture] = []) {
        self.photos = photos
    }

    public static let empty = TextureLibrary()

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TextureLibrary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TextureLibrary.self, from: data)
    }

    public func photo(for surfaceId: UUID) -> SurfaceTexture? {
        photos.first { $0.surfaceId == surfaceId }
    }
}

/// JPEG bytes plus the corner fit, ready to bake into a model.
public struct AppliedTexture: Equatable, Sendable {
    public var surfaceId: UUID
    public var jpeg: Data
    public var corners: [ImagePoint]

    public init(surfaceId: UUID, jpeg: Data, corners: [ImagePoint]) {
        self.surfaceId = surfaceId
        self.jpeg = jpeg
        self.corners = corners
    }
}

struct Mat4: Equatable {
    var m: [Double]

    static let identity = Mat4(m: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    ])

    func multiplyPoint(_ point: Vec3) -> Vec3 {
        let x = m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12]
        let y = m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13]
        let z = m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14]
        let w = m[3] * point.x + m[7] * point.y + m[11] * point.z + m[15]
        let scale = abs(w) < 1e-12 ? 1 : w
        return Vec3(x: x / scale, y: y / scale, z: z / scale)
    }

    func inverse() -> Mat4? {
        var a = m
        var inv = Mat4.identity.m
        for col in 0..<4 {
            var pivot = col
            var maxAbs = abs(a[col * 4 + col])
            if col + 1 < 4 {
                for row in (col + 1)..<4 {
                    let value = abs(a[col * 4 + row])
                    if value > maxAbs {
                        maxAbs = value
                        pivot = row
                    }
                }
            }
            if maxAbs < 1e-10 { return nil }
            if pivot != col {
                for column in 0..<4 {
                    a.swapAt(column * 4 + col, column * 4 + pivot)
                    inv.swapAt(column * 4 + col, column * 4 + pivot)
                }
            }
            let diagonal = a[col * 4 + col]
            for column in 0..<4 {
                a[column * 4 + col] /= diagonal
                inv[column * 4 + col] /= diagonal
            }
            for row in 0..<4 where row != col {
                let factor = a[col * 4 + row]
                for column in 0..<4 {
                    a[column * 4 + row] -= factor * a[column * 4 + col]
                    inv[column * 4 + row] -= factor * inv[column * 4 + col]
                }
            }
        }
        return Mat4(m: inv)
    }
}

public enum SurfaceFrame {
    /// Bottom-left, bottom-right, top-right, top-left. Shifted a centimeter off the wall so a texture sits on the face.
    public static func wallCorners(_ wall: WallSegment, offset: Vec3 = .zero, lift: Double = 0.02) -> [Vec3] {
        let start = Vec3(x: wall.start.x + offset.x, y: wall.start.y, z: wall.start.z + offset.z)
        let end = Vec3(x: wall.end.x + offset.x, y: wall.end.y, z: wall.end.z + offset.z)
        let up = Vec3(x: 0, y: wall.height, z: 0)
        let corners = [start, end, end + up, start + up]
        let normal = faceNormal(corners)
        return corners.map { $0 + normal.scaled(lift) }
    }

    public static func floorCorners(_ floor: FloorPolygon, offset: Vec3 = .zero, lift: Double = 0.02) -> [Vec3] {
        let raw: [Vec3]
        if floor.corners.count == 4 {
            raw = floor.corners.map { Vec3(x: $0.x + offset.x, y: $0.y, z: $0.z + offset.z) }
        } else if floor.corners.count >= 3 {
            let shifted = floor.corners.map { Vec3(x: $0.x + offset.x, y: $0.y, z: $0.z + offset.z) }
            let minX = shifted.map(\.x).min() ?? 0
            let maxX = shifted.map(\.x).max() ?? 0
            let minZ = shifted.map(\.z).min() ?? 0
            let maxZ = shifted.map(\.z).max() ?? 0
            let y = shifted.map(\.y).reduce(0, +) / Double(shifted.count)
            raw = [
                Vec3(x: minX, y: y, z: maxZ),
                Vec3(x: maxX, y: y, z: maxZ),
                Vec3(x: maxX, y: y, z: minZ),
                Vec3(x: minX, y: y, z: minZ)
            ]
        } else {
            raw = []
        }
        guard raw.count == 4 else { return raw }
        let normal = Vec3(x: 0, y: 1, z: 0)
        return raw.map { $0 + normal.scaled(lift) }
    }

    public static func faceNormal(_ corners: [Vec3]) -> Vec3 {
        guard corners.count >= 3 else { return Vec3(x: 0, y: 1, z: 0) }
        let edgeU = corners[1] - corners[0]
        let edgeV = corners[corners.count - 1] - corners[0]
        let crossed = Vec3(
            x: edgeU.y * edgeV.z - edgeU.z * edgeV.y,
            y: edgeU.z * edgeV.x - edgeU.x * edgeV.z,
            z: edgeU.x * edgeV.y - edgeU.y * edgeV.x
        )
        return crossed.normalized(fallback: Vec3(x: 0, y: 1, z: 0))
    }
}

public struct TextureTarget: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: TexturedSurfaceKind
    public var title: String
    public var aspect: Double

    public init(id: UUID, kind: TexturedSurfaceKind, title: String, aspect: Double) {
        self.id = id
        self.kind = kind
        self.title = title
        self.aspect = aspect
    }
}

public enum TextureProjection {
    public static func fullFrameCorners() -> [ImagePoint] {
        [
            ImagePoint(x: 0, y: 1),
            ImagePoint(x: 1, y: 1),
            ImagePoint(x: 1, y: 0),
            ImagePoint(x: 0, y: 0)
        ]
    }

    public static func targets(in plan: FloorPlan) -> [TextureTarget] {
        var items: [TextureTarget] = []
        for (index, wall) in plan.walls.enumerated() where wall.length > 0.05 {
            let aspect = wall.height > 0.05 ? wall.length / wall.height : 1
            items.append(TextureTarget(
                id: wall.id,
                kind: .wall,
                title: "Wall \(index + 1) · \(ObjectLabels.meters(wall.length)) m",
                aspect: aspect
            ))
        }
        for (index, floor) in plan.floors.enumerated() {
            let corners = SurfaceFrame.floorCorners(floor, lift: 0)
            let width = corners.isEmpty ? 1 : (corners.map(\.x).max() ?? 0) - (corners.map(\.x).min() ?? 0)
            let depth = corners.isEmpty ? 1 : (corners.map(\.z).max() ?? 0) - (corners.map(\.z).min() ?? 0)
            let aspect = depth > 0.05 ? width / depth : 1
            items.append(TextureTarget(
                id: floor.id,
                kind: .floor,
                title: "Floor \(index + 1)",
                aspect: aspect
            ))
        }
        return items
    }

    /// Projects a world point into normalized image coordinates, origin top-left.
    public static func project(_ world: Vec3, pose: ScanCameraPose) -> ImagePoint? {
        guard pose.columns.count == 16, pose.imageWidth > 1, pose.imageHeight > 1 else { return nil }
        guard let worldToCamera = Mat4(m: pose.columns).inverse() else { return nil }
        let camera = worldToCamera.multiplyPoint(world)
        let depth = -camera.z
        guard depth > 0.05 else { return nil }
        let pixelX = pose.fx * (camera.x / depth) + pose.cx
        let pixelY = pose.cy - pose.fy * (camera.y / depth)
        return ImagePoint(x: pixelX / pose.imageWidth, y: pixelY / pose.imageHeight)
    }

    public static func suggestCorners(wall: WallSegment, pose: ScanCameraPose) -> [ImagePoint]? {
        let corners = SurfaceFrame.wallCorners(wall, lift: 0)
        return suggest(corners: corners, pose: pose)
    }

    public static func suggestCorners(floor: FloorPolygon, pose: ScanCameraPose) -> [ImagePoint]? {
        let corners = SurfaceFrame.floorCorners(floor, lift: 0)
        guard corners.count == 4 else { return nil }
        return suggest(corners: corners, pose: pose)
    }

    public static func bestTarget(in plan: FloorPlan, pose: ScanCameraPose) -> UUID? {
        let forward = cameraForward(pose)
        if let forward, forward.y < -0.45 {
            return plan.floors.max { lhs, rhs in
                floorArea(lhs) < floorArea(rhs)
            }?.id
        }
        var best: (UUID, Double)?
        for wall in plan.walls {
            guard let corners = suggestCorners(wall: wall, pose: pose) else { continue }
            let score = visibleArea(corners)
            guard score > 0.02 else { continue }
            if best == nil || score > best!.1 {
                best = (wall.id, score)
            }
        }
        return best?.0
    }

    public static func bestTarget(in plan: FloorPlan, imageAspect: Double) -> UUID? {
        let items = targets(in: plan).filter { $0.kind == .wall }
        let pool = items.isEmpty ? targets(in: plan) : items
        return pool.min { lhs, rhs in
            aspectDistance(lhs.aspect, imageAspect) < aspectDistance(rhs.aspect, imageAspect)
        }?.id
    }

    /// Greedy one-photo-per-surface assignment for frames captured during the scan.
    public static func assign(photos: [(id: UUID, pose: ScanCameraPose)], plan: FloorPlan) -> [UUID: UUID] {
        var pairs: [(photo: UUID, surface: UUID, score: Double)] = []
        for photo in photos where photo.pose.matchesScan {
            for wall in plan.walls {
                guard let corners = suggestCorners(wall: wall, pose: photo.pose) else { continue }
                let score = visibleArea(corners)
                if score > 0.04 {
                    pairs.append((photo.id, wall.id, score))
                }
            }
        }
        pairs.sort { $0.score > $1.score }
        var usedPhotos: Set<UUID> = []
        var usedSurfaces: Set<UUID> = []
        var result: [UUID: UUID] = [:]
        for pair in pairs where !usedPhotos.contains(pair.photo) && !usedSurfaces.contains(pair.surface) {
            result[pair.photo] = pair.surface
            usedPhotos.insert(pair.photo)
            usedSurfaces.insert(pair.surface)
        }
        return result
    }

    private static func suggest(corners: [Vec3], pose: ScanCameraPose) -> [ImagePoint]? {
        var projected: [ImagePoint] = []
        for corner in corners {
            guard let point = project(corner, pose: pose) else { return nil }
            projected.append(point)
        }
        guard projected.count == 4 else { return nil }
        return projected
    }

    private static func visibleArea(_ corners: [ImagePoint]) -> Double {
        guard corners.count == 4 else { return 0 }
        let inside = corners.allSatisfy { point in
            point.x >= -0.02 && point.x <= 1.02 && point.y >= -0.02 && point.y <= 1.02
        }
        guard inside else { return 0 }
        return abs(quadArea(corners))
    }

    private static func quadArea(_ corners: [ImagePoint]) -> Double {
        var sum = 0.0
        for index in corners.indices {
            let next = corners[(index + 1) % corners.count]
            sum += corners[index].x * next.y - next.x * corners[index].y
        }
        return sum / 2
    }

    private static func floorArea(_ floor: FloorPolygon) -> Double {
        MeasurementMath.polygonArea(floor.corners)
    }

    private static func aspectDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let left = max(lhs, 0.05)
        let right = max(rhs, 0.05)
        return abs(left - right)
    }

    private static func cameraForward(_ pose: ScanCameraPose) -> Vec3? {
        guard pose.columns.count == 16 else { return nil }
        let columns = pose.columns
        // Camera +Z in world is columns 8,9,10. The camera looks down -Z.
        return Vec3(x: -columns[8], y: -columns[9], z: -columns[10]).normalized()
    }
}
