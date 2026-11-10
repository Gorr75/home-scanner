import QuartzCore
import SceneKit
import SwiftUI
import RoomScanCore
import UIKit

struct SurfacePaint {
    var surfaceId: UUID
    var image: UIImage
    var corners: [ImagePoint]
}

struct RoomModelView: UIViewRepresentable {
    var layers: [PlanLayer]
    var usdzURL: URL?
    var pins: [DevicePin]
    var showPins: Bool
    var looksByEntity: [String: PinLook]
    var captionByPin: [UUID: String]
    var selectedPinID: UUID?
    var placementEnabled: Bool
    var cameraToken: Int
    var onSelectPin: (UUID?) -> Void
    var onTogglePin: (UUID) -> Void
    var onPlace: (Vec3) -> Void
    var onRenderedUSDZ: (Bool) -> Void
    var surfacePaints: [SurfacePaint] = []
    /// Nil keeps the neutral studio lights. A value tints the room and lets on-lights cast colour.
    var daylight: DaylightTint? = nil
    /// Stacked storeys. Walls fade as the camera gets close.
    var dollhouse: Bool = false
    var selectedFurnitureID: UUID? = nil
    var placingFurniture: Bool = false
    var onSelectFurniture: (UUID?) -> Void = { _ in }
    var onMoveFurniture: (UUID, Vec3) -> Void = { _, _ in }
    var onPlaceFurniture: (Vec3) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(Theme.charcoal)
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.draggedFurniture(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        context.coordinator.furniturePan = pan
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        view.autoenablesDefaultLighting = false
        view.delegate = context.coordinator
        if let pan = context.coordinator.furniturePan {
            for gesture in view.gestureRecognizers ?? [] where gesture !== pan && gesture is UIPanGestureRecognizer {
                gesture.require(toFail: pan)
            }
        }
        let urlKey = usdzURL?.path
        let signature = Self.structureSignature(layers)
        let geometryChanged = context.coordinator.signature != signature || context.coordinator.urlKey != urlKey
        if geometryChanged || view.scene == nil {
            let scene = SCNScene()
            scene.background.contents = view.backgroundColor
            var usedUSDZ = false
            if let usdzURL, FileManager.default.fileExists(atPath: usdzURL.path),
               let loaded = try? SCNScene(url: usdzURL, options: [.checkConsistency: false]) {
                copyChildren(from: loaded, into: scene)
                usedUSDZ = true
            } else {
                addProceduralGeometry(to: scene)
            }
            view.scene = scene
            context.coordinator.layers = layers
            context.coordinator.signature = signature
            context.coordinator.urlKey = urlKey
            context.coordinator.renderedUSDZ = usedUSDZ
            frameCamera(in: view, scene: scene)
            context.coordinator.cameraToken = cameraToken
            let rendered = usedUSDZ
            let report = onRenderedUSDZ
            DispatchQueue.main.async {
                report(rendered)
            }
        } else if context.coordinator.cameraToken != cameraToken, let scene = view.scene {
            frameCamera(in: view, scene: scene)
            context.coordinator.cameraToken = cameraToken
        }
        if let scene = view.scene {
            applyLighting(to: scene, in: view)
            replacePins(in: scene)
            replaceFurniture(in: scene)
            replaceTextures(in: scene)
        }
    }

    /// Walls, floors, and openings. Furniture is redrawn on its own so a drag does not reset the camera.
    private static func structureSignature(_ layers: [PlanLayer]) -> [PlanLayer] {
        layers.map { layer in
            var copy = layer
            copy.furniture = []
            return copy
        }
    }

    /// Sun or studio key plus an ambient fill. Pin bulbs are added with the pins so a
    /// lamp stays in its own colour when the room goes blue.
    private func applyLighting(to scene: SCNScene, in view: SCNView) {
        let backdrop = DaylightPaint.background(daylight)
        view.backgroundColor = backdrop
        scene.background.contents = backdrop
        let tint = daylight ?? .studio
        let key = lightNode(named: "daylight-key", type: .directional, in: scene)
        key.light?.color = DaylightPaint.color(tint)
        key.light?.intensity = CGFloat(1100 * tint.key)
        key.eulerAngles = SCNVector3(-1.0, DaylightPaint.yaw(for: tint.phase), 0)
        let fill = lightNode(named: "daylight-fill", type: .ambient, in: scene)
        fill.light?.color = DaylightPaint.color(tint)
        fill.light?.intensity = CGFloat(700 * tint.fill)
    }

