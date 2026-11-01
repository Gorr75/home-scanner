import Foundation

/// A two-room apartment in one coordinate space, so the simulator can open
/// the viewer without a LiDAR scan. Geometry is mirrored by `scripts/make_sample_usdz.py`.
public enum SampleApartment {
    public static let createdAt = Date(timeIntervalSince1970: 1_767_225_600)

    public static let homeID = id(0x01)
    public static let kitchenID = id(0x10)
    public static let livingRoomID = id(0x20)

    public static func id(_ value: Int) -> UUID {
        let formatted = String(format: "6F0C2A10-4B1E-4E0A-9C11-%012X", value)
        guard let uuid = UUID(uuidString: formatted) else {
            preconditionFailure("Invalid sample id \(value)")
        }
        return uuid
    }

    public static func make() -> Home {
        let kitchen = Room(
            id: kitchenID,
            name: "Kitchen",
            createdAt: createdAt,
            floorPlan: kitchenPlan()
        )
        let living = Room(
            id: livingRoomID,
            name: "Living room",
            createdAt: createdAt,
            floorPlan: livingPlan()
        )
        return Home(
            id: homeID,
            name: "Sample apartment",
            createdAt: createdAt,
            updatedAt: createdAt,
            rooms: [kitchen, living],
            pins: pins(),
            structure: StructureLink(
                builtAt: createdAt,
                roomIds: [kitchenID, livingRoomID],
                coordinatesAreUnified: true,
                usdz: "structure.usdz"
            )
        )
    }

    private static func wall(
        _ n: Int,
        from start: (Double, Double),
        to end: (Double, Double)
    ) -> WallSegment {
        WallSegment(
            id: id(n),
            start: Vec3(x: start.0, y: 0, z: start.1),
            end: Vec3(x: end.0, y: 0, z: end.1),
            height: 2.4,
            thickness: 0.12
        )
    }

    private static func kitchenPlan() -> FloorPlan {
        FloorPlan(
            walls: [
                wall(0x11, from: (0, 0), to: (3.6, 0)),
                wall(0x12, from: (0, 0), to: (0, 3.2)),
                wall(0x13, from: (0, 3.2), to: (3.6, 3.2)),
                wall(0x14, from: (3.6, 0), to: (3.6, 3.2))
            ],
            openings: [
                Opening(
                    id: id(0x15),
                    kind: .door,
                    center: Vec3(x: 3.6, y: 1.05, z: 1.6),
                    width: 0.9,
                    height: 2.1,
                    yaw: .pi / 2
                )
            ],
            floors: [
                FloorPolygon(
                    id: id(0x16),
                    corners: [
                        Vec3(x: 0, y: 0, z: 0),
                        Vec3(x: 3.6, y: 0, z: 0),
                        Vec3(x: 3.6, y: 0, z: 3.2),
                        Vec3(x: 0, y: 0, z: 3.2)
                    ]
                )
            ],
            objects: [
                PlacedObject(
                    id: id(0x17),
                    category: "refrigerator",
                    center: Vec3(x: 0.45, y: 0.9, z: 2.7),
                    dimensions: Vec3(x: 0.7, y: 1.8, z: 0.7),
                    yaw: 0
                ),
                PlacedObject(
                    id: id(0x18),
                    category: "table",
                    center: Vec3(x: 1.8, y: 0.38, z: 1.4),
                    dimensions: Vec3(x: 1.2, y: 0.76, z: 0.8),
                    yaw: 0
                )
            ]
        )
    }

    private static func livingPlan() -> FloorPlan {
        FloorPlan(
            walls: [
                wall(0x21, from: (3.6, 0), to: (8.8, 0)),
                wall(0x22, from: (8.8, 0), to: (8.8, 4)),
                wall(0x23, from: (8.8, 4), to: (3.6, 4)),
                wall(0x24, from: (3.6, 4), to: (3.6, 3.2))
            ],
            openings: [
                Opening(
                    id: id(0x25),
                    kind: .window,
                    center: Vec3(x: 6.2, y: 1.5, z: 0),
                    width: 1.8,
                    height: 1.3,
                    yaw: 0
                )
            ],
            floors: [
                FloorPolygon(
                    id: id(0x26),
                    corners: [
                        Vec3(x: 3.6, y: 0, z: 0),
                        Vec3(x: 8.8, y: 0, z: 0),
                        Vec3(x: 8.8, y: 0, z: 4),
                        Vec3(x: 3.6, y: 0, z: 4)
                    ]
                )
            ],
            objects: [
                PlacedObject(
                    id: id(0x27),
                    category: "sofa",
                    center: Vec3(x: 6.6, y: 0.4, z: 2.8),
                    dimensions: Vec3(x: 2.2, y: 0.85, z: 0.9),
                    yaw: .pi / 2
                ),
                PlacedObject(
                    id: id(0x28),
                    category: "table",
                    center: Vec3(x: 6.2, y: 0.22, z: 1.5),
                    dimensions: Vec3(x: 1.1, y: 0.42, z: 0.6),
                    yaw: 0
                )
            ]
        )
    }

    private static func pins() -> [DevicePin] {
        [
            DevicePin(
                id: id(0x31),
                roomId: kitchenID,
                name: "Kitchen light",
                kind: .light,
                entityId: "light.kitchen",
                position: Vec3(x: 1.8, y: 2.35, z: 1.6)
            ),
            DevicePin(
                id: id(0x32),
                roomId: livingRoomID,
                name: "Living room light",
                kind: .light,
                entityId: "light.living_room",
                position: Vec3(x: 6.2, y: 2.35, z: 2)
            ),
            DevicePin(
                id: id(0x33),
                roomId: livingRoomID,
                name: "Living room switch",
                kind: .switch,
                entityId: "switch.living_room",
                position: Vec3(x: 4, y: 1.15, z: 2.15)
            ),
            DevicePin(
                id: id(0x34),
                roomId: livingRoomID,
                name: "Living room temperature",
                kind: .sensor,
                entityId: "sensor.living_room_temperature",
                position: Vec3(x: 8.45, y: 1.45, z: 3.4)
            )
        ]
    }
}
