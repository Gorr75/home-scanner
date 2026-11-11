import Observation
import SwiftUI
import RoomScanCore

enum MarkupKind: Equatable {
    case note
    case measurement
    case inventory
}

struct MarkupPin: Identifiable, Equatable {
    var id: UUID
    var position: Vec3
    var title: String
    var kind: MarkupKind
}

struct MarkupSegment: Identifiable, Equatable {
    var id: UUID
    var start: Vec3
    var end: Vec3
    var title: String
}

enum MarkupGeometry {
    static func layer(for point: Vec3, in layers: [PlanLayer]) -> PlanLayer? {
        let containing = layers.filter { layer in
            let box = FloorPlanGeometry.bounds(of: layer.plan).translated(by: layer.offset)
            return point.x >= box.min.x - 0.5 && point.x <= box.max.x + 0.5
                && point.z >= box.min.z - 0.5 && point.z <= box.max.z + 0.5
        }
        let pool = containing.isEmpty ? layers : containing
        return pool.min { distance($0, to: point) < distance($1, to: point) }
    }

    static func snap(_ point: Vec3, in layers: [PlanLayer]) -> (display: Vec3, layer: PlanLayer)? {
        guard let layer = layer(for: point, in: layers) else { return nil }
        let local = Vec3(x: point.x - layer.offset.x, y: point.y - layer.offset.y, z: point.z - layer.offset.z)
        let snapped = MeasureSnap.point(local, in: layer.plan)
        return (snapped + layer.offset, layer)
    }

    /// Display space back into the room's scan space, including the align yaw.
    static func stored(_ display: Vec3, on layer: PlanLayer) -> Vec3 {
        let local = Vec3(x: display.x - layer.offset.x, y: display.y - layer.offset.y, z: display.z - layer.offset.z)
        return layer.placement.inverse().applying(local)
    }

    static func display(_ stored: Vec3, on layer: PlanLayer) -> Vec3 {
        layer.placement.applying(stored) + layer.offset
    }

    private static func distance(_ layer: PlanLayer, to point: Vec3) -> Double {
        let box = FloorPlanGeometry.bounds(of: layer.plan).translated(by: layer.offset)
        let dx = max(box.min.x - point.x, point.x - box.max.x, 0)
        let dz = max(box.min.z - point.z, point.z - box.max.z, 0)
        return hypot(dx, dz)
    }
}

@MainActor
@Observable
final class MarkupSession {
    enum Tool: Equatable {
        case off
        case measure
        case annotate
    }

    var tool: Tool = .off
    var draftStart: Vec3?
    var draftEnd: Vec3?
    var selectedID: UUID?

    var distanceLabel: String? {
        guard let draftStart, let draftEnd else { return nil }
        return MeasureSnap.label(from: draftStart, to: draftEnd)
    }

    func toggleMeasure() {
        tool = tool == .measure ? .off : .measure
        draftStart = nil
        draftEnd = nil
    }

    func toggleAnnotate() {
        tool = tool == .annotate ? .off : .annotate
        draftStart = nil
        draftEnd = nil
    }

    func clearDraft() {
        draftStart = nil
        draftEnd = nil
    }

    func measureTap(_ raw: Vec3, layers: [PlanLayer]) {
        let snapped = MarkupGeometry.snap(raw, in: layers)?.display ?? raw
        if draftStart == nil || draftEnd != nil {
            draftStart = snapped
            draftEnd = nil
        } else {
            draftEnd = snapped
        }
    }

    func savedMeasurement(layers: [PlanLayer]) -> (roomID: UUID, note: RoomAnnotation)? {
        guard let draftStart, let draftEnd else { return nil }
        let mid = Vec3(
            x: (draftStart.x + draftEnd.x) / 2,
            y: (draftStart.y + draftEnd.y) / 2,
            z: (draftStart.z + draftEnd.z) / 2
        )
        guard let layer = MarkupGeometry.layer(for: mid, in: layers) else { return nil }
        let start = MarkupGeometry.stored(draftStart, on: layer)
        let end = MarkupGeometry.stored(draftEnd, on: layer)
        return (layer.id, RoomAnnotation.measurement(from: start, to: end))
    }

    func newNote(at raw: Vec3, layers: [PlanLayer]) -> (roomID: UUID, note: RoomAnnotation)? {
        guard let layer = MarkupGeometry.layer(for: raw, in: layers) else { return nil }
        return (layer.id, RoomAnnotation.note(at: MarkupGeometry.stored(raw, on: layer), text: ""))
    }

    func pins(home: Home, layers: [PlanLayer], includeInventory: Bool) -> [MarkupPin] {
        var pins: [MarkupPin] = []
        for room in home.rooms {
            guard let layer = layers.first(where: { $0.id == room.id }) else { continue }
            for note in room.roomAnnotations {
                let fallback = note.kind == .measurement ? "Measurement" : "Note"
                pins.append(MarkupPin(
                    id: note.id,
                    position: MarkupGeometry.display(note.position, on: layer),
                    title: note.text.isEmpty ? fallback : note.text,
                    kind: note.kind == .measurement ? .measurement : .note
                ))
            }
            if includeInventory {
                for item in room.inventoryItems {
                    guard let position = item.position else { continue }
                    pins.append(MarkupPin(
                        id: item.id,
                        position: MarkupGeometry.display(position, on: layer),
                        title: item.name,
                        kind: .inventory
                    ))
                }
            }
        }
        return pins
    }

    func segments(home: Home, layers: [PlanLayer]) -> [MarkupSegment] {
        var segments: [MarkupSegment] = []
        for room in home.rooms {
            guard let layer = layers.first(where: { $0.id == room.id }) else { continue }
            for note in room.roomAnnotations {
                guard let measurement = note.measurement else { continue }
                segments.append(MarkupSegment(
                    id: note.id,
                    start: MarkupGeometry.display(measurement.start, on: layer),
                    end: MarkupGeometry.display(measurement.end, on: layer),
                    title: note.text.isEmpty ? MeasureSnap.label(from: measurement.start, to: measurement.end) : note.text
                ))
            }
        }
        return segments
    }

    var hint: String {
        switch tool {
        case .off:
            return ""
        case .annotate:
            return "Tap a wall, the floor, or an object."
        case .measure:
            if let distanceLabel { return distanceLabel }
            if draftStart == nil { return "Tap the first point. Corners and edges snap." }
            return "Tap the second point."
        }
    }
}

struct MarkupBar: View {
    var tool: MarkupSession.Tool
    var hint: String
    var canSave: Bool
    var onSave: () -> Void
    var onClear: () -> Void

    var body: some View {
        if tool != .off {
            HStack(spacing: 10) {
                Text(hint)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.chalk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if tool == .measure {
                    Button("Clear", action: onClear)
                        .buttonStyle(.bordered)
                    Button("Save", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.navy)
        }
    }
}
