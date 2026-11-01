import SwiftUI
import RoomScanCore

struct FloorPlanCanvas: View {
    var layers: [PlanLayer]
    var pins: [DevicePin]
    var showPins: Bool
    var selectedPinID: UUID?
    var placing: Bool
    var interactive: Bool = true
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
                for layer in layers {
                    drawFloor(layer, in: context, projector: projector)
                }
                for layer in layers {
                    drawObjects(layer, in: context, projector: projector)
                }
                for layer in layers {
                    drawWalls(layer, in: context, projector: projector)
                    drawOpenings(layer, in: context, projector: projector)
                    drawLabel(layer, in: context, projector: projector)
                }
                if showPins {
                    drawPins(in: context, projector: projector)
                }
                if layers.allSatisfy({ $0.plan.isEmpty }) {
                    context.draw(
                        Text("No measurements yet")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary),
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
                            .tint(Theme.ink)
                            .padding(8)
                            .accessibilityLabel("Fit the floor plan")
                    }
            } else {
                canvas.allowsHitTesting(false)
            }
        }
        .background(Theme.card)
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
        context.stroke(path, with: .color(Theme.line.opacity(0.7)), lineWidth: 1)
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
            context.fill(path, with: .color(Theme.roomTint(layer.tintIndex)))
        }
    }

    private func drawObjects(_ layer: PlanLayer, in context: GraphicsContext, projector: PlanProjector) {
        for object in layer.plan.objects {
            let corners = object.footprint.map { shifted($0, by: layer.offset) }
            guard corners.count >= 3 else { continue }
            var path = Path()
            path.move(to: point(projector.screen(x: corners[0].x, z: corners[0].z)))
            for corner in corners.dropFirst() {
                path.addLine(to: point(projector.screen(x: corner.x, z: corner.z)))
            }
            path.closeSubpath()
            context.fill(path, with: .color(Theme.ink.opacity(0.08)))
            context.stroke(path, with: .color(Theme.ink.opacity(0.35)), lineWidth: 1)
        }
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
        context.stroke(path, with: .color(Theme.ink), style: StrokeStyle(lineWidth: width, lineCap: .square))
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
            context.stroke(path, with: .color(Theme.card), style: StrokeStyle(lineWidth: erase, lineCap: .butt))
            let color: Color = opening.kind == .window ? Theme.accent : Color(red: 0.55, green: 0.35, blue: 0.24)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func drawLabel(_ layer: PlanLayer, in context: GraphicsContext, projector: PlanProjector) {
        let box = FloorPlanGeometry.bounds(of: layer.plan).translated(by: layer.offset)
        let screen = projector.screen(x: box.center.x, z: box.center.z)
        context.draw(
            Text(layer.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary),
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
        context.stroke(path, with: .color(Theme.ink), lineWidth: 1.5)
        context.draw(
            Text("1 m").font(.caption2).foregroundStyle(Theme.ink),
            at: CGPoint(x: 16 + pixels / 2, y: y - 10)
        )
    }

    private func pinColor(_ pin: DevicePin) -> Color {
        guard pin.entityId != nil else { return Theme.accent }
        return Theme.ink
    }

    private func point(_ value: (x: Double, y: Double)) -> CGPoint {
        CGPoint(x: value.x, y: value.y)
    }

    private func shifted(_ point: Vec3, by offset: Vec3) -> Vec3 {
        point + offset
    }
}
