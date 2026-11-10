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
        let offset = layers.first { $0.id == pin.roomId }?.offset ?? .zero
        return pin.position + offset
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
