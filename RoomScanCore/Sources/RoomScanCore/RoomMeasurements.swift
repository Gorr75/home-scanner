import Foundation

public struct RoomMeasurements: Equatable, Sendable {
    public var floorArea: Double
    public var wallLengths: [Double]
    public var doorWidths: [Double]
    public var windowWidths: [Double]

    public init(floorArea: Double, wallLengths: [Double], doorWidths: [Double], windowWidths: [Double]) {
        self.floorArea = floorArea
        self.wallLengths = wallLengths
        self.doorWidths = doorWidths
        self.windowWidths = windowWidths
    }

    public var wallLength: Double {
        wallLengths.reduce(0, +)
    }
}

public enum MeasurementMath {
    public static func summarize(_ plan: FloorPlan) -> RoomMeasurements {
        RoomMeasurements(
            floorArea: floorArea(of: plan),
            wallLengths: plan.walls.map(\.length),
            doorWidths: plan.openings.filter { $0.kind == .door }.map(\.width),
            windowWidths: plan.openings.filter { $0.kind == .window }.map(\.width)
        )
    }

    public static func summarize(home: Home) -> [(name: String, measurements: RoomMeasurements)] {
        home.rooms.map { ($0.name, summarize($0.floorPlan)) }
    }

    /// Shoelace area of each floor polygon, in square meters. Polygons are on the XZ plane.
    public static func floorArea(of plan: FloorPlan) -> Double {
        plan.floors.reduce(0) { partial, floor in
            partial + polygonArea(floor.corners)
        }
    }

    public static func polygonArea(_ corners: [Vec3]) -> Double {
        guard corners.count >= 3 else { return 0 }
        var sum = 0.0
        for index in corners.indices {
            let next = corners[(index + 1) % corners.count]
            sum += corners[index].x * next.z - next.x * corners[index].z
        }
        return abs(sum) / 2
    }

    public static func meters(_ value: Double) -> String {
        ObjectLabels.meters(value)
    }

    public static func squareMeters(_ value: Double) -> String {
        "\(meters(value)) m²"
    }
}
