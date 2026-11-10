import Foundation

/// Which side of a room box a handle moves. `u` follows the room's long wall
/// (world +X when the scan is axis-aligned). `v` is the perpendicular on the floor.
public enum PlanFrameAxis: String, Sendable, Equatable, Hashable {
    case u
    case v
}

public enum PlanEdge: String, Sendable, Equatable, Hashable {
    case minU
    case maxU
    case minV
    case maxV

    public var axis: PlanFrameAxis {
        switch self {
        case .minU, .maxU: return .u
        case .minV, .maxV: return .v
        }
    }
}

public enum PlanCorner: String, Sendable, Equatable, Hashable {
    case minUMinV
    case maxUMinV
    case maxUMaxV
    case minUMaxV
}

/// Four corners and four edge midpoints. Dragging one resizes the room box.
public enum PlanHandle: Sendable, Equatable, Hashable {
    case edge(PlanEdge)
    case corner(PlanCorner)

    public static let all: [PlanHandle] = [
        .corner(.minUMinV),
        .edge(.minV),
        .corner(.maxUMinV),
        .edge(.maxU),
        .corner(.maxUMaxV),
        .edge(.maxV),
        .corner(.minUMaxV),
        .edge(.minU)
    ]

    public var edges: [PlanEdge] {
        switch self {
        case .edge(let edge):
            return [edge]
        case .corner(.minUMinV):
            return [.minU, .minV]
        case .corner(.maxUMinV):
            return [.maxU, .minV]
        case .corner(.maxUMaxV):
            return [.maxU, .maxV]
        case .corner(.minUMaxV):
            return [.minU, .maxV]
        }
    }
}

/// A dashed alignment line, in the same meters as the floor plan.
public struct PlanGuide: Equatable, Sendable {
    public var start: Vec3
    public var end: Vec3

    public init(start: Vec3, end: Vec3) {
        self.start = start
        self.end = end
    }
}

/// The room's footprint in a floor-parallel frame, plus the eight handle points.
public struct PlanBox: Equatable, Sendable {
    public var axisU: Vec3
    public var axisV: Vec3
    public var minU: Double
    public var maxU: Double
    public var minV: Double
    public var maxV: Double
    public var floorY: Double

    public init(
        axisU: Vec3,
        axisV: Vec3,
        minU: Double,
        maxU: Double,
        minV: Double,
        maxV: Double,
        floorY: Double
    ) {
        self.axisU = axisU
        self.axisV = axisV
        self.minU = minU
        self.maxU = maxU
        self.minV = minV
        self.maxV = maxV
        self.floorY = floorY
    }

    public var width: Double { maxU - minU }
    public var depth: Double { maxV - minV }

    public func u(_ point: Vec3) -> Double {
        point.x * axisU.x + point.z * axisU.z
    }

    public func v(_ point: Vec3) -> Double {
        point.x * axisV.x + point.z * axisV.z
    }

    public func world(u: Double, v: Double, y: Double) -> Vec3 {
        Vec3(
            x: axisU.x * u + axisV.x * v,
            y: y,
            z: axisU.z * u + axisV.z * v
        )
    }

    public func coordinate(_ point: Vec3, axis: PlanFrameAxis) -> Double {
        switch axis {
        case .u: return u(point)
        case .v: return v(point)
        }
    }

    public func point(_ handle: PlanHandle) -> Vec3 {
        switch handle {
        case .edge(.minU):
            return world(u: minU, v: midV, y: floorY)
        case .edge(.maxU):
            return world(u: maxU, v: midV, y: floorY)
        case .edge(.minV):
            return world(u: midU, v: minV, y: floorY)
        case .edge(.maxV):
            return world(u: midU, v: maxV, y: floorY)
        case .corner(.minUMinV):
            return world(u: minU, v: minV, y: floorY)
        case .corner(.maxUMinV):
            return world(u: maxU, v: minV, y: floorY)
        case .corner(.maxUMaxV):
            return world(u: maxU, v: maxV, y: floorY)
        case .corner(.minUMaxV):
            return world(u: minU, v: maxV, y: floorY)
        }
    }

    public func segment(_ edge: PlanEdge) -> (start: Vec3, end: Vec3) {
        switch edge {
        case .minU:
            return (world(u: minU, v: minV, y: floorY), world(u: minU, v: maxV, y: floorY))
        case .maxU:
            return (world(u: maxU, v: minV, y: floorY), world(u: maxU, v: maxV, y: floorY))
        case .minV:
            return (world(u: minU, v: minV, y: floorY), world(u: maxU, v: minV, y: floorY))
        case .maxV:
            return (world(u: minU, v: maxV, y: floorY), world(u: maxU, v: maxV, y: floorY))
        }
    }

    public func value(_ edge: PlanEdge) -> Double {
        switch edge {
        case .minU: return minU
        case .maxU: return maxU
        case .minV: return minV
        case .maxV: return maxV
        }
    }

    public func contains(u: Double, v: Double, slack: Double = 0) -> Bool {
        u >= minU - slack && u <= maxU + slack && v >= minV - slack && v <= maxV + slack
    }

    private var midU: Double { (minU + maxU) / 2 }
    private var midV: Double { (minV + maxV) / 2 }
}