    private func lightNode(named name: String, type: SCNLight.LightType, in scene: SCNScene) -> SCNNode {
        if let existing = scene.rootNode.childNode(withName: name, recursively: false) {
            existing.light?.type = type
            return existing
        }
        let node = SCNNode()
        node.name = name
        let light = SCNLight()
        light.type = type
        light.castsShadow = false
        node.light = light
        scene.rootNode.addChildNode(node)
        return node
    }

    private func replaceTextures(in scene: SCNScene) {
        scene.rootNode.childNodes
            .filter { $0.name?.hasPrefix("texture:") == true }
            .forEach { $0.removeFromParentNode() }
        for paint in surfacePaints {
            for layer in layers {
                if let wall = layer.plan.walls.first(where: { $0.id == paint.surfaceId }) {
                    addTexturedQuad(SurfaceFrame.wallCorners(wall, offset: layer.offset), paint: paint, in: scene)
                }
                if let floor = layer.plan.floors.first(where: { $0.id == paint.surfaceId }) {
                    let corners = SurfaceFrame.floorCorners(floor, offset: layer.offset)
                    if corners.count == 4 {
                        addTexturedQuad(corners, paint: paint, in: scene)
                    }
                }
            }
        }
    }

    private func addTexturedQuad(_ corners: [Vec3], paint: SurfacePaint, in scene: SCNScene) {
        guard corners.count == 4, paint.corners.count == 4 else { return }
        let vertices = corners.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
        let coordinates = paint.corners.map { CGPoint(x: $0.x, y: 1 - $0.y) }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let uvSource = SCNGeometrySource(textureCoordinates: coordinates)
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: 2, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [vertexSource, uvSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = paint.image
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = "texture:\(paint.surfaceId.uuidString)"
        scene.rootNode.addChildNode(node)
    }

    private func copyChildren(from source: SCNScene, into destination: SCNScene) {
        for child in source.rootNode.childNodes {
            destination.rootNode.addChildNode(child.clone())
        }
    }

    private func addProceduralGeometry(to scene: SCNScene) {
        for layer in layers {
            addFloors(layer, to: scene)
            addWalls(layer, to: scene)
            addOpenings(layer, to: scene)
            addObjects(layer, to: scene)
        }
    }

    private func addFloors(_ layer: PlanLayer, to scene: SCNScene) {
            let color = floorColor(for: layer)
        for floor in layer.plan.floors where floor.corners.count >= 3 {
            let path = UIBezierPath()
            let first = floor.corners[0]
            path.move(to: CGPoint(x: first.x + layer.offset.x, y: -(first.z + layer.offset.z)))
            for corner in floor.corners.dropFirst() {
                path.addLine(to: CGPoint(x: corner.x + layer.offset.x, y: -(corner.z + layer.offset.z)))
            }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0.02)
            shape.materials = [material(color, roughness: 0.9)]
            let node = SCNNode(geometry: shape)
            node.eulerAngles.x = -.pi / 2
            node.position.y = Float(layer.offset.y) - 0.02
            scene.rootNode.addChildNode(node)
        }
    }

    private func addWalls(_ layer: PlanLayer, to scene: SCNScene) {
        for wall in layer.plan.walls {
            let start = wall.start + layer.offset
            let end = wall.end + layer.offset
            let dx = end.x - start.x
            let dz = end.z - start.z
            let length = (dx * dx + dz * dz).squareRoot()
            guard length > 0.02 else { continue }
            let box = SCNBox(
                width: CGFloat(length),
                height: CGFloat(max(wall.height, 0.1)),
                length: CGFloat(max(wall.thickness, 0.04)),
                chamferRadius: 0
            )
            box.materials = [material(Self.wallColor)]
            let node = SCNNode(geometry: box)
            node.name = "dollhouse-wall"
            node.position = SCNVector3(
                Float((start.x + end.x) / 2),
                Float(start.y + wall.height / 2),
                Float((start.z + end.z) / 2)
            )
            node.eulerAngles.y = -Float(atan2(dz, dx))
            scene.rootNode.addChildNode(node)
        }
    }

