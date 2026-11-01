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
                OutdoorMeshView(url: store.existingFile(homeId: homeID, relative: zone.assets.obj))
                    .overlay(alignment: .bottomLeading) {
                        Text("\(zone.kind.label) · \(String(format: "%.1f", zone.height)) m tall · drag to orbit")
                            .font(.caption)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(12)
                    }
            } else {
                ContentUnavailableView("Scan missing", systemImage: "cube.transparent", description: Text("This outdoor zone is no longer on the device."))
            }
        }
        .navigationTitle(zone?.name ?? "Outdoor")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OutdoorMeshView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.957, green: 0.941, blue: 0.910, alpha: 1)
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.scene = loadScene()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func loadScene() -> SCNScene {
        if let url, let loaded = try? SCNScene(url: url, options: nil) {
            return loaded
        }
        let scene = SCNScene()
        let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        box.firstMaterial?.diffuse.contents = UIColor(red: 0.55, green: 0.5, blue: 0.42, alpha: 1)
        scene.rootNode.addChildNode(SCNNode(geometry: box))
        return scene
    }
}