public struct PlanEdit: Equatable, Sendable {
    public var plan: FloorPlan
    public var guides: [PlanGuide]

    public init(plan: FloorPlan, guides: [PlanGuide]) {
        self.plan = plan
        self.guides = guides
    }
}

public struct PlanOpeningCopy: Equatable, Sendable {
    public var plan: FloorPlan
    public var openingID: UUID

    public init(plan: FloorPlan, openingID: UUID) {
        self.plan = plan
        self.openingID = openingID
    }
}

/// One scanned room cut into the piece that stays and the piece that becomes a new room.
public struct PlanSplit: Equatable, Sendable {
    public var kept: FloorPlan
    public var created: FloorPlan
    public var frame: PlanBox
    public var axis: PlanFrameAxis
    public var mid: Double
    /// Ids of walls, openings, floors, and scan objects that moved to the new room.
    public var movedIDs: [UUID: UUID]

    public init(
        kept: FloorPlan,
        created: FloorPlan,
        frame: PlanBox,
        axis: PlanFrameAxis,
        mid: Double,
        movedIDs: [UUID: UUID] = [:]
    ) {
        self.kept = kept
        self.created = created
        self.frame = frame
        self.axis = axis
        self.mid = mid
        self.movedIDs = movedIDs
    }

    /// The new room is the high side of the cut. Points on the cut stay with the original room.
    public func containsCreated(x: Double, z: Double) -> Bool {
        let point = Vec3(x: x, y: frame.floorY, z: z)
        return frame.coordinate(point, axis: axis) > mid + 1e-7
    }
}

public struct PlanSnapshot: Equatable, Sendable {
    public var rooms: [Room]
    public var pins: [DevicePin]

    public init(rooms: [Room], pins: [DevicePin]) {
        self.rooms = rooms
        self.pins = pins
    }

    public init(home: Home) {
        self.init(rooms: home.rooms, pins: home.pins)
    }
}

/// Undo and redo for plan edits. Each entry is the rooms and pins from before the edit.
public struct PlanHistory: Equatable, Sendable {
    public static let limit = 40

    private var undoStack: [PlanSnapshot] = []
    private var redoStack: [PlanSnapshot] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ snapshot: PlanSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.limit {
            undoStack.removeFirst(undoStack.count - Self.limit)
        }
        redoStack.removeAll()
    }

    public mutating func undo(current: PlanSnapshot) -> PlanSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: PlanSnapshot) -> PlanSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}

/// Geometry for the plan editor: resize a room box, snap, split, and slide or copy openings.
/// Device control stays outside this type.
public enum PlanEditor {
    /// Walls and openings closer than this, in meters, count as the same line.
    public static let edgeEpsilon = 0.06
    /// Default alignment distance, in meters. The canvas can pass a tighter value when zoomed in.
    public static let defaultSnapThreshold = 0.08
    /// A resized edge stops here so a room cannot fold shut.
    public static let minimumSpan = 0.45
    public static let openingHostDistance = 0.25
    public static let copyGap = 0.12

    public static func box(of plan: FloorPlan) -> PlanBox? {
        PlanBox.make(from: plan)
    }

    public static func contains(x: Double, z: Double, in plan: FloorPlan) -> Bool {
        if plan.floors.contains(where: { polygonContains($0.corners, x: x, z: z) }) {
            return true
        }
        guard let box = PlanBox.make(from: plan) else { return false }
        let point = Vec3(x: x, y: box.floorY, z: z)
        return box.contains(u: box.u(point), v: box.v(point), slack: edgeEpsilon)
    }

    public static func translated(_ plan: FloorPlan, by offset: Vec3) -> FloorPlan {
        guard offset.x != 0 || offset.y != 0 || offset.z != 0 else { return plan }
        var copy = plan
        copy.walls = plan.walls.map { wall in
            var wall = wall
            wall.start = wall.start + offset
            wall.end = wall.end + offset
            return wall
        }
        copy.openings = plan.openings.map { opening in
            var opening = opening
            opening.center = opening.center + offset
            return opening
        }
        copy.floors = plan.floors.map { floor in
            var floor = floor
            floor.corners = floor.corners.map { $0 + offset }
            return floor
        }
        copy.objects = plan.objects.map { object in
            var object = object
            object.center = object.center + offset
            return object
        }
        return copy
    }

