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
    var onSelectPin: (UUID?) -> Void = { _ in }
    var onMovePin: (UUID, Double, Double) -> Void = { _, _, _ in }
    var onCreate: (Double, Double) -> Void = { _, _ in }

    @State private var userScale: Double = 1
    @State private var userOffset = CGSize.zero
    @State private var magnifyBase: Double = 1
    @State private var dragMode: DragMode = .idle
    @State private var panOrigin = CGSize.zero
    @State private var movedDisplay: (id: UUID, x: Double, z: Double)?

    private enum DragMode {
        case idle
        case pan
        case pin(UUID)
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
            let bounds = PlanLayers.bounds(of: layers)
            let fitted = PlanProjector.fitting(
                bounds: bounds,
                viewWidth: geo.size.width,
                viewHeight: geo.size.height,
                padding: interactive ? 32 : 8
            )
            let projector = adjusted(fitted)
            let canvas = Canvas { context, size in
                drawGrid(in: context, projector: projector, bounds: bounds, size: size)
                drawHeat(in: context, projector: projector, bounds: bounds)
                for layer in layers {
                    drawFloor(layer, in: context, projector: projector)
                }
                if markup != .structure {
                    for layer in layers {
                        drawObjects(layer, in: context, projector: projector, labeled: markup == .annotated)
                    }
                }
                for layer in layers {
                    drawWalls(layer, in: context, projector: projector)
                    drawOpenings(layer, in: context, projector: projector)
                }
                switch markup {
                case .annotated:
                    for layer in layers {
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
                if layers.allSatisfy({ $0.plan.isEmpty }) {
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
                    if showPins, let pin = hitPin(at: value.startLocation, projector: projector) {
                        dragMode = .pin(pin)
                    } else {
                        panOrigin = userOffset
                        dragMode = .pan
                    }
                }
                switch dragMode {
                case .pin(let id):
                    let world = projector.world(screenX: value.location.x, screenY: value.location.y)
                    movedDisplay = (id, world.x, world.z)
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
                if distance < 8 {
                    if showPins, let pin = hitPin(at: value.startLocation, projector: projector) {
                        onSelectPin(pin)
                    } else if placing {
                        let world = projector.world(screenX: value.location.x, screenY: value.location.y)
                        onCreate(world.x, world.z)
                    } else {
                        onSelectPin(nil)
                    }
                } else if let movedDisplay {
                    commitMove(movedDisplay)
                }
                dragMode = .idle
                movedDisplay = nil
                panOrigin = .zero
            }
    }

    private func commitMove(_ moved: (id: UUID, x: Double, z: Double)) {
        let offset = layers.first { $0.id == pins.first { $0.id == moved.id }?.roomId }?.offset ?? .zero
        onMovePin(moved.id, moved.x - offset.x, moved.z - offset.z)
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
            context.fill(path, with: .color(Theme.roomTint(layer.tintIndex, onCharcoal: onCharcoal)))
        }
    }

    private func drawObjects(
        _ layer: PlanLayer,
        in context: GraphicsContext,
        projector: PlanProjector,
        labeled: Bool
    ) {
        for object in layer.plan.objects {
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
            let color: Color = opening.kind == .window ? palette.accent : palette.door
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func drawPreviewLabels(in context: GraphicsContext, projector: PlanProjector) {
        struct Item {
            var name: String
            var room: PlanLabelFit.Span
            var size: PlanLabelFit.LabelSize
        }
        var items: [Item] = []
        for layer in layers {
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
