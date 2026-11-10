import SwiftUI
import RoomScanCore

struct RoomDetailView: View {
    @Environment(HomeStore.self) private var store
    @Environment(PinBoard.self) private var pinBoard
    @Environment(HomeAssistantSettings.self) private var assistant

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
    @State private var sending = false
    @State private var showSettings = false
    @State private var showUploaded = false
    @State private var uploadedMessage = ""
    @State private var rescanning = false
    @State private var compareRoomID: UUID?
    @State private var showHeat = false
    @State private var texturing = false
    @State private var pendingPlacements: [DevicePin] = []
    @State private var confirmAutoPlace = false
    @State private var previewHour: Double?
    @State private var planEditor = PlanEditorSession()
    @State private var placingFurniture = false
    @State private var catalogItemID: String?
    @State private var showCatalog = false
    @State private var replacingObjectID: UUID?
    @State private var selectedFurnitureID: UUID?
    @State private var captureToken = 0
    @AppStorage(DaylightPreference.enabledKey) private var daylightEnabled = true
    @Environment(\.dismiss) private var dismiss

    private enum Page: String, CaseIterable, Identifiable {
        case model = "Model"
        case plan = "Plan"
        case objects = "Objects"
        case devices = "Devices"
        var id: String { rawValue }
    }

    private var home: Home? { store.home(id: homeID) }
    private var room: Room? { home?.room(id: roomID) }
    private var pins: [DevicePin] { home?.pins(in: roomID) ?? [] }

    private var viewing: Bool { page == .model || page == .plan }