    private func addOpenings(_ layer: PlanLayer, to scene: SCNScene) {
        for opening in layer.plan.openings {
            let box = SCNBox(
                width: CGFloat(max(opening.width, 0.05)),
                height: CGFloat(max(opening.height, 0.05)),
                length: 0.08,
                chamferRadius: 0
            )
            let isWindow = opening.kind == .window
            box.materials = [
                material(
                    isWindow ? Self.windowColor : Self.doorColor,
                    roughness: isWindow ? 0.15 : 0.55,
                    alpha: isWindow ? 0.45 : 1
                )
            ]
            let node = SCNNode(geometry: box)
            let center = opening.center + layer.offset
            node.position = SCNVector3(Float(center.x), Float(center.y), Float(center.z))
            node.eulerAngles.y = -Float(opening.yaw)
            scene.rootNode.addChildNode(node)
        }
    }

    private func addObjects(_ layer: PlanLayer, to scene: SCNScene) {
        let hidden = Set(layer.furniture.compactMap(\.replacesObjectId))
        for object in layer.plan.objects where !hidden.contains(object.id) {
            let box = SCNBox(
                width: CGFloat(max(object.dimensions.x, 0.05)),
                height: CGFloat(max(object.dimensions.y, 0.05)),
                length: CGFloat(max(object.dimensions.z, 0.05)),
                chamferRadius: 0.01
            )
            box.materials = [material(Self.objectColor, roughness: 0.7)]
            let node = SCNNode(geometry: box)
            let center = object.center + layer.offset
            node.position = SCNVector3(Float(center.x), Float(center.y), Float(center.z))
            node.eulerAngles.y = -Float(object.yaw)
            scene.rootNode.addChildNode(node)
        }
    }

    private func floorColor(for layer: PlanLayer) -> UIColor {
        if let flooring = layer.flooring {
            return UIColor(red: flooring.red, green: flooring.green, blue: flooring.blue, alpha: 1)
        }
        return Self.floorColors[abs(layer.tintIndex) % Self.floorColors.count]
    }

    private func replaceFurniture(in scene: SCNScene) {
        scene.rootNode.childNodes
            .filter { $0.name?.hasPrefix("furniture:") == true }
            .forEach { $0.removeFromParentNode() }
        for layer in layers {
            for item in layer.furniture {
                let root = SCNNode()
                root.name = "furniture:\(item.id.uuidString)"
                let origin = item.position + layer.offset
                root.position = SCNVector3(Float(origin.x), Float(origin.y), Float(origin.z))
                root.eulerAngles.y = -Float(item.yaw)
                let parts = FurnitureCatalog.item(id: item.catalogId)?.parts ?? []
                if parts.isEmpty {
                    root.addChildNode(partNode(
                        shape: .box,
                        center: Vec3(x: 0, y: 0.25, z: 0),
                        size: Vec3(x: 0.5, y: 0.5, z: 0.5),
                        material: FurnitureMaterial(name: "missing", red: 0.55, green: 0.46, blue: 0.36)
                    ))
                } else {
                    for part in parts {
                        let center = Vec3(
                            x: part.center.x * item.scale.x,
                            y: part.center.y * item.scale.y,
                            z: part.center.z * item.scale.z
                        )
                        let size: Vec3
                        switch part.shape {
                        case .box:
                            size = Vec3(
                                x: part.size.x * item.scale.x,
                                y: part.size.y * item.scale.y,
                                z: part.size.z * item.scale.z
                            )
                        case .cylinder:
                            let diameter = part.size.x * max(item.scale.x, item.scale.z)
                            size = Vec3(x: diameter, y: part.size.y * item.scale.y, z: diameter)
                        }
                        root.addChildNode(partNode(shape: part.shape, center: center, size: size, material: part.material))
                    }
                }
                if item.id == selectedFurnitureID {
                    let size = FurnitureGeometry.worldSize(of: item)
                    let ring = SCNBox(width: CGFloat(size.x + 0.04), height: 0.02, length: CGFloat(size.z + 0.04), chamferRadius: 0)
                    let ringMaterial = material(UIColor(Theme.accentOnCharcoal), roughness: 0.4)
                    ringMaterial.emission.contents = UIColor(Theme.accentOnCharcoal)
                    ring.materials = [ringMaterial]
                    let ringNode = SCNNode(geometry: ring)
                    ringNode.position = SCNVector3(0, 0.02, 0)
                    root.addChildNode(ringNode)
                }
                scene.rootNode.addChildNode(root)
            }
        }
    }

