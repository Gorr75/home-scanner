import SwiftUI
import RoomScanCore

/// How much annotation a plan canvas draws.
/// Thumbnails and the home hero stay quiet. The floor-plan screen uses `.annotated`.
enum PlanMarkup: Equatable {
    /// Walls, room fills, and openings.
    case structure
    /// Structure, furniture outlines, and room names that fit without overlapping.
    case preview
    /// Furniture names, footprint sizes, and every room name.
    case annotated
}

struct FloorPlanCanvas: View {
    var layers: [PlanLayer]
    var pins: [DevicePin]
    var showPins: Bool
    var selectedPinID: UUID?
    var placing: Bool
    var pinCaptions: [UUID: String] = [:]
    var pinLooks: [UUID: PinLook] = [:]
    var changes: [ObjectChange] = []
    var heatSamples: [HeatSample] = []
    var interactive: Bool = true
    /// List rows use `.structure`. The home screen hero uses `.preview`.
    var markup: PlanMarkup = .annotated
    /// Full floor-plan viewers draw on charcoal. List thumbnails stay on paper.
    var onCharcoal: Bool = false
    /// Dim plan of the storey underneath. Not interactive.
    var ghostLayers: [PlanLayer] = []
    var selectedFurnitureID: UUID? = nil
    var placingFurniture: Bool = false
    var onSelectPin: (UUID?) -> Void = { _ in }
    var onMovePin: (UUID, Double, Double) -> Void = { _, _, _ in }
    var onCreate: (Double, Double) -> Void = { _, _ in }
    /// Geometry edits: tap a room, drag a handle, slide an opening. Device pins stay separate.
    var planEditing: Bool = false
    var selectedRoomID: UUID?
    var selectedOpeningID: UUID?
    /// Other rooms in the same coordinate space, used when this canvas shows only one of them.
    var extraSnapPlans: [FloorPlan] = []
    var onSelectRoom: (UUID?) -> Void = { _ in }
    var onSelectOpening: (UUID?) -> Void = { _ in }
    var onCommitPlan: (UUID, FloorPlan) -> Void = { _, _ in }
    var onSelectFurniture: (UUID?) -> Void = { _ in }
    var onMoveFurniture: (UUID, Double, Double) -> Void = { _, _, _ in }
    var onCreateFurniture: (Double, Double) -> Void = { _, _ in }
    var markupPins: [MarkupPin] = []
    var markupSegments: [MarkupSegment] = []
    var draftStart: Vec3? = nil
    var draftEnd: Vec3? = nil
    var selectedMarkupID: UUID? = nil
    var measureEnabled: Bool = false
    var annotateEnabled: Bool = false
    var onMeasurePoint: (Vec3) -> Void = { _ in }
    var onAnnotatePoint: (Vec3) -> Void = { _ in }
    var onSelectMarkup: (UUID) -> Void = { _ in }

    @State private var userScale: Double = 1
    @State private var userOffset = CGSize.zero
    @State private var magnifyBase: Double = 1
    @State private var dragMode: DragMode = .idle
    @State private var panOrigin = CGSize.zero
    @State private var movedDisplay: (id: UUID, x: Double, z: Double)?
    @State private var movedFurniture: (id: UUID, x: Double, z: Double)?
    @State private var editPreview: EditPreview?

    private struct EditPreview {
        var roomID: UUID
        var plan: FloorPlan
        var guides: [PlanGuide]
    }

    private enum DragMode {
        case idle
        case pan
        case pin(UUID)
        case furniture(UUID)
        case handle(UUID, PlanHandle)
        case opening(UUID, UUID)
    }

    /// The committed layers, with the in-progress drag drawn on top. Furniture stays on the layer.
    private var displayLayers: [PlanLayer] {
        guard let editPreview else { return layers }
        return layers.map { layer in
            guard layer.id == editPreview.roomID else { return layer }
            var copy = layer
            copy.plan = editPreview.plan
            return copy
        }
    }

    private struct Palette {
        var ground: Color
        var ink: Color
        var muted: Color
        var line: Color
        var accent: Color
        var door: Color

        static let paper = Palette(
            ground: Theme.card,
            ink: Theme.ink,
            muted: Theme.secondary,
            line: Theme.line.opacity(0.7),
            accent: Theme.accent,
            door: Color(red: 0.55, green: 0.35, blue: 0.24)
        )

        static let charcoal = Palette(
            ground: Theme.charcoal,
            ink: Theme.chalk,
            muted: Theme.mist,
            line: Theme.charcoalLine,
            accent: Theme.accentOnCharcoal,
            door: Color(red: 0.76, green: 0.56, blue: 0.40)
        )
    }

    private var palette: Palette { onCharcoal ? .charcoal : .paper }