    /// Moves the handle to `point`. Walls on that edge follow, and so do doors and windows on those walls.
    /// Openings on a wall that only gets shorter stay on the remaining segment.
    public static func resize(
        _ plan: FloorPlan,
        handle: PlanHandle,
        to point: Vec3,
        against others: [FloorPlan] = [],
        threshold: Double = defaultSnapThreshold
    ) -> PlanEdit {
        guard let box = PlanBox.make(from: plan), point.x.isFinite, point.z.isFinite else {
            return PlanEdit(plan: plan, guides: [])
        }
        var proposed: [PlanEdge: Double] = [:]
        for edge in handle.edges {
            switch edge.axis {
            case .u:
                proposed[edge] = box.u(point)
            case .v:
                proposed[edge] = box.v(point)
            }
        }
        var pendingGuides: [(PlanEdge, Double, PlanGuide)] = []
        for edge in handle.edges {
            guard let value = proposed[edge] else { continue }
            let snapped = snapEdge(
                proposed: value,
                edge: edge,
                box: box,
                plan: plan,
                others: others,
                threshold: threshold
            )
            if let guide = snapped.guide, respectsSpan(edge, value: snapped.value, box: box) {
                proposed[edge] = snapped.value
                pendingGuides.append((edge, snapped.value, guide))
            } else {
                proposed[edge] = value
            }
        }
        for edge in handle.edges {
            if let value = proposed[edge] {
                proposed[edge] = clamped(edge, value: value, box: box)
            }
        }
        var guides: [PlanGuide] = []
        for (edge, snapped, guide) in pendingGuides {
            if let value = proposed[edge], abs(value - snapped) <= 1e-6 {
                guides.append(guide)
            }
        }
        let changed = proposed.contains { edge, value in
            abs(value - box.value(edge)) > 1e-6
        }
        guard changed else { return PlanEdit(plan: plan, guides: []) }
        return PlanEdit(plan: apply(plan, box: box, moves: proposed), guides: guides)
    }

    /// Slides an opening along its wall. The result snaps to other openings and to corners.
    public static func slide(
        _ plan: FloorPlan,
        openingID: UUID,
        to point: Vec3,
        against others: [FloorPlan] = [],
        threshold: Double = defaultSnapThreshold
    ) -> PlanEdit {
        guard let index = plan.openings.firstIndex(where: { $0.id == openingID }),
              point.x.isFinite, point.z.isFinite,
              let wall = hostWall(for: plan.openings[index], in: plan) else {
            return PlanEdit(plan: plan, guides: [])
        }
        let opening = plan.openings[index]
        let metrics = WallMetrics(wall)
        guard metrics.length > 1e-4 else { return PlanEdit(plan: plan, guides: []) }
        var scalar = metrics.project(point)
        scalar = metrics.clamp(scalar, halfWidth: opening.width / 2)
        let snapped = snapOpening(
            center: scalar,
            halfWidth: opening.width / 2,
            metrics: metrics,
            openingID: openingID,
            plan: plan,
            others: others,
            threshold: threshold
        )
        let clampedScalar = metrics.clamp(snapped.scalar, halfWidth: opening.width / 2)
        let guides = abs(clampedScalar - snapped.scalar) > 1e-6 ? [] : snapped.guides
        var updated = opening
        updated.center = metrics.point(at: clampedScalar, y: opening.center.y)
        guard (updated.center - opening.center).horizontalLength > 1e-6 else {
            return PlanEdit(plan: plan, guides: [])
        }
        var copy = plan
        copy.openings[index] = updated
        return PlanEdit(plan: copy, guides: guides)
    }

    /// A second door or window on the same wall, offset toward the side with more free space.
    public static func copyOpening(
        _ openingID: UUID,
        in plan: FloorPlan,
        newID: UUID = UUID()
    ) -> PlanOpeningCopy? {
        guard let opening = plan.openings.first(where: { $0.id == openingID }),
              let wall = hostWall(for: opening, in: plan) else {
            return nil
        }
        let metrics = WallMetrics(wall)
        guard metrics.length > 1e-4 else { return nil }
        let half = opening.width / 2
        let center = metrics.project(opening.center)
        let shift = opening.width + copyGap
        let towardEnd = metrics.length - (center + half)
        let towardStart = center - half
        var next = center
        if towardEnd >= shift || towardEnd >= towardStart {
            next = center + shift
        } else {
            next = center - shift
        }
        next = metrics.clamp(next, halfWidth: half)
        if abs(next - center) < max(0.05, opening.width * 0.25) {
            let flipped = center + (next >= center ? -shift : shift)
            let flippedClamp = metrics.clamp(flipped, halfWidth: half)
            if abs(flippedClamp - center) > abs(next - center) {
                next = flippedClamp
            }
        }
        var duplicate = opening
        duplicate.id = newID
        duplicate.center = metrics.point(at: next, y: opening.center.y)
        var copy = plan
        copy.openings.append(duplicate)
        return PlanOpeningCopy(plan: copy, openingID: newID)
    }

    public static func canSplit(_ plan: FloorPlan) -> Bool {
        guard let box = PlanBox.make(from: plan) else { return false }
        guard box.width >= minimumSpan * 2 - 1e-6 || box.depth >= minimumSpan * 2 - 1e-6 else {
            return false
        }
        let cross = box.width >= box.depth ? box.depth : box.width
        return cross >= 0.2
    }

    /// Halves the room on its longer axis and inserts a door centered on the new wall.
    /// Both pieces keep that wall and door, so each room is still a closed box.
    public static func split(
        _ plan: FloorPlan,
        makeID: @escaping () -> UUID = { UUID() }
    ) -> PlanSplit? {
        guard let box = PlanBox.make(from: plan) else { return nil }
        let spanU = box.width
        let spanV = box.depth
        guard spanU >= minimumSpan * 2 - 1e-6 || spanV >= minimumSpan * 2 - 1e-6 else { return nil }
        let axis: PlanFrameAxis = spanU >= spanV ? .u : .v
        guard (axis == .u ? spanV : spanU) >= 0.2 else { return nil }
        let mid = axis == .u ? (box.minU + box.maxU) / 2 : (box.minV + box.maxV) / 2
        let kept = half(plan, box: box, axis: axis, mid: mid, keepLow: true, makeID: makeID, keepIDs: true)
        let created = half(plan, box: box, axis: axis, mid: mid, keepLow: false, makeID: makeID, keepIDs: false)
        guard !kept.plan.walls.isEmpty, !created.plan.walls.isEmpty else { return nil }
        return PlanSplit(
            kept: kept.plan,
            created: created.plan,
            frame: box,
            axis: axis,
            mid: mid,
            movedIDs: created.movedIDs
        )
    }