    private func partNode(shape: FurnitureShape, center: Vec3, size: Vec3, material: FurnitureMaterial) -> SCNNode {
        let geometry: SCNGeometry
        switch shape {
        case .box:
            geometry = SCNBox(
                width: CGFloat(max(size.x, 0.01)),
                height: CGFloat(max(size.y, 0.01)),
                length: CGFloat(max(size.z, 0.01)),
                chamferRadius: 0.005
            )
        case .cylinder:
            geometry = SCNCylinder(radius: CGFloat(max(size.x, 0.01) / 2), height: CGFloat(max(size.y, 0.01)))
        }
        let surface = self.material(
            UIColor(red: material.red, green: material.green, blue: material.blue, alpha: material.alpha),
            roughness: CGFloat(material.roughness),
            alpha: CGFloat(material.alpha)
        )
        surface.metalness.contents = material.metallic
        geometry.materials = [surface]
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(Float(center.x), Float(center.y), Float(center.z))
        return node
    }

    private func replacePins(in scene: SCNScene) {
        scene.rootNode.childNodes
            .filter { $0.name?.hasPrefix("pin:") == true }
            .forEach { $0.removeFromParentNode() }
        guard showPins else { return }
        for pin in pins {
            let world = PlanLayers.displayPosition(of: pin, in: layers)
            let root = SCNNode()
            root.name = "pin:\(pin.id.uuidString)"
            let sphere = SCNSphere(radius: pin.id == selectedPinID ? 0.09 : 0.07)
            sphere.segmentCount = 18
            let pinColor = color(for: pin)
            let pinMaterial = material(pinColor, roughness: 0.35)
            let look = look(for: pin)
            let lampOn = look?.domain == "light" && look?.state == "on"
            if lampOn {
                pinMaterial.emission.contents = pinColor
                pinMaterial.lightingModel = .constant
                if daylight != nil {
                    pinMaterial.emission.intensity = CGFloat(1 + 1.4 * (1 - lighting.key))
                }
            } else if pin.id == selectedPinID {
                pinMaterial.emission.contents = UIColor(white: 0.4, alpha: 1)
            } else if daylight != nil, lighting.key < 0.35 {
                pinMaterial.emission.contents = pinColor
                pinMaterial.emission.intensity = 0.45
            }
            sphere.materials = [pinMaterial]
            let sphereNode = SCNNode(geometry: sphere)
            sphereNode.position = SCNVector3(Float(world.x), Float(world.y), Float(world.z))
            root.addChildNode(sphereNode)
            if lampOn, daylight != nil, let look {
                root.addChildNode(lampLight(look, at: world))
            }
            let caption = captionByPin[pin.id]
            let label = caption.map { "\(pin.name)\n\($0)" } ?? pin.name
            let textNode = labelNode(label)
            textNode.position = SCNVector3(Float(world.x), Float(world.y + 0.18), Float(world.z))
            root.addChildNode(textNode)
            if world.y > 0.25 {
                let stem = SCNCylinder(radius: 0.012, height: CGFloat(world.y))
                let stemMaterial = material(color(for: pin).withAlphaComponent(0.85), roughness: 0.5)
                if lampOn {
                    stemMaterial.lightingModel = .constant
                }
                stem.materials = [stemMaterial]
                let stemNode = SCNNode(geometry: stem)
                stemNode.position = SCNVector3(Float(world.x), Float(world.y / 2), Float(world.z))
                root.addChildNode(stemNode)
            }
            scene.rootNode.addChildNode(root)
        }
    }

    private func frameCamera(in view: SCNView, scene: SCNScene) {
        scene.rootNode.childNode(withName: "camera", recursively: false)?.removeFromParentNode()
        let box = PlanLayers.bounds(of: layers)
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.fieldOfView = 48
        camera.automaticallyAdjustsZRange = true
        cameraNode.camera = camera
        let center = box.center
        let span = max(box.size.x, box.size.z, 1.6)
        cameraNode.position = SCNVector3(
            Float(center.x + span * 0.1),
            Float(max(box.max.y, 1.2) + span * 0.7),
            Float(center.z + span * 1.05)
        )
        cameraNode.look(at: SCNVector3(Float(center.x), Float(min(max(center.y, 0.4), 1.4)), Float(center.z)))
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
    }

    private var lighting: DaylightTint { daylight ?? .studio }

