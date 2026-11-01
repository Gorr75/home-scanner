import SwiftUI
import RoomScanCore

struct RoomDetailView: View {
    @Environment(HomeStore.self) private var store
    @Environment(PinBoard.self) private var pinBoard

    let homeID: UUID
    let roomID: UUID

    @State private var page: Page = .model
    @State private var placing = false
    @State private var placeKind: DeviceKind = .light
    @State private var selectedPinID: UUID?
    @State private var editor: DevicePin?
    @State private var renderedUSDZ = false
    @State private var cameraToken = 0
    @State private var renaming = false
    @State private var renameDraft = ""
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private enum Page: String, CaseIterable, Identifiable {
        case model = "Model"
        case plan = "Plan"
        case devices = "Devices"
        var id: String { rawValue }
    }

    private var home: Home? { store.home(id: homeID) }
    private var room: Room? { home?.room(id: roomID) }
    private var pins: [DevicePin] { home?.pins(in: roomID) ?? [] }

    var body: some View {
        PaperScreen {
            if let home, let room {
                VStack(spacing: 0) {
                    Picker("View", selection: $page) {
                        ForEach(Page.allCases) { page in
                            Text(page.rawValue).tag(page)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    switch page {
                    case .model:
                        model(home, room: room)
                    case .plan:
                        plan(room)
                    case .devices:
                        deviceList
                    }
                    if let selected = pins.first(where: { $0.id == selectedPinID }) {
                        selectionBar(selected)
                    }
                }
            } else {
                ContentUnavailableView("Room missing", systemImage: "square.dashed", description: Text("It may have been deleted."))
            }
        }
        .navigationTitle(room?.name ?? "Room")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: pins.map(\.id)) {
            await pinBoard.refresh(pins: pins)
        }
        .sheet(item: $editor) { pin in
            PinEditorSheet(
                pin: pin,
                snapshot: pinBoard.snapshot(for: pin),
                onToggle: { Task { await pinBoard.toggle(pin) } },
                onSave: { saved in
                    save(saved)
                    selectedPinID = saved.id
                },
                onDelete: {
                    deletePin(pin.id)
                    if selectedPinID == pin.id { selectedPinID = nil }
                }
            )
        }
        .alert("Rename room", isPresented: $renaming) {
            TextField("Name", text: $renameDraft)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this room?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteRoom() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't update the room", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func model(_ home: Home, room: Room) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoomModelView(
                layers: PlanLayers.single(room),
                usdzURL: store.roomModelURL(in: home, room: room),
                pins: pins,
                showPins: true,
                stateByEntity: pinBoard.stateMap(for: pins),
                captionByPin: pinBoard.captions(for: pins),
                selectedPinID: selectedPinID,
                placementEnabled: placing,
                cameraToken: cameraToken,
                onSelectPin: { selectedPinID = $0 },
                onPlace: { place(at: $0, in: room) },
                onRenderedUSDZ: { renderedUSDZ = $0 }
            )
            caption(room)
        }
    }

    private func plan(_ room: Room) -> some View {
        FloorPlanCanvas(
            layers: PlanLayers.single(room),
            pins: pins,
            showPins: true,
            selectedPinID: selectedPinID,
            placing: placing,
            pinCaptions: pinBoard.captions(for: pins),
            pinStates: pinBoard.states(for: pins),
            onSelectPin: { selectedPinID = $0 },
            onMovePin: { id, x, z in move(id, x: x, z: z) },
            onCreate: { x, z in
                create(in: roomID, x: x, z: z, y: placeKind.defaultHeight)
            }
        )
    }