    /// Cuts one room into two. The new room keeps the parent's floor and flooring.
    /// The saved viewpoint stays on the original room. Furniture follows the half that contains it.
    public static func splitRoom(
        _ room: Room,
        newID: UUID,
        name: String,
        createdAt: Date,
        makeID: @escaping () -> UUID = { UUID() }
    ) -> (kept: Room, created: Room, plan: PlanSplit)? {
        guard let plan = split(room.floorPlan, makeID: makeID) else { return nil }
        let pieces = reassignedFurniture(room.placedFurniture, split: plan)
        var kept = room
        kept.floorPlan = plan.kept
        kept.placedFurniture = pieces.kept
        let created = Room(
            id: newID,
            name: name,
            createdAt: createdAt,
            floorPlan: plan.created,
            floor: room.floor,
            flooring: room.flooring,
            furniture: pieces.created.isEmpty ? nil : pieces.created
        )
        return (kept, created, plan)
    }

    public static func reassignedPins(
        _ pins: [DevicePin],
        from roomID: UUID,
        to newRoomID: UUID,
        split: PlanSplit
    ) -> [DevicePin] {
        pins.map { pin in
            guard pin.roomId == roomID, split.containsCreated(x: pin.position.x, z: pin.position.z) else {
                return pin
            }
            var copy = pin
            copy.roomId = newRoomID
            return copy
        }
    }

    /// Furniture stays on the half that contains its floor position.
    /// A catalog item that replaced a scan box keeps that link only when the box stayed in the same half.
    public static func reassignedFurniture(
        _ items: [PlacedFurniture],
        split: PlanSplit
    ) -> (kept: [PlacedFurniture], created: [PlacedFurniture]) {
        var kept: [PlacedFurniture] = []
        var created: [PlacedFurniture] = []
        for item in items {
            var copy = item
            let onCreated = split.containsCreated(x: item.position.x, z: item.position.z)
            if let replaced = copy.replacesObjectId {
                if onCreated, let moved = split.movedIDs[replaced] {
                    copy.replacesObjectId = moved
                } else if onCreated || split.movedIDs[replaced] != nil {
                    copy.replacesObjectId = nil
                }
            }
            if onCreated {
                created.append(copy)
            } else {
                kept.append(copy)
            }
        }
        return (kept, created)
    }
}

extension PlanBox {
    static func make(from plan: FloorPlan) -> PlanBox? {
        let points = PlanEditor.footprintPoints(in: plan)
        guard let first = points.first else { return nil }
        let (axisU, axisV) = PlanEditor.axes(of: plan)
        var minU = Double.greatestFiniteMagnitude
        var maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude
        var maxV = -Double.greatestFiniteMagnitude
        var floorY = first.y
        for point in points {
            let u = point.x * axisU.x + point.z * axisU.z
            let v = point.x * axisV.x + point.z * axisV.z
            minU = min(minU, u)
            maxU = max(maxU, u)
            minV = min(minV, v)
            maxV = max(maxV, v)
            floorY = min(floorY, point.y)
        }
        guard minU.isFinite, maxU.isFinite else { return nil }
        return PlanBox(
            axisU: axisU,
            axisV: axisV,
            minU: minU,
            maxU: maxU,
            minV: minV,
            maxV: maxV,
            floorY: floorY
        )
    }
}

private struct WallMetrics {
    var start: Vec3
    var length: Double
    var unit: Vec3

    init(_ wall: WallSegment) {
        let delta = (wall.end - wall.start).flattened
        length = delta.horizontalLength
        unit = length > 1e-9 ? delta.normalized() : Vec3(x: 1, y: 0, z: 0)
        start = wall.start
    }

    func project(_ point: Vec3) -> Double {
        (point.x - start.x) * unit.x + (point.z - start.z) * unit.z
    }

    func point(at scalar: Double, y: Double) -> Vec3 {
        Vec3(x: start.x + unit.x * scalar, y: y, z: start.z + unit.z * scalar)
    }

    func clamp(_ scalar: Double, halfWidth: Double) -> Double {
        let margin = min(max(halfWidth, 0), length / 2)
        return min(max(scalar, margin), max(margin, length - margin))
    }
}