    /// Omni at an on-light. Intensity rises as the sun drops so the bulb still colours the room at night.
    private func lampLight(_ look: PinLook, at world: Vec3) -> SCNNode {
        let light = SCNLight()
        light.type = .omni
        light.castsShadow = false
        let red = CGFloat(look.red ?? 1)
        let green = CGFloat(look.green ?? 0.78)
        let blue = CGFloat(look.blue ?? 0.45)
        light.color = UIColor(red: red, green: green, blue: blue, alpha: 1)
        let brightness = min(1, max(0, look.brightness ?? 1))
        let presence = 0.35 + 0.65 * brightness
        light.intensity = CGFloat(presence * (280 + 900 * (1 - lighting.key)))
        light.attenuationStartDistance = 0.15
        light.attenuationEndDistance = 3.4
        light.attenuationFalloffExponent = 2
        let node = SCNNode()
        node.name = "pin-light"
        node.light = light
        node.position = SCNVector3(Float(world.x), Float(world.y), Float(world.z))
        return node
    }

    private func look(for pin: DevicePin) -> PinLook? {
        guard let entityId = pin.entityId else { return nil }
        return looksByEntity[entityId]
    }

    private func color(for pin: DevicePin) -> UIColor {
        PinPaint.uiColor(look(for: pin), linked: pin.entityId != nil)
    }

