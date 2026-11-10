import Metal
import SceneKit
import UIKit
import RoomScanCore

/// SceneKit stills for the photo card. Kept apart from the interactive viewer so a
/// furniture or dollhouse change does not have to touch the upload plates.
enum PlateRenderer {
    static func render(room: Room, pins: [DevicePin]) -> [String: Data] {
        guard let device = MTLCreateSystemDefaultDevice() else { return [:] }
        let viewpoint = PlateCatalog.viewpoint(for: room)
        let lights = pins.filter { $0.kind == .light && ($0.roomId == nil || $0.roomId == room.id) }
        let size = CGSize(width: PlateLayout.width, height: PlateLayout.height)
        var images: [String: Data] = [:]
        for variant in [PlateVariant.day, PlateVariant.night] {
            let tint = variant == .day
                ? DaylightMath.tint(elevation: 48, morning: true)
                : DaylightMath.tint(elevation: -90, morning: false)
            let baseScene = makeScene(plan: room.floorPlan, tint: tint, lamp: nil)
            if let base = snapshot(baseScene, viewpoint: viewpoint, device: device, size: size),
               let jpeg = base.jpegData(compressionQuality: 0.82) {
                images[PlatePaths.base(variant)] = jpeg
            }
            for pin in lights {
                let lit = makeScene(plan: room.floorPlan, tint: tint, lamp: pin.position)
                guard let shot = snapshot(lit, viewpoint: viewpoint, device: device, size: size),
                      let png = illuminationPNG(shot, size: size) else { continue }
                images[PlatePaths.light(pin.id, variant)] = png
            }
        }
        return images
    }

    private static func snapshot(
        _ scene: SCNScene,
        viewpoint: CameraViewpoint,
        device: MTLDevice,
        size: CGSize
    ) -> UIImage? {
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(viewpoint.fieldOfView)
        camera.automaticallyAdjustsZRange = true
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(
            Float(viewpoint.position.x),
            Float(viewpoint.position.y),
            Float(viewpoint.position.z)
        )
        scene.rootNode.addChildNode(cameraNode)
        cameraNode.look(at: SCNVector3(
            Float(viewpoint.target.x),
            Float(viewpoint.target.y),
            Float(viewpoint.target.z)
        ))
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image.size.width > 1 ? image : nil
    }

    private static func makeScene(plan: FloorPlan, tint: DaylightTint, lamp: Vec3?) -> SCNScene {
        let scene = SCNScene()
        let contribution = lamp != nil
        scene.background.contents = contribution ? UIColor.black : DaylightPaint.background(tint)
        addFloors(plan, to: scene)
        addWalls(plan, to: scene)
        addOpenings(plan, to: scene)
        addObjects(plan, to: scene)
        if contribution, let lamp {
            let light = SCNLight()
            light.type = .omni
            light.color = UIColor.white
            light.castsShadow = false
            light.intensity = CGFloat(280 + 900 * (1 - tint.key))
            light.attenuationStartDistance = 0.15
            light.attenuationEndDistance = 4
            light.attenuationFalloffExponent = 2
            let node = SCNNode()
            node.light = light
            node.position = SCNVector3(Float(lamp.x), Float(lamp.y), Float(lamp.z))
            scene.rootNode.addChildNode(node)
        } else {
            let key = SCNLight()
            key.type = .directional
            key.color = DaylightPaint.color(tint)
            key.intensity = CGFloat(1100 * tint.key)
            key.castsShadow = false
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.eulerAngles = SCNVector3(-1.0, DaylightPaint.yaw(for: tint.phase), 0)
            scene.rootNode.addChildNode(keyNode)
            let fill = SCNLight()
            fill.type = .ambient
            fill.color = DaylightPaint.color(tint)
            fill.intensity = CGFloat(700 * tint.fill)
            let fillNode = SCNNode()
            fillNode.light = fill
            scene.rootNode.addChildNode(fillNode)
        }
        return scene
    }

