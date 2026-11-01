import Foundation

/// What an outdoor LiDAR mesh is of. The sensor's useful range is about 5 meters.
public enum OutdoorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case facade
    case patio
    case shed
    case yard
    case other

    public var label: String {
        switch self {
        case .facade: return "Facade"
        case .patio: return "Patio"
        case .shed: return "Shed"
        case .yard: return "Yard"
        case .other: return "Other"
        }
    }
}

public struct OutdoorAssets: Codable, Equatable, Sendable {
    /// Wavefront OBJ of the whole clipped mesh, relative to the home folder.
    public var obj: String?
    /// Upward faces near the ground, when the mesh had a terrain band.
    public var terrain: String?

    public init(obj: String? = nil, terrain: String? = nil) {
        self.obj = obj
        self.terrain = terrain
    }
}

/// A facade, patio, shed, or yard scanned with a generic LiDAR mesh, not RoomPlan.
public struct OutdoorZone: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: OutdoorKind
    public var createdAt: Date
    /// Ground rectangle in this zone's scan space. Four corners, Y is 0.
    public var footprint: [Vec3]
    /// Highest vertex above the footprint, in meters.
    @Quantized public var height: Double
    public var meshVertexCount: Int
    public var assets: OutdoorAssets
    /// Convex hull of the vertical faces, in this zone's scan space. Empty when no facade was found.
    public var buildingFootprint: [Vec3]
    public var groundVertexCount: Int
    /// Facade planes. Each wall can carry the same `texture` object as an indoor wall.
    public var walls: [WallSegment]

    public init(
        id: UUID,
        name: String,
        kind: OutdoorKind,
        createdAt: Date,
        footprint: [Vec3],
        height: Double,
        meshVertexCount: Int,
        assets: OutdoorAssets = OutdoorAssets(),
        buildingFootprint: [Vec3] = [],
        groundVertexCount: Int = 0,
        walls: [WallSegment] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.footprint = footprint
        self.height = height
        self.meshVertexCount = meshVertexCount
        self.assets = assets
        self.buildingFootprint = buildingFootprint
        self.groundVertexCount = groundVertexCount
        self.walls = walls
    }
}

extension OutdoorZone {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case createdAt
        case footprint
        case height
        case meshVertexCount
        case assets
        case buildingFootprint
        case groundVertexCount
        case walls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(OutdoorKind.self, forKey: .kind)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        footprint = try container.decode([Vec3].self, forKey: .footprint)
        height = try container.decode(Double.self, forKey: .height)
        meshVertexCount = try container.decode(Int.self, forKey: .meshVertexCount)
        assets = try container.decode(OutdoorAssets.self, forKey: .assets)
        buildingFootprint = try container.decodeIfPresent([Vec3].self, forKey: .buildingFootprint) ?? []
        groundVertexCount = try container.decodeIfPresent(Int.self, forKey: .groundVertexCount) ?? 0
        walls = try container.decodeIfPresent([WallSegment].self, forKey: .walls) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(footprint, forKey: .footprint)
        try container.encode(Quantized(wrappedValue: height), forKey: .height)
        try container.encode(meshVertexCount, forKey: .meshVertexCount)
        try container.encode(assets, forKey: .assets)
        if !buildingFootprint.isEmpty {
            try container.encode(buildingFootprint, forKey: .buildingFootprint)
        }
        if groundVertexCount > 0 {
            try container.encode(groundVertexCount, forKey: .groundVertexCount)
        }
        if !walls.isEmpty {
            try container.encode(walls, forKey: .walls)
        }
    }
}

/// Where the underlay sits on the earth. Drawing uses meters; this is the georeference.
public struct Georeference: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Clockwise degrees from true north to the underlay image's +Z axis, before `yaw`.
    public var headingDegrees: Double

    public init(latitude: Double, longitude: Double, headingDegrees: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.headingDegrees = headingDegrees
    }
}

/// An aerial orthophoto or drone image, scaled into meters and placed on the site.
public struct SiteUnderlay: Codable, Equatable, Sendable {
    public var image: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    @Quantized public var widthMeters: Double
    @Quantized public var heightMeters: Double
    public var center: Vec3
    @Quantized public var yaw: Double
    public var georeference: Georeference?

