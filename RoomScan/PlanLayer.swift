import Foundation
import RoomScanCore

struct PlanLayer: Equatable, Identifiable {
    var id: UUID
    var name: String
    var plan: FloorPlan
    var offset: Vec3
    var tintIndex: Int
    var furniture: [PlacedFurniture] = []
    var flooring: FlooringMaterial? = nil
    var ghost: Bool = false
    /// Moves pins and catalog furniture with the room. The plan on the layer is already in display space.
    var placement: RigidYaw = .identity
}

enum PlanLayers {
    static func rooms(_ rooms: [Room], unified: Bool, stacked: Bool = false) -> [PlanLayer] {
        let frames = FloorPlanLayout.frames(rooms: rooms, coordinatesAreUnified: unified)
        return rooms.enumerated().map { index, room in
            var offset = frames.first { $0.roomId == room.id }?.offset ?? .zero
            if stacked, let floor = room.floor {
                offset = Vec3(x: offset.x, y: FloorStack.elevation(for: floor), z: offset.z)
            }
            return PlanLayer(
                id: room.id,
                name: room.name,
                plan: room.floorPlan,
                offset: offset,
                tintIndex: index,
                furniture: room.placedFurniture,
                flooring: room.flooring
            )
        }
    }

    /// A dim copy of another storey, drawn under the plan being edited.
    static func ghost(_ rooms: [Room], unified: Bool) -> [PlanLayer] {
        rooms(rooms, unified: unified).map { layer in
            var copy = layer
            copy.ghost = true
            return copy
        }
    }

    static func single(_ room: Room) -> [PlanLayer] {
        [PlanLayer(id: room.id, name: room.name, plan: room.floorPlan, offset: .zero, tintIndex: 0)]
    }

    static func overview(_ plan: FloorPlan, name: String) -> [PlanLayer] {
        [PlanLayer(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(), name: name, plan: plan, offset: .zero, tintIndex: 0)]
    }

    /// The floor the viewer should draw. Placements from the align step win over the raw shell.
    static func forHome(_ home: Home) -> [PlanLayer] {
        let applied = RoomAlignment.applied(to: home)
        if applied.changesDisplay {
            return placed(home, applied)
        }
        if let overview = home.structure?.overviewFloorPlan, !home.coordinatesAreUnified {
            return overview(overview, name: home.name)
        }
        return rooms(home.rooms, unified: home.coordinatesAreUnified)
    }

    static func showsDevicePins(_ home: Home) -> Bool {
        home.coordinatesAreUnified || RoomAlignment.applied(to: home).changesDisplay
    }

    static func aligned(_ rooms: [Room], applied: RoomAlignmentResult, stacked: Bool = false) -> [PlanLayer] {
        let hidden = Set(applied.suppressedRoomIds)
        return rooms.enumerated().compactMap { index, room in
            guard !hidden.contains(room.id) else { return nil }
            let transform = applied.placement(for: room.id)?.transform ?? .identity
            var offset = Vec3.zero
            if stacked, let floor = room.floor {
                offset.y = FloorStack.elevation(for: floor)
            }
            return PlanLayer(
                id: room.id,
                name: room.name,
                plan: room.floorPlan.transformed(by: transform),
                offset: offset,
                tintIndex: index,
                furniture: room.placedFurniture.map { moved($0, by: transform) },
                flooring: room.flooring,
                placement: transform
            )
        }
    }

    private static func placed(_ home: Home, _ applied: RoomAlignmentResult) -> [PlanLayer] {
        aligned(home.rooms, applied: applied)
    }

    private static func moved(_ item: PlacedFurniture, by rigid: RigidYaw) -> PlacedFurniture {
        var copy = item
        copy.position = rigid.applying(item.position)
        copy.yaw += rigid.yaw
        return copy
    }

    static func storedPoint(_ point: Vec3, in layer: PlanLayer) -> Vec3 {
        let shifted = Vec3(x: point.x - layer.offset.x, y: point.y, z: point.z - layer.offset.z)
        return layer.placement.inverse().applying(shifted)
    }

    static func bounds(of layers: [PlanLayer]) -> AABB {
        let boxes = layers.map {
            FloorPlanGeometry.bounds(of: $0.plan, furniture: $0.furniture).translated(by: $0.offset)
        }
        guard let first = boxes.first else {
            return AABB(min: .zero, max: Vec3(x: 1, y: 1, z: 1))
        }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    static func displayPosition(of pin: DevicePin, in layers: [PlanLayer]) -> Vec3 {
        guard let layer = layers.first(where: { $0.id == pin.roomId }) else {
            return pin.position
        }
        return layer.placement.applying(pin.position) + layer.offset
    }

    /// Display coordinates from a drag or a tap, written back into the scan the pin belongs to.
    static func storedXZ(displayX: Double, displayZ: Double, of pin: DevicePin, in layers: [PlanLayer]) -> (x: Double, z: Double) {
        guard let layer = layers.first(where: { $0.id == pin.roomId }) else {
            return (displayX, displayZ)
        }
        let world = Vec3(x: displayX - layer.offset.x, y: pin.position.y, z: displayZ - layer.offset.z)
        let stored = layer.placement.inverse().applying(world)
        return (stored.x, stored.z)
    }

    static func roomID(containingX x: Double, z: Double, in layers: [PlanLayer]) -> UUID? {
        for layer in layers {
            let box = FloorPlanGeometry.bounds(of: layer.plan).translated(by: layer.offset)
            if x >= box.min.x - 0.35, x <= box.max.x + 0.35, z >= box.min.z - 0.35, z <= box.max.z + 0.35 {
                return layer.id
            }
        }
        return layers.first?.id
    }

    static func roomID(containingX x: Double, z: Double, in home: Home) -> UUID? {
        for room in home.rooms {
            let box = FloorPlanGeometry.bounds(of: room.floorPlan)
            if x >= box.min.x - 0.2, x <= box.max.x + 0.2, z >= box.min.z - 0.2, z <= box.max.z + 0.2 {
                return room.id
            }
        }
        return home.rooms.first?.id
    }
}
