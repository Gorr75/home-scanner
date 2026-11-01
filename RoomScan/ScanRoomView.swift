import ARKit
import RoomPlan
import SwiftUI
import RoomScanCore

struct ScanRoomView: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = ScanSessionController()

    let homeID: UUID
    var replacingRoomID: UUID? = nil
    var onSaved: () -> Void

    @State private var roomName = ""
    @State private var saving = false
    @State private var saveError: String?
    @State private var pendingReplace: PendingReplace?

    private var roomCount: Int {
        store.home(id: homeID)?.rooms.count ?? 0
    }

    var body: some View {
        Group {
            if case .finished(let room) = session.phase {
                nameForm(for: room)
            } else {
                captureScreen
            }
        }
        .tint(Theme.accent)
        .interactiveDismissDisabled(saving || session.phaseIsProcessing)
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
    }

    private var captureScreen: some View {
        ZStack {
            RoomCaptureRepresentable(controller: session)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text(session.instruction)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                Spacer()
                if session.phaseIsProcessing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Building the room model")
                            .font(.headline)
                        Text("RoomPlan is turning the scan into walls and openings.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 24)
                }
                HStack {
                    Button(session.phaseIsProcessing ? "Discard" : "Cancel", role: .cancel) {
                        session.cancel()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if !session.phaseIsProcessing {
                        Button("Capture frame") { session.captureFrame(manual: true) }
                            .buttonStyle(.bordered)
                        Button("Done") { session.finish() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                if !session.phaseIsProcessing {
                    Toggle("Save wall photos while scanning", isOn: $session.autoTexture)
                        .font(.footnote)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .tint(Theme.accent)
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

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text("The scan didn't finish")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Close") {
                session.cancel()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(24)
    }

    private func nameForm(for room: CapturedRoom) -> some View {
        NavigationStack {
            PaperScreen {
                Form {
                    Section {
                        TextField("Room name", text: $roomName)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Self.suggestions, id: \.self) { suggestion in
                                    Button(suggestion) { roomName = suggestion }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    } header: {
                        Text("Name this room")
                    } footer: {
                        Text(session.frames.isEmpty
                        ? "The model stays on this iPhone, with the floor plan and a USDZ file."
                        : "\(session.frames.count) camera frames will be matched to walls when you save.")
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
            .navigationTitle("Save room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(room) }
                        .disabled(saving || roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        }
        .onAppear {
            if roomName.isEmpty {
                roomName = "Room \(roomCount + 1)"
            }
        }
    }

    private var saveAlert: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private func save(_ room: CapturedRoom) {
        saving = true
        let name = roomName
        Task {
            do {
                let plan = FloorPlanExtractor.floorPlan(from: room)
                let json = try ScanArchive.encodeRoom(room)
                let usdz = try ScanArchive.usdzData(for: room)
                if let replacingRoomID,
                   let previous = store.home(id: homeID)?.room(id: replacingRoomID)?.floorPlan {
                    pendingReplace = PendingReplace(
                        plan: plan,
                        json: json,
                        usdz: usdz,
                        diff: ScanDiff.compare(previous: previous, current: plan),
                        frames: session.frames
                    )
                    saving = false
                    return
                }
                _ = try store.addCapturedRoom(
                    homeId: homeID,
                    name: name,
                    floorPlan: plan,
                    capturedJSON: json,
                    usdz: usdz
                )
                try store.installScanFrames(
                    session.frames.map { (id: $0.id, jpeg: $0.jpeg, pose: $0.pose) },
                    plan: plan,
                    homeId: homeID
                )
                onSaved()
                dismiss()
            } catch {
                saveError = error.localizedDescription
                saving = false
            }
        }
    }

    private func replaceSheet(_ pending: PendingReplace) -> some View {
        let counts = ScanDiff.counts(pending.diff)
        return NavigationStack {
            VStack(spacing: 0) {
                FloorPlanCanvas(
                    layers: [PlanLayer(id: replacingRoomID ?? UUID(), name: roomName, plan: pending.plan, offset: .zero, tintIndex: 0)],
                    pins: [],
                    showPins: false,
                    selectedPinID: nil,
                    placing: false,
                    changes: pending.diff
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
            }
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
        guard let replacingRoomID else { return }
        saving = true
        do {
            _ = try store.replaceCapturedRoom(
                homeId: homeID,
                roomId: replacingRoomID,
                floorPlan: pending.plan,
                capturedJSON: pending.json,
                usdz: pending.usdz
            )
            try store.installScanFrames(
                pending.frames.map { (id: $0.id, jpeg: $0.jpeg, pose: $0.pose) },
                plan: pending.plan,
                homeId: homeID
            )
            pendingReplace = nil
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
            saving = false
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
    var usdz: Data
    var diff: [ObjectChange]
    var frames: [ScanHeldFrame]
}

private struct RoomCaptureRepresentable: UIViewRepresentable {
    let controller: ScanSessionController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

final class ScanSessionController: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    enum Phase {
        case scanning
        case processing
        case finished(CapturedRoom)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .scanning
    @Published private(set) var instruction = "Walk slowly and point the camera along the walls."
    @Published private(set) var frames: [ScanHeldFrame] = []
    @Published var autoTexture = true
    @Published var captureNote: String?

    private weak var captureView: RoomCaptureView?
    private var cancelled = false
    private var didStop = false

    var phaseIsProcessing: Bool {
        if case .processing = phase { return true }
        return false
    }

    func attach(_ view: RoomCaptureView) {
        guard captureView == nil else { return }
        captureView = view
        view.delegate = self
        view.captureSession.delegate = self
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func finish() {
        guard case .scanning = phase else { return }
        phase = .processing
        stopSession()
    }

    func cancel() {
        cancelled = true
        stopSession()
    }

    func captureFrame(manual: Bool) {
        guard !didStop, let frame = captureView?.captureSession.arSession.currentFrame else {
            if manual {
                publish { self.captureNote = "The camera frame was not ready. Keep the phone moving and try again." }
            }
            return
        }
        guard let jpeg = ScanFrameImage.jpeg(from: frame.capturedImage) else {
            if manual {
                publish { self.captureNote = "That frame could not be saved." }
            }
            return
        }
        let held = ScanHeldFrame(id: UUID(), jpeg: jpeg, pose: ScanFrameImage.pose(from: frame), manual: manual)
        publish {
            if manual {
                self.frames.append(held)
                self.captureNote = "Saved a frame. It is matched to a wall when you save the room."
            } else {
                let automatic = self.frames.filter { !$0.manual }
                if automatic.count >= 8, let index = self.frames.firstIndex(where: { !$0.manual }) {
                    self.frames.remove(at: index)
                }
                self.frames.append(held)
            }
        }
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let message = error?.localizedDescription {
            publish { self.phase = .failed(message) }
            return false
        }
        publish { self.phase = .processing }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        let message = error?.localizedDescription
        publish {
            guard !self.cancelled else { return }
            if let message {
                self.phase = .failed(message)
            } else {
                self.phase = .finished(processedResult)
            }
        }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text = Self.text(for: instruction)
        publish { self.instruction = text }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        guard let message = error?.localizedDescription else { return }
        publish {
            guard !self.cancelled else { return }
            if case .finished = self.phase { return }
            self.phase = .failed(message)
        }
    }

    private func stopSession() {
        guard !didStop else { return }
        didStop = true
        captureView?.captureSession.stop()
    }

    private func publish(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    private static func text(for instruction: RoomCaptureSession.Instruction) -> String {
        switch instruction {
        case .moveCloseToWall:
            return "Move closer to a wall."
        case .moveAwayFromWall:
            return "Step back from the wall."
        case .slowDown:
            return "Slow down."
        case .turnOnLight:
            return "Turn on a light so the walls are easier to see."
        case .normal:
            return "Keep going. Trace the edges of the room."
        case .lowTexture:
            return "Point at a surface with more detail."
        @unknown default:
            return "Keep scanning."
        }
    }
}
