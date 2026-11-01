import PhotosUI
import SwiftUI
import RoomScanCore
import UIKit

struct FacadeTextureView: View {
    @Environment(HomeStore.self) private var store
    let homeID: UUID
    let zoneID: UUID
    let wallID: UUID

    @State private var corners: [UVPoint] = SurfaceTexture.fullImage(path: "textures/wall.jpg", pixelWidth: 1, pixelHeight: 1).corners
    @State private var image: UIImage?
    @State private var relativePath: String?
    @State private var pixelWidth = 1
    @State private var pixelHeight = 1
    @State private var photoItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var saving = false
    @State private var message = "Drag the four corners onto the wall in the photo. Order is bottom-start, bottom-end, top-end, top-start."
    @State private var errorMessage: String?

    private var home: Home? { store.home(id: homeID) }
    private var zone: OutdoorZone? { home?.outdoorZone(id: zoneID) }
    private var wall: WallSegment? { zone?.walls.first { $0.id == wallID } }

    var body: some View {
        PaperScreen {
            VStack(spacing: 0) {
                if let image {
                    CornerEditor(image: image, corners: $corners)
                } else {
                    ContentUnavailableView(
                        "No photo yet",
                        systemImage: "photo",
                        description: Text("Import a drone photo of this facade. GPS can place the corners when the scan sits on a georeferenced site plan.")
                    )
                }
                controls
            }
        }
        .navigationTitle(zone?.name ?? "Facade")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Photo") { showLibrary = true }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(saving || image == nil || relativePath == nil)
            }
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .onAppear(perform: loadExisting)
        .alert("Couldn't update the facade", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            HStack {
                Button("Suggest from GPS") { suggest() }
                    .buttonStyle(.bordered)
                    .disabled(image == nil)
                Button("Reset corners") {
                    corners = SurfaceTexture.fullImage(path: "x", pixelWidth: 1, pixelHeight: 1).corners
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
    }

    private func loadExisting() {
        guard let wall, let texture = wall.texture, texture.isUsable else { return }
        corners = texture.corners
        relativePath = texture.image
        pixelWidth = texture.pixelWidth
        pixelHeight = texture.pixelHeight
        if let url = store.existingFile(homeId: homeID, relative: texture.image),
           let data = try? Data(contentsOf: url) {
            image = PhotoIngest.image(from: data)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "That photo could not be read."
                return
            }
            switch PhotoIngest.prepare(data, maxPixel: 4096) {
            case .failure(let failure):
                errorMessage = failure.localizedDescription
            case .success(let prepared):
                let footprint = PhotoIngest.footprint(for: prepared.metadata, pixelWidth: prepared.pixelWidth, pixelHeight: prepared.pixelHeight)
                let center = PhotoIngest.siteCenter(metadata: prepared.metadata, underlay: home?.site?.underlay)
                let georeference = prepared.metadata.hasLocation
                    ? Georeference(
                        latitude: prepared.metadata.latitude ?? 0,
                        longitude: prepared.metadata.longitude ?? 0,
                        headingDegrees: prepared.metadata.cameraHeading ?? 0
                    )
                    : nil
                let id = UUID()
                _ = try store.importDroneOverlay(
                    homeId: homeID,
                    id: id,
                    image: prepared.data,
                    fileExtension: prepared.fileExtension,
                    pixelWidth: prepared.pixelWidth,
                    pixelHeight: prepared.pixelHeight,
                    center: center,
                    yaw: footprint.yaw,
                    widthMeters: footprint.width,
                    heightMeters: footprint.height,
                    georeference: georeference,
                    altitudeMeters: prepared.metadata.altitudeMeters,
                    relativeAltitudeMeters: prepared.metadata.relativeAltitudeMeters,
                    focalLengthMillimeters: prepared.metadata.focalLengthMillimeters,
                    focalLength35mm: prepared.metadata.focalLength35mm,
                    headingDegrees: prepared.metadata.cameraHeading,
                    pitchDegrees: prepared.metadata.pitchDegrees,
                    note: footprint.note
                )
                image = PhotoIngest.image(from: prepared.data)
                relativePath = "site/overlays/\(id.uuidString).jpg"
                pixelWidth = prepared.pixelWidth
                pixelHeight = prepared.pixelHeight
                message = footprint.note
                suggest()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func suggest() {
        guard let wall, let home, let zone else { return }
        guard let overlay = home.site?.overlays.last(where: { $0.image == relativePath }) ?? home.site?.overlays.last else {
            message = "Import a drone photo first."
            return
        }
        guard let placement = home.site?.placements.first(where: { placement in
            if case .outdoorZone(let id) = placement.subject { return id == zone.id }
            return false
        }) else {
            message = "Arrange this scan on the site plan before using GPS. You can still drag the corners."
            return
        }
        guard let latitude = overlay.georeference?.latitude, let longitude = overlay.georeference?.longitude else {
            message = "This photo has no GPS position. Drag the four corners by hand."
            return
        }
        guard home.site?.underlay?.georeference != nil else {
            message = "Give the aerial photo a latitude before GPS can project this wall."
            return
        }
        let position = SiteGeodesy.overlayPosition(overlay, underlay: home.site?.underlay)
        let altitude = overlay.relativeAltitudeMeters ?? overlay.center.y
        let pose = CameraPose(
            position: Vec3(x: position.x, y: altitude > 0.2 ? altitude : 1.6, z: position.z),
            headingDegrees: overlay.headingDegrees ?? overlay.georeference?.headingDegrees ?? 0,
            pitchDegrees: overlay.pitchDegrees ?? 0,
            focalLength35mm: overlay.focalLength35mm,
            focalLengthMillimeters: overlay.focalLengthMillimeters,
            pixelWidth: overlay.pixelWidth,
            pixelHeight: overlay.pixelHeight
        )
        guard let suggestion = FacadeProjection.suggestCorners(wall: wall, placement: placement, camera: pose) else {
            message = "GPS could not see this wall from the camera. The heading or pitch may be missing. Drag the corners."
            return
        }
        corners = suggestion.corners
        if suggestion.usedEquivalentFocalLength {
            message = "Corners projected from GPS, heading, and focal length. Drag any corner that missed the wall."
        } else {
            message = "Corners are a guess: the photo has no 35 mm focal length, so a 6.3 mm sensor width was assumed."
        }
    }

    private func save() {
        guard let relativePath else { return }
        saving = true
        do {
            _ = try store.setFacadeTexture(
                homeId: homeID,
                zoneId: zoneID,
                wallId: wallID,
                imageRelativePath: relativePath,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                corners: corners
            )
            message = "Saved on this facade. Export layout JSON from the home to share the same wall texture format."
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}

private struct CornerEditor: View {
    let image: UIImage
    @Binding var corners: [UVPoint]
    @State private var active: Int?

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(in: geo.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Canvas { context, _ in
                    guard corners.count == 4 else { return }
                    var path = Path()
                    path.move(to: point(corners[0], in: rect))
                    for corner in corners.dropFirst() {
                        path.addLine(to: point(corner, in: rect))
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(Theme.accent), lineWidth: 2)
                }
                ForEach(corners.indices, id: \.self) { index in
                    let location = point(corners[index], in: rect)
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.card)
                        .frame(width: 28, height: 28)
                        .background(Theme.accent, in: Circle())
                        .position(location)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: rect))
        }
        .background(Theme.ink.opacity(0.92))
        .accessibilityLabel("Facade photo. Drag the numbered corners onto the wall.")
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let imageAspect = max(image.size.width / max(image.size.height, 1), 0.01)
        let viewAspect = max(size.width / max(size.height, 1), 0.01)
        if imageAspect > viewAspect {
            let height = size.width / imageAspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * imageAspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    private func point(_ uv: UVPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + uv.u * rect.width, y: rect.minY + uv.v * rect.height)
    }

    private func uv(_ location: CGPoint, in rect: CGRect) -> UVPoint {
        guard rect.width > 1, rect.height > 1 else { return UVPoint(u: 0, v: 0) }
        return UVPoint(
            u: min(1, max(0, (location.x - rect.minX) / rect.width)),
            v: min(1, max(0, (location.y - rect.minY) / rect.height))
        )
    }

    private func drag(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if active == nil {
                    let start = value.startLocation
                    active = corners.indices.min { lhs, rhs in
                        distance(point(corners[lhs], in: rect), start) < distance(point(corners[rhs], in: rect), start)
                    }
                }
                guard let active, corners.indices.contains(active) else { return }
                corners[active] = uv(value.location, in: rect)
            }
            .onEnded { _ in
                active = nil
            }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
