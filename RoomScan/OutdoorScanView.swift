import ARKit
import RealityKit
import SwiftUI
import RoomScanCore

struct OutdoorScanView: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var collector = OutdoorMeshCollector()

    let homeID: UUID

    @State private var mesh: TriangleMesh?
    @State private var name = ""
    @State private var kind: OutdoorKind = .facade
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let mesh {
                nameForm(mesh)
            } else if OutdoorScanSupport.canScan {
                capture
            } else {
                unavailable
            }
        }
        .tint(Theme.accent)
    }

    private var capture: some View {
        ZStack {
            OutdoorARView(collector: collector)
                .ignoresSafeArea()
            VStack {
                Text("LiDAR mesh, about \(Int(OutdoorScanSupport.rangeMeters)) m. Walk the facade, patio, or shed. Stay close.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                Spacer()
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Done") { finish() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(20)
            }
        }
        .background(Color.black)
    }

    private var unavailable: some View {
        PaperScreen {
            VStack(alignment: .leading, spacing: 16) {
                Text("Outdoor scan")
                    .font(.system(.largeTitle, design: .serif))
                Text(OutdoorScanSupport.unavailableReason)
                    .foregroundStyle(Theme.secondary)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }

    private func nameForm(_ mesh: TriangleMesh) -> some View {
        NavigationStack {
            Form {
                if mesh.vertices.isEmpty {
                    Section {
                        Text("Nothing was captured inside \(Int(OutdoorScanSupport.rangeMeters)) meters. Move closer and scan again.")
                            .foregroundStyle(Theme.secondary)
                    }
                } else {
                    Section("Name") {
                        TextField("North facade", text: $name)
                        Picker("Kind", selection: $kind) {
                            ForEach(OutdoorKind.allCases, id: \.self) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                    }
                    Section {
                        Text("\(mesh.vertices.count) vertices kept within \(Int(OutdoorScanSupport.rangeMeters)) m of each mesh chunk.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .navigationTitle("Save outdoor scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(mesh) }
                        .disabled(saving || mesh.vertices.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Couldn't save the scan", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if name.isEmpty { name = kind.label }
            }
        }
    }

    private func finish() {
        let captured = collector.snapshot()
        mesh = captured
    }

    private func save(_ mesh: TriangleMesh) {
        saving = true
        do {
            _ = try store.addOutdoorZone(homeId: homeID, name: name, kind: kind, mesh: mesh)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            saving = false
        }
    }
}

private struct OutdoorARView: UIViewRepresentable {
    let collector: OutdoorMeshCollector

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session.delegate = collector
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .none
        view.session.run(configuration)
        view.debugOptions.insert(.showSceneUnderstanding)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}