    public init(
        image: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        widthMeters: Double,
        heightMeters: Double,
        center: Vec3 = .zero,
        yaw: Double = 0,
        georeference: Georeference? = nil
    ) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.center = center
        self.yaw = yaw
        self.georeference = georeference
    }

    public var metersPerPixel: Double {
        guard pixelWidth > 0 else { return 0 }
        return widthMeters / Double(pixelWidth)
    }
}

public enum SiteSubject: Equatable, Hashable, Sendable {
    case room(UUID)
    case outdoorZone(UUID)
}

extension SiteSubject: Codable {
    private enum Kind: String, Codable {
        case room
        case outdoorZone = "outdoor_zone"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let id = try container.decode(UUID.self, forKey: .id)
        switch kind {
        case .room:
            self = .room(id)
        case .outdoorZone:
            self = .outdoorZone(id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .room(let id):
            try container.encode(Kind.room, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .outdoorZone(let id):
            try container.encode(Kind.outdoorZone, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

/// Where a room floor plan or an outdoor zone sits on the site, in site meters.
public struct SitePlacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var subject: SiteSubject
    /// Image of the subject's local origin.
    public var origin: Vec3
    @Quantized public var yaw: Double

    public init(id: UUID = UUID(), subject: SiteSubject, origin: Vec3, yaw: Double = 0) {
        self.id = id
        self.subject = subject
        self.origin = origin
        self.yaw = yaw
    }
}

/// A drone or phone photo placed on the site from its GPS, and available as a facade texture.
public struct DroneOverlay: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var image: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Used when the photo or the underlay has no geographic position.
    public var center: Vec3
    @Quantized public var yaw: Double
    @Quantized public var widthMeters: Double
    @Quantized public var heightMeters: Double
    public var georeference: Georeference?
    public var altitudeMeters: Double?
    public var relativeAltitudeMeters: Double?
    public var focalLengthMillimeters: Double?
    public var focalLength35mm: Double?
    public var headingDegrees: Double?
    public var pitchDegrees: Double?
    public var note: String?

    public init(
        id: UUID = UUID(),
        image: String,
        pixelWidth: Int,
        pixelHeight: Int,
        center: Vec3,
        yaw: Double = 0,
        widthMeters: Double,
        heightMeters: Double,
        georeference: Georeference? = nil,
        altitudeMeters: Double? = nil,
        relativeAltitudeMeters: Double? = nil,
        focalLengthMillimeters: Double? = nil,
        focalLength35mm: Double? = nil,
        headingDegrees: Double? = nil,
        pitchDegrees: Double? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.center = center
        self.yaw = yaw
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.georeference = georeference
        self.altitudeMeters = altitudeMeters
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.focalLengthMillimeters = focalLengthMillimeters
        self.focalLength35mm = focalLength35mm
        self.headingDegrees = headingDegrees
        self.pitchDegrees = pitchDegrees
        self.note = note
    }
}

public struct Site: Codable, Equatable, Sendable {
    public var underlay: SiteUnderlay?
    public var placements: [SitePlacement]
    public var overlays: [DroneOverlay]

    public init(underlay: SiteUnderlay? = nil, placements: [SitePlacement] = [], overlays: [DroneOverlay] = []) {
        self.underlay = underlay
        self.placements = placements
        self.overlays = overlays
    }
}

extension Site {
    private enum CodingKeys: String, CodingKey {
        case underlay
        case placements
        case overlays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        underlay = try container.decodeIfPresent(SiteUnderlay.self, forKey: .underlay)
        placements = try container.decodeIfPresent([SitePlacement].self, forKey: .placements) ?? []
        overlays = try container.decodeIfPresent([DroneOverlay].self, forKey: .overlays) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(underlay, forKey: .underlay)
        try container.encode(placements, forKey: .placements)
        if !overlays.isEmpty {
            try container.encode(overlays, forKey: .overlays)
        }
    }
}

public struct MeshFace: Equatable, Sendable {
    public var a: Int
    public var b: Int
    public var c: Int

    public init(a: Int, b: Int, c: Int) {
        self.a = a
        self.b = b
        self.c = c
    }
}

public struct TriangleMesh: Equatable, Sendable {
    public var vertices: [Vec3]
    public var faces: [MeshFace]

    public init(vertices: [Vec3], faces: [MeshFace]) {
        self.vertices = vertices
        self.faces = faces
    }
}

public enum MeshRange {
    /// Practical range of the iPhone LiDAR sensor used for outdoor meshes.
    public static let lidarMeters: Double = 5

    /// Drops vertices farther than `range` meters from `origin`, and any triangle that used one.
    public static func clipped(
        _ mesh: TriangleMesh,
        origin: Vec3 = .zero,
        range: Double = lidarMeters
    ) -> TriangleMesh {
        let limit = range * range
        var remap = Array(repeating: -1, count: mesh.vertices.count)
        var vertices: [Vec3] = []
        for (index, vertex) in mesh.vertices.enumerated() {
            let delta = vertex - origin
            let distance = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
            guard distance <= limit else { continue }
            remap[index] = vertices.count
            vertices.append(vertex)
        }
        let faces = mesh.faces.compactMap { face -> MeshFace? in
            guard face.a >= 0, face.b >= 0, face.c >= 0,
                  face.a < remap.count, face.b < remap.count, face.c < remap.count
            else { return nil }
            let a = remap[face.a]
            let b = remap[face.b]
            let c = remap[face.c]
            guard a >= 0, b >= 0, c >= 0 else { return nil }
            return MeshFace(a: a, b: b, c: c)
        }
        return TriangleMesh(vertices: vertices, faces: faces)
    }

    /// Axis-aligned ground rectangle of the mesh, plus its height.
    public static func footprint(_ mesh: TriangleMesh) -> (corners: [Vec3], height: Double) {
        guard let first = mesh.vertices.first else {
            return (
                [
                    Vec3(x: 0, y: 0, z: 0),
                    Vec3(x: 1, y: 0, z: 0),
                    Vec3(x: 1, y: 0, z: 1),
                    Vec3(x: 0, y: 0, z: 1)
                ],
                1
            )
        }
        var minX = first.x
        var maxX = first.x
        var minZ = first.z
        var maxZ = first.z
        var minY = first.y
        var maxY = first.y
        for vertex in mesh.vertices.dropFirst() {
            minX = min(minX, vertex.x)
            maxX = max(maxX, vertex.x)
            minZ = min(minZ, vertex.z)
            maxZ = max(maxZ, vertex.z)
            minY = min(minY, vertex.y)
            maxY = max(maxY, vertex.y)
        }
        let corners = [
            Vec3(x: minX, y: 0, z: minZ),
            Vec3(x: maxX, y: 0, z: minZ),
            Vec3(x: maxX, y: 0, z: maxZ),
            Vec3(x: minX, y: 0, z: maxZ)
        ]
        return (corners, max(maxY - minY, 0))
    }
}

public enum MeshOBJ {
    public static func encode(_ mesh: TriangleMesh) -> String {
        var lines: [String] = ["# Home Scanner outdoor mesh", "o outdoor"]
        for vertex in mesh.vertices {
            let x = Vec3.quantize(vertex.x)
            let y = Vec3.quantize(vertex.y)
            let z = Vec3.quantize(vertex.z)
            lines.append("v \(decimal(x)) \(decimal(y)) \(decimal(z))")
        }
        for face in mesh.faces {
            lines.append("f \(face.a + 1) \(face.b + 1) \(face.c + 1)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func decode(_ text: String) -> TriangleMesh? {
        var vertices: [Vec3] = []
        var faces: [MeshFace] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("v ") {
                let parts = line.split(separator: " ")
                guard parts.count >= 4,
                      let x = Double(parts[1]),
                      let y = Double(parts[2]),
                      let z = Double(parts[3])
                else { return nil }
                vertices.append(Vec3(x: x, y: y, z: z))
            } else if line.hasPrefix("f ") {
                let parts = line.split(separator: " ").dropFirst()
                let indices = parts.compactMap { token -> Int? in
                    let head = token.split(separator: "/").first
                    guard let head, let value = Int(head), value > 0 else { return nil }
                    return value - 1
                }
                guard indices.count >= 3 else { return nil }
                faces.append(MeshFace(a: indices[0], b: indices[1], c: indices[2]))
            }
        }
        guard !vertices.isEmpty else { return nil }
        return TriangleMesh(vertices: vertices, faces: faces)
    }

    private static func decimal(_ value: Double) -> String {
        let quantized = Vec3.quantize(value)
        if quantized == 0 { return "0" }
        return String(quantized)
    }
}

public enum SiteLayout {
    public static func apply(_ point: Vec3, placement: SitePlacement) -> Vec3 {
        let cosine = Trig.cos(placement.yaw)
        let sine = Trig.sin(placement.yaw)
        return Vec3(
            x: placement.origin.x + point.x * cosine - point.z * sine,
            y: placement.origin.y + point.y,
            z: placement.origin.z + point.x * sine + point.z * cosine
        )
    }

    public static func roomFootprint(_ room: Room) -> [Vec3] {
        let box = FloorPlanGeometry.bounds(of: room.floorPlan)
        return [
            Vec3(x: box.min.x, y: 0, z: box.min.z),
            Vec3(x: box.max.x, y: 0, z: box.min.z),
            Vec3(x: box.max.x, y: 0, z: box.max.z),
            Vec3(x: box.min.x, y: 0, z: box.max.z)
        ]
    }

    public static func underlayCorners(_ underlay: SiteUnderlay) -> [Vec3] {
        let halfWidth = underlay.widthMeters / 2
        let halfHeight = underlay.heightMeters / 2
        let local = [
            Vec3(x: -halfWidth, y: 0, z: -halfHeight),
            Vec3(x: halfWidth, y: 0, z: -halfHeight),
            Vec3(x: halfWidth, y: 0, z: halfHeight),
            Vec3(x: -halfWidth, y: 0, z: halfHeight)
        ]
        let placement = SitePlacement(subject: .room(UUID()), origin: underlay.center, yaw: underlay.yaw)
        return local.map { apply($0, placement: placement) }
    }

    /// Lays rooms and outdoor zones in a row, each in its own scan space, centered on the origin.
    public static func defaultPlacements(rooms: [Room], zones: [OutdoorZone], gap: Double = 1) -> [SitePlacement] {
        struct Item {
            var subject: SiteSubject
            var corners: [Vec3]
        }
        var items: [Item] = rooms.map { Item(subject: .room($0.id), corners: roomFootprint($0)) }
        items.append(contentsOf: zones.map { Item(subject: .outdoorZone($0.id), corners: $0.footprint) })
        var cursor = 0.0
        var placed: [(SitePlacement, Double)] = []
        var total = 0.0
        for item in items {
            let minX = item.corners.map(\.x).min() ?? 0
            let maxX = item.corners.map(\.x).max() ?? minX
            let minZ = item.corners.map(\.z).min() ?? 0
            let width = max(maxX - minX, 0.5)
            let origin = Vec3(x: cursor - minX, y: 0, z: -minZ)
            placed.append((SitePlacement(subject: item.subject, origin: origin, yaw: 0), width))
            cursor += width + gap
            total = cursor - gap
        }
        let shift = total / 2
        return placed.map { item, _ in
            var copy = item
            copy.origin.x -= shift
            return copy
        }
    }
}

public enum SampleSite {
    public static let patioID = UUID(uuidString: "6F0C2A10-4B1E-4E0A-9C11-0000000000A1")!

    /// A small shed within the 5 meter LiDAR range, local origin at a corner.
    public static func shedMesh() -> TriangleMesh {
        let corners: [(Double, Double)] = [(0, 0), (4, 0), (4, 3), (0, 3)]
        var vertices: [Vec3] = []
        var faces: [MeshFace] = []
        for (x, z) in corners {
            vertices.append(Vec3(x: x, y: 0, z: z))
        }
        for (x, z) in corners {
            vertices.append(Vec3(x: x, y: 2.4, z: z))
        }
        faces.append(MeshFace(a: 0, b: 2, c: 1))
        faces.append(MeshFace(a: 0, b: 3, c: 2))
        faces.append(MeshFace(a: 4, b: 6, c: 5))
        faces.append(MeshFace(a: 4, b: 7, c: 6))
        let walls = [(0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        for wall in walls {
            faces.append(MeshFace(a: wall.0, b: wall.1, c: wall.2))
            faces.append(MeshFace(a: wall.0, b: wall.2, c: wall.3))
        }
        return TriangleMesh(vertices: vertices, faces: faces)
    }

    public static func shedZone(createdAt: Date = SampleApartment.createdAt) -> OutdoorZone {
        let mesh = shedMesh()
        let shape = MeshRange.footprint(mesh)
        let survey = MeshSurveyor.analyze(mesh)
        return OutdoorZone(
            id: patioID,
            name: "Shed",
            kind: .shed,
            createdAt: createdAt,
            footprint: shape.corners,
            height: shape.height,
            meshVertexCount: mesh.vertices.count,
            assets: OutdoorAssets(obj: "outdoor/\(patioID.uuidString).obj"),
            buildingFootprint: survey.buildingFootprint,
            groundVertexCount: survey.ground.vertices.count,
            walls: survey.walls
        )
    }
}
