import PhotosUI
import SwiftUI
import RoomScanCore
import UIKit

struct SitePlanView: View {
    @Environment(HomeStore.self) private var store
    let homeID: UUID

    @State private var photoItem: PhotosPickerItem?
    @State private var underlayImage: UIImage?
    @State private var selectedPlacementID: UUID?
    @State private var errorMessage: String?
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var heading = ""
    @State private var showGeoreference = false

    private var home: Home? { store.home(id: homeID) }

    var body: some View {
        PaperScreen {
            if let home {
                VStack(spacing: 0) {
                    SiteCanvas(
                        home: home,
                        image: underlayImage,
                        selectedPlacementID: selectedPlacementID,
                        onSelect: { selectedPlacementID = $0 },
                        onMove: { id, x, z in move(id, x: x, z: z) }
                    )
                    controls(home)
                }
            } else {
                ContentUnavailableView("Home missing", systemImage: "map", description: Text("It may have been deleted."))
            }
        }
        .navigationTitle("Site plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                }
                .accessibilityLabel("Import aerial or drone photo")
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .onChange(of: home?.site?.underlay?.image) { _, _ in
            loadUnderlay()
        }
        .onAppear(perform: loadUnderlay)
        .alert("Couldn't update the site", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showGeoreference) {
            georeferenceSheet
        }
    }

    @ViewBuilder
    private func controls(_ home: Home) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption(home))
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            HStack {
                Button("Sample yard") { installSample() }
                    .buttonStyle(.bordered)
                Button("Arrange") { arrange(home) }
                    .buttonStyle(.bordered)
                if home.site?.underlay != nil {
                    Button("Georeference") {
                        let geo = home.site?.underlay?.georeference
                        latitude = geo.map { String($0.latitude) } ?? ""
                        longitude = geo.map { String($0.longitude) } ?? ""
                        heading = geo.map { String($0.headingDegrees) } ?? ""
                        showGeoreference = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let underlay = home.site?.underlay {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Photo width \(underlay.widthMeters, format: .number.precision(.fractionLength(1))) m · \(underlay.metersPerPixel, format: .number.precision(.fractionLength(3))) m/pixel")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    Slider(
                        value: Binding(
                            get: { underlay.widthMeters },
                            set: { setWidth($0, underlay: underlay) }
                        ),
                        in: 5...500
                    )
                    .accessibilityLabel("Aerial photo width in meters")
                }
            }
            if let placement = home.site?.placements.first(where: { $0.id == selectedPlacementID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: placement, in: home))
                        .font(.subheadline.weight(.semibold))
                    Text("Rotation \(placement.yaw * 180 / .pi, format: .number.precision(.fractionLength(0)))°")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    Slider(
                        value: Binding(
                            get: { placement.yaw * 180 / .pi },
                            set: { setYaw($0, placementID: placement.id) }
                        ),
                        in: -180...180
                    )
                    .accessibilityLabel("Rotation of the selected plan")
                }
            }
        }
        .padding(16)
        .background(Theme.card)
    }

    private var georeferenceSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Latitude", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Heading, degrees clockwise from north", text: $heading)
                        .keyboardType(.numbersAndPunctuation)
                } footer: {
                    Text("Optional. Records where the center of the photo sits, and which way the photo's up axis points. The drawing scale is still the width in meters.")
                }
            }
            .navigationTitle("Georeference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showGeoreference = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveGeoreference() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func caption(_ home: Home) -> String {
        if home.site?.underlay == nil && home.outdoorZones.isEmpty && home.rooms.isEmpty {
            return "Import an aerial or drone photo, scan a facade, or open the sample yard."
        }
        if home.site?.placements.isEmpty != false {
            return "Arrange drops each room and outdoor scan onto the photo. Drag a shape to move it."
        }
        return "Drag a floor plan or outdoor zone. Pinch is not needed: use the width slider to scale the photo."
    }

    private func title(for placement: SitePlacement, in home: Home) -> String {
        switch placement.subject {
        case .room(let id):
            return home.room(id: id)?.name ?? "Room"
        case .outdoorZone(let id):
            return home.outdoorZone(id: id)?.name ?? "Outdoor"
        }
    }

    private func loadUnderlay() {
        guard let relative = home?.site?.underlay?.image,
              let url = store.existingFile(homeId: homeID, relative: relative),
              let data = try? Data(contentsOf: url)
        else {
            underlayImage = nil
            return
        }
        underlayImage = UIImage(data: data)
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.85)
            else {
                errorMessage = "That photo could not be read."
                return
            }
            let width = Int(image.size.width * image.scale)
            let height = Int(image.size.height * image.scale)
            let meters = home?.site?.underlay?.widthMeters ?? 40
            _ = try store.importUnderlay(
                homeId: homeID,
                image: jpeg,
                pixelWidth: max(width, 1),
                pixelHeight: max(height, 1),
                widthMeters: meters,
                georeference: home?.site?.underlay?.georeference
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installSample() {
        do {
            let bundled = SampleBundle.siteImage()
            _ = try store.installSampleSite(
                homeId: homeID,
                image: bundled?.data,
                pixelWidth: bundled?.width ?? 512,
                pixelHeight: bundled?.height ?? 512
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func arrange(_ home: Home) {
        do {
            try store.updateSite(homeId: homeID) { site in
                site.placements = SiteLayout.defaultPlacements(rooms: home.rooms, zones: home.outdoorZones)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setWidth(_ width: Double, underlay: SiteUnderlay) {
        do {
            try store.updateSite(homeId: homeID) { site in
                guard var current = site.underlay else { return }
                let aspect = current.pixelWidth > 0 ? Double(current.pixelHeight) / Double(current.pixelWidth) : 1
                current.widthMeters = width
                current.heightMeters = width * aspect
                site.underlay = current
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setYaw(_ degrees: Double, placementID: UUID) {
        do {
            try store.updateSite(homeId: homeID) { site in
                guard let index = site.placements.firstIndex(where: { $0.id == placementID }) else { return }
                site.placements[index].yaw = degrees * .pi / 180
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func move(_ id: UUID, x: Double, z: Double) {
        do {
            try store.updateSite(homeId: homeID) { site in
                guard let index = site.placements.firstIndex(where: { $0.id == id }) else { return }
                site.placements[index].origin.x = x
                site.placements[index].origin.z = z
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveGeoreference() {
        let parsed: Georeference?
        if latitude.isEmpty && longitude.isEmpty && heading.isEmpty {
            parsed = nil
        } else if let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
                  let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")),
                  let headingValue = Double(heading.replacingOccurrences(of: ",", with: ".")) {
            parsed = Georeference(latitude: lat, longitude: lon, headingDegrees: headingValue)
        } else {
            errorMessage = "Latitude, longitude, and heading need to be numbers."
            return
        }
        do {
            try store.updateSite(homeId: homeID) { site in
                guard var underlay = site.underlay else { return }
                underlay.georeference = parsed
                site.underlay = underlay
            }
            showGeoreference = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SiteCanvas: View {
    var home: Home
    var image: UIImage?
    var selectedPlacementID: UUID?
    var onSelect: (UUID?) -> Void
    var onMove: (UUID, Double, Double) -> Void

    @State private var userScale: Double = 1
    @State private var userOffset = CGSize.zero
    @State private var magnifyBase: Double = 1
    @State private var dragMode: DragMode = .idle
    @State private var panOrigin = CGSize.zero
    @State private var previewOrigin: Vec3?

    private enum DragMode {
        case idle
        case pan
        case placement(UUID, Vec3)
    }

    var body: some View {
        GeometryReader { geo in
            let projector = makeProjector(size: geo.size)
            Canvas { context, size in
                drawUnderlay(in: context, projector: projector)
                for placement in home.site?.placements ?? [] {
                    draw(placement, in: context, projector: projector)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(projector))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        userScale = min(8, max(0.4, magnifyBase * value))
                    }
                    .onEnded { _ in magnifyBase = userScale }
            )
        }
        .background(Theme.card)
        .accessibilityLabel("Site plan")
    }

    private func makeProjector(size: CGSize) -> PlanProjector {
        var points: [Vec3] = []
        if let underlay = home.site?.underlay {
            points.append(contentsOf: SiteLayout.underlayCorners(underlay))
        }
        for placement in home.site?.placements ?? [] {
            points.append(contentsOf: worldCorners(placement))
        }
        if points.isEmpty {
            points = [Vec3(x: -10, y: 0, z: -10), Vec3(x: 10, y: 0, z: 10)]
        }
        let first = points[0]
        var box = AABB(min: first, max: first)
        for point in points.dropFirst() {
            box = box.union(AABB(min: point, max: point))
        }
        var fitted = PlanProjector.fitting(bounds: box, viewWidth: size.width, viewHeight: size.height, padding: 28)
        fitted.userScale = userScale
        fitted.userOffsetX = userOffset.width
        fitted.userOffsetY = userOffset.height
        return fitted
    }

    private func drawUnderlay(in context: GraphicsContext, projector: PlanProjector) {
        guard let underlay = home.site?.underlay, let image else { return }
        let centerWorld = underlay.center
        let center = screen(centerWorld, projector)
        let east = screen(
            SiteLayout.apply(Vec3(x: underlay.widthMeters / 2, y: 0, z: 0), placement: SitePlacement(subject: .room(UUID()), origin: centerWorld, yaw: underlay.yaw)),
            projector
        )
        let north = screen(
            SiteLayout.apply(Vec3(x: 0, y: 0, z: underlay.heightMeters / 2), placement: SitePlacement(subject: .room(UUID()), origin: centerWorld, yaw: underlay.yaw)),
            projector
        )
        let halfW = hypot(east.x - center.x, east.y - center.y)
        let halfH = hypot(north.x - center.x, north.y - center.y)
        let angle = atan2(east.y - center.y, east.x - center.x)
        var draw = context
        draw.translateBy(x: center.x, y: center.y)
        draw.rotate(by: .radians(angle))
        draw.draw(Image(uiImage: image), in: CGRect(x: -halfW, y: -halfH, width: halfW * 2, height: halfH * 2))
    }

    private func draw(_ placement: SitePlacement, in context: GraphicsContext, projector: PlanProjector) {
        let corners = worldCorners(placement)
        guard corners.count >= 3 else { return }
        var path = Path()
        path.move(to: screen(corners[0], projector))
        for corner in corners.dropFirst() {
            path.addLine(to: screen(corner, projector))
        }
        path.closeSubpath()
        let selected = placement.id == selectedPlacementID
        let color: Color = {
            if case .outdoorZone = placement.subject { return Theme.accent.opacity(0.35) }
            return Theme.ink.opacity(0.12)
        }()
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(selected ? Theme.accent : Theme.ink), lineWidth: selected ? 2.5 : 1.5)
        let label: String
        switch placement.subject {
        case .room(let id):
            label = home.room(id: id)?.name ?? "Room"
        case .outdoorZone(let id):
            label = home.outdoorZone(id: id)?.name ?? "Outdoor"
        }
        let anchor = corners.reduce(Vec3.zero) { partial, corner in partial + corner }.scaled(1 / Double(corners.count))
        context.draw(Text(label).font(.caption.weight(.medium)).foregroundStyle(Theme.ink), at: screen(anchor, projector))
    }

    private func worldCorners(_ placement: SitePlacement) -> [Vec3] {
        let local: [Vec3]
        switch placement.subject {
        case .room(let id):
            guard let room = home.room(id: id) else { return [] }
            local = SiteLayout.roomFootprint(room)
        case .outdoorZone(let id):
            guard let zone = home.outdoorZone(id: id) else { return [] }
            local = zone.footprint
        }
        var placed = placement
        if case .placement(let id, _) = dragMode, id == placement.id, let previewOrigin {
            placed.origin = previewOrigin
        }
        return local.map { SiteLayout.apply($0, placement: placed) }
    }

    private func screen(_ point: Vec3, _ projector: PlanProjector) -> CGPoint {
        let value = projector.screen(x: point.x, z: point.z)
        return CGPoint(x: value.x, y: value.y)
    }

    private func drag(_ projector: PlanProjector) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if case .idle = dragMode {
                    if let hit = hit(value.startLocation, projector: projector) {
                        dragMode = .placement(hit.id, hit.origin)
                        previewOrigin = hit.origin
                    } else {
                        panOrigin = userOffset
                        dragMode = .pan
                    }
                }
                switch dragMode {
                case .placement(_, let origin):
                    let start = projector.world(screenX: value.startLocation.x, screenY: value.startLocation.y)
                    let current = projector.world(screenX: value.location.x, screenY: value.location.y)
                    previewOrigin = Vec3(x: origin.x + (current.x - start.x), y: origin.y, z: origin.z + (current.z - start.z))
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
                    onSelect(hit(value.location, projector: projector)?.id)
                } else if case .placement(let id, _) = dragMode, let previewOrigin {
                    onMove(id, previewOrigin.x, previewOrigin.z)
                }
                dragMode = .idle
                previewOrigin = nil
                panOrigin = .zero
            }
    }

    private func hit(_ point: CGPoint, projector: PlanProjector) -> SitePlacement? {
        let world = projector.world(screenX: point.x, screenY: point.y)
        let target = Vec3(x: world.x, y: 0, z: world.z)
        for placement in (home.site?.placements ?? []).reversed() {
            if contains(target, polygon: worldCorners(placement)) {
                return placement
            }
        }
        return nil
    }

    private func contains(_ point: Vec3, polygon: [Vec3]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for corner in polygon {
            let intersects = ((corner.z > point.z) != (previous.z > point.z))
                && (point.x < (previous.x - corner.x) * (point.z - corner.z) / ((previous.z - corner.z) == 0 ? 1 : (previous.z - corner.z)) + corner.x)
            if intersects { inside.toggle() }
            previous = corner
        }
        return inside
    }
}
