import Foundation

public enum ScanConfidence: String, Codable, Sendable, Equatable {
    case high
    case medium
    case low
}

public struct WallSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Vec3
    public var end: Vec3
    @Quantized public var height: Double
    @Quantized public var thickness: Double
    public var confidence: ScanConfidence?

    public init(
        id: UUID,
        start: Vec3,
        end: Vec3,
        height: Double,
        thickness: Double,
        confidence: ScanConfidence? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.height = height
        self.thickness = thickness
        self.confidence = confidence
    }

    public var length: Double {
        (end - start).horizontalLength
    }
}

public enum OpeningKind: String, Codable, Sendable, Equatable {
    case door
    case window
    case opening
}

public struct Opening: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: OpeningKind
    public var center: Vec3
    @Quantized public var width: Double
    @Quantized public var height: Double
    /// Radians around Y. Zero means the opening's width runs along +X.
    @Quantized public var yaw: Double
    public var confidence: ScanConfidence?

    public init(
        id: UUID,
        kind: OpeningKind,
        center: Vec3,
        width: Double,
        height: Double,
        yaw: Double,
        confidence: ScanConfidence? = nil
    ) {
        self.id = id
        self.kind = kind
        self.center = center
        self.width = width
        self.height = height
        self.yaw = yaw
        self.confidence = confidence
    }
}

public struct FloorPolygon: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var corners: [Vec3]

    public init(id: UUID, corners: [Vec3]) {
        self.id = id
        self.corners = corners
    }
}

public struct PlacedObject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Stable category token such as `sofa`, `table`, or `refrigerator`.
    public var category: String
    public var center: Vec3
    /// Width (X), height (Y), and depth (Z) before `yaw` is applied.
    public var dimensions: Vec3
    @Quantized public var yaw: Double
    public var confidence: ScanConfidence?

    public init(
        id: UUID,
        category: String,
        center: Vec3,
        dimensions: Vec3,
        yaw: Double,
        confidence: ScanConfidence? = nil
    ) {
        self.id = id
        self.category = category
        self.center = center
        self.dimensions = dimensions
        self.yaw = yaw
        self.confidence = confidence
    }
}

public struct FloorPlan: Codable, Equatable, Sendable {
    public var walls: [WallSegment]
    public var openings: [Opening]
    public var floors: [FloorPolygon]
    public var objects: [PlacedObject]

    public init(
        walls: [WallSegment] = [],
        openings: [Opening] = [],
        floors: [FloorPolygon] = [],
        objects: [PlacedObject] = []
    ) {
        self.walls = walls
        self.openings = openings
        self.floors = floors
        self.objects = objects
    }

    public static let empty = FloorPlan()

    public var isEmpty: Bool {
        walls.isEmpty && openings.isEmpty && floors.isEmpty && objects.isEmpty
    }
}
