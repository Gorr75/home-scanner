import SwiftUI
import RoomScanCore

struct ScanRoomView: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = ScanSessionController()

    let launch: ScanLaunch
    var onSaved: () -> Void

    @State private var names: [UUID: String] = [:]
    @State private var saving = false
    @State private var saveError: String?
    @State private var pendingReplace: PendingReplace?
    @State private var nudge: NudgeRequest?

    private var roomCount: Int {
        store.home(id: launch.homeID)?.rooms.count ?? 0
    }

    var body: some View {
        Group {
            if session.phase == .finished {
                nameForm
            } else {
                captureScreen
            }
        }
        .tint(Theme.accent)
        .interactiveDismissDisabled(saving || session.phaseIsProcessing)
        .task {
            session.start(
                launch: launch,
                checkpoints: store.checkpoints,
                homeMap: store.worldMapData(homeId: launch.homeID)
            )
            store.activeCheckpointID = session.checkpointID
        }
        .onDisappear {
            if store.activeCheckpointID == session.checkpointID {
                store.activeCheckpointID = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            session.sceneMovedToBackground(phase != .active)
        }
        .task(id: session.phase) {
            guard session.phase == .relocalizing else { return }
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            session.noteRelocalizationIsSlow()
        }
        .task(id: session.autoTexture) {
            guard session.autoTexture else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                session.captureFrame(manual: false)
            }
        }
        .sheet(item: $nudge, onDismiss: finishAfterNudge) { request in
            RoomNudgeSheet(homeID: request.homeID, roomIDs: request.roomIDs, sharesSpace: request.sharesSpace)
        }
    }

    private var captureScreen: some View {
        ZStack {
            if session.camera == .relocalizing || session.holdPreview {
                RelocalizationRepresentable(controller: session)
                    .opacity(session.camera == .relocalizing ? 1 : 0)
                    .allowsHitTesting(session.camera == .relocalizing)
            }
            if session.camera == .capturing {
                RoomCaptureRepresentable(controller: session)
                    .id(session.generation)
            }
            if session.camera == .none && session.phase == .preparing {
                ProgressView("Starting the scan")
                    .tint(.white)
            }
            VStack(spacing: 12) {
                statusBanners
                Spacer()
                if session.phaseIsProcessing {
                    processingCard
                }
                controls
                if session.phase == .scanning {
                    Toggle("Save wall photos while scanning", isOn: $session.autoTexture)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .tint(Theme.accentOnCharcoal)
                }
                if let note = session.captureNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)
                }
            }
            if case .failed(let message) = session.phase {
                failure(message)
            }
        }
        .background(Color.black)
    }

    private var statusBanners: some View {
        VStack(spacing: 8) {
            if session.phase == .relocalizing {
                VStack(spacing: 6) {
                    Text("Find the room")
                        .font(.headline)
                    Text(session.trackingGuidance)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
            } else if session.phase == .scanning {
                Text(session.mode == .wholeFloor ? "\(session.instruction) Room \(session.finishedSectionCount + 1)." : session.instruction)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if let guardMessage = session.guardMessage {
                Text(guardMessage)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.warn.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 12)
    }

    private var processingCard: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(session.phase == .betweenRooms ? "Saving this room" : "Building the room model")
                .font(.headline)
            Text(session.phase == .betweenRooms
                 ? "The camera stays running. The next room starts in the same place."
                 : "RoomPlan is turning the scan into walls and openings.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 24)
    }

    private var controls: some View {
        HStack {
            Button(session.preservesCheckpointOnCancel ? "Close" : (session.phaseIsProcessing ? "Discard" : "Cancel"), role: .cancel) {
                session.cancel(discard: !session.preservesCheckpointOnCancel)
                dismiss()
            }
            .buttonStyle(.bordered)
            Spacer()
            if session.phase == .relocalizing {
                Button("Scan and align later") { session.skipRelocalization() }
                    .buttonStyle(.borderedProminent)
            } else if session.phase == .scanning {
                Button("Capture frame") { session.captureFrame(manual: true) }
                    .buttonStyle(.bordered)
                if session.showsNextRoom {
                    Button("Next room") { session.nextRoom() }
                        .buttonStyle(.bordered)
                }
                Button("Done") { session.finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text("The scan didn't finish")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Close") {
                let keep = session.savedSections.contains { !$0.capturedRoom.isEmpty }
                session.cancel(discard: !keep)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(24)
    }

    private var nameForm: some View {
        NavigationStack {
            PaperScreen {
                Form {
                    Section {
                        if session.savedSections.count <= 1 {
                            TextField("Room name", text: nameBinding(session.savedSections.first?.id))
                            suggestionRow
                        } else {
                            ForEach(session.savedSections) { section in
                                TextField(section.name, text: nameBinding(section.id))
                            }
                        }
                    } header: {
                        Text(session.savedSections.count > 1 ? "Name these rooms" : "Name this room")
                    } footer: {
                        Text(footer)
                    }
                    if saving {
                        Section {
                            HStack {
                                ProgressView()
                                Text("Saving the scan")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .paperChrome()
            .navigationTitle("Save room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") {
                        session.cancel(discard: true)
                        dismiss()
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || !namesAreFilled)
                }
            }
            .alert("Couldn't save the room", isPresented: saveAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .sheet(item: $pendingReplace) { pending in
                replaceSheet(pending)
            }
            .onAppear {
                if names.isEmpty {
                    for (index, section) in session.savedSections.enumerated() {
                        names[section.id] = section.name == "Room \(index + 1)" && session.savedSections.count == 1
                            ? "Room \(roomCount + 1)"
                            : section.name
                    }
                }
            }
        }
    }

    private var footer: String {
        if session.relocalized {
            return "This scan locked onto the saved map, so the new room keeps that place."
        }
        if session.relocalizationFailed {
            return "The saved map did not lock. You can line the room up with the doorway after saving."
        }
        if session.frames.isEmpty {
            return "The model stays on this iPhone, with the floor plan and a USDZ file."
        }
        return "\(session.frames.count) camera frames will be matched to walls when you save."
    }

    private var namesAreFilled: Bool {
        let sections = session.savedSections
        guard !sections.isEmpty else { return false }
        return sections.allSatisfy { name in
            !(names[name.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func nameBinding(_ id: UUID?) -> Binding<String> {
        Binding(
            get: { id.flatMap { names[$0] } ?? "" },
            set: { if let id { names[id] = $0 } }
        )
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        if let id = session.savedSections.first?.id {
                            names[id] = suggestion
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var saveAlert: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private func save() {
        saving = true
        session.applyNames(names)
        Task {
            do {
                let pieces = try session.makePieces()
                if let replacingRoomID = launch.replacingRoomID, let piece = pieces.last {
                    let previous = store.home(id: launch.homeID)?.room(id: replacingRoomID)?.floorPlan
                    if let previous {
                        pendingReplace = PendingReplace(
                            plan: piece.plan,
                            json: piece.json,
                            usdz: piece.usdz,
                            diff: ScanDiff.compare(previous: previous, current: piece.plan),
                            frames: session.frames
                        )
                        saving = false
                        return
                    }
                }
                let map = await session.latestWorldMap()
                let result = try await ScanCommit.save(
                    pieces: pieces,
                    homeID: launch.homeID,
                    replacingRoomID: launch.replacingRoomID,
                    worldMap: map,
                    frames: session.frames,
                    store: store
                )
                session.markSaved()
                saving = false
                if result.needsNudge {
                    nudge = NudgeRequest(
                        homeID: launch.homeID,
                        roomIDs: result.roomIDs,
                        sharesSpace: result.sharesSpace
                    )
                } else {
                    onSaved()
                    dismiss()
                }
            } catch {
                saveError = error.localizedDescription
                saving = false
            }
        }
    }

    private func finishAfterNudge() {
        guard nudge == nil else { return }
        onSaved()
        dismiss()
    }

    private func replaceSheet(_ pending: PendingReplace) -> some View {
        let counts = ScanDiff.counts(pending.diff)
        return NavigationStack {
            VStack(spacing: 0) {
                FloorPlanCanvas(
                    layers: [PlanLayer(
                        id: launch.replacingRoomID ?? UUID(),
                        name: names[session.savedSections.last?.id ?? UUID()] ?? "Room",
                        plan: pending.plan,
                        offset: .zero,
                        tintIndex: 0
                    )],
                    pins: [],
                    showPins: false,
                    selectedPinID: nil,
                    placing: false,
                    changes: pending.diff,
                    onCharcoal: true
                )
                List {
                    Section {
                        Text("\(counts.added) added · \(counts.removed) removed · \(counts.moved) moved")
                    }
                    ForEach(pending.diff.filter { change in
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
            .navigationTitle("What changed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { pendingReplace = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace room") { commitReplace(pending) }
                        .disabled(saving)
                }
            }
        }
    }

    private func commitReplace(_ pending: PendingReplace) {
        guard launch.replacingRoomID != nil else { return }
        saving = true
        Task {
            do {
                let map = await session.latestWorldMap()
                let pieces = try session.makePieces()
                _ = try await ScanCommit.save(
                    pieces: pieces,
                    homeID: launch.homeID,
                    replacingRoomID: launch.replacingRoomID,
                    worldMap: map,
                    frames: pending.frames,
                    store: store
                )
                session.markSaved()
                pendingReplace = nil
                onSaved()
                dismiss()
            } catch {
                saveError = error.localizedDescription
                saving = false
            }
        }
    }

    private static let suggestions = [
        "Kitchen", "Living room", "Bedroom", "Bathroom", "Hallway", "Office", "Dining room", "Entry"
    ]
}

private struct PendingReplace: Identifiable {
    let id = UUID()
    var plan: FloorPlan
    var json: Data
    var usdz: Data?
    var diff: [ObjectChange]
    var frames: [ScanHeldFrame]
}

struct NudgeRequest: Identifiable {
    let id = UUID()
    var homeID: UUID
    var roomIDs: [UUID]
    var sharesSpace: Bool
}
