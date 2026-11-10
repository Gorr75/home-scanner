import Foundation

/// A finish for a room floor. Photo textures still cover the surface when a scan has one.
public enum FlooringMaterial: String, Codable, CaseIterable, Sendable {
    case oak
    case walnut
    case tile
    case stone
    case carpet
    case concrete
    case herringbone
    case painted

    public var title: String {
        switch self {
        case .oak: return "Oak"
        case .walnut: return "Walnut"
        case .tile: return "Tile"
        case .stone: return "Stone"
        case .carpet: return "Carpet"
        case .concrete: return "Concrete"
        case .herringbone: return "Herringbone"
        case .painted: return "Painted"
        }
    }

    public var red: Double {
        switch self {
        case .oak: return 0.76
        case .walnut: return 0.42
        case .tile: return 0.82
        case .stone: return 0.62
        case .carpet: return 0.45
        case .concrete: return 0.70
        case .herringbone: return 0.62
        case .painted: return 0.90
        }
    }

    public var green: Double {
        switch self {
        case .oak: return 0.62
        case .walnut: return 0.28
        case .tile: return 0.84
        case .stone: return 0.62
        case .carpet: return 0.52
        case .concrete: return 0.70
        case .herringbone: return 0.45
        case .painted: return 0.89
        }
    }

    public var blue: Double {
        switch self {
        case .oak: return 0.42
        case .walnut: return 0.18
        case .tile: return 0.86
        case .stone: return 0.60
        case .carpet: return 0.48
        case .concrete: return 0.68
        case .herringbone: return 0.30
        case .painted: return 0.86
        }
    }

    public var rgba: [Double] { [red, green, blue, 1] }
}

public enum FloorStack {
    /// Clear height between the floor of one storey and the floor of the next, in meters.
    public static let storyHeight = 3.0

    public static func elevation(for floor: Int) -> Double {
        Double(floor) * storyHeight
    }

    /// True when at least two different `floor` indexes are set. Unassigned rooms are not a storey.
    public static func hasStackedFloors(_ home: Home) -> Bool {
        Set(home.rooms.compactMap(\.floor)).count > 1
    }

    /// Structural copy of a storey: walls, openings, and floor polygons, with new ids.
    /// Scan objects, catalog furniture, and device pins stay on the floor they were placed.
    public static func copiedRooms(
        from rooms: [Room],
        floor: Int,
        createdAt: Date,
        makeID: () -> UUID
    ) -> [Room] {
        rooms.map { room in
            Room(
                id: makeID(),
                name: room.name,
                createdAt: createdAt,
                floorPlan: FloorPlan(
                    walls: room.floorPlan.walls.map { wall in
                        var copy = wall
                        copy.id = makeID()
                        return copy
                    },
                    openings: room.floorPlan.openings.map { opening in
                        var copy = opening
                        copy.id = makeID()
                        return copy
                    },
                    floors: room.floorPlan.floors.map { floor in
                        var copy = floor
                        copy.id = makeID()
                        return copy
                    }
                ),
                floor: floor,
                flooring: room.flooring
            )
        }
    }

    /// One room whose walls follow the bounding footprint of the source storey, in display space.
    public static func footprintRoom(
        from rooms: [Room],
        unified: Bool,
        floor: Int,
        createdAt: Date,
        makeID: () -> UUID
    ) -> Room? {
        let frames = FloorPlanLayout.frames(rooms: rooms, coordinatesAreUnified: unified)
        var points: [Vec3] = []
        var height = 2.4
        for room in rooms {
            let offset = frames.first { $0.roomId == room.id }?.offset ?? .zero
            for floor in room.floorPlan.floors {
                points.append(contentsOf: floor.corners.map { $0 + offset })
            }
            for wall in room.floorPlan.walls {
                points.append(wall.start + offset)
                points.append(wall.end + offset)
                height = max(height, wall.height)
            }
        }
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minZ = first.z
        var maxZ = first.z
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minZ = min(minZ, point.z)
            maxZ = max(maxZ, point.z)
        }
        guard maxX - minX > 0.2, maxZ - minZ > 0.2 else { return nil }
        let corners = [
            Vec3(x: minX, y: 0, z: minZ),
            Vec3(x: maxX, y: 0, z: minZ),
            Vec3(x: maxX, y: 0, z: maxZ),
            Vec3(x: minX, y: 0, z: maxZ)
        ]
        let walls = (0..<4).map { index in
            WallSegment(
                id: makeID(),
                start: corners[index],
                end: corners[(index + 1) % 4],
                height: height,
                thickness: 0.12
            )
        }
        return Room(
            id: makeID(),
            name: FloorGrouping.label(for: floor),
            createdAt: createdAt,
            floorPlan: FloorPlan(
                walls: walls,
                floors: [FloorPolygon(id: makeID(), corners: corners)]
            ),
            floor: floor
        )
    }
}

public enum HomeFurnishing {
    public static func needsExport(_ home: Home) -> Bool {
        FloorStack.hasStackedFloors(home) || home.rooms.contains { needsExport($0) }
    }

    public static func needsExport(_ room: Room) -> Bool {
        !room.placedFurniture.isEmpty || room.flooring != nil
    }

    public static func layers(for home: Home, stacked: Bool) -> [DrawnLayer] {
        let frames = FloorPlanLayout.frames(
            rooms: home.rooms,
            coordinatesAreUnified: home.coordinatesAreUnified
        )
        return home.rooms.map { room in
            var offset = frames.first { $0.roomId == room.id }?.offset ?? .zero
            if stacked, let floor = room.floor {
                offset = Vec3(
                    x: offset.x,
                    y: offset.y + FloorStack.elevation(for: floor),
                    z: offset.z
                )
            }
            return DrawnLayer(
                plan: room.floorPlan,
                offset: offset,
                furniture: room.placedFurniture,
                flooring: room.flooring
            )
        }
    }

    public static func layer(for room: Room) -> DrawnLayer {
        DrawnLayer(
            plan: room.floorPlan,
            offset: .zero,
            furniture: room.placedFurniture,
            flooring: room.flooring
        )
    }
}