fileprivate extension PlanEditor {
    static func footprintPoints(in plan: FloorPlan) -> [Vec3] {
        var points: [Vec3] = []
        for wall in plan.walls {
            points.append(wall.start)
            points.append(wall.end)
        }
        for floor in plan.floors {
            points.append(contentsOf: floor.corners)
        }
        return points
    }

    static func segments(in plan: FloorPlan) -> [(start: Vec3, end: Vec3)] {
        if !plan.walls.isEmpty {
            return plan.walls.map { ($0.start, $0.end) }
        }
        var edges: [(Vec3, Vec3)] = []
        for floor in plan.floors where floor.corners.count >= 2 {
            for index in floor.corners.indices {
                let next = floor.corners[(index + 1) % floor.corners.count]
                edges.append((floor.corners[index], next))
            }
        }
        return edges
    }

    static func isAxisAligned(_ plan: FloorPlan) -> Bool {
        let lines = segments(in: plan)
        guard !lines.isEmpty else { return true }
        for segment in lines {
            let delta = segment.end - segment.start
            let length = delta.horizontalLength
            guard length > 1e-4 else { continue }
            let minor = min(abs(delta.x), abs(delta.z)) / length
            if minor > 0.14 { return false }
        }
        return true
    }

    static func axes(of plan: FloorPlan) -> (Vec3, Vec3) {
        if isAxisAligned(plan) {
            return (Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 0, z: 1))
        }
        var bestLength = 0.0
        var best = Vec3(x: 1, y: 0, z: 0)
        for segment in segments(in: plan) {
            let delta = (segment.end - segment.start).flattened
            let length = delta.horizontalLength
            if length > bestLength {
                bestLength = length
                best = delta.normalized()
            }
        }
        if best.x < -1e-9 || (abs(best.x) <= 1e-9 && best.z < 0) {
            best = best.scaled(-1)
        }
        return (best, Vec3(x: -best.z, y: 0, z: best.x))
    }

    static func respectsSpan(_ edge: PlanEdge, value: Double, box: PlanBox) -> Bool {
        switch edge {
        case .minU: return value <= box.maxU - minimumSpan + 1e-9
        case .maxU: return value >= box.minU + minimumSpan - 1e-9
        case .minV: return value <= box.maxV - minimumSpan + 1e-9
        case .maxV: return value >= box.minV + minimumSpan - 1e-9
        }
    }

    static func clamped(_ edge: PlanEdge, value: Double, box: PlanBox) -> Double {
        switch edge {
        case .minU: return min(value, box.maxU - minimumSpan)
        case .maxU: return max(value, box.minU + minimumSpan)
        case .minV: return min(value, box.maxV - minimumSpan)
        case .maxV: return max(value, box.minV + minimumSpan)
        }
    }

    static func snapEdge(
        proposed: Double,
        edge: PlanEdge,
        box: PlanBox,
        plan: FloorPlan,
        others: [FloorPlan],
        threshold: Double
    ) -> (value: Double, guide: PlanGuide?) {
        guard threshold > 0 else { return (proposed, nil) }
        let original = box.value(edge)
        var samples = coordinates(in: plan, box: box, axis: edge.axis).filter {
            abs($0.coordinate - original) > edgeEpsilon
        }
        for other in others {
            samples.append(contentsOf: coordinates(in: other, box: box, axis: edge.axis))
        }
        let eligible = samples.filter { sample in
            let delta = abs(sample.coordinate - proposed)
            return delta <= threshold + 1e-9 && respectsSpan(edge, value: sample.coordinate, box: box)
        }
        guard let best = eligible.min(by: { abs($0.coordinate - proposed) < abs($1.coordinate - proposed) }) else {
            return (proposed, nil)
        }
        let match = best.coordinate
        let matching = eligible.filter { abs($0.coordinate - match) <= 1e-3 }
        let segment = box.segment(edge)
        let movingCross = (
            box.coordinate(segment.start, axis: edge.axis == .u ? .v : .u),
            box.coordinate(segment.end, axis: edge.axis == .u ? .v : .u)
        )
        let crosses = matching.map(\.cross) + [movingCross.0, movingCross.1]
        guard let low = crosses.min(), let high = crosses.max() else { return (match, nil) }
        let pad = 0.15
        let guideStart = guidePoint(edge: edge, coordinate: match, cross: low - pad, box: box)
        let guideEnd = guidePoint(edge: edge, coordinate: match, cross: high + pad, box: box)
        return (match, PlanGuide(start: guideStart, end: guideEnd))
    }

    static func guidePoint(edge: PlanEdge, coordinate: Double, cross: Double, box: PlanBox) -> Vec3 {
        switch edge.axis {
        case .u:
            return box.world(u: coordinate, v: cross, y: box.floorY)
        case .v:
            return box.world(u: cross, v: coordinate, y: box.floorY)
        }
    }

    static func coordinates(
        in plan: FloorPlan,
        box: PlanBox,
        axis: PlanFrameAxis
    ) -> [(coordinate: Double, cross: Double)] {
        var samples: [(Double, Double)] = []
        func add(_ point: Vec3) {
            switch axis {
            case .u:
                samples.append((box.u(point), box.v(point)))
            case .v:
                samples.append((box.v(point), box.u(point)))
            }
        }
        for wall in plan.walls {
            add(wall.start)
            add(wall.end)
        }
        for opening in plan.openings {
            add(opening.center)
            let ends = opening.widthEndpoints
            add(ends.start)
            add(ends.end)
        }
        return samples
    }

    struct OpeningAnchor {
        var wallID: UUID
        var edge: PlanEdge?
        var u: Double
        var v: Double
    }

    static func apply(_ plan: FloorPlan, box: PlanBox, moves: [PlanEdge: Double]) -> FloorPlan {
        let anchored = anchors(in: plan, box: box)
        let originalWalls = plan.walls
        var copy = plan
        copy.walls = plan.walls.map { wall in
            var wall = wall
            wall.start = moved(wall.start, moves: moves, box: box)
            wall.end = moved(wall.end, moves: moves, box: box)
            return wall
        }
        copy.floors = plan.floors.map { floor in
            var floor = floor
            floor.corners = floor.corners.map { moved($0, moves: moves, box: box) }
            return floor
        }
        copy.openings = plan.openings.map { opening in
            guard let anchor = anchored[opening.id],
                  let wall = copy.walls.first(where: { $0.id == anchor.wallID }),
                  let original = originalWalls.first(where: { $0.id == anchor.wallID }),
                  wallChanged(original, wall) else {
                return opening
            }
            var u = anchor.u
            var v = anchor.v
            if let edge = anchor.edge, let value = moves[edge] {
                switch edge {
                case .minU, .maxU: u = value
                case .minV, .maxV: v = value
                }
            }
            let desired = box.world(u: u, v: v, y: opening.center.y)
            var updated = opening
            updated.center = clampedOnto(desired, wall: wall, halfWidth: opening.width / 2, y: opening.center.y)
            return updated
        }
        return copy
    }

    static func wallChanged(_ original: WallSegment, _ updated: WallSegment) -> Bool {
        (original.start - updated.start).horizontalLength > 1e-6
            || (original.end - updated.end).horizontalLength > 1e-6
    }

    static func anchors(in plan: FloorPlan, box: PlanBox) -> [UUID: OpeningAnchor] {
        var result: [UUID: OpeningAnchor] = [:]
        for opening in plan.openings {
            guard let wall = hostWall(for: opening, in: plan) else { continue }
            result[opening.id] = OpeningAnchor(
                wallID: wall.id,
                edge: edge(of: wall, box: box),
                u: box.u(opening.center),
                v: box.v(opening.center)
            )
        }
        return result
    }

    static func edge(of wall: WallSegment, box: PlanBox) -> PlanEdge? {
        let startU = box.u(wall.start)
        let endU = box.u(wall.end)
        let startV = box.v(wall.start)
        let endV = box.v(wall.end)
        if abs(startU - box.maxU) <= edgeEpsilon && abs(endU - box.maxU) <= edgeEpsilon { return .maxU }
        if abs(startU - box.minU) <= edgeEpsilon && abs(endU - box.minU) <= edgeEpsilon { return .minU }
        if abs(startV - box.maxV) <= edgeEpsilon && abs(endV - box.maxV) <= edgeEpsilon { return .maxV }
        if abs(startV - box.minV) <= edgeEpsilon && abs(endV - box.minV) <= edgeEpsilon { return .minV }
        return nil
    }

    static func moved(_ point: Vec3, moves: [PlanEdge: Double], box: PlanBox) -> Vec3 {
        var u = box.u(point)
        var v = box.v(point)
        if let value = moves[.minU], abs(u - box.minU) <= edgeEpsilon { u = value }
        if let value = moves[.maxU], abs(u - box.maxU) <= edgeEpsilon { u = value }
        if let value = moves[.minV], abs(v - box.minV) <= edgeEpsilon { v = value }
        if let value = moves[.maxV], abs(v - box.maxV) <= edgeEpsilon { v = value }
        return box.world(u: u, v: v, y: point.y)
    }

    static func clampedOnto(_ desired: Vec3, wall: WallSegment, halfWidth: Double, y: Double) -> Vec3 {
        let metrics = WallMetrics(wall)
        guard metrics.length > 1e-4 else { return desired }
        let scalar = metrics.clamp(metrics.project(desired), halfWidth: halfWidth)
        return metrics.point(at: scalar, y: y)
    }

    static func hostWall(for opening: Opening, in plan: FloorPlan) -> WallSegment? {
        let direction = Vec3(x: Trig.cos(opening.yaw), y: 0, z: Trig.sin(opening.yaw))
        var best: (WallSegment, Double)?
        for wall in plan.walls {
            let delta = (wall.end - wall.start).flattened
            let length = delta.horizontalLength
            guard length > 1e-4 else { continue }
            let unit = delta.scaled(1 / length)
            guard abs(unit.dot(direction)) > 0.94 else { continue }
            let metrics = lineDistance(opening.center, wall.start, wall.end)
            guard metrics.distance <= openingHostDistance else { continue }
            let margin = (opening.width / 2) / length + 0.05
            guard metrics.t >= -margin && metrics.t <= 1 + margin else { continue }
            if best == nil || metrics.distance < best!.1 {
                best = (wall, metrics.distance)
            }
        }
        return best?.0
    }

    static func lineDistance(_ point: Vec3, _ start: Vec3, _ end: Vec3) -> (distance: Double, t: Double) {
        let dx = end.x - start.x
        let dz = end.z - start.z
        let lengthSquared = dx * dx + dz * dz
        guard lengthSquared > 1e-12 else {
            return ((point - start).horizontalLength, 0)
        }
        let t = ((point.x - start.x) * dx + (point.z - start.z) * dz) / lengthSquared
        let projectedX = start.x + dx * t
        let projectedZ = start.z + dz * t
        let distance = ((point.x - projectedX) * (point.x - projectedX) + (point.z - projectedZ) * (point.z - projectedZ)).squareRoot()
        return (distance, t)
    }

    struct SnapTarget {
        var scalar: Double
        var point: Vec3
    }

    static func snapOpening(
        center: Double,
        halfWidth: Double,
        metrics: WallMetrics,
        openingID: UUID,
        plan: FloorPlan,
        others: [FloorPlan],
        threshold: Double
    ) -> (scalar: Double, guides: [PlanGuide]) {
        guard threshold > 0 else { return (center, []) }
        var targets: [SnapTarget] = []
        func addWallCorners(_ walls: [WallSegment]) {
            for wall in walls {
                targets.append(SnapTarget(scalar: metrics.project(wall.start), point: wall.start))
                targets.append(SnapTarget(scalar: metrics.project(wall.end), point: wall.end))
            }
        }
        func addOpenings(_ openings: [Opening]) {
            for opening in openings where opening.id != openingID {
                let ends = opening.widthEndpoints
                targets.append(SnapTarget(scalar: metrics.project(opening.center), point: opening.center))
                targets.append(SnapTarget(scalar: metrics.project(ends.start), point: ends.start))
                targets.append(SnapTarget(scalar: metrics.project(ends.end), point: ends.end))
            }
        }
        addWallCorners(plan.walls)
        addOpenings(plan.openings)
        for other in others {
            addWallCorners(other.walls)
            addOpenings(other.openings)
        }
        let anchors = [0.0, -halfWidth, halfWidth]
        var best: (delta: Double, scalar: Double, from: Vec3, to: Vec3)?
        for target in targets {
            for anchor in anchors {
                let next = target.scalar - anchor
                let delta = next - center
                guard abs(delta) <= threshold + 1e-9 else { continue }
                let clamped = metrics.clamp(next, halfWidth: halfWidth)
                guard abs(clamped - next) <= 1e-6 else { continue }
                if best == nil || abs(delta) < abs(best!.delta) {
                    let from = metrics.point(at: target.scalar, y: metrics.start.y)
                    best = (delta, next, from, target.point)
                }
            }
        }
        guard let best else { return (center, []) }
        return (best.scalar, [guideBetween(best.from, best.to, unit: metrics.unit)])
    }

    static func guideBetween(_ from: Vec3, _ to: Vec3, unit: Vec3) -> PlanGuide {
        if (from - to).horizontalLength < 0.05 {
            let normal = Vec3(x: -unit.z, y: 0, z: unit.x)
            return PlanGuide(start: from, end: from + normal.scaled(0.55))
        }
        return PlanGuide(start: from, end: to)
    }

    static func half(
        _ plan: FloorPlan,
        box: PlanBox,
        axis: PlanFrameAxis,
        mid: Double,
        keepLow: Bool,
        makeID: () -> UUID,
        keepIDs: Bool
    ) -> (plan: FloorPlan, movedIDs: [UUID: UUID]) {
        var walls = plan.walls.compactMap { wall -> WallSegment? in
            guard let clipped = clipSegment(wall.start, wall.end, box: box, axis: axis, mid: mid, keepLow: keepLow) else {
                return nil
            }
            guard (clipped.end - clipped.start).horizontalLength > 0.02 else { return nil }
            var wall = wall
            wall.start = clipped.start
            wall.end = clipped.end
            return wall
        }
        let clipped = FloorPlan(walls: walls)
        var openings = plan.openings.filter { opening in
            keepPoint(opening.center, box: box, axis: axis, mid: mid, keepLow: keepLow)
                && hostWall(for: opening, in: clipped) != nil
        }
        openings = openings.map { opening in
            guard let wall = hostWall(for: opening, in: FloorPlan(walls: walls)) else { return opening }
            var opening = opening
            opening.center = clampedOnto(opening.center, wall: wall, halfWidth: opening.width / 2, y: opening.center.y)
            return opening
        }
        let objects = plan.objects.filter {
            keepPoint($0.center, box: box, axis: axis, mid: mid, keepLow: keepLow)
        }
        var floors = plan.floors.compactMap { floor -> FloorPolygon? in
            let corners = clipPolygon(floor.corners, box: box, axis: axis, mid: mid, keepLow: keepLow)
            guard corners.count >= 3, MeasurementMath.polygonArea(corners) > 1e-4 else { return nil }
            var floor = floor
            floor.corners = corners
            return floor
        }
        if !keepIDs {
            var ids: [UUID: UUID] = [:]
            func remap(_ id: UUID) -> UUID {
                if let existing = ids[id] { return existing }
                let created = makeID()
                ids[id] = created
                return created
            }
            walls = walls.map { wall in
                var wall = wall
                wall.id = remap(wall.id)
                return wall
            }
            openings = openings.map { opening in
                var opening = opening
                opening.id = remap(opening.id)
                return opening
            }
            floors = floors.map { floor in
                var floor = floor
                floor.id = remap(floor.id)
                return floor
            }
            let remappedObjects = objects.map { object in
                var object = object
                object.id = remap(object.id)
                return object
            }
            var result = FloorPlan(walls: walls, openings: openings, floors: floors, objects: remappedObjects)
            addDivider(to: &result, box: box, axis: axis, mid: mid, makeID: makeID)
            return (result, ids)
        }
        var result = FloorPlan(walls: walls, openings: openings, floors: floors, objects: objects)
        addDivider(to: &result, box: box, axis: axis, mid: mid, makeID: makeID)
        return (result, [:])
    }

    static func keepPoint(
        _ point: Vec3,
        box: PlanBox,
        axis: PlanFrameAxis,
        mid: Double,
        keepLow: Bool
    ) -> Bool {
        let coordinate = box.coordinate(point, axis: axis)
        if keepLow { return coordinate <= mid + 1e-7 }
        return coordinate > mid + 1e-7
    }

    static func clipSegment(
        _ start: Vec3,
        _ end: Vec3,
        box: PlanBox,
        axis: PlanFrameAxis,
        mid: Double,
        keepLow: Bool
    ) -> (start: Vec3, end: Vec3)? {
        let startCoord = box.coordinate(start, axis: axis)
        let endCoord = box.coordinate(end, axis: axis)
        let startIn = keepLow ? startCoord <= mid + 1e-8 : startCoord >= mid - 1e-8
        let endIn = keepLow ? endCoord <= mid + 1e-8 : endCoord >= mid - 1e-8
        if startIn && endIn { return (start, end) }
        if !startIn && !endIn { return nil }
        let delta = endCoord - startCoord
        guard abs(delta) > 1e-9 else { return startIn ? (start, end) : nil }
        let t = (mid - startCoord) / delta
        let cut = Vec3(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t,
            z: start.z + (end.z - start.z) * t
        )
        if startIn { return (start, cut) }
        return (cut, end)
    }

    static func clipPolygon(
        _ corners: [Vec3],
        box: PlanBox,
        axis: PlanFrameAxis,
        mid: Double,
        keepLow: Bool
    ) -> [Vec3] {
        guard corners.count >= 3 else { return [] }
        func inside(_ point: Vec3) -> Bool {
            let coordinate = box.coordinate(point, axis: axis)
            if keepLow { return coordinate <= mid + 1e-8 }
            return coordinate >= mid - 1e-8
        }
        func intersection(_ a: Vec3, _ b: Vec3) -> Vec3 {
            let aCoord = box.coordinate(a, axis: axis)
            let bCoord = box.coordinate(b, axis: axis)
            let delta = bCoord - aCoord
            let t = abs(delta) < 1e-9 ? 0 : (mid - aCoord) / delta
            return Vec3(
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t,
                z: a.z + (b.z - a.z) * t
            )
        }
        var output: [Vec3] = []
        for index in corners.indices {
            let current = corners[index]
            let previous = corners[(index + corners.count - 1) % corners.count]
            let currentIn = inside(current)
            let previousIn = inside(previous)
            if currentIn {
                if !previousIn {
                    output.append(intersection(previous, current))
                }
                output.append(current)
            } else if previousIn {
                output.append(intersection(previous, current))
            }
        }
        return output
    }

    static func addDivider(
        to plan: inout FloorPlan,
        box: PlanBox,
        axis: PlanFrameAxis,
        mid: Double,
        makeID: () -> UUID
    ) {
        let start: Vec3
        let end: Vec3
        switch axis {
        case .u:
            start = box.world(u: mid, v: box.minV, y: box.floorY)
            end = box.world(u: mid, v: box.maxV, y: box.floorY)
        case .v:
            start = box.world(u: box.minU, v: mid, y: box.floorY)
            end = box.world(u: box.maxU, v: mid, y: box.floorY)
        }
        let height = plan.walls.map(\.height).max() ?? 2.4
        let thickness = plan.walls.first?.thickness ?? 0.12
        let wall = WallSegment(
            id: makeID(),
            start: start,
            end: end,
            height: height,
            thickness: thickness
        )
        plan.walls.append(wall)
        let length = wall.length
        guard length > 0.2 else { return }
        let width = min(0.9, max(0.45, min(length * 0.45, length - 0.1)))
        let doorHeight = min(2.1, max(0.8, height - 0.3))
        let yaw = Trig.atan2(end.z - start.z, end.x - start.x)
        let center = Vec3(
            x: (start.x + end.x) / 2,
            y: box.floorY + doorHeight / 2,
            z: (start.z + end.z) / 2
        )
        plan.openings.append(
            Opening(
                id: makeID(),
                kind: .door,
                center: center,
                width: width,
                height: doorHeight,
                yaw: yaw
            )
        )
    }

    static func polygonContains(_ corners: [Vec3], x: Double, z: Double) -> Bool {
        guard corners.count >= 3 else { return false }
        var inside = false
        var previous = corners[corners.count - 1]
        for corner in corners {
            let crosses = (corner.z > z) != (previous.z > z)
            if crosses {
                let span = previous.z - corner.z
                if abs(span) > 1e-12 {
                    let atX = (previous.x - corner.x) * (z - corner.z) / span + corner.x
                    if x < atX { inside.toggle() }
                }
            }
            previous = corner
        }
        return inside
    }
}