    var body: some View {
        Group {
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
                        PlanEditorBar(
                            canUndo: planEditor.canUndo,
                            canRedo: planEditor.canRedo,
                            canSplit: planEditor.canSplit(home),
                            canCopy: planEditor.canCopy,
                            onUndo: undoPlan,
                            onRedo: redoPlan,
                            onSplit: splitRoom,
                            onCopy: copyOpening
                        )
                        measurementLine(room)
                    case .objects:
                        objectList(room)
                    case .devices:
                        deviceList
                    }
                    if let furniture = room.placedFurniture.first(where: { $0.id == selectedFurnitureID }) {
                        FurnitureAdjustBar(
                            title: FurnitureCatalog.item(id: furniture.catalogId)?.name ?? "Furniture",
                            onCharcoal: viewing,
                            onRotate: { delta in
                                mutate { $0.rotateFurniture(id: furniture.id, by: delta) }
                            },
                            onScale: { factor in
                                mutate { $0.scaleFurniture(id: furniture.id, by: factor) }
                            },
                            onDelete: {
                                mutate { $0.removeFurniture(id: furniture.id) }
                                selectedFurnitureID = nil
                            }
                        )
                    }
                    if let selected = pins.first(where: { $0.id == selectedPinID }) {
                        selectionBar(selected)
                    }
                }
            } else {
                ContentUnavailableView("Room missing", systemImage: "square.dashed", description: Text("It may have been deleted."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .confirmationDialog(
            pendingPlacements.count == 1
                ? "Add 1 device from Home Assistant?"
                : "Add \(pendingPlacements.count) devices from Home Assistant?",
            isPresented: $confirmAutoPlace,
            titleVisibility: .visible
        ) {
            Button("Add devices") { commitAutoPlace() }
            Button("Cancel", role: .cancel) { pendingPlacements = [] }
        } message: {
            Text(DeviceAutoPlace.confirmDetail)
        }
        .alert("Sent to Home Assistant", isPresented: $showUploaded) {
            Button("Open Home Assistant") { openCompanion() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(uploadedMessage)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: Binding(
            get: { compareRoomID != nil },
            set: { if !$0 { compareRoomID = nil } }
        )) {
            if let compareRoomID {
                compareSheet(compareRoomID)
            }
        }
        .fullScreenCover(isPresented: $rescanning) {
            ScanRoomView(homeID: homeID, replacingRoomID: roomID) { rescanning = false }
        }
        .sheet(isPresented: $texturing) {
            TextureStudioView(homeID: homeID, roomID: roomID)
        }
        .sheet(isPresented: $showCatalog) {
            FurnitureCatalogSheet(suggestedID: suggestedCatalogID) { item in
                if let replacingObjectID {
                    mutate { home in
                        if let placed = home.replaceObject(id: replacingObjectID, in: roomID, with: item.id) {
                            selectedFurnitureID = placed.id
                        }
                    }
                    self.replacingObjectID = nil
                    placingFurniture = false
                } else {
                    catalogItemID = item.id
                    placingFurniture = true
                    placing = false
                    if page == .devices || page == .objects { page = .plan }
                }
            }
        }
        .overlay {
            if sending {
                ProgressView("Sending to Home Assistant")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .surfaceChrome(charcoal: viewing)
    }

    private func model(_ home: Home, room: Room) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let tint = DaylightScene.tint(
                enabled: daylightEnabled,
                previewHour: previewHour,
                sun: pinBoard.sun,
                now: timeline.date
            )
            RoomModelView(
                layers: PlanLayers.single(room),
                usdzURL: room.flooring == nil ? store.roomModelURL(in: home, room: room) : nil,
                pins: pins,
                showPins: true,
                looksByEntity: pinBoard.looksByEntity(for: pins),
                captionByPin: pinBoard.captions(for: pins),
                selectedPinID: selectedPinID,
                placementEnabled: placing,
                cameraToken: cameraToken,
                onSelectPin: { selectedPinID = $0 },
                onTogglePin: { togglePin($0) },
                onPlace: { place(at: $0, in: room) },
                onRenderedUSDZ: { renderedUSDZ = $0 },
                surfacePaints: TexturePaints.forRoom(room, homeId: homeID, store: store),
                daylight: tint,
                selectedFurnitureID: selectedFurnitureID,
                placingFurniture: placingFurniture,
                onSelectFurniture: { id in
                    selectedFurnitureID = id
                    if id != nil { selectedPinID = nil }
                },
                onMoveFurniture: { id, point in
                    moveFurniture(id, x: point.x, z: point.z)
                },
                onPlaceFurniture: { point in
                    placeFurniture(x: point.x, z: point.z, in: room.id)
                },
                savedViewpoint: room.viewpoint,
                captureToken: captureToken,
                onCaptureViewpoint: { saveViewpoint($0) }
            )
            .overlay(alignment: .top) {
                if let tint {
                    DaylightScrubber(previewHour: $previewHour, now: timeline.date, tint: tint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom) {
                    caption(room)
                    Spacer(minLength: 8)
                    Button("Save viewpoint") { captureToken += 1 }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.chalk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.navy, in: Capsule())
                        .padding(12)
                }
            }
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
            pinLooks: pinBoard.looksByPin(for: pins),
            heatSamples: showHeat ? heatSamples(in: room) : [],
            onCharcoal: true,
            onSelectPin: { selectedPinID = $0 },
            onMovePin: { id, x, z in move(id, x: x, z: z) },
            onCreate: { x, z in
                create(in: roomID, x: x, z: z, y: placeKind.defaultHeight)
            },
            planEditing: !placing && !placingFurniture,
            selectedRoomID: planEditor.selectedRoomID,
            selectedOpeningID: planEditor.selectedOpeningID,
            extraSnapPlans: snapPlans(except: room.id),
            onSelectRoom: { id in
                planEditor.selectedRoomID = id
                if id != nil { selectedFurnitureID = nil }
            },
            onSelectOpening: { planEditor.selectedOpeningID = $0 },
            onCommitPlan: { commitPlan(roomID: $0, plan: $1) },
            selectedFurnitureID: selectedFurnitureID,
            placingFurniture: placingFurniture,
            onSelectFurniture: { id in
                selectedFurnitureID = id
                if id != nil {
                    selectedPinID = nil
                    planEditor.selectedRoomID = nil
                    planEditor.selectedOpeningID = nil
                }
            },
            onMoveFurniture: { id, x, z in
                moveFurniture(id, x: x, z: z)
            },
            onCreateFurniture: { x, z in
                placeFurniture(x: x, z: z, in: room.id)
            }
        )
    }

    private func objectList(_ room: Room) -> some View {
        List {
            Section {
                Button {
                    replacingObjectID = nil
                    showCatalog = true
                } label: {
                    Label("Add from the catalog", systemImage: "plus")
                }
            } footer: {
                Text(flooringCaption(room))
            }
            if room.placedFurniture.isEmpty && room.floorPlan.objects.isEmpty {
                ContentUnavailableView(
                    "No furniture yet",
                    systemImage: "cube",
                    description: Text("Add a sofa, table, lamp, or plant. A RoomPlan box can be replaced with a catalog item.")
                )
            }
            if !room.placedFurniture.isEmpty {
                Section("Placed") {
                    ForEach(room.placedFurniture) { item in
                        Button {
                            selectedFurnitureID = item.id
                            page = .plan
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(FurnitureCatalog.item(id: item.catalogId)?.name ?? item.catalogId)
                                    .foregroundStyle(Theme.ink)
                                Text(item.replacesObjectId == nil ? "Catalog item" : "Replaces a scan box")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !room.floorPlan.objects.isEmpty {
                Section("Recognised by RoomPlan") {
                    ForEach(room.floorPlan.objects) { object in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ObjectLabels.title(for: object.category))
                            Text(ObjectLabels.size(object))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.secondary)
                            if room.replacedObjectIDs.contains(object.id) {
                                Text("Replaced by a catalog item")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                            } else {
                                Button("Replace with a catalog item") {
                                    replacingObjectID = object.id
                                    showCatalog = true
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var suggestedCatalogID: String? {
        guard let replacingObjectID,
              let category = room?.floorPlan.objects.first(where: { $0.id == replacingObjectID })?.category else {
            return nil
        }
        return FurnitureCatalog.match(for: category)?.id
    }

    private func flooringCaption(_ room: Room) -> String {
        let finish = room.flooring?.title ?? "the scan default"
        return "Flooring is \(finish). A photo from the scan still covers the floor when one is saved."
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
            Button("Place devices from Home Assistant") { proposeAutoPlace() }
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
            .foregroundStyle(Theme.chalk)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.navy, in: Capsule())
            .padding(12)
    }

    private func captionText(_ room: Room) -> String {
        if placingFurniture {
            let name = catalogItemID.flatMap { FurnitureCatalog.item(id: $0)?.name } ?? "furniture"
            return "Tap the plan or the model to place a \(name.lowercased())."
        }
        if placing { return "Tap a surface to place a \(placeKind.label.lowercased())." }
        if renderedUSDZ { return "Tap a light, switch, or fan to toggle it · Drag to orbit" }
        if room.assets.usdz == nil {
            return "Measured plan · Tap a light to toggle it · Drag to orbit"
        }
        return "USDZ didn't open, so this is the measured plan. Tap a light to toggle it."
    }

    private func selectionBar(_ pin: DevicePin) -> some View {
        PinSelectionBar(
            pin: pin,
            snapshot: pinBoard.snapshot(for: pin),
            onCharcoal: viewing,
            onToggle: { Task { await pinBoard.toggle(pin) } },
            onBrightness: { level in Task { await pinBoard.setBrightness(level, pin: pin) } },
            onEdit: { editor = pin }
        )
    }

    private func togglePin(_ id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        guard pinBoard.snapshot(for: pin)?.isToggleable == true else { return }
        Task { await pinBoard.toggle(pin) }
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
                    if placing {
                        placingFurniture = false
                        page = page == .devices ? .plan : page
                    }
                }
                Button(placingFurniture ? "Stop placing furniture" : "Add furniture") {
                    if placingFurniture {
                        placingFurniture = false
                    } else {
                        replacingObjectID = nil
                        showCatalog = true
                    }
                }
                Menu("Flooring") {
                    Button("Scan default") { setFlooring(nil) }
                    ForEach(FlooringMaterial.allCases, id: \.self) { material in
                        Button(material.title) { setFlooring(material) }
                    }
                }
                Button("Add \(placeKind.label.lowercased()) at the center") {
                    addAtCenter()
                }
                Button("Place devices from Home Assistant") { proposeAutoPlace() }
                Divider()
                Button(showHeat ? "Hide sensor heatmap" : "Show sensor heatmap") { showHeat.toggle() }
                Button("Wall photos") { texturing = true }
                if LiDARSupport.canScan {
                    Button("Re-scan this room") { rescanning = true }
                }
                if (home?.rooms.count ?? 0) > 1 {
                    Button("Compare with another scan") {
                        compareRoomID = home?.rooms.first { $0.id != roomID }?.id
                    }
                }
                Button("Rename room") {
                    renameDraft = room?.name ?? ""
                    renaming = true
                }
                Menu(room?.floor.map { FloorGrouping.label(for: $0) } ?? "Floor") {
                    Button("No floor") { setFloor(nil) }
                    ForEach(FloorGrouping.selectable, id: \.self) { level in
                        Button(FloorGrouping.label(for: level)) { setFloor(level) }
                    }
                }
                Button("Home Assistant settings") { showSettings = true }
                Button("Send to Home Assistant") { sendToHomeAssistant() }
                    .disabled(sending)
                Button("Share a .zip") { shareZip() }
                Button("Floor plan PDF") { sharePDF() }
                Button("Open in Home Assistant") { openCompanion() }
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

    private func proposeAutoPlace() {
        guard let home else { return }
        guard assistant.isConfigured, let client = assistant.makeClient() else {
            errorMessage = "Add the Home Assistant URL and a long-lived token in Settings, then place devices again."
            showSettings = true
            return
        }
        Task {
            do {
                let pins = try await DeviceAutoPlace.propose(home: home, roomID: roomID, client: client)
                if pins.isEmpty {
                    errorMessage = "No unmatched devices lined up with this room. An area, a friendly name, or the entity id needs to match the room name. Pins you already linked stay put."
                } else {
                    pendingPlacements = pins
                    confirmAutoPlace = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commitAutoPlace() {
        let pins = pendingPlacements
        pendingPlacements = []
        mutate { home in
            for pin in pins {
                home.upsertPin(pin)
            }
        }
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

    private func placeFurniture(x: Double, z: Double, in roomId: UUID) {
        guard let catalogItemID else { return }
        let item = PlacedFurniture.placed(catalogId: catalogItemID, x: x, z: z)
        mutate { _ = $0.upsertFurniture(item, in: roomId) }
        selectedFurnitureID = item.id
        placingFurniture = false
    }

    private func moveFurniture(_ id: UUID, x: Double, z: Double) {
        mutate { $0.moveFurniture(id: id, x: x, z: z) }
    }

    private func setFlooring(_ material: FlooringMaterial?) {
        mutate { $0.setFlooring(material, roomID: roomID) }
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

    private func setFloor(_ level: Int?) {
        mutate { home in
            guard let index = home.rooms.firstIndex(where: { $0.id == roomID }) else { return }
            home.rooms[index].floor = level
        }
    }

    private func saveViewpoint(_ viewpoint: CameraViewpoint) {
        mutate { home in
            guard let index = home.rooms.firstIndex(where: { $0.id == roomID }) else { return }
            home.rooms[index].viewpoint = viewpoint
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

    private func sendToHomeAssistant() {
        guard let home else { return }
        guard assistant.isConfigured, let client = assistant.makeClient() else {
            errorMessage = "Add the Home Assistant URL and a long-lived token in Settings, then send the floor again."
            showSettings = true
            return
        }
        sending = true
        Task {
            defer { sending = false }
            do {
                let receipts = try await HomeExportActions.send(home, store: store, client: client)
                uploadedMessage = "Uploaded \(receipts.count) folders. The card reads layout.json and model.glb under /local/home_scanner/."
                showUploaded = true
            } catch let error as HomeAssistantClientError {
                if case .httpStatus(404, _) = error {
                    errorMessage = "Home Assistant did not find /api/home_scanner/upload. Install the home_scanner integration, or share a zip and copy it into config/www."
                } else {
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func heatSamples(in room: Room) -> [HeatSample] {
        pins.compactMap { pin in
            guard let state = pinBoard.snapshot(for: pin)?.state, let value = Double(state) else { return nil }
            return HeatSample(x: pin.position.x, z: pin.position.z, value: value)
        }
    }

    private func compareSheet(_ otherID: UUID) -> some View {
        let current = room
        let other = home?.room(id: otherID)
        let diff = ScanDiff.compare(
            previous: other?.floorPlan ?? .empty,
            current: current?.floorPlan ?? .empty
        )
        let counts = ScanDiff.counts(diff)
        return NavigationStack {
            VStack(spacing: 0) {
                if let current {
                    FloorPlanCanvas(
                        layers: PlanLayers.single(current),
                        pins: [],
                        showPins: false,
                        selectedPinID: nil,
                        placing: false,
                        changes: diff,
                        onCharcoal: true
                    )
                }
                List {
                    Picker("Compare with", selection: $compareRoomID) {
                        ForEach(home?.rooms.filter { $0.id != roomID } ?? []) { otherRoom in
                            Text(otherRoom.name).tag(Optional(otherRoom.id))
                        }
                    }
                    Text("\(counts.added) added · \(counts.removed) removed · \(counts.moved) moved. Green is new, amber moved, dashed red removed.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                    ForEach(diff.filter { change in
                        if case .unchanged = change.kind { return false }
                        return true
                    }) { change in
                        Text(change.summary)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.paper)
            }
            .paperChrome()
            .navigationTitle("Scan diff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { compareRoomID = nil }
                }
            }
        }
    }

    private func measurementLine(_ room: Room) -> some View {
        let summary = MeasurementMath.summarize(room.floorPlan)
        let doors = summary.doorWidths.map { "\(MeasurementMath.meters($0)) m" }.joined(separator: ", ")
        let doorText = doors.isEmpty ? "no doors" : "doors \(doors)"
        return Text("\(MeasurementMath.squareMeters(summary.floorArea)) · walls \(MeasurementMath.meters(summary.wallLength)) m · \(doorText)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.mist)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private func sharePDF() {
        guard let home else { return }
        do {
            SharePresenter.present(url: try FloorPlanPDF.fileURL(for: home))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shareZip() {
        guard let home else { return }
        do {
            SharePresenter.present(url: try HomeExportActions.zipURL(for: home, store: store))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openCompanion() {
        guard let url = HomeAssistantLinks.companionDashboard else { return }
        SharePresenter.open(url) { accepted in
            guard !accepted else { return }
            Task { @MainActor in
                self.errorMessage = "The Home Assistant app did not open. Install the companion app, then try Open in Home Assistant again."
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

    private func snapPlans(except roomID: UUID) -> [FloorPlan] {
        guard let home, home.coordinatesAreUnified else { return [] }
        return home.rooms.filter { $0.id != roomID }.map(\.floorPlan)
    }

    private func commitPlan(roomID: UUID, plan: FloorPlan) {
        guard let home, let edited = planEditor.commit(roomID: roomID, plan: plan, in: home) else { return }
        applyPlanEdit(edited)
    }

    private func splitRoom() {
        guard let home, let edited = planEditor.split(home) else { return }
        applyPlanEdit(edited)
    }

    private func copyOpening() {
        guard let home, let edited = planEditor.copyOpening(in: home) else { return }
        applyPlanEdit(edited)
    }

    private func undoPlan() {
        guard let home, let edited = planEditor.undo(home) else { return }
        applyPlanEdit(edited)
    }

    private func redoPlan() {
        guard let home, let edited = planEditor.redo(home) else { return }
        applyPlanEdit(edited)
    }

    private func applyPlanEdit(_ edited: Home) {
        mutate { home in
            home.rooms = edited.rooms
            home.pins = edited.pins
        }
    }

    private func mutate(_ body: (inout Home) -> Void) {
        do {
            try store.update(homeId: homeID, body)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
