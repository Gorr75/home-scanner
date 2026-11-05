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
    @AppStorage(DaylightPreference.enabledKey) private var daylightEnabled = true

    private var home: Home? { store.home(id: homeID) }

    var body: some View {
        CharcoalScreen {
            if let home {
                VStack(spacing: 0) {
                    viewer(home)
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
            if home?.coordinatesAreUnified == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Device type", selection: $placeKind) {
                            ForEach(DeviceKind.allCases, id: \.self) { kind in
                                Label(kind.label, systemImage: kind.symbolName).tag(kind)
                            }
                        }
                        Button(placing ? "Stop placing" : "Place a device") { placing.toggle() }
                        if showsPlan {
                            Button(showHeat ? "Hide sensor heatmap" : "Show sensor heatmap") {
                                showHeat.toggle()
                            }
                        }
                        Button("Reset camera") { cameraToken += 1 }
                            .disabled(showsPlan)
                    } label: {
                        Image(systemName: placing ? "mappin.circle.fill" : "plus")
                    }
                    .accessibilityLabel("Place a device")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let home {
                Text(caption(home))
                    .font(.footnote)
                    .foregroundStyle(Theme.mist)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.charcoal)
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
                onSelectPin: { selectedPinID = $0 },
                onMovePin: { id, x, z in move(id, x: x, z: z) },
                onCreate: { x, z in create(in: home, x: x, z: z, y: placeKind.defaultHeight) }
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
                    usdzURL: store.structureModelURL(in: home),
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
                    daylight: tint
                )
                .overlay(alignment: .top) {
                    if let tint {
                        DaylightScrubber(previewHour: $previewHour, now: timeline.date, tint: tint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    private func layers(_ home: Home) -> [PlanLayer] {
        if let overview = home.structure?.overviewFloorPlan, !home.coordinatesAreUnified {
            return PlanLayers.overview(overview, name: home.name)
        }
        return PlanLayers.rooms(home.rooms, unified: home.coordinatesAreUnified)
    }

    private func showsPins(_ home: Home) -> Bool {
        home.coordinatesAreUnified
    }

    private func caption(_ home: Home) -> String {
        if let _ = home.structure?.overviewFloorPlan, !home.coordinatesAreUnified {
            return "Aligned shell from RoomPlan. Pins stay in each room because the align step does not move them yet."
        }
        if !home.coordinatesAreUnified && home.rooms.count > 1 {
            return "Rooms are side by side because each scan has its own origin. Combine them after scanning through a shared door."
        }
        if showsPlan {
            if showHeat {
                return "Heatmap blends numeric sensor readings, such as temperature or signal level, across the pins."
            }
            return placing ? "Tap the plan to place a \(placeKind.label.lowercased()). Drag a dot to move it." : "Drag the plan to pan. Pinch to zoom. Drag a device to move it."
        }
        if renderedUSDZ {
            return "USDZ model. Tap a light, switch, or fan to toggle it. Drag to orbit, pinch to zoom."
        }
        return "Built from the floor plan. Tap a light to toggle it. Drag to orbit, pinch to zoom."
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

    private func create(in home: Home, x: Double, z: Double, y: Double) {
        guard let roomId = PlanLayers.roomID(containingX: x, z: z, in: home) else { return }
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
        if selectedPinID == id { selectedPinID = nil }
    }

    private func mutate(_ body: (inout Home) -> Void) {
        do {
            try store.update(homeId: homeID, body)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