    var body: some View {
        GeometryReader { geo in
            let bounds = PlanLayers.bounds(of: layers + ghostLayers)
            let fitted = PlanProjector.fitting(
                bounds: bounds,
                viewWidth: geo.size.width,
                viewHeight: geo.size.height,
                padding: interactive ? 32 : 8
            )
            let projector = adjusted(fitted)
            let drawn = displayLayers
            let canvas = Canvas { context, size in
                drawGrid(in: context, projector: projector, bounds: bounds, size: size)
                drawHeat(in: context, projector: projector, bounds: bounds)
                var ghost = context
                ghost.opacity = 0.28
                for layer in ghostLayers {
                    drawFloor(layer, in: ghost, projector: projector)
                    drawObjects(layer, in: ghost, projector: projector, labeled: false)
                    drawWalls(layer, in: ghost, projector: projector)
                    drawOpenings(layer, in: ghost, projector: projector)
                }
                for layer in drawn {
                    drawFloor(layer, in: context, projector: projector)
                }
                if markup != .structure {
                    for layer in drawn {
                        drawObjects(layer, in: context, projector: projector, labeled: markup == .annotated)
                    }
                }
                for layer in drawn {
                    drawWalls(layer, in: context, projector: projector)
                    drawOpenings(layer, in: context, projector: projector)
                }
                switch markup {
                case .annotated:
                    for layer in drawn {
                        drawLabel(layer, in: context, projector: projector)
                    }
                case .preview:
                    drawPreviewLabels(in: context, projector: projector)
                case .structure:
                    break
                }
                if showPins {
                    drawPins(in: context, projector: projector)
                }
                drawMarkup(in: context, projector: projector)
                drawEditor(in: context, projector: projector)
                if drawn.allSatisfy({ $0.plan.isEmpty }) {
                    context.draw(
                        Text("No measurements yet")
                            .font(.subheadline)
                            .foregroundStyle(palette.muted),
                        at: CGPoint(x: size.width / 2, y: size.height / 2)
                    )
                }
                drawScale(in: context, projector: projector, size: size)
            }
            .contentShape(Rectangle())

            if interactive {
                canvas
                    .gesture(drag(projector))
                    .simultaneousGesture(magnify)
                    .overlay(alignment: .topTrailing) {
                        Button("Fit") { resetView() }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.bordered)
                            .tint(palette.ink)
                            .padding(8)
                            .accessibilityLabel("Fit the floor plan")
                    }
            } else {
                canvas.allowsHitTesting(false)
            }
        }
        .background(palette.ground)
        .environment(\.colorScheme, onCharcoal ? .dark : .light)
        .accessibilityLabel("Floor plan")
        .accessibilityHint(planEditing ? "Tap a room, then drag a handle to resize it. Drag a door or window along its wall." : "")
    }

    private func adjusted(_ fitted: PlanProjector) -> PlanProjector {
        var copy = fitted
        copy.userScale = userScale
        copy.userOffsetX = userOffset.width
        copy.userOffsetY = userOffset.height
        return copy
    }

    private func resetView() {
        userScale = 1
        magnifyBase = 1
        userOffset = .zero
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                userScale = min(8, max(0.4, magnifyBase * value))
            }
            .onEnded { _ in
                magnifyBase = userScale
            }
    }

    private func drag(_ projector: PlanProjector) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if case .idle = dragMode {
                    dragMode = beginDrag(at: value.startLocation, projector: projector)
                }
                switch dragMode {
                case .handle(let roomID, let handle):
                    updateResize(roomID: roomID, handle: handle, at: value.location, projector: projector)
                case .opening(let roomID, let openingID):
                    updateSlide(roomID: roomID, openingID: openingID, at: value.location, projector: projector)
                case .pin(let id):
                    let world = projector.world(screenX: value.location.x, screenY: value.location.y)
                    movedDisplay = (id, world.x, world.z)
                case .furniture(let id):
                    let world = projector.world(screenX: value.location.x, screenY: value.location.y)
                    movedFurniture = (id, world.x, world.z)
                case .pan:
                    userOffset = CGSize(
                        width: panOrigin.width + value.translation.width,
                        height: panOrigin.height + value.translation.height
                    )
                case .idle:
                    break
                }
            }
            .onEnded { value in
                let distance = hypot(value.translation.width, value.translation.height)
                let mode = dragMode
                if distance < 8 {
                    editPreview = nil
                    handleTap(at: value.startLocation, projector: projector)
                } else {
                    switch mode {
                    case .handle(let room, _):
                        onSelectRoom(room)
                        onSelectOpening(nil)
                        onSelectFurniture(nil)
                        commitPreview()
                    case .opening(let room, let opening):
                        onSelectRoom(room)
                        onSelectOpening(opening)
                        onSelectPin(nil)
                        onSelectFurniture(nil)
                        commitPreview()
                    case .pin:
                        if let movedDisplay { commitMove(movedDisplay) }
                    case .furniture:
                        if let movedFurniture { commitFurniture(movedFurniture) }
                    case .pan, .idle:
                        break
                    }
                }
                dragMode = .idle
                movedDisplay = nil
                movedFurniture = nil
                panOrigin = .zero
            }
    }

    private func beginDrag(at location: CGPoint, projector: PlanProjector) -> DragMode {
        if measureEnabled || annotateEnabled {
            panOrigin = userOffset
            return .pan
        }
        if let hit = hitCorner(at: location, projector: projector) {
            return .handle(hit.0, hit.1)
        }
        if let hit = hitOpening(at: location, projector: projector) {
            return .opening(hit.0, hit.1)
        }
        if let furniture = hitFurniture(at: location, projector: projector) {
            return .furniture(furniture)
        }
        if let hit = hitEdge(at: location, projector: projector) {
            return .handle(hit.0, hit.1)
        }
        if showPins, !placingFurniture, let pin = hitPin(at: location, projector: projector) {
            return .pin(pin)
        }
        panOrigin = userOffset
        return .pan
    }

    private func handleTap(at location: CGPoint, projector: PlanProjector) {
        if measureEnabled || annotateEnabled {
            if annotateEnabled, let note = hitMarkup(at: location, projector: projector) {
                onSelectMarkup(note)
                return
            }
            let world = projector.world(screenX: location.x, screenY: location.y)
            let point = Vec3(x: world.x, y: 0, z: world.z)
            if measureEnabled {
                onMeasurePoint(point)
            } else {
                onAnnotatePoint(point)
            }
            return
        }
        if let note = hitMarkup(at: location, projector: projector) {
            onSelectMarkup(note)
            onSelectPin(nil)
            onSelectFurniture(nil)
            return
        }
        if let hit = hitOpening(at: location, projector: projector) {
            onSelectRoom(hit.0)
            onSelectOpening(hit.1)
            onSelectPin(nil)
            onSelectFurniture(nil)
            return
        }
        if showPins, !placingFurniture, let pin = hitPin(at: location, projector: projector) {
            onSelectPin(pin)
            onSelectFurniture(nil)
            onSelectRoom(nil)
            onSelectOpening(nil)
            return
        }
        if let furniture = hitFurniture(at: location, projector: projector) {
            onSelectFurniture(furniture)
            onSelectPin(nil)
            onSelectRoom(nil)
            onSelectOpening(nil)
            return
        }
        if hitCorner(at: location, projector: projector) != nil || hitEdge(at: location, projector: projector) != nil {
            return
        }
        if let room = hitRoom(at: location, projector: projector) {
            onSelectRoom(room)
            onSelectOpening(nil)
            onSelectPin(nil)
            onSelectFurniture(nil)
            return
        }
        if placingFurniture {
            let world = projector.world(screenX: location.x, screenY: location.y)
            onCreateFurniture(world.x, world.z)
            return
        }
        if placing {
            let world = projector.world(screenX: location.x, screenY: location.y)
            onCreate(world.x, world.z)
            return
        }
        onSelectPin(nil)
        onSelectFurniture(nil)
        onSelectRoom(nil)
        onSelectOpening(nil)
    }

    private func updateResize(roomID: UUID, handle: PlanHandle, at location: CGPoint, projector: PlanProjector) {
        guard let layer = layers.first(where: { $0.id == roomID }) else { return }
        let world = projector.world(screenX: location.x, screenY: location.y)
        let local = Vec3(x: world.x - layer.offset.x, y: 0, z: world.z - layer.offset.z)
        let result = PlanEditor.resize(
            layer.plan,
            handle: handle,
            to: local,
            against: snapTargets(for: roomID),
            threshold: snapThreshold(projector)
        )
        editPreview = EditPreview(roomID: roomID, plan: result.plan, guides: result.guides)
    }

    private func updateSlide(roomID: UUID, openingID: UUID, at location: CGPoint, projector: PlanProjector) {
        guard let layer = layers.first(where: { $0.id == roomID }) else { return }
        let world = projector.world(screenX: location.x, screenY: location.y)
        let local = Vec3(x: world.x - layer.offset.x, y: 0, z: world.z - layer.offset.z)
        let result = PlanEditor.slide(
            layer.plan,
            openingID: openingID,
            to: local,
            against: snapTargets(for: roomID),
            threshold: snapThreshold(projector)
        )
        editPreview = EditPreview(roomID: roomID, plan: result.plan, guides: result.guides)
    }

    private func commitPreview() {
        guard let editPreview else { return }
        onCommitPlan(editPreview.roomID, editPreview.plan)
        self.editPreview = nil
    }

    private func snapTargets(for roomID: UUID) -> [FloorPlan] {
        guard let edited = layers.first(where: { $0.id == roomID }) else { return extraSnapPlans }
        let others = layers.compactMap { layer -> FloorPlan? in
            guard layer.id != roomID else { return nil }
            return PlanEditor.translated(layer.plan, by: layer.offset - edited.offset)
        }
        return others + extraSnapPlans
    }

    private func snapThreshold(_ projector: PlanProjector) -> Double {
        let pixels = projector.metersToPoints * max(projector.userScale, 0.001)
        return min(0.16, max(0.04, 12 / pixels))
    }

    private func hitCorner(at point: CGPoint, projector: PlanProjector) -> (UUID, PlanHandle)? {
        guard planEditing, let roomID = selectedRoomID, let box = box(for: roomID) else { return nil }
        let layer = displayLayers.first { $0.id == roomID }
        let offset = layer?.offset ?? .zero
        var best: (PlanHandle, CGFloat)?
        for handle in PlanHandle.all {
            guard case .corner = handle else { continue }
            let screen = screenPoint(box.point(handle) + offset, projector)
            let distance = hypot(screen.x - point.x, screen.y - point.y)
            if distance <= 22, best == nil || distance < best!.1 {
                best = (handle, distance)
            }
        }
        guard let best else { return nil }
        return (roomID, best.0)
    }

    private func hitEdge(at point: CGPoint, projector: PlanProjector) -> (UUID, PlanHandle)? {
        guard planEditing, let roomID = selectedRoomID, let box = box(for: roomID) else { return nil }
        let layer = displayLayers.first { $0.id == roomID }
        let offset = layer?.offset ?? .zero
        var best: (PlanHandle, CGFloat)?
        for handle in PlanHandle.all {
            guard case .edge(let edge) = handle else { continue }
            let segment = box.segment(edge)
            let start = screenPoint(segment.start + offset, projector)
            let end = screenPoint(segment.end + offset, projector)
            let distance = distance(point, to: start, end)
            if distance <= 16, best == nil || distance < best!.1 {
                best = (handle, distance)
            }
        }
        guard let best else { return nil }
        return (roomID, best.0)
    }

    private func hitOpening(at point: CGPoint, projector: PlanProjector) -> (UUID, UUID)? {
        guard planEditing else { return nil }
        var best: (UUID, UUID, CGFloat)?
        for layer in displayLayers {
            for opening in layer.plan.openings {
                let ends = opening.widthEndpoints
                let start = screenPoint(ends.start + layer.offset, projector)
                let end = screenPoint(ends.end + layer.offset, projector)
                let distance = distance(point, to: start, end)
                if distance <= 18, best == nil || distance < best!.2 {
                    best = (layer.id, opening.id, distance)
                }
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    private func hitRoom(at point: CGPoint, projector: PlanProjector) -> UUID? {
        guard planEditing else { return nil }
        let world = projector.world(screenX: point.x, screenY: point.y)
        var best: (UUID, Double)?
        for layer in displayLayers {
            let area = MeasurementMath.floorArea(of: layer.plan)
            guard PlanEditor.contains(x: world.x - layer.offset.x, z: world.z - layer.offset.z, in: layer.plan) else {
                continue
            }
            let score = area > 0 ? area : Double.greatestFiniteMagnitude
            if best == nil || score < best!.1 {
                best = (layer.id, score)
            }
        }
        return best?.0
    }

    private func box(for roomID: UUID) -> PlanBox? {
        guard let layer = displayLayers.first(where: { $0.id == roomID }) else { return nil }
        return PlanEditor.box(of: layer.plan)
    }

    private func drawEditor(in context: GraphicsContext, projector: PlanProjector) {
        guard planEditing else { return }
        if let editPreview, let layer = displayLayers.first(where: { $0.id == editPreview.roomID }) {
            var path = Path()
            for guide in editPreview.guides {
                let start = guide.start + layer.offset
                let end = guide.end + layer.offset
                path.move(to: screenPoint(start, projector))
                path.addLine(to: screenPoint(end, projector))
            }
            context.stroke(
                path,
                with: .color(palette.accent),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [7, 5])
            )
        }
        let roomID = selectedRoomID ?? editPreview?.roomID
        guard let roomID, let layer = displayLayers.first(where: { $0.id == roomID }),
              let box = PlanEditor.box(of: layer.plan) else {
            return
        }
        var outline = Path()
        for edge in [PlanEdge.minU, .maxU, .minV, .maxV] {
            let segment = box.segment(edge)
            outline.move(to: screenPoint(segment.start + layer.offset, projector))
            outline.addLine(to: screenPoint(segment.end + layer.offset, projector))
        }
        context.stroke(outline, with: .color(palette.accent.opacity(0.95)), lineWidth: 1.5)
        for handle in PlanHandle.all {
            let screen = screenPoint(box.point(handle) + layer.offset, projector)
            let corner: Bool
            if case .corner = handle { corner = true } else { corner = false }
            let size: CGFloat = corner ? 12 : 10
            let rect = CGRect(x: screen.x - size / 2, y: screen.y - size / 2, width: size, height: size)
            let path = corner ? Path(roundedRect: rect, cornerRadius: 2) : Path(ellipseIn: rect)
            context.fill(path, with: .color(palette.accent))
            context.stroke(path, with: .color(onCharcoal ? Theme.chalk : Color.white), lineWidth: 1.5)
        }
    }

    private func screenPoint(_ world: Vec3, _ projector: PlanProjector) -> CGPoint {
        point(projector.screen(x: world.x, z: world.z))
    }

    private func distance(_ point: CGPoint, to start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 1 {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + dx * t), point.y - (start.y + dy * t))
    }

    private func commitMove(_ moved: (id: UUID, x: Double, z: Double)) {
        guard let pin = pins.first(where: { $0.id == moved.id }) else { return }
        let stored = PlanLayers.storedXZ(displayX: moved.x, displayZ: moved.z, of: pin, in: layers)
        onMovePin(moved.id, stored.x, stored.z)
    }

    private func commitFurniture(_ moved: (id: UUID, x: Double, z: Double)) {
        guard let layer = layers.first(where: { $0.furniture.contains { $0.id == moved.id } }) else { return }
        let stored = PlanLayers.storedPoint(Vec3(x: moved.x, y: 0, z: moved.z), in: layer)
        onMoveFurniture(moved.id, stored.x, stored.z)
    }

    private func hitFurniture(at point: CGPoint, projector: PlanProjector) -> UUID? {
        for layer in layers.reversed() {
            for item in layer.furniture.reversed() {
                let corners = displayedFootprint(item, offset: layer.offset).map {
                    projector.screen(x: $0.x, z: $0.z)
                }
                if polygonContains(point, corners: corners) {
                    return item.id
                }
            }
        }
        return nil
    }

    private func displayedFootprint(_ item: PlacedFurniture, offset: Vec3) -> [Vec3] {
        var placed = item
        if let movedFurniture, movedFurniture.id == item.id {
            placed.position = Vec3(x: movedFurniture.x - offset.x, y: item.position.y, z: movedFurniture.z - offset.z)
        }
        return FurnitureGeometry.footprint(of: placed).map { $0 + offset }
    }

    private func polygonContains(_ point: CGPoint, corners: [(x: Double, y: Double)]) -> Bool {
        guard corners.count >= 3 else { return false }
        var inside = false
        var previous = corners[corners.count - 1]
        for corner in corners {
            let crosses = (corner.y > point.y) != (previous.y > point.y)
            if crosses {
                let x = (previous.x - corner.x) * (point.y - corner.y) / (previous.y - corner.y) + corner.x
                if point.x < x { inside.toggle() }
            }
            previous = corner
        }
        return inside
    }

    private func hitPin(at point: CGPoint, projector: PlanProjector) -> UUID? {
        var best: (UUID, Double)?
        for pin in pins {
            let world = displayed(pin)
            let screen = projector.screen(x: world.x, z: world.z)
            let distance = hypot(screen.x - point.x, screen.y - point.y)
            if distance <= 22, best == nil || distance < best!.1 {
                best = (pin.id, distance)
            }
        }
        return best?.0
    }

    private func hitMarkup(at point: CGPoint, projector: PlanProjector) -> UUID? {
        var best: (UUID, Double)?
        for pin in markupPins {
            let screen = projector.screen(x: pin.position.x, z: pin.position.z)
            let distance = hypot(screen.x - point.x, screen.y - point.y)
            if distance <= 22, best == nil || distance < best!.1 {
                best = (pin.id, distance)
            }
        }
        return best?.0
    }

    private func drawMarkup(in context: GraphicsContext, projector: PlanProjector) {
        let accent = palette.accent
        func stroke(_ start: Vec3, _ end: Vec3, title: String) {
            var path = Path()
            let a = point(projector.screen(x: start.x, z: start.z))
            let b = point(projector.screen(x: end.x, z: end.z))
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 10)
            context.draw(
                Text(title)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.ink),
                at: mid
            )
        }
        for segment in markupSegments {
            stroke(segment.start, segment.end, segment.title)
        }
        if let draftStart {
            let screen = point(projector.screen(x: draftStart.x, z: draftStart.z))
            let rect = CGRect(x: screen.x - 5, y: screen.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: rect), with: .color(accent))
            if let draftEnd {
                let title = MeasureSnap.label(from: draftStart, to: draftEnd)
                stroke(draftStart, draftEnd, title)
            }
        }
        for pin in markupPins {
            let screen = point(projector.screen(x: pin.position.x, z: pin.position.z))
            let selected = pin.id == selectedMarkupID
            let radius: CGFloat = selected ? 8 : 6
            let rect = CGRect(x: screen.x - radius, y: screen.y - radius, width: radius * 2, height: radius * 2)
            let color: Color = pin.kind == .inventory ? Theme.warn : accent
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(palette.ink), lineWidth: selected ? 2 : 1)
            if selected {
                context.draw(
                    Text(pin.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(palette.ink),
                    at: CGPoint(x: screen.x, y: screen.y - radius - 8)
                )
            }
        }
    }

    private func displayed(_ pin: DevicePin) -> Vec3 {
        if let movedDisplay, movedDisplay.id == pin.id {
            return Vec3(x: movedDisplay.x, y: pin.position.y, z: movedDisplay.z)
        }
        return PlanLayers.displayPosition(of: pin, in: layers)
    }

    private func drawHeat(in context: GraphicsContext, projector: PlanProjector, bounds: AABB) {
        guard let span = Heatmap.range(of: heatSamples) else { return }
        let cells = Heatmap.grid(samples: heatSamples, bounds: bounds, columns: 18, rows: 18)
        let columnCount = cells.first?.count ?? 0
        guard columnCount > 0 else { return }
        let rowCount = cells.count
        for (row, line) in cells.enumerated() {
            for (column, value) in line.enumerated() {
                guard let value else { continue }
                let x0 = bounds.min.x + Double(column) / Double(columnCount) * bounds.size.x
                let x1 = bounds.min.x + Double(column + 1) / Double(columnCount) * bounds.size.x
                let z0 = bounds.min.z + Double(row) / Double(rowCount) * bounds.size.z
                let z1 = bounds.min.z + Double(row + 1) / Double(rowCount) * bounds.size.z
                let origin = point(projector.screen(x: x0, z: z0))
                let opposite = point(projector.screen(x: x1, z: z1))
                let rect = CGRect(
                    x: min(origin.x, opposite.x),
                    y: min(origin.y, opposite.y),
                    width: abs(opposite.x - origin.x),
                    height: abs(opposite.y - origin.y)
                )
                context.fill(Path(rect), with: .color(heatColor(value, span: span)))
            }
        }
    }

    private func heatColor(_ value: Double, span: (min: Double, max: Double)) -> Color {
        let width = span.max - span.min
        let t = width < 0.0001 ? 0.5 : min(1, max(0, (value - span.min) / width))
        return Color(red: t, green: 0.35 * (1 - abs(t - 0.5) * 2), blue: 1 - t).opacity(0.42)
    }

    private func drawGrid(in context: GraphicsContext, projector: PlanProjector, bounds: AABB, size: CGSize) {
        var path = Path()
        let startX = floor(bounds.min.x)
        let endX = ceil(bounds.max.x)
        var x = startX
        while x <= endX + 0.001 {
            let top = point(projector.screen(x: x, z: bounds.min.z))
            let bottom = point(projector.screen(x: x, z: bounds.max.z))
            path.move(to: top)
            path.addLine(to: bottom)
            x += 1
        }
        let startZ = floor(bounds.min.z)
        let endZ = ceil(bounds.max.z)
        var z = startZ
        while z <= endZ + 0.001 {
            let left = point(projector.screen(x: bounds.min.x, z: z))
            let right = point(projector.screen(x: bounds.max.x, z: z))
            path.move(to: left)
            path.addLine(to: right)
            z += 1
        }
        context.stroke(path, with: .color(palette.line), lineWidth: 1)
    }

    private func drawFloor(_ layer: PlanLayer, in context: GraphicsContext, projector: PlanProjector) {
        for floor in layer.plan.floors where floor.corners.count >= 3 {
            var path = Path()
            let first = shifted(floor.corners[0], by: layer.offset)
            path.move(to: point(projector.screen(x: first.x, z: first.z)))
            for corner in floor.corners.dropFirst() {
                let world = shifted(corner, by: layer.offset)
                path.addLine(to: point(projector.screen(x: world.x, z: world.z)))
            }
            path.closeSubpath()
            context.fill(path, with: .color(floorColor(layer)))
        }
    }

    private func floorColor(_ layer: PlanLayer) -> Color {
        if layer.ghost {
            return palette.ink.opacity(onCharcoal ? 0.16 : 0.1)
        }
        if let flooring = layer.flooring {
            return Color(red: flooring.red, green: flooring.green, blue: flooring.blue)
                .opacity(onCharcoal ? 0.72 : 0.95)
        }
        return Theme.roomTint(layer.tintIndex, onCharcoal: onCharcoal)
    }

    private func drawObjects(
        _ layer: PlanLayer,
        in context: GraphicsContext,
        projector: PlanProjector,
        labeled: Bool
    ) {
        let hidden = Set(layer.furniture.compactMap(\.replacesObjectId))
        for object in layer.plan.objects where !hidden.contains(object.id) {
            let corners = object.footprint.map { shifted($0, by: layer.offset) }
            guard corners.count >= 3 else { continue }
            var path = Path()
            path.move(to: point(projector.screen(x: corners[0].x, z: corners[0].z)))
            for corner in corners.dropFirst() {
                path.addLine(to: point(projector.screen(x: corner.x, z: corner.z)))
            }
            path.closeSubpath()
            context.fill(path, with: .color(changeFill(object.id)))
            context.stroke(
                path,
                with: .color(changeStroke(object.id)),
                style: StrokeStyle(lineWidth: changeLineWidth(object.id), dash: changeDash(object.id))
            )
            if labeled {
                let anchor = shifted(object.center, by: layer.offset)
                let screen = point(projector.screen(x: anchor.x, z: anchor.z))
                context.draw(
                    Text("\(ObjectLabels.title(for: object.category))\n\(ObjectLabels.footprint(object))")
                        .font(.caption2)
                        .foregroundStyle(palette.ink),
                    at: screen
                )
            }
        }
        for change in changes {
            guard case .removed = change.kind else { continue }
            let corners = change.object.footprint.map { shifted($0, by: layer.offset) }
            guard corners.count >= 3 else { continue }
            var path = Path()
            path.move(to: point(projector.screen(x: corners[0].x, z: corners[0].z)))
            for corner in corners.dropFirst() {
                path.addLine(to: point(projector.screen(x: corner.x, z: corner.z)))
            }
            path.closeSubpath()
            context.stroke(path, with: .color(Theme.warn), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
        for item in layer.furniture {
            let corners = displayedFootprint(item, offset: layer.offset)
            guard corners.count >= 3 else { continue }
            var path = Path()
            path.move(to: point(projector.screen(x: corners[0].x, z: corners[0].z)))
            for corner in corners.dropFirst() {
                path.addLine(to: point(projector.screen(x: corner.x, z: corner.z)))
            }
            path.closeSubpath()
            let selected = item.id == selectedFurnitureID
            let fill = palette.accent.opacity(selected ? 0.45 : (onCharcoal ? 0.28 : 0.18))
            context.fill(path, with: .color(fill))
            context.stroke(
                path,
                with: .color(selected ? palette.accent : palette.ink.opacity(0.8)),
                style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5)
            )
            if labeled, let catalog = FurnitureCatalog.item(id: item.catalogId) {
                let anchor = corners.reduce(Vec3.zero) { $0 + $1 }
                let count = Double(corners.count)
                let center = Vec3(x: anchor.x / count, y: 0, z: anchor.z / count)
                let screen = point(projector.screen(x: center.x, z: center.z))
                let size = FurnitureGeometry.worldSize(of: item)
                context.draw(
                    Text("\(catalog.name)\n\(ObjectLabels.meters(size.x)) × \(ObjectLabels.meters(size.z)) m")
                        .font(.caption2)
                        .foregroundStyle(palette.ink),
                    at: screen
                )
            }
        }
    }

    private func changeFill(_ id: UUID) -> Color {
        switch changeKind(id) {
        case .added: return Color(red: 0.18, green: 0.55, blue: 0.32).opacity(0.25)
        case .moved: return Theme.warn.opacity(0.2)
        case .removed, .unchanged: return palette.ink.opacity(onCharcoal ? 0.16 : 0.08)
        }
    }

    private func changeStroke(_ id: UUID) -> Color {
        switch changeKind(id) {
        case .added: return Color(red: 0.18, green: 0.55, blue: 0.32)
        case .moved: return Theme.warn
        case .removed, .unchanged: return palette.ink.opacity(onCharcoal ? 0.75 : 0.35)
        }
    }

    private func changeLineWidth(_ id: UUID) -> CGFloat {
        switch changeKind(id) {
        case .added, .moved: return 2
        case .removed, .unchanged: return 1
        }
    }

    private func changeDash(_ id: UUID) -> [CGFloat] {
        if case .moved = changeKind(id) { return [5, 3] }
        return []
    }

    private func changeKind(_ id: UUID) -> ObjectChange.Kind {
        changes.first { $0.object.id == id }?.kind ?? .unchanged
    }

    private func drawWalls(_ layer: PlanLayer, in context: GraphicsContext, projector: PlanProjector) {
        var path = Path()
        for wall in layer.plan.walls {
            let start = shifted(wall.start, by: layer.offset)
            let end = shifted(wall.end, by: layer.offset)
            path.move(to: point(projector.screen(x: start.x, z: start.z)))
            path.addLine(to: point(projector.screen(x: end.x, z: end.z)))
        }
        let width = max(3, 0.12 * projector.metersToPoints * projector.userScale)
        context.stroke(path, with: .color(palette.ink), style: StrokeStyle(lineWidth: width, lineCap: .square))
    }

    private func drawOpenings(_ layer: PlanLayer, in context: GraphicsContext, projector: PlanProjector) {
        for opening in layer.plan.openings {
            let ends = opening.widthEndpoints
            let start = shifted(ends.start, by: layer.offset)
            let end = shifted(ends.end, by: layer.offset)
            var path = Path()
            path.move(to: point(projector.screen(x: start.x, z: start.z)))
            path.addLine(to: point(projector.screen(x: end.x, z: end.z)))
            let erase = max(5, 0.16 * projector.metersToPoints * projector.userScale)
            context.stroke(path, with: .color(palette.ground), style: StrokeStyle(lineWidth: erase, lineCap: .butt))
            let selected = opening.id == selectedOpeningID
            let color: Color = selected ? palette.accent : (opening.kind == .window ? palette.accent : palette.door)
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: selected ? 4 : 2, lineCap: .round)
            )
        }
    }

    private func drawPreviewLabels(in context: GraphicsContext, projector: PlanProjector) {
        struct Item {
            var name: String
            var room: PlanLabelFit.Span
            var size: PlanLabelFit.LabelSize
        }
        var items: [Item] = []
        for layer in displayLayers {
            guard !layer.plan.isEmpty, !layer.name.isEmpty else { continue }
            guard let room = roomSpan(layer, projector: projector) else { continue }
            let measured = context.resolve(
                Text(layer.name).font(.caption.weight(.medium))
            ).measure(in: CGSize(width: 2000, height: 80))
            guard measured.width > 0, measured.height > 0 else { continue }
            items.append(Item(
                name: layer.name,
                room: room,
                size: PlanLabelFit.LabelSize(width: Double(measured.width), height: Double(measured.height))
            ))
        }
        let accepted = PlanLabelFit.accepted(
            rooms: items.map(\.room),
            labelSizes: items.map(\.size)
        )
        for index in accepted {
            let item = items[index]
            context.draw(
                Text(item.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.muted),
                at: point((
                    x: (item.room.minX + item.room.maxX) / 2,
                    y: (item.room.minY + item.room.maxY) / 2
                ))
            )
        }
    }

    /// Walls and floor corners, in screen points. Furniture is left out so a
    /// name is judged against the room, not the objects inside it.
    private func roomSpan(_ layer: PlanLayer, projector: PlanProjector) -> PlanLabelFit.Span? {
        var points: [(x: Double, y: Double)] = []
        for floor in layer.plan.floors {
            for corner in floor.corners {
                let world = shifted(corner, by: layer.offset)
                points.append(projector.screen(x: world.x, z: world.z))
            }
        }
        for wall in layer.plan.walls {
            let start = shifted(wall.start, by: layer.offset)
            let end = shifted(wall.end, by: layer.offset)
            points.append(projector.screen(x: start.x, z: start.z))
            points.append(projector.screen(x: end.x, z: end.z))
        }
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        guard maxX - minX > 1, maxY - minY > 1 else { return nil }
        return PlanLabelFit.Span(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func drawLabel(_ layer: PlanLayer, in context: GraphicsContext, projector: PlanProjector) {
        let box = FloorPlanGeometry.bounds(of: layer.plan).translated(by: layer.offset)
        let screen = projector.screen(x: box.center.x, z: box.center.z)
        context.draw(
            Text(layer.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.muted),
            at: point(screen)
        )
    }

    private func drawPins(in context: GraphicsContext, projector: PlanProjector) {
        for pin in pins {
            let world = displayed(pin)
            let screen = point(projector.screen(x: world.x, z: world.z))
            let selected = pin.id == selectedPinID
            let radius: CGFloat = selected ? 9 : 7
            let rect = CGRect(x: screen.x - radius, y: screen.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(pinColor(pin)))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: selected ? 2 : 1)
            if let caption = pinCaptions[pin.id], !caption.isEmpty {
                context.draw(
                    Text(caption)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.ink),
                    at: CGPoint(x: screen.x + radius + 4, y: screen.y),
                    anchor: .leading
                )
            }
        }
    }

    private func drawScale(in context: GraphicsContext, projector: PlanProjector, size: CGSize) {
        guard interactive else { return }
        let pixels = projector.metersToPoints * projector.userScale
        guard pixels > 12, pixels < size.width * 0.7 else { return }
        var path = Path()
        let y = size.height - 16
        path.move(to: CGPoint(x: 16, y: y))
        path.addLine(to: CGPoint(x: 16 + pixels, y: y))
        context.stroke(path, with: .color(palette.ink), lineWidth: 1.5)
        context.draw(
            Text("1 m").font(.caption2).foregroundStyle(palette.ink),
            at: CGPoint(x: 16 + pixels / 2, y: y - 10)
        )
    }

    private func pinColor(_ pin: DevicePin) -> Color {
        PinPaint.color(
            pinLooks[pin.id],
            linked: pin.entityId != nil,
            muted: palette.muted,
            accent: palette.accent,
            ink: palette.ink
        )
    }

    private func point(_ value: (x: Double, y: Double)) -> CGPoint {
        CGPoint(x: value.x, y: value.y)
    }

    private func shifted(_ point: Vec3, by offset: Vec3) -> Vec3 {
        point + offset
    }
}