    private static func addFloors(_ plan: FloorPlan, to scene: SCNScene) {
        for floor in plan.floors where floor.corners.count >= 3 {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: floor.corners[0].x, y: -floor.corners[0].z))
            for corner in floor.corners.dropFirst() {
                path.addLine(to: CGPoint(x: corner.x, y: -corner.z))
            }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0.02)
            shape.materials = [material(floorColor)]
            let node = SCNNode(geometry: shape)
            node.eulerAngles.x = -.pi / 2
            node.position.y = -0.02
            scene.rootNode.addChildNode(node)
        }
    }

    private static func addWalls(_ plan: FloorPlan, to scene: SCNScene) {
        for wall in plan.walls {
            let dx = wall.end.x - wall.start.x
            let dz = wall.end.z - wall.start.z
            let length = (dx * dx + dz * dz).squareRoot()
            guard length > 0.02 else { continue }
            let box = SCNBox(
                width: CGFloat(length),
                height: CGFloat(max(wall.height, 0.1)),
                length: CGFloat(max(wall.thickness, 0.04)),
                chamferRadius: 0
            )
            box.materials = [material(wallColor)]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(
                Float((wall.start.x + wall.end.x) / 2),
                Float(wall.start.y + wall.height / 2),
                Float((wall.start.z + wall.end.z) / 2)
            )
            node.eulerAngles.y = -Float(atan2(dz, dx))
            scene.rootNode.addChildNode(node)
        }
    }

    private static func addOpenings(_ plan: FloorPlan, to scene: SCNScene) {
        for opening in plan.openings {
            let box = SCNBox(
                width: CGFloat(max(opening.width, 0.05)),
                height: CGFloat(max(opening.height, 0.05)),
                length: 0.08,
                chamferRadius: 0
            )
            let isWindow = opening.kind == .window
            box.materials = [material(isWindow ? windowColor : doorColor, alpha: isWindow ? 0.45 : 1)]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(Float(opening.center.x), Float(opening.center.y), Float(opening.center.z))
            node.eulerAngles.y = -Float(opening.yaw)
            scene.rootNode.addChildNode(node)
        }
    }

    private static func addObjects(_ plan: FloorPlan, to scene: SCNScene) {
        for object in plan.objects {
            let box = SCNBox(
                width: CGFloat(max(object.dimensions.x, 0.05)),
                height: CGFloat(max(object.dimensions.y, 0.05)),
                length: CGFloat(max(object.dimensions.z, 0.05)),
                chamferRadius: 0.01
            )
            box.materials = [material(objectColor)]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(Float(object.center.x), Float(object.center.y), Float(object.center.z))
            node.eulerAngles.y = -Float(object.yaw)
            scene.rootNode.addChildNode(node)
        }
    }

    private static func material(_ color: UIColor, alpha: CGFloat = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
        material.transparency = alpha
        return material
    }

    /// White RGB with alpha from luminance, so the card can tint the plate with the live colour.
    private static func illuminationPNG(_ image: UIImage, size: CGSize) -> Data? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index])
            let green = Double(pixels[index + 1])
            let blue = Double(pixels[index + 2])
            let luma = UInt8(min(255, max(0, (0.2126 * red + 0.7152 * green + 0.0722 * blue).rounded())))
            pixels[index] = luma
            pixels[index + 1] = luma
            pixels[index + 2] = luma
            pixels[index + 3] = luma
        }
        guard let output = context.makeImage() else { return nil }
        return UIImage(cgImage: output).pngData()
    }

    private static let wallColor = UIColor(red: 0.91, green: 0.88, blue: 0.83, alpha: 1)
    private static let floorColor = UIColor(red: 0.93, green: 0.89, blue: 0.80, alpha: 1)
    private static let objectColor = UIColor(red: 0.62, green: 0.55, blue: 0.46, alpha: 1)
    private static let doorColor = UIColor(red: 0.55, green: 0.35, blue: 0.24, alpha: 1)
    private static let windowColor = UIColor(red: 0.61, green: 0.75, blue: 0.80, alpha: 1)
}
