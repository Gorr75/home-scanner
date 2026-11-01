import SceneKit
import SwiftUI
import RoomScanCore

struct OutdoorZoneView: View {
    @Environment(HomeStore.self) private var store
    let homeID: UUID
    let zoneID: UUID

    private var zone: OutdoorZone? {
        store.home(id: homeID)?.outdoorZone(id: zoneID)
    }

    var body: some View {
        PaperScreen {
            if let zone {
                VStack(spacing: 0) {
                    OutdoorMeshView(
                        url: store.existingFile(homeId: homeID, relative: zone.assets.obj),
                        walls: zone.walls,
                        images: textureImages(for: zone)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        Text("\(zone.kind.label) · \(String(format: "%.1f", zone.height)) m tall · drag to orbit")
                            .font(.caption)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(12)
                    }
                    if zone.walls.isEmpty {
                        Text("No facade plane was found in this mesh. Walk closer to a wall and scan it again.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .padding(16)
                    } else {
                        List(zone.walls) { wall in
                            NavigationLink(value: AppRoute.facade(home: homeID, zone: zone.id, wall: wall.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(format: "%.1f m facade", wall.length))
                                    Text(wall.texture == nil ? "No photo yet" : "Textured photo")
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
            } else {
                ContentUnavailableView("Scan missing", systemImage: "cube.transparent", description: Text("This outdoor zone is no longer on the device."))
            }
        }
        .navigationTitle(zone?.name ?? "Outdoor")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func textureImages(for zone: OutdoorZone) -> [String: UIImage] {
        var images: [String: UIImage] = [:]
        for wall in zone.walls {
            guard let texture = wall.texture, images[texture.image] == nil,
                  let url = store.existingFile(homeId: homeID, relative: texture.image),
                  let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data)
            else { continue }
            images[texture.image] = image
        }
        return images
    }
}

private struct OutdoorMeshView: UIViewRepresentable {
    let url: URL?
    var walls: [WallSegment]
    var images: [String: UIImage]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.957, green: 0.941, blue: 0.910, alpha: 1)
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        let token = sceneToken
        context.coordinator.token = token
        view.scene = loadScene()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let token = sceneToken
        guard context.coordinator.token != token else { return }
        context.coordinator.token = token
        uiView.scene = loadScene()
    }

    private var sceneToken: String {
        let textures = walls.map { "\($0.id.uuidString):\($0.texture?.image ?? "")" }.joined(separator: "|")
        return "\(url?.path ?? "")#\(textures)"
    }

    private func loadScene() -> SCNScene {
        let scene: SCNScene
        if let url, let loaded = try? SCNScene(url: url, options: nil) {
            scene = loaded
        } else {
            scene = SCNScene()
            let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
            box.firstMaterial?.diffuse.contents = UIColor(red: 0.55, green: 0.5, blue: 0.42, alpha: 1)
            scene.rootNode.addChildNode(SCNNode(geometry: box))
        }
        for wall in walls {
            guard let texture = wall.texture, let image = images[texture.image],
                  let node = TexturedFacade.node(wall: wall, image: image, texture: texture)
            else { continue }
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    final class Coordinator {
        var token = ""
    }
}
