import SwiftUI
import RoomScanCore

struct HomeDetailView: View {
    @Environment(HomeStore.self) private var store
    @Environment(PinBoard.self) private var pinBoard

    let homeID: UUID

    @State private var scanning = false
    @State private var scanningOutdoor = false
    @State private var combining = false
    @State private var renaming = false
    @State private var renameDraft = ""
    @State private var pendingRoom: Room?
    @State private var editor: DevicePin?
    @State private var errorMessage: String?

    private var home: Home? { store.home(id: homeID) }

    var body: some View {
        PaperScreen {
            if let home {
                List {
                    if !LiDARSupport.canScan {
                        Section {
                            LiDARNotice()
                                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                                .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        FloorPlanCanvas(
                            layers: previewLayers(home),
                            pins: home.pins,
                            showPins: home.coordinatesAreUnified,
                            selectedPinID: nil,
                            placing: false,
                            interactive: false
                        )
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        NavigationLink(value: AppRoute.model(home.id)) {
                            Label("3D model", systemImage: "cube")
                        }
                        NavigationLink(value: AppRoute.plan(home.id)) {
                            Label("Floor plan", systemImage: "square.split.bottomrightquarter")
                        }
                    } footer: {
                        Text(layoutCaption(home))
                    }
                    Section("Rooms") {
                        if home.rooms.isEmpty {
                            Text("Scan the kitchen, then the rooms that open off it.")
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(home.rooms) { room in
                            NavigationLink(value: AppRoute.room(home: home.id, room: room.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(room.name)
                                    Text(roomCaption(room, in: home))
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { pendingRoom = room }
                            }
                        }
                        if LiDARSupport.canScan {
                            Button {
                                scanning = true
                            } label: {
                                Label("Scan a room", systemImage: "viewfinder")
                            }
                        }
                    }
                    Section {
                        if capturedCount(home) >= 2 {
                            Button {
                                combine(home)
                            } label: {
                                if combining {
                                    HStack {
                                        ProgressView()
                                        Text("Aligning rooms")
                                    }
                                } else {
                                    Label(
                                        home.structure == nil ? "Combine into one floor" : "Rebuild the floor",
                                        systemImage: "square.stack.3d.up"
                                    )
                                }
                            }
                            .disabled(combining)
                        } else if home.coordinatesAreUnified && home.rooms.count > 1 {
                            Label("Rooms already share one floor", systemImage: "checkmark.circle")
                                .foregroundStyle(Theme.accent)
                        } else {
                            Text("Scan at least two rooms that share a doorway, then RoomPlan can align them.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                        }
                    } header: {
                        Text("One floor")
                    }
                    outdoorSection(home)
                    Section("Devices") {
                        if home.pins.isEmpty {
                            Text("Open a room and place lights, switches, or sensors.")
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(home.pins) { pin in
                            Button {
                                editor = pin
                            } label: {
                                pinRow(pin)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(pinBoard.banner)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("Home missing", systemImage: "house", description: Text("It may have been deleted."))
            }
        }
        .navigationTitle(home?.name ?? "Home")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbar }
        .fullScreenCover(isPresented: $scanning) {
            ScanRoomView(homeID: homeID) { scanning = false }
        }
        .fullScreenCover(isPresented: $scanningOutdoor) {
            OutdoorScanView(homeID: homeID)
        }
        .task(id: home?.pins.map { "\($0.id.uuidString)|\($0.entityId ?? "")" }.joined(separator: ",") ?? "") {
            await pinBoard.refresh(pins: home?.pins ?? [])
        }
        .sheet(item: $editor) { pin in
            PinEditorSheet(
                pin: pin,
                snapshot: pinBoard.snapshot(for: pin),
                onToggle: { Task { await pinBoard.toggle(pin) } },
                onSave: { save($0) },
                onDelete: { deletePin(pin.id) }
            )
        }
        .alert("Rename home", isPresented: $renaming) {
            TextField("Name", text: $renameDraft)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(pendingRoom?.name ?? "this room")?",
            isPresented: Binding(get: { pendingRoom != nil }, set: { if !$0 { pendingRoom = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete room", role: .destructive) {
                if let pendingRoom { deleteRoom(pendingRoom) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Devices placed in this room are deleted too. A combined model is cleared so it doesn't keep the old room.")
        }
        .alert("Couldn't update the home", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename") {
                    renameDraft = home?.name ?? ""
                    renaming = true
                }
                Button("Export layout JSON") { shareJSON() }
                Button("Share 3D model") { shareModel() }
                    .disabled(home.flatMap { store.structureModelURL(in: $0) } == nil)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func previewLayers(_ home: Home) -> [PlanLayer] {
        if let overview = home.structure?.overviewFloorPlan, !home.coordinatesAreUnified {
            return PlanLayers.overview(overview, name: home.name)
        }
        return PlanLayers.rooms(home.rooms, unified: home.coordinatesAreUnified)
    }

    private func layoutCaption(_ home: Home) -> String {
        if let _ = home.structure?.overviewFloorPlan, !home.coordinatesAreUnified {
            return "The thumbnail is the aligned shell. Device pins stay in each room's own scan."
        }
        if home.coordinatesAreUnified {
            return "Drag to orbit the 3D model. The floor plan is the same measurement, seen from above."
        }
        return "Each scan still has its own origin. Combine them after two LiDAR passes through a shared door."
    }

    private func roomCaption(_ room: Room, in home: Home) -> String {
        let devices = home.pins(in: room.id).count
        let deviceText = devices == 1 ? "1 device" : "\(devices) devices"
        let source = room.assets.capturedRoom == nil ? "Drawn plan" : "LiDAR scan"
        return "\(source) · \(deviceText)"
    }

    @ViewBuilder
    private func outdoorSection(_ home: Home) -> some View {
        Section {
            NavigationLink(value: AppRoute.site(home.id)) {
                Label("Site plan", systemImage: "map")
            }
            ForEach(home.outdoorZones) { zone in
                NavigationLink(value: AppRoute.outdoor(home: home.id, zone: zone.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(zone.name)
                        Text("\(zone.kind.label) · \(zone.walls.count) facades · \(zone.groundVertexCount) ground points")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        do {
                            try store.deleteOutdoorZone(homeId: home.id, zoneId: zone.id)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            if OutdoorScanSupport.canScan {
                Button {
                    scanningOutdoor = true
                } label: {
                    Label("Scan outside", systemImage: "viewfinder")
                }
            } else {
                Text(OutdoorScanSupport.unavailableReason)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
        } header: {
            Text("Outside")
        } footer: {
            Text("LiDAR mesh reaches about \(Int(OutdoorScanSupport.rangeMeters)) meters. Place rooms and outdoor scans on an aerial or drone photo in the site plan.")
        }
    }

    private func capturedCount(_ home: Home) -> Int {
        home.rooms.filter { $0.assets.capturedRoom != nil }.count
    }

    private func pinRow(_ pin: DevicePin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pin.kind.symbolName)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.name)
                    .foregroundStyle(Theme.ink)
                Text(pin.entityId ?? "No entity id")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if let snapshot = pinBoard.snapshot(for: pin) {
                Text(snapshot.displayState)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    private func combine(_ home: Home) {
        combining = true
        Task {
            defer { combining = false }
            do {
                let payloads = try store.capturedPayloads(in: home)
                guard payloads.count >= 2 else {
                    errorMessage = "Scan at least two rooms before combining them."
                    return
                }
                let captured = try payloads.map { try ScanArchive.decodeRoom($0.data) }
                let structure = try await ScanArchive.buildStructure(from: captured)
                let overview = FloorPlanExtractor.floorPlan(from: structure)
                let json = try ScanArchive.encodeStructure(structure)
                let usdz = try ScanArchive.usdzData(for: structure)
                try store.attachStructure(
                    homeId: home.id,
                    capturedJSON: json,
                    usdz: usdz,
                    overview: overview,
                    roomIds: payloads.map(\.room.id)
                )
            } catch {
                errorMessage = "RoomPlan could not align these scans. Include the shared doorway in each room, then try again. \(error.localizedDescription)"
            }
        }
    }

    private func shareJSON() {
        guard let home else { return }
        do {
            SharePresenter.present(url: try store.exportLayout(for: home))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shareModel() {
        guard let home, let url = store.structureModelURL(in: home) else {
            errorMessage = "Combine the rooms to share one USDZ model."
            return
        }
        SharePresenter.present(url: url)
    }

    private func rename() {
        mutate { $0.name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.name : renameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func deleteRoom(_ room: Room) {
        do {
            try store.deleteRoom(homeId: homeID, roomId: room.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingRoom = nil
    }

    private func save(_ pin: DevicePin) {
        mutate { $0.upsertPin(pin) }
    }

    private func deletePin(_ id: UUID) {
        mutate { $0.deletePin(id: id) }
    }

    private func mutate(_ body: (inout Home) -> Void) {
        do {
            try store.update(homeId: homeID, body)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