    private func labelNode(_ text: String) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0.2)
        geometry.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        geometry.flatness = 0.3
        geometry.alignmentMode = CATextLayerAlignmentMode.center.rawValue
        let textMaterial = material(UIColor(Theme.chalk), roughness: 1)
        textMaterial.lightingModel = .constant
        geometry.materials = [textMaterial]
        let node = SCNNode(geometry: geometry)
        let (minBound, maxBound) = node.boundingBox
        let dx = (maxBound.x - minBound.x) / 2
        let dy = (maxBound.y - minBound.y) / 2
        node.pivot = SCNMatrix4MakeTranslation(minBound.x + dx, minBound.y + dy, 0)
        node.scale = SCNVector3(0.008, 0.008, 0.008)
        let plate = SCNPlane(
            width: CGFloat(maxBound.x - minBound.x) + 28,
            height: CGFloat(maxBound.y - minBound.y) + 18
        )
        plate.cornerRadius = 8
        let plateMaterial = SCNMaterial()
        plateMaterial.diffuse.contents = UIColor(Theme.charcoal).withAlphaComponent(0.88)
        plateMaterial.lightingModel = .constant
        plateMaterial.isDoubleSided = true
        plate.materials = [plateMaterial]
        let plateNode = SCNNode(geometry: plate)
        plateNode.position = SCNVector3(minBound.x + dx, minBound.y + dy, -0.5)
        node.addChildNode(plateNode)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        node.constraints = [billboard]
        return node
    }

    private func material(_ color: UIColor, roughness: CGFloat = 0.8, alpha: CGFloat = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.roughness.contents = roughness
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
        material.transparency = alpha
        return material
    }

    private static let wallColor = UIColor(red: 0.91, green: 0.88, blue: 0.83, alpha: 1)
    private static let objectColor = UIColor(red: 0.62, green: 0.55, blue: 0.46, alpha: 1)
    private static let doorColor = UIColor(red: 0.55, green: 0.35, blue: 0.24, alpha: 1)
    private static let windowColor = UIColor(red: 0.61, green: 0.75, blue: 0.80, alpha: 1)
    private static let floorColors: [UIColor] = [
        UIColor(red: 0.93, green: 0.89, blue: 0.80, alpha: 1),
        UIColor(red: 0.86, green: 0.90, blue: 0.86, alpha: 1),
        UIColor(red: 0.90, green: 0.86, blue: 0.80, alpha: 1),
        UIColor(red: 0.86, green: 0.88, blue: 0.91, alpha: 1)
    ]

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, SCNSceneRendererDelegate {
        var parent: RoomModelView
        var layers: [PlanLayer] = []
        var signature: [PlanLayer] = []
        var urlKey: String?
        var cameraToken = -1
        var renderedUSDZ = false
        var furniturePan: UIPanGestureRecognizer?
        private var draggingFurniture: UUID?

        init(parent: RoomModelView) {
            self.parent = parent
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view as? SCNView else {
                return true
            }
            return furnitureID(at: pan.location(in: view), in: view) != nil
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let pointOfView = renderer.pointOfView else { return }
            let camera = pointOfView.presentation.worldPosition
            renderer.scene?.rootNode.enumerateChildNodes { node, _ in
                guard node.name == "dollhouse-wall", let material = node.geometry?.firstMaterial else { return }
                guard parent.dollhouse else {
                    material.transparency = 1
                    material.writesToDepthBuffer = true
                    return
                }
                let position = node.presentation.worldPosition
                let dx = camera.x - position.x
                let dy = camera.y - position.y
                let dz = camera.z - position.z
                let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
                let near: Float = 1.5
                let far: Float = 4.0
                let fade = min(1, max(0, (distance - near) / (far - near)))
                material.transparency = CGFloat(fade)
                material.writesToDepthBuffer = fade > 0.85
            }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            if let pin = hits.lazy.compactMap({ self.pinID(in: $0.node) }).first {
                parent.onSelectPin(pin)
                parent.onSelectFurniture(nil)
                parent.onTogglePin(pin)
                return
            }
            if let furniture = hits.lazy.compactMap({ self.furnitureID(in: $0.node) }).first {
                parent.onSelectFurniture(furniture)
                parent.onSelectPin(nil)
                return
            }
            if parent.placingFurniture, let hit = hits.first {
                let location = hit.worldCoordinates
                parent.onPlaceFurniture(Vec3(x: Double(location.x), y: Double(location.y), z: Double(location.z)))
                return
            }
            guard parent.placementEnabled, let hit = hits.first(where: { self.pinID(in: $0.node) == nil }) else {
                if !parent.placementEnabled {
                    parent.onSelectPin(nil)
                    parent.onSelectFurniture(nil)
                }
                return
            }
            let location = hit.worldCoordinates
            parent.onPlace(Vec3(x: Double(location.x), y: Double(location.y), z: Double(location.z)))
        }

        @objc func draggedFurniture(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                guard let id = furnitureID(at: point, in: view) else { return }
                draggingFurniture = id
                parent.onSelectFurniture(id)
                parent.onSelectPin(nil)
                view.allowsCameraControl = false
            case .changed:
                guard let id = draggingFurniture,
                      let item = parent.layers.lazy.compactMap({ layer in
                          layer.furniture.first { $0.id == id }.map { (layer, $0) }
                      }).first else { return }
                let floorY = Float(item.1.position.y + item.0.offset.y)
                guard let world = floorPoint(in: view, screen: point, y: floorY) else { return }
                if let node = view.scene?.rootNode.childNode(withName: "furniture:\(id.uuidString)", recursively: false) {
                    node.position.x = world.x
                    node.position.z = world.z
                }
            case .ended:
                if let id = draggingFurniture,
                   let node = view.scene?.rootNode.childNode(withName: "furniture:\(id.uuidString)", recursively: false) {
                    parent.onMoveFurniture(id, Vec3(
                        x: Double(node.position.x),
                        y: Double(node.position.y),
                        z: Double(node.position.z)
                    ))
                }
                draggingFurniture = nil
                view.allowsCameraControl = true
            case .cancelled, .failed:
                draggingFurniture = nil
                view.allowsCameraControl = true
            default:
                break
            }
        }

        private func floorPoint(in view: SCNView, screen: CGPoint, y: Float) -> SCNVector3? {
            let near = view.unprojectPoint(SCNVector3(Float(screen.x), Float(screen.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(screen.x), Float(screen.y), 1))
            let dy = far.y - near.y
            guard abs(dy) > 0.0001 else { return nil }
            let t = (y - near.y) / dy
            guard t.isFinite else { return nil }
            return SCNVector3(near.x + (far.x - near.x) * t, y, near.z + (far.z - near.z) * t)
        }

        private func furnitureID(at point: CGPoint, in view: SCNView) -> UUID? {
            let hits = view.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            return hits.lazy.compactMap { furnitureID(in: $0.node) }.first
        }

        private func furnitureID(in node: SCNNode) -> UUID? {
            var current: SCNNode? = node
            while let cursor = current {
                if let name = cursor.name, name.hasPrefix("furniture:"),
                   let id = UUID(uuidString: String(name.dropFirst("furniture:".count))) {
                    return id
                }
                current = cursor.parent
            }
            return nil
        }

        private func pinID(in node: SCNNode) -> UUID? {
            var current: SCNNode? = node
            while let cursor = current {
                if let name = cursor.name, name.hasPrefix("pin:"),
                   let id = UUID(uuidString: String(name.dropFirst(4))) {
                    return id
                }
                current = cursor.parent
            }
            return nil
        }
    }
}
