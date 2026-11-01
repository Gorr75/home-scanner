import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import RoomScanCore
import UIKit

private enum SiteTool: String, CaseIterable, Identifiable {
    case move
    case scale
    case align

    var id: String { rawValue }

    var label: String {
        switch self {
        case .move: return "Move"
        case .scale: return "Scale"
        case .align: return "Align"
        }
    }
}

struct SitePlanView: View {
    @Environment(HomeStore.self) private var store
    let homeID: UUID

    @State private var photoItem: PhotosPickerItem?
    @State private var underlayImage: UIImage?
    @State private var overlayImages: [UUID: UIImage] = [:]
    @State private var selectedPlacementID: UUID?
    @State private var errorMessage: String?
    @State private var importNote: String?
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var heading = ""
    @State private var showGeoreference = false
    @State private var showLibrary = false
    @State private var showFiles = false
    @State private var showWorld = false
    @State private var tool: SiteTool = .move
    @State private var markers: [Vec3] = []
    @State private var showDistance = false
    @State private var distanceText = ""
    @State private var bearingText = ""
    @State private var pending: PhotoIngest.Prepared?
    @State private var showGPSChoice = false

    private var home: Home? { store.home(id: homeID) }

    var body: some View {
        PaperScreen {
            if let home {
                VStack(spacing: 0) {
                    SiteCanvas(
                        home: home,
                        image: underlayImage,
                        overlayImages: overlayImages,
                        selectedPlacementID: selectedPlacementID,
                        tool: tool,
                        markers: markers,
                        guide: guide(in: home),
                        onSelect: { selectedPlacementID = $0 },
                        onMove: { id, x, z in move(id, x: x, z: z) },
                        onTap: { handleTap($0, in: home) }
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
                Menu {
                    Button("Photo library") { showLibrary = true }
                    Button("Image or GeoTIFF") { showFiles = true }
                    Button("World file") { showWorld = true }
                        .disabled(home?.site?.underlay == nil)
                    Button("Export layout JSON") { exportJSON() }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Import a photo or export the layout")
            }
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .tiff], allowsMultipleSelection: false) { result in
            openFile(result)
        }
        .fileImporter(isPresented: $showWorld, allowedContentTypes: worldTypes, allowsMultipleSelection: false) { result in
            openWorld(result)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .onChange(of: home?.site?.underlay?.image) { _, _ in
            loadUnderlay()
        }
        .onChange(of: home?.site?.overlays.map(\.id)) { _, _ in
            loadOverlays()
        }
        .onChange(of: tool) { _, _ in
            markers = []
        }
        .onAppear {
            loadUnderlay()
            loadOverlays()
        }
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
        .sheet(isPresented: $showDistance) {
            distanceSheet
        }
        .confirmationDialog(
            "This photo has a GPS position",
            isPresented: $showGPSChoice,
            titleVisibility: .visible
        ) {
            Button("Use as the site underlay") { commitPending(asOverlay: false) }
            Button("Place as a drone overlay") { commitPending(asOverlay: true) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("A drone photo can lie on the plan at its GPS position, or replace the aerial underlay. Facade texturing uses the drone photo either way.")
        }
    }

    private var worldTypes: [UTType] {
        var types: [UTType] = [.plainText, .data]
        for ext in ["tfw", "jgw", "pgw", "wld"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    @ViewBuilder
    private func controls(_ home: Home) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tool", selection: $tool) {
                ForEach(SiteTool.allCases) { tool in
                    Text(tool.label).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            Text(caption(home))
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            if let importNote {
                Text(importNote)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
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
                    Text("Photo rotation \(underlay.yaw * 180 / .pi, format: .number.precision(.fractionLength(0)))°")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    Slider(
                        value: Binding(
                            get: { underlay.yaw * 180 / .pi },
                            set: { setUnderlayYaw($0) }
                        ),
                        in: -180...180
                    )
                    .accessibilityLabel("Aerial photo rotation")
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
            if let overlays = home.site?.overlays, !overlays.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drone photos")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                    ForEach(overlays) { overlay in
                        HStack {
                            Text(overlay.note ?? "GPS photo")
                                .font(.caption)
                                .lineLimit(2)
                            Spacer()
                            Button("Delete") {
                                deleteOverlay(overlay.id)
                            }
                            .font(.caption)
                        }
                    }
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
                    Text("Records where the center of the photo sits. Site +X is east and site +Z is north. A GeoTIFF in SWEREF 99 TM fills this in. A plain photo still needs the width, or two points and a distance.")
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

    private var distanceSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Meters between the two points", text: $distanceText)
                        .keyboardType(.decimalPad)
                    TextField("Bearing of that line, optional", text: $bearingText)
                        .keyboardType(.numbersAndPunctuation)
                } footer: {
                    Text("The distance sets meters per pixel. A bearing, clockwise from north from the first tap to the second, also rotates the photo. Leave the bearing blank to keep the current rotation.")
                }
            }
            .navigationTitle("Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showDistance = false
                        markers = []
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { applyScale() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func caption(_ home: Home) -> String {
        switch tool {
        case .scale:
            return markers.isEmpty
                ? "Tap two points on the aerial that you know the distance between."
                : "Tap the second point."
        case .align:
            if selectedPlacementID == nil {
                return "Select a room or outdoor scan in Move, then come back to Align."
            }
            return markers.isEmpty
                ? "The highlighted wall keeps its measured length. Tap where its start should sit, then its end."
                : "Tap where the other end of the highlighted wall should sit."
        case .move:
            if home.site?.underlay == nil && home.outdoorZones.isEmpty && home.rooms.isEmpty {
                return "Import an aerial photo, a GeoTIFF, or a drone photo. Sample yard works before the real orthophoto arrives."
            }
            if home.site?.placements.isEmpty != false {
                return "Arrange drops each room and outdoor scan onto the photo. Drag a shape to move it."
            }
            return "Drag a floor plan or outdoor zone. Scale uses two points. Align turns a room onto the photo without resizing it."
        }
    }

    private func title(for placement: SitePlacement, in home: Home) -> String {
        switch placement.subject {
        case .room(let id):
            return home.room(id: id)?.name ?? "Room"
        case .outdoorZone(let id):
            return home.outdoorZone(id: id)?.name ?? "Outdoor"
        }
    }

    private func guide(in home: Home) -> (Vec3, Vec3)? {
        guard tool == .align, let ends = localEnds(in: home), let placement = selected(in: home) else { return nil }
        return (
            SiteLayout.apply(ends.0, placement: placement),
            SiteLayout.apply(ends.1, placement: placement)
        )
    }

    private func selected(in home: Home) -> SitePlacement? {
        home.site?.placements.first { $0.id == selectedPlacementID }
    }

    private func localEnds(in home: Home) -> (Vec3, Vec3)? {
        guard let placement = selected(in: home) else { return nil }
        switch placement.subject {
        case .room(let id):
            guard let room = home.room(id: id), let wall = SiteSurvey.longestWall(in: room.floorPlan) else { return nil }
            return (wall.start, wall.end)
        case .outdoorZone(let id):
            guard let zone = home.outdoorZone(id: id) else { return nil }
            if let wall = SiteSurvey.longestWall(in: zone) {
                return (wall.start, wall.end)
            }
            guard zone.footprint.count >= 2 else { return nil }
            return (zone.footprint[0], zone.footprint[1])
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
        underlayImage = PhotoIngest.image(from: data)
    }

    private func loadOverlays() {
        var images: [UUID: UIImage] = [:]
        for overlay in home?.site?.overlays ?? [] {
            guard let url = store.existingFile(homeId: homeID, relative: overlay.image),
                  let data = try? Data(contentsOf: url),
                  let image = PhotoIngest.image(from: data)
            else { continue }
            images[overlay.id] = image
        }
        overlayImages = images
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "That photo could not be read."
                return
            }
            receive(data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "That file could not be read."
                return
            }
            receive(data)
        }
    }

    private func openWorld(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                errorMessage = "That world file could not be read."
                return
            }
            applyWorldFile(text)
        }
    }

    private func receive(_ data: Data) {
        switch PhotoIngest.prepare(data, maxPixel: 2048) {
        case .failure(let failure):
            errorMessage = failure.localizedDescription
        case .success(let prepared):
            if prepared.placement != nil {
                commit(prepared, asOverlay: false)
            } else if prepared.metadata.hasLocation {
                pending = prepared
                showGPSChoice = true
            } else {
                commit(prepared, asOverlay: false)
            }
        }
    }

    private func commitPending(asOverlay: Bool) {
        guard let pending else { return }
        commit(pending, asOverlay: asOverlay)
        self.pending = nil
    }

    private func commit(_ prepared: PhotoIngest.Prepared, asOverlay: Bool) {
        do {
            if asOverlay {
                let footprint = PhotoIngest.footprint(
                    for: prepared.metadata,
                    pixelWidth: prepared.pixelWidth,
                    pixelHeight: prepared.pixelHeight
                )
                let georeference = prepared.metadata.hasLocation
                    ? Georeference(
                        latitude: prepared.metadata.latitude ?? 0,
                        longitude: prepared.metadata.longitude ?? 0,
                        headingDegrees: prepared.metadata.cameraHeading ?? 0
                    )
                    : nil
                _ = try store.importDroneOverlay(
                    homeId: homeID,
                    image: prepared.data,
                    fileExtension: prepared.fileExtension,
                    pixelWidth: prepared.pixelWidth,
                    pixelHeight: prepared.pixelHeight,
                    center: PhotoIngest.siteCenter(metadata: prepared.metadata, underlay: home?.site?.underlay),
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
                importNote = footprint.note
            } else if let placement = prepared.placement {
                _ = try store.importUnderlay(
                    homeId: homeID,
                    image: prepared.data,
                    pixelWidth: prepared.pixelWidth,
                    pixelHeight: prepared.pixelHeight,
                    widthMeters: placement.widthMeters,
                    heightMeters: placement.heightMeters,
                    yaw: placement.yaw,
                    georeference: placement.georeference ?? home?.site?.underlay?.georeference
                )
                importNote = placement.summary
            } else {
                let meters = home?.site?.underlay?.widthMeters ?? 40
                _ = try store.importUnderlay(
                    homeId: homeID,
                    image: prepared.data,
                    pixelWidth: prepared.pixelWidth,
                    pixelHeight: prepared.pixelHeight,
                    widthMeters: meters,
                    georeference: home?.site?.underlay?.georeference
                )
                importNote = "Plain photo. Set the width, import a world file, or use Scale and tap two points whose distance you know."
            }
            loadUnderlay()
            loadOverlays()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyWorldFile(_ text: String) {
        guard let underlay = home?.site?.underlay,
              let placement = RasterGeoreference.worldFile(text, pixelWidth: underlay.pixelWidth, pixelHeight: underlay.pixelHeight)
        else {
            errorMessage = "That world file needs six numbers: pixel size, two rotations, pixel size, and the upper-left origin."
            return
        }
        do {
            try store.updateSite(homeId: homeID) { site in
                guard var current = site.underlay else { return }
                current.widthMeters = placement.widthMeters
                current.heightMeters = placement.heightMeters
                current.yaw = placement.yaw
                if let georeference = placement.georeference {
                    current.georeference = georeference
                }
                site.underlay = current
            }
            importNote = placement.summary
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installSample() {
        do {
            let bundled = SampleBundle.siteImage()
            let facade = SampleBundle.facadeImage()
            _ = try store.installSampleSite(
                homeId: homeID,
                image: bundled?.data,
                pixelWidth: bundled?.width ?? 512,
                pixelHeight: bundled?.height ?? 512,
                facade: facade?.data,
                facadePixelWidth: facade?.width ?? 0,
                facadePixelHeight: facade?.height ?? 0
            )
            importNote = "Placeholder aerial of a lot, not a survey. The shed has a stand-in facade texture. Replace both when the orthophoto arrives."
            loadUnderlay()
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
                let aspect = current.heightMeters > 0 && current.widthMeters > 0
                    ? current.heightMeters / current.widthMeters
                    : (current.pixelWidth > 0 ? Double(current.pixelHeight) / Double(current.pixelWidth) : 1)
                current.widthMeters = width
                current.heightMeters = width * aspect
                site.underlay = current
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setUnderlayYaw(_ degrees: Double) {
        do {
            try store.updateSite(homeId: homeID) { site in
                guard var current = site.underlay else { return }
                current.yaw = degrees * .pi / 180
                site.underlay = current
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func wrapAngle(_ angle: Double) -> Double {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
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

    private func handleTap(_ world: Vec3, in home: Home) {
        guard tool != .move else { return }
        markers.append(world)
        guard markers.count >= 2 else { return }
        let pair = Array(markers.prefix(2))
        markers = []
        switch tool {
        case .scale:
            let distance = hypot(pair[1].x - pair[0].x, pair[1].z - pair[0].z)
            distanceText = String(format: "%.2f", distance)
            bearingText = ""
            markers = pair
            showDistance = true
        case .align:
            applyAlignment(pair, in: home)
        case .move:
            break
        }
    }

    private func applyScale() {
        guard let underlay = home?.site?.underlay, markers.count >= 2 else {
            showDistance = false
            return
        }
        let meters = Double(distanceText.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard let pixelA = SiteSurvey.underlayPixel(world: markers[0], underlay: underlay),
              let pixelB = SiteSurvey.underlayPixel(world: markers[1], underlay: underlay),
              let measured = SiteSurvey.scale(
                pixelA: pixelA,
                pixelB: pixelB,
                pixelWidth: underlay.pixelWidth,
                pixelHeight: underlay.pixelHeight,
                distanceMeters: meters
              )
        else {
            errorMessage = "Those two points did not fall on the photo, or the distance was not a number."
            return
        }
        let bearing = Double(bearingText.replacingOccurrences(of: ",", with: "."))
        do {
            try store.updateSite(homeId: homeID) { site in
                guard var current = site.underlay else { return }
                current.widthMeters = measured.widthMeters
                current.heightMeters = measured.heightMeters
                if let bearing {
                    let localX = pixelB.x - pixelA.x
                    let localZ = -(pixelB.y - pixelA.y)
                    let radians = bearing * .pi / 180
                    let desired = atan2(cos(radians), sin(radians))
                    let local = atan2(localZ, localX)
                    current.yaw = wrapAngle(desired - local)
                }
                site.underlay = current
            }
            if bearing == nil {
                importNote = String(format: "Scale set to %.3f m/pixel from the two points.", measured.metersPerPixel)
            } else {
                importNote = String(format: "Scale set to %.3f m/pixel and the photo was rotated to the bearing.", measured.metersPerPixel)
            }
            showDistance = false
            markers = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyAlignment(_ pair: [Vec3], in home: Home) {
        guard let placement = selected(in: home), let ends = localEnds(in: home) else {
            errorMessage = "Select a room or outdoor scan before aligning it."
            return
        }
        guard let updated = SiteSurvey.placementMatching(
            subject: placement.subject,
            localA: ends.0,
            localB: ends.1,
            siteA: pair[0],
            siteB: pair[1]
        ) else {
            errorMessage = "Those two points are too close together."
            return
        }
        let localLength = hypot(ends.1.x - ends.0.x, ends.1.z - ends.0.z)
        let siteLength = hypot(pair[1].x - pair[0].x, pair[1].z - pair[0].z)
        do {
            try store.updateSite(homeId: homeID) { site in
                guard let index = site.placements.firstIndex(where: { $0.id == placement.id }) else { return }
                site.placements[index].origin = updated.origin
                site.placements[index].yaw = updated.yaw
            }
            if localLength > 0.05, abs(siteLength - localLength) / localLength > 0.1 {
                importNote = String(format: "Aligned. The taps are %.1f m apart and the wall measures %.1f m, so the plan was rotated but not scaled.", siteLength, localLength)
            } else {
                importNote = "Aligned to the two taps. The measured size was kept."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteOverlay(_ id: UUID) {
        do {
            try store.deleteDroneOverlay(homeId: homeID, overlayId: id)
            loadOverlays()
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

    private func exportJSON() {
        guard let home else { return }
        do {
            SharePresenter.present(url: try store.exportLayout(for: home))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SiteCanvas: View {
    var home: Home
    var image: UIImage?
    var overlayImages: [UUID: UIImage]
    var selectedPlacementID: UUID?
    var tool: SiteTool
    var markers: [Vec3]
    var guide: (Vec3, Vec3)?
    var onSelect: (UUID?) -> Void
    var onMove: (UUID, Double, Double) -> Void
    var onTap: (Vec3) -> Void

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
                for overlay in home.site?.overlays ?? [] {
                    drawOverlay(overlay, in: context, projector: projector)
                }
                for placement in home.site?.placements ?? [] {
                    draw(placement, in: context, projector: projector)
                }
                if let guide {
                    stroke([guide.0, guide.1], in: context, projector: projector, color: Theme.warn, width: 3)
                    dot(guide.0, in: context, projector: projector)
                }
                for marker in markers {
                    dot(marker, in: context, projector: projector)
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
        for overlay in home.site?.overlays ?? [] {
            let center = SiteGeodesy.overlayPosition(overlay, underlay: home.site?.underlay)
            points.append(center)
            points.append(Vec3(x: center.x + overlay.widthMeters / 2, y: 0, z: center.z + overlay.heightMeters / 2))
        }
        for placement in home.site?.placements ?? [] {
            points.append(contentsOf: worldCorners(placement))
        }
        points.append(contentsOf: markers)
        if let guide {
            points.append(guide.0)
            points.append(guide.1)
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
        drawPhoto(
            image,
            center: underlay.center,
            yaw: underlay.yaw,
            width: underlay.widthMeters,
            height: underlay.heightMeters,
            in: context,
            projector: projector
        )
    }

    private func drawOverlay(_ overlay: DroneOverlay, in context: GraphicsContext, projector: PlanProjector) {
        let center = SiteGeodesy.overlayPosition(overlay, underlay: home.site?.underlay)
        if let image = overlayImages[overlay.id] {
            drawPhoto(
                image,
                center: center,
                yaw: overlay.yaw,
                width: overlay.widthMeters,
                height: overlay.heightMeters,
                in: context,
                projector: projector
            )
        }
        let corners = photoCorners(center: center, yaw: overlay.yaw, width: overlay.widthMeters, height: overlay.heightMeters)
        stroke(corners, in: context, projector: projector, color: Theme.accent, width: 1.5)
    }

    private func drawPhoto(
        _ image: UIImage,
        center: Vec3,
        yaw: Double,
        width: Double,
        height: Double,
        in context: GraphicsContext,
        projector: PlanProjector
    ) {
        let centerPoint = screen(center, projector)
        let east = screen(
            SiteLayout.apply(Vec3(x: width / 2, y: 0, z: 0), placement: SitePlacement(subject: .room(UUID()), origin: center, yaw: yaw)),
            projector
        )
        let north = screen(
            SiteLayout.apply(Vec3(x: 0, y: 0, z: height / 2), placement: SitePlacement(subject: .room(UUID()), origin: center, yaw: yaw)),
            projector
        )
        let halfW = hypot(east.x - centerPoint.x, east.y - centerPoint.y)
        let halfH = hypot(north.x - centerPoint.x, north.y - centerPoint.y)
        let angle = atan2(east.y - centerPoint.y, east.x - centerPoint.x)
        var draw = context
        draw.translateBy(x: centerPoint.x, y: centerPoint.y)
        draw.rotate(by: .radians(angle))
        draw.draw(Image(uiImage: image), in: CGRect(x: -halfW, y: -halfH, width: halfW * 2, height: halfH * 2))
    }

    private func photoCorners(center: Vec3, yaw: Double, width: Double, height: Double) -> [Vec3] {
        let placement = SitePlacement(subject: .room(UUID()), origin: center, yaw: yaw)
        return [
            Vec3(x: -width / 2, y: 0, z: -height / 2),
            Vec3(x: width / 2, y: 0, z: -height / 2),
            Vec3(x: width / 2, y: 0, z: height / 2),
            Vec3(x: -width / 2, y: 0, z: height / 2)
        ].map { SiteLayout.apply($0, placement: placement) }
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
        drawWalls(placement, in: context, projector: projector)
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

    private func drawWalls(_ placement: SitePlacement, in context: GraphicsContext, projector: PlanProjector) {
        let walls: [WallSegment]
        switch placement.subject {
        case .room(let id):
            walls = home.room(id: id)?.floorPlan.walls ?? []
        case .outdoorZone(let id):
            walls = home.outdoorZone(id: id)?.walls ?? []
        }
        var placed = placement
        if case .placement(let id, _) = dragMode, id == placement.id, let previewOrigin {
            placed.origin = previewOrigin
        }
        for wall in walls {
            let start = SiteLayout.apply(wall.start, placement: placed)
            let end = SiteLayout.apply(wall.end, placement: placed)
            var path = Path()
            path.move(to: screen(start, projector))
            path.addLine(to: screen(end, projector))
            context.stroke(path, with: .color(Theme.ink), lineWidth: wall.texture == nil ? 2 : 3)
        }
    }

    private func stroke(_ corners: [Vec3], in context: GraphicsContext, projector: PlanProjector, color: Color, width: CGFloat) {
        guard let first = corners.first else { return }
        var path = Path()
        path.move(to: screen(first, projector))
        for corner in corners.dropFirst() {
            path.addLine(to: screen(corner, projector))
        }
        if corners.count > 2 { path.closeSubpath() }
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private func dot(_ point: Vec3, in context: GraphicsContext, projector: PlanProjector) {
        let location = screen(point, projector)
        let rect = CGRect(x: location.x - 5, y: location.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: rect), with: .color(Theme.warn))
    }

    private func worldCorners(_ placement: SitePlacement) -> [Vec3] {
        let local: [Vec3]
        switch placement.subject {
        case .room(let id):
            guard let room = home.room(id: id) else { return [] }
            local = SiteLayout.roomFootprint(room)
        case .outdoorZone(let id):
            guard let zone = home.outdoorZone(id: id) else { return [] }
            local = zone.buildingFootprint.count >= 3 ? zone.buildingFootprint : zone.footprint
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
                    if tool == .move, let hit = hit(value.startLocation, projector: projector) {
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
                    let world = projector.world(screenX: value.location.x, screenY: value.location.y)
                    if tool == .move {
                        onSelect(hit(value.location, projector: projector)?.id)
                    } else {
                        onTap(Vec3(x: world.x, y: 0, z: world.z))
                    }
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
