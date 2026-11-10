import SwiftUI
import RoomScanCore

struct HomeViewer: View {
    @Environment(HomeStore.self) private var store
    @Environment(PinBoard.self) private var pinBoard

    let homeID: UUID
    var showsPlan: Bool

    @State private var selectedPinID: UUID?
    @State private var placing = false
    @State private var placeKind: DeviceKind = .light
    @State private var editor: DevicePin?
    @State private var renderedUSDZ = false
    @State private var cameraToken = 0
    @State private var errorMessage: String?
    @State private var showHeat = false
    @State private var previewHour: Double?
    @State private var planEditor = PlanEditorSession()
    @State private var selectedFloor: Int?
    @State private var didPickFloor = false
    @State private var dollhouse = false
    @State private var placingFurniture = false
    @State private var catalogItemID: String?
    @State private var showCatalog = false
    @State private var selectedFurnitureID: UUID?
    @State private var captureToken = 0
    @State private var captureRoomID: UUID?
    @AppStorage(DaylightPreference.enabledKey) private var daylightEnabled = true

    private var home: Home? { store.home(id: homeID) }

    var body: some View {
        CharcoalScreen {
            if let home {
                VStack(spacing: 0) {
                    if FloorGrouping.groups(in: home.rooms).count > 1 {
                        FloorTabBar(
                            groups: FloorGrouping.groups(in: home.rooms),
                            selection: activeGroup(home)?.level,
                            choosesUnassigned: activeGroup(home)?.level == nil,
                            onSelect: { picked in
                                selectedFloor = picked
                                didPickFloor = true
                                dollhouse = false
                            }
                        )
                    }
                    viewer(home)
                    if let selectedFurnitureID, let furniture = home.furnitureItem(id: selectedFurnitureID)?.item {
                        FurnitureAdjustBar(
                            title: FurnitureCatalog.item(id: furniture.catalogId)?.name ?? "Furniture",
                            onCharcoal: true,
                            onRotate: { delta in mutate { $0.rotateFurniture(id: furniture.id, by: delta) } },
                            onScale: { factor in mutate { $0.scaleFurniture(id: furniture.id, by: factor) } },
                            onDelete: {
                                mutate { $0.removeFurniture(id: furniture.id) }
                                selectedFurnitureID = nil
                            }
                        )
                    }
                    if showsPins(home), let pin = home.pins.first(where: { $0.id == selectedPinID }) {
                        selectionBar(pin)
                    }
                }
            } else {
                ContentUnavailableView("Home missing", systemImage: "house", description: Text("It may have been deleted."))
            }
        }
        .navigationTitle(showsPlan ? "Floor plan" : "3D model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let home {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if PlanLayers.showsDevicePins(home) {
                            Picker("Device type", selection: $placeKind) {
                                ForEach(DeviceKind.allCases, id: \.self) { kind in
                                    Label(kind.label, systemImage: kind.symbolName).tag(kind)
                                }
                            }
                            Button(placing ? "Stop placing" : "Place a device") {
                                placing.toggle()
                                if placing { placingFurniture = false }
                            }
                        }
                        Button(placingFurniture ? "Stop placing furniture" : "Add furniture") {
                            if placingFurniture {
                                placingFurniture = false
                            } else {
                                showCatalog = true
                            }
                        }
                        if !showsPlan {
                            Button(dollhouse ? "Show this floor" : "Dollhouse") {
                                dollhouse.toggle()
                            }
                        }
                        if !home.rooms.isEmpty {
                            Button("New floor from the one below") { addCopiedFloor() }
                            Button("New floor as one room") { addFootprintFloor() }
                        }
                        if showsPlan, PlanLayers.showsDevicePins(home) {
                            Button(showHeat ? "Hide sensor heatmap" : "Show sensor heatmap") {
                                showHeat.toggle()
                            }
                        }
                        Button("Reset camera") { cameraToken += 1 }
                            .disabled(showsPlan)
                    } label: {
                        Image(systemName: placing || placingFurniture ? "plus.circle.fill" : "plus")
                    }
                    .accessibilityLabel("Place or add a floor")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let home {
                VStack(spacing: 0) {
                    if showsPlan {
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
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        overlapChoices(home)
                        Text(caption(home))
                            .font(.footnote)
                            .foregroundStyle(Theme.mist)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.charcoal)
                }
            }
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
        .alert("Couldn't update the home", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showCatalog) {
            FurnitureCatalogSheet(suggestedID: nil) { item in
                catalogItemID = item.id
                placingFurniture = true
                placing = false
            }
        }
        .charcoalChrome()
    }

    @ViewBuilder
    private func viewer(_ home: Home) -> some View {
        if showsPlan {
            FloorPlanCanvas(
                layers: layers(home),
                pins: home.pins,
                showPins: showsPins(home),
                selectedPinID: selectedPinID,
                placing: placing && showsPins(home),
                pinCaptions: pinBoard.captions(for: home.pins),
                pinLooks: pinBoard.looksByPin(for: home.pins),
                heatSamples: showHeat ? heatSamples(for: home) : [],
                onCharcoal: true,
                ghostLayers: ghostLayers(home),
                selectedFurnitureID: selectedFurnitureID,
                placingFurniture: placingFurniture,
                onSelectPin: { id in
                    selectedPinID = id
                    if id != nil { selectedFurnitureID = nil }
                },
                onMovePin: { id, x, z in move(id, x: x, z: z) },
                onCreate: { x, z in create(in: home, x: x, z: z, y: placeKind.defaultHeight) },
                planEditing: !placing && !placingFurniture,
                selectedRoomID: planEditor.selectedRoomID,
                selectedOpeningID: planEditor.selectedOpeningID,
                onSelectRoom: { id in
                    planEditor.selectedRoomID = id
                    if id != nil { selectedFurnitureID = nil }
                },
                onSelectOpening: { planEditor.selectedOpeningID = $0 },
                onCommitPlan: { commitPlan(roomID: $0, plan: $1) },
                onSelectFurniture: { id in
                    selectedFurnitureID = id
                    if id != nil {
                        selectedPinID = nil
                        planEditor.selectedRoomID = nil
                        planEditor.selectedOpeningID = nil
                    }
                },
                onMoveFurniture: { id, x, z in
                    mutate { $0.moveFurniture(id: id, x: x, z: z) }
                },
                onCreateFurniture: { x, z in
                    placeFurniture(x: x, y: 0, z: z, in: home)
                }
            )
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let tint = DaylightScene.tint(
                    enabled: daylightEnabled,
                    previewHour: previewHour,
                    sun: pinBoard.sun,
                    now: timeline.date
                )
                RoomModelView(
                    layers: layers(home),
                    usdzURL: shellURL(home),
                    pins: home.pins,
                    showPins: showsPins(home),
                    looksByEntity: pinBoard.looksByEntity(for: home.pins),
                    captionByPin: pinBoard.captions(for: home.pins),
                    selectedPinID: selectedPinID,
                    placementEnabled: placing && showsPins(home),
                    cameraToken: cameraToken,
                    onSelectPin: { selectedPinID = $0 },
                    onTogglePin: { togglePin($0, in: home) },
                    onPlace: { point in
                        let height = point.y < 0.25 ? placeKind.defaultHeight : point.y
                        create(in: home, x: point.x, z: point.z, y: height)
                    },
                    onRenderedUSDZ: { renderedUSDZ = $0 },
                    surfacePaints: TexturePaints.forHome(home, store: store),
                    daylight: tint,
                    dollhouse: dollhouse,
                    selectedFurnitureID: selectedFurnitureID,
                    placingFurniture: placingFurniture,
                    onSelectFurniture: { id in
                        selectedFurnitureID = id
                        if id != nil { selectedPinID = nil }
                    },
                    onMoveFurniture: { id, point in
                        let layer = layers(home).first { $0.furniture.contains { $0.id == id } }
                        let stored = layer.map {
                            PlanLayers.storedPoint(Vec3(x: point.x, y: 0, z: point.z), in: $0)
                        } ?? Vec3(x: point.x, y: 0, z: point.z)
                        mutate { $0.moveFurniture(id: id, x: stored.x, z: stored.z) }
                    },
                    onPlaceFurniture: { point in
                        placeFurniture(x: point.x, y: point.y, z: point.z, in: home)
                    },
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
                .overlay(alignment: .bottomTrailing) {
                    saveViewpointControl(home)
                }
            }
        }
    }

    private func activeGroup(_ home: Home) -> FloorGroup? {
        let groups = FloorGrouping.groups(in: home.rooms)
        if didPickFloor, let match = groups.first(where: { $0.level == selectedFloor }) {
            return match
        }
        return groups.first
    }

    private func editingRooms(_ home: Home) -> [Room] {
        if dollhouse && !showsPlan {
            let numbered = home.rooms.filter { $0.floor != nil }
            return numbered.isEmpty ? home.rooms : numbered
        }
        guard FloorGrouping.groups(in: home.rooms).count > 1 else { return home.rooms }
        return activeGroup(home)?.rooms ?? home.rooms
    }

    private func layers(_ home: Home) -> [PlanLayer] {
        let rooms = editingRooms(home)
        let hidden = Set(RoomAlignment.applied(to: home).suppressedRoomIds)
        let visible = rooms.filter { !hidden.contains($0.id) }
        if showsPlan {
            // The plan editor writes scan-space walls. The align move is applied with the furniture and camera.
            return PlanLayers.rooms(visible, unified: home.coordinatesAreUnified)
        }
        let applied = RoomAlignment.applied(to: home)
        if applied.changesDisplay {
            return PlanLayers.aligned(visible, applied: applied, stacked: dollhouse)
        }
        if dollhouse {
            return PlanLayers.rooms(rooms, unified: home.coordinatesAreUnified, stacked: true)
        }
        if FloorStack.hasStackedFloors(home) || home.rooms.contains(where: { !$0.placedFurniture.isEmpty || $0.flooring != nil }) {
            return PlanLayers.rooms(rooms, unified: home.coordinatesAreUnified)
        }
        if let overview = home.structure?.overviewFloorPlan, !home.coordinatesAreUnified {
            return PlanLayers.overview(overview, name: home.name)
        }
        return PlanLayers.rooms(rooms, unified: home.coordinatesAreUnified)
    }

    private func ghostLayers(_ home: Home) -> [PlanLayer] {
        guard showsPlan, let level = activeGroup(home)?.level else { return [] }
        let hidden = Set(RoomAlignment.applied(to: home).suppressedRoomIds)
        let rooms = home.rooms.filter { $0.floor == level - 1 && !hidden.contains($0.id) }
        guard !rooms.isEmpty else { return [] }
        return PlanLayers.ghost(rooms, unified: home.coordinatesAreUnified)
    }

    private func proceduralModel(_ home: Home) -> Bool {
        dollhouse || editingRooms(home).contains { $0.flooring != nil } || home.rooms.contains { !$0.placedFurniture.isEmpty }
    }

    private func showsPins(_ home: Home) -> Bool {
        if FloorStack.hasStackedFloors(home) || dollhouse { return true }
        return PlanLayers.showsDevicePins(home)
    }

    private func shellURL(_ home: Home) -> URL? {
        if proceduralModel(home) { return nil }
        let applied = RoomAlignment.applied(to: home)
        if applied.changesDisplay && applied.hidesMergedModel { return nil }
        return store.structureModelURL(in: home)
    }

    private func caption(_ home: Home) -> String {
        let applied = RoomAlignment.applied(to: home)
        if showsPlan {
            if showHeat {
                return "Heatmap blends numeric sensor readings, such as temperature or signal level, across the pins."
            }
            if placingFurniture {
                return "Tap the plan to place the furniture."
            }
            if placing {
                return "Tap the plan to place a \(placeKind.label.lowercased()). Drag a dot to move it."
            }
            if applied.changesDisplay && !applied.overlaps.isEmpty {
                return overlapCaption(applied, in: home)
            }
            if let group = activeGroup(home), FloorGrouping.groups(in: home.rooms).count > 1 {
                return "\(FloorGrouping.label(for: group.level)). Tap a room, then drag a handle. The floor below is a faint ghost when that storey exists."
            }
            if !home.coordinatesAreUnified && home.rooms.count > 1 {
                return "Rooms sit side by side while each scan has its own origin. Tap a room, then drag a handle to resize it."
            }
            return "Tap a room, then drag a handle to resize it. Drag a door or window along its wall."
        }
        if applied.changesDisplay {
            if !applied.overlaps.isEmpty {
                return overlapCaption(applied, in: home)
            }
            if applied.hidesMergedModel {
                return "Rooms were moved onto their shared walls. Pins, furniture, and the saved camera moved with each room."
            }
            return "Pins, furniture, and the saved camera moved with each room into the aligned floor."
        }
        if dollhouse {
            return "Dollhouse. Walls fade as you move closer. Drag a catalog item to move it."
        }
        if let _ = home.structure?.overviewFloorPlan, !home.coordinatesAreUnified {
            return "Aligned shell from RoomPlan. Pins stay in each room because the align step does not move them yet."
        }
        if !home.coordinatesAreUnified && home.rooms.count > 1 {
            return "Rooms are side by side because each scan has its own origin. Combine them after scanning through a shared door."
        }
        if renderedUSDZ {
            return "USDZ model. Tap a light, switch, or fan to toggle it. Drag to orbit, pinch to zoom."
        }
        return "Built from the floor plan. Tap a light to toggle it. Drag to orbit, pinch to zoom."
    }

    @ViewBuilder
    private func saveViewpointControl(_ home: Home) -> some View {
        if home.rooms.count == 1, let room = home.rooms.first {
            Button("Save viewpoint") {
                captureRoomID = room.id
                captureToken += 1
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.chalk)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.navy, in: Capsule())
            .padding(12)
        } else if !home.rooms.isEmpty {
            Menu("Save viewpoint") {
                ForEach(home.rooms) { room in
                    Button(room.name) {
                        captureRoomID = room.id
                        captureToken += 1
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.chalk)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.navy, in: Capsule())
            .padding(12)
        }
    }

    private func saveViewpoint(_ viewpoint: CameraViewpoint) {
        guard let roomID = captureRoomID, let home else { return }
        let layer = layers(home).first { $0.id == roomID }
        let offset = layer?.offset ?? .zero
        let placement = layer?.placement ?? .identity
        let shifted = CameraViewpoint(
            position: viewpoint.position - offset,
            target: viewpoint.target - offset,
            fieldOfView: viewpoint.fieldOfView
        )
        let stored = shifted.transformed(by: placement.inverse())
        mutate { home in
            guard let index = home.rooms.firstIndex(where: { $0.id == roomID }) else { return }
            home.rooms[index].viewpoint = stored
        }
    }

    private func selectionBar(_ pin: DevicePin) -> some View {
        PinSelectionBar(
            pin: pin,
            snapshot: pinBoard.snapshot(for: pin),
            onCharcoal: true,
            onToggle: { Task { await pinBoard.toggle(pin) } },
            onBrightness: { level in Task { await pinBoard.setBrightness(level, pin: pin) } },
            onEdit: { editor = pin }
        )
    }

    private func togglePin(_ id: UUID, in home: Home) {
        guard let pin = home.pins.first(where: { $0.id == id }) else { return }
        guard pinBoard.snapshot(for: pin)?.isToggleable == true else { return }
        Task { await pinBoard.toggle(pin) }
    }

    private func heatSamples(for home: Home) -> [HeatSample] {
        let layers = layers(home)
        return home.pins.compactMap { pin in
            guard let state = pinBoard.snapshot(for: pin)?.state, let value = Double(state) else { return nil }
            let world = PlanLayers.displayPosition(of: pin, in: layers)
            return HeatSample(x: world.x, z: world.z, value: value)
        }
    }

    private func placeFurniture(x: Double, y: Double, z: Double, in home: Home) {
        guard let catalogItemID else { return }
        let current = layers(home)
        let matches = current.filter { layer in
            let box = FloorPlanGeometry.bounds(of: layer.plan)
            let localX = x - layer.offset.x
            let localZ = z - layer.offset.z
            return localX >= box.min.x - 0.4 && localX <= box.max.x + 0.4
                && localZ >= box.min.z - 0.4 && localZ <= box.max.z + 0.4
        }
        let match = matches.min { lhs, rhs in
            abs(lhs.offset.y - y) < abs(rhs.offset.y - y)
        } ?? current.first
        guard let match else { return }
        let stored = PlanLayers.storedPoint(Vec3(x: x, y: 0, z: z), in: match)
        let item = PlacedFurniture.placed(catalogId: catalogItemID, x: stored.x, z: stored.z)
        mutate { _ = $0.upsertFurniture(item, in: match.id) }
        selectedFurnitureID = item.id
        placingFurniture = false
    }

    private func addCopiedFloor() {
        mutate { home in
            let copies = home.addCopiedFloor()
            selectedFloor = copies.first?.floor
            didPickFloor = selectedFloor != nil
        }
    }

    private func addFootprintFloor() {
        mutate { home in
            if let room = home.addFootprintFloor() {
                selectedFloor = room.floor
                didPickFloor = true
            }
        }
    }

    private func overlapCaption(_ applied: RoomAlignmentResult, in home: Home) -> String {
        guard let overlap = applied.overlaps.first else {
            return "Two scans cover the same floor. Choose which one to keep. Pins moved with each room."
        }
        if overlap.roomIds.count == 2,
           let name = home.room(id: overlap.roomIds[0])?.name,
           home.room(id: overlap.roomIds[1])?.name == name {
            return "\(name) was scanned twice, so the later copy is hidden. Choose which scan to keep. Pins moved with each room."
        }
        return "Two scans cover the same floor. The extra copy is hidden. Choose which scan to keep. Pins moved with each room."
    }

    @ViewBuilder
    private func overlapChoices(_ home: Home) -> some View {
        let overlaps = RoomAlignment.applied(to: home).overlaps
        if !overlaps.isEmpty {
            ForEach(overlaps) { overlap in
                ForEach(overlap.choices(in: home)) { choice in
                    Button(choice.title) { keep(choice.id, in: overlap) }
                        .buttonStyle(.bordered)
                        .tint(Theme.accentOnCharcoal)
                }
            }
        }
    }

    private func keep(_ id: UUID, in overlap: RoomOverlap) {
        do {
            for roomId in overlap.roomIds where roomId != id {
                try store.deleteRoom(homeId: homeID, roomId: roomId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create(in home: Home, x: Double, z: Double, y: Double) {
        let drawn = layers(home)
        guard let roomId = PlanLayers.roomID(containingX: x, z: z, in: drawn) else { return }
        var pin = DevicePin.placed(in: roomId, kind: placeKind, x: x, z: z)
        pin.position.y = y
        let stored = PlanLayers.storedXZ(displayX: x, displayZ: z, of: pin, in: drawn)
        pin.position.x = stored.x
        pin.position.z = stored.z
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
        if selectedPinID == id { selectedPinID = nil }
    }

    private func commitPlan(roomID: UUID, plan: FloorPlan) {
        guard let home else { return }
        let placement = layers(home).first { $0.id == roomID }?.placement ?? .identity
        let stored = plan.transformed(by: placement.inverse())
        guard let edited = planEditor.commit(roomID: roomID, plan: stored, in: home) else { return }
        applyPlanEdit(edited)
    }

    private func splitRoom() {
        guard let home, let parentID = planEditor.selectedRoomID, let edited = planEditor.split(home) else { return }
        let previous = Set(home.rooms.map(\.id))
        let created = edited.rooms.map(\.id).filter { !previous.contains($0) }
        mutate { home in
            if let newID = created.first,
               var placements = home.structure?.placements,
               let parent = placements.first(where: { $0.roomId == parentID }) {
                placements.append(RoomPlacement(
                    roomId: newID,
                    yaw: parent.yaw,
                    translation: parent.translation,
                    snapped: parent.snapped
                ))
                home.structure?.placements = placements
                if home.structure?.roomIds.contains(newID) == false {
                    home.structure?.roomIds.append(newID)
                }
            }
            home.rooms = edited.rooms
            home.pins = edited.pins
        }
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
