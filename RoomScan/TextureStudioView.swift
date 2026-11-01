import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import RoomScanCore

@MainActor
enum TexturePaints {
    static func forHome(_ home: Home, store: HomeStore) -> [SurfacePaint] {
        paints(homeId: home.id, plans: home.rooms.map(\.floorPlan), store: store)
    }

    static func forRoom(_ room: Room, homeId: UUID, store: HomeStore) -> [SurfacePaint] {
        paints(homeId: homeId, plans: [room.floorPlan], store: store)
    }

    private static func paints(homeId: UUID, plans: [FloorPlan], store: HomeStore) -> [SurfacePaint] {
        let ids = Set(plans.flatMap { plan in plan.walls.map(\.id) + plan.floors.map(\.id) })
        return store.textureLibrary(homeId: homeId).photos.compactMap { photo in
            guard ids.contains(photo.surfaceId),
                  let data = store.textureData(homeId: homeId, relative: photo.imagePath),
                  let image = UIImage(data: data) else {
                return nil
            }
            return SurfacePaint(surfaceId: photo.surfaceId, image: image, corners: photo.corners)
        }
    }
}

struct TextureStudioView: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let homeID: UUID
    let roomID: UUID

    @State private var selectedSurface: UUID?
    @State private var autoMatch = false
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var importingFile = false
    @State private var showCamera = false
    @State private var draftImage: UIImage?
    @State private var draftCorners: [ImagePoint] = TextureProjection.fullFrameCorners()
    @State private var draftPose: ScanCameraPose?
    @State private var errorMessage: String?

    private var room: Room? { store.home(id: homeID)?.room(id: roomID) }
    private var targets: [TextureTarget] {
        guard let room else { return [] }
        return TextureProjection.targets(in: room.floorPlan)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let draftImage {
                    CornerFitView(image: draftImage, corners: $draftCorners)
                        .frame(maxHeight: 320)
                    fitControls
                }
                List {
                    Section {
                        Toggle("Auto-match photos to walls", isOn: $autoMatch)
                        photoButtons
                    } footer: {
                        Text("Pick a wall, or turn on auto-match. Drag the four corners so the photo sits on that surface. Frames captured while scanning already carry the camera pose and can suggest the fit. Photos from Files, including drone pictures, line up the same way.")
                    }
                    Section("Surfaces") {
                        if targets.isEmpty {
                            Text("This room has no walls to texture yet.")
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(targets) { target in
                            Button {
                                selectedSurface = target.id
                                loadExisting(target)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.title)
                                            .foregroundStyle(Theme.ink)
                                        Text(store.textureLibrary(homeId: homeID).photo(for: target.id) == nil ? "No photo" : "Textured")
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                    if selectedSurface == target.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(Theme.paper)
            .navigationTitle("Wall photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save fit") { saveDraft() }
                        .disabled(draftImage == nil || selectedSurface == nil)
                }
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url):
                    importFile(url)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    receive([(image, nil)])
                }
            }
            .onChange(of: libraryItems) { _, items in
                Task { await loadLibrary(items) }
            }
            .alert("Couldn't use that photo", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var photoButtons: some View {
        PhotosPicker(selection: $libraryItems, maxSelectionCount: 8, matching: .images) {
            Label("Photo library", systemImage: "photo")
        }
        Button {
            importingFile = true
        } label: {
            Label("Files or drone photo", systemImage: "folder")
        }
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button {
                showCamera = true
            } label: {
                Label("Camera", systemImage: "camera")
            }
        }
    }

    @ViewBuilder
    private var fitControls: some View {
        HStack {
            Button("Whole photo") { draftCorners = TextureProjection.fullFrameCorners() }
                .buttonStyle(.bordered)
            Button("Suggest from scan camera") { suggestFromPose() }
                .buttonStyle(.bordered)
                .disabled(draftPose?.matchesScan != true || selectedSurface == nil)
        }
        .font(.footnote)
        .padding(.vertical, 8)
    }

    private func loadExisting(_ target: TextureTarget) {
        guard let photo = store.textureLibrary(homeId: homeID).photo(for: target.id),
              let data = store.textureData(homeId: homeID, relative: photo.imagePath),
              let image = UIImage(data: data) else {
            draftImage = nil
            draftPose = nil
            draftCorners = TextureProjection.fullFrameCorners()
            return
        }
        draftImage = image
        draftCorners = photo.corners.count == 4 ? photo.corners : TextureProjection.fullFrameCorners()
        draftPose = photo.pose
    }

    private func loadLibrary(_ items: [PhotosPickerItem]) async {
        var images: [(UIImage, ScanCameraPose?)] = []
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    images.append((image, nil))
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
        await MainActor.run {
            self.libraryItems = []
            self.receive(images)
        }
    }

    private func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            guard let image = UIImage(data: data) else {
                errorMessage = "That file is not a photo Home Scanner can read."
                return
            }
            receive([(image, nil)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receive(_ images: [(UIImage, ScanCameraPose?)]) {
        guard let room, let first = images.first else { return }
        let plan = room.floorPlan
        if autoMatch || selectedSurface == nil {
            var used = Set(store.textureLibrary(homeId: homeID).photos.map(\.surfaceId))
            for image in images {
                let aspect = image.0.size.height > 0 ? image.0.size.width / image.0.size.height : 1
                let open = targets.filter { !used.contains($0.id) }
                let choice = open.min { abs($0.aspect - aspect) < abs($1.aspect - aspect) } ?? targets.first
                guard let choice else { continue }
                let corners = suggestedCorners(pose: image.1, surface: choice, plan: plan)
                persist(image: image.0, surface: choice, corners: corners, pose: image.1)
                used.insert(choice.id)
                selectedSurface = choice.id
                draftImage = image.0
                draftCorners = corners
                draftPose = image.1
            }
            return
        }
        guard let selectedSurface, let target = targets.first(where: { $0.id == selectedSurface }) else { return }
        let corners = suggestedCorners(pose: first.1, surface: target, plan: plan)
        draftImage = first.0
        draftPose = first.1
        draftCorners = corners
        if images.count > 1 {
            var used: Set<UUID> = [selectedSurface]
            for image in images.dropFirst() {
                let aspect = image.0.size.height > 0 ? image.0.size.width / image.0.size.height : 1
                let open = targets.filter { !used.contains($0.id) }
                guard let choice = open.min(by: { abs($0.aspect - aspect) < abs($1.aspect - aspect) }) else { continue }
                persist(image: image.0, surface: choice, corners: TextureProjection.fullFrameCorners(), pose: image.1)
                used.insert(choice.id)
            }
        }
    }

    private func suggestedCorners(pose: ScanCameraPose?, surface: TextureTarget, plan: FloorPlan) -> [ImagePoint] {
        guard let pose, pose.matchesScan else { return TextureProjection.fullFrameCorners() }
        if surface.kind == .wall, let wall = plan.walls.first(where: { $0.id == surface.id }),
           let corners = TextureProjection.suggestCorners(wall: wall, pose: pose) {
            return corners
        }
        if surface.kind == .floor, let floor = plan.floors.first(where: { $0.id == surface.id }),
           let corners = TextureProjection.suggestCorners(floor: floor, pose: pose) {
            return corners
        }
        return TextureProjection.fullFrameCorners()
    }

    private func suggestFromPose() {
        guard let room, let selectedSurface, let target = targets.first(where: { $0.id == selectedSurface }) else { return }
        draftCorners = suggestedCorners(pose: draftPose, surface: target, plan: room.floorPlan)
    }

    private func saveDraft() {
        guard let draftImage, let selectedSurface, let target = targets.first(where: { $0.id == selectedSurface }) else { return }
        persist(image: draftImage, surface: target, corners: draftCorners, pose: draftPose)
    }

    private func persist(image: UIImage, surface: TextureTarget, corners: [ImagePoint], pose: ScanCameraPose?) {
        guard let jpeg = ScanFrameImage.jpeg(from: image, maxEdge: 4096) else {
            errorMessage = "The photo could not be saved."
            return
        }
        let id = UUID()
        let relative = "textures/\(id.uuidString).jpg"
        do {
            if let previous = store.textureLibrary(homeId: homeID).photo(for: surface.id) {
                store.removeTextureFile(homeId: homeID, relative: previous.imagePath)
            }
            try store.writeTextureImage(homeId: homeID, relative: relative, data: jpeg)
            var library = store.textureLibrary(homeId: homeID)
            library.photos.removeAll { $0.surfaceId == surface.id }
            library.photos.append(
                SurfaceTexture(
                    id: id,
                    surfaceId: surface.id,
                    kind: surface.kind,
                    imagePath: relative,
                    corners: corners,
                    pose: pose
                )
            )
            try store.saveTextures(library, homeId: homeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CornerFitView: View {
    var image: UIImage
    @Binding var corners: [ImagePoint]
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(view: geo.size, image: image.size)
            ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
            Path { path in
                guard corners.count == 4 else { return }
                path.move(to: point(corners[0], in: rect))
                for corner in corners.dropFirst() {
                    path.addLine(to: point(corner, in: rect))
                }
                path.closeSubpath()
            }
            .stroke(Theme.accent, lineWidth: 2)
            ForEach(0..<min(corners.count, 4), id: \.self) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 22, height: 22)
                    .position(point(corners[index], in: rect))
            }
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragging == nil {
                                dragging = nearest(to: value.startLocation, in: rect)
                            }
                            guard let dragging, corners.indices.contains(dragging) else { return }
                            corners[dragging] = normalize(value.location, in: rect)
                        }
                        .onEnded { _ in
                            dragging = nil
                        }
                )
            }
        }
        .background(Color.black.opacity(0.85))
    }

    private func fittedRect(view: CGSize, image: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else {
            return CGRect(origin: .zero, size: view)
        }
        let scale = min(view.width / image.width, view.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (view.width - size.width) / 2,
            y: (view.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func point(_ corner: ImagePoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(corner.x) * rect.width, y: rect.minY + CGFloat(corner.y) * rect.height)
    }

    private func normalize(_ location: CGPoint, in rect: CGRect) -> ImagePoint {
        let x = rect.width > 0 ? (location.x - rect.minX) / rect.width : 0
        let y = rect.height > 0 ? (location.y - rect.minY) / rect.height : 0
        return ImagePoint(x: min(1, max(0, Double(x))), y: min(1, max(0, Double(y))))
    }

    private func nearest(to location: CGPoint, in rect: CGRect) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in corners.indices {
            let spot = point(corners[index], in: rect)
            let distance = hypot(spot.x - location.x, spot.y - location.y)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void

        init(onImage: @escaping (UIImage) -> Void) {
            self.onImage = onImage
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                self.onImage(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
