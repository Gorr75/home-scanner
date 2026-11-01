import QuartzCore
import SceneKit
import SwiftUI
import RoomScanCore
import UIKit

struct RoomModelView: UIViewRepresentable {
    var layers: [PlanLayer]
    var usdzURL: URL?
    var pins: [DevicePin]
    var showPins: Bool
    var stateByEntity: [String: String]
    var captionByPin: [UUID: String]
    var selectedPinID: UUID?
    var placementEnabled: Bool
    var cameraToken: Int
    var onSelectPin: (UUID?) -> Void
    var onPlace: (Vec3) -> Void
    var onRenderedUSDZ: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.957, green: 0.941, blue: 0.910, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        let urlKey = usdzURL?.path
        let geometryChanged = context.coordinator.layers != layers || context.coordinator.urlKey != urlKey
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
            replacePins(in: scene)
        }
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
        let color = Self.floorColors[abs(layer.tintIndex) % Self.floorColors.count]
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
            node.position.y = -0.02
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
        for object in layer.plan.objects {
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
            let pinMaterial = material(color(for: pin), roughness: 0.35)
            if pin.id == selectedPinID {
                pinMaterial.emission.contents = UIColor(white: 0.4, alpha: 1)
            }
            sphere.materials = [pinMaterial]
            let sphereNode = SCNNode(geometry: sphere)
            sphereNode.position = SCNVector3(Float(world.x), Float(world.y), Float(world.z))
            root.addChildNode(sphereNode)
            let caption = captionByPin[pin.id]
            let label = caption.map { "\(pin.name)\n\($0)" } ?? pin.name
            let textNode = labelNode(label)
            textNode.position = SCNVector3(Float(world.x), Float(world.y + 0.18), Float(world.z))
            root.addChildNode(textNode)
            if world.y > 0.25 {
                let stem = SCNCylinder(radius: 0.012, height: CGFloat(world.y))
                stem.materials = [material(color(for: pin).withAlphaComponent(0.85), roughness: 0.5)]
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

    private func color(for pin: DevicePin) -> UIColor {
        guard let entityId = pin.entityId, let state = stateByEntity[entityId] else {
            return Self.accent
        }
        if state == "on" { return Self.onColor }
        if state == "off" { return Self.offColor }
        return Self.readingColor
    }

    private func labelNode(_ text: String) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0.2)
        geometry.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        geometry.flatness = 0.3
        geometry.alignmentMode = CATextLayerAlignmentMode.center.rawValue
        geometry.materials = [material(Self.ink, roughness: 1)]
        let node = SCNNode(geometry: geometry)
        let (minBound, maxBound) = node.boundingBox
        let dx = (maxBound.x - minBound.x) / 2
        let dy = (maxBound.y - minBound.y) / 2
        node.pivot = SCNMatrix4MakeTranslation(minBound.x + dx, minBound.y + dy, 0)
        node.scale = SCNVector3(0.008, 0.008, 0.008)
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

    private static let ink = UIColor(red: 0.110, green: 0.098, blue: 0.082, alpha: 1)
    private static let accent = UIColor(red: 0.122, green: 0.420, blue: 0.353, alpha: 1)
    private static let onColor = UIColor(red: 0.18, green: 0.55, blue: 0.32, alpha: 1)
    private static let offColor = UIColor(red: 0.45, green: 0.42, blue: 0.38, alpha: 1)
    private static let readingColor = UIColor(red: 0.20, green: 0.38, blue: 0.55, alpha: 1)
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

    final class Coordinator: NSObject {
        var parent: RoomModelView
        var layers: [PlanLayer] = []
        var urlKey: String?
        var cameraToken = -1
        var renderedUSDZ = false

        init(parent: RoomModelView) {
            self.parent = parent
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: nil)
            if let pin = hits.lazy.compactMap({ pinID(in: $0.node) }).first {
                parent.onSelectPin(pin)
                return
            }
            guard parent.placementEnabled, let hit = hits.first(where: { pinID(in: $0.node) == nil }) else {
                if !parent.placementEnabled {
                    parent.onSelectPin(nil)
                }
                return
            }
            let location = hit.worldCoordinates
            parent.onPlace(Vec3(x: Double(location.x), y: Double(location.y), z: Double(location.z)))
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