    private var deviceList: some View {
        List {
            if pins.isEmpty {
                ContentUnavailableView(
                    "No devices in this room",
                    systemImage: "mappin.slash",
                    description: Text("Choose a type, then tap the plan or the model.")
                )
            }
            ForEach(pins) { pin in
                HStack {
                    Button {
                        selectedPinID = pin.id
                        editor = pin
                    } label: {
                        HStack {
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
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let snapshot = pinBoard.snapshot(for: pin) {
                        Text(snapshot.displayState)
                            .font(.subheadline.monospacedDigit())
                        if snapshot.isToggleable {
                            Button(snapshot.isOn ? "Off" : "On") {
                                Task { await pinBoard.toggle(pin) }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel(snapshot.isOn ? "Turn off \(pin.name)" : "Turn on \(pin.name)")
                        }
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { pins[$0].id }
                ids.forEach(deletePin)
            }
            Text(pinBoard.banner)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            if let lastError = pinBoard.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func caption(_ room: Room) -> some View {
        Text(captionText(room))
            .font(.caption)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
    }

    private func captionText(_ room: Room) -> String {
        if placing { return "Tap a surface to place a \(placeKind.label.lowercased())." }
        if renderedUSDZ { return "Drag to orbit · Pinch to zoom" }
        if room.assets.usdz == nil {
            return "Measured plan · Drag to orbit · Pinch to zoom"
        }
        return "USDZ didn't open, so this is the measured plan."
    }

    private func selectionBar(_ pin: DevicePin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pin.kind.symbolName)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.name)
                    .font(.subheadline.weight(.semibold))
                Text(pinBoard.snapshot(for: pin)?.displayState ?? pin.entityId ?? "Not linked")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if let snapshot = pinBoard.snapshot(for: pin), snapshot.isToggleable {
                Button(snapshot.isOn ? "Turn off" : "Turn on") {
                    Task { await pinBoard.toggle(pin) }
                }
                .buttonStyle(.bordered)
            }
            Button("Edit") { editor = pin }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.card)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Device type", selection: $placeKind) {
                    ForEach(DeviceKind.allCases, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.symbolName).tag(kind)
                    }
                }
                Button(placing ? "Stop placing" : "Place on the plan") {
                    placing.toggle()
                    if placing { page = page == .devices ? .plan : page }
                }
                Button("Add \(placeKind.label.lowercased()) at the center") {
                    addAtCenter()
                }
                Divider()
                Button("Rename room") {
                    renameDraft = room?.name ?? ""
                    renaming = true
                }
                Button("Export layout JSON") { shareJSON() }
                Button("Share USDZ") { shareModel() }
                Button("Reset camera") { cameraToken += 1 }
                Divider()
                Button("Delete room", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: placing ? "mappin.circle.fill" : "ellipsis.circle")
            }
            .accessibilityLabel("Room actions")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func place(at point: Vec3, in room: Room) {
        let height = point.y < 0.25 ? placeKind.defaultHeight : point.y
        create(in: room.id, x: point.x, z: point.z, y: height)
    }

    private func addAtCenter() {
        guard let room else { return }
        let box = FloorPlanGeometry.bounds(of: room.floorPlan)
        create(in: room.id, x: box.center.x, z: box.center.z, y: placeKind.defaultHeight)
    }

    private func create(in roomId: UUID, x: Double, z: Double, y: Double) {
        var pin = DevicePin.placed(in: roomId, kind: placeKind, x: x, z: z)
        pin.position.y = y
        save(pin)
        selectedPinID = pin.id
        editor = pin
        placing = false
    }

    private func move(_ id: UUID, x: Double, z: Double) {
        mutate { home in
            guard let pin = home.pins.first(where: { $0.id == id }) else { return }
            home.upsertPin(pin.moved(x: x, z: z))
        }
    }

    private func save(_ pin: DevicePin) {
        mutate { $0.upsertPin(pin) }
    }

    private func deletePin(_ id: UUID) {
        mutate { $0.deletePin(id: id) }
    }

    private func rename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { home in
            guard let index = home.rooms.firstIndex(where: { $0.id == roomID }) else { return }
            home.rooms[index].name = trimmed
        }
    }

    private func deleteRoom() {
        do {
            try store.deleteRoom(homeId: homeID, roomId: roomID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
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
        guard let home, let room else { return }
        if let url = store.roomModelURL(in: home, room: room) {
            SharePresenter.present(url: url)
            return
        }
        if home.coordinatesAreUnified, let url = store.structureModelURL(in: home) {
            SharePresenter.present(url: url)
            return
        }
        errorMessage = "This room has no USDZ file yet. A LiDAR scan writes one you can share."
    }

    private func mutate(_ body: (inout Home) -> Void) {
        do {
            try store.update(homeId: homeID, body)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
