import RoomPlan
import SwiftUI
import RoomScanCore

struct ScanRoomView: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = ScanSessionController()

    let homeID: UUID
    var onSaved: () -> Void

    @State private var roomName = ""
    @State private var saving = false
    @State private var saveError: String?

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
                        Button("Done") { session.finish() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
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
                        Text("The model stays on this iPhone, with the floor plan and a USDZ file.")
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
                _ = try store.addCapturedRoom(
                    homeId: homeID,
                    name: name,
                    floorPlan: plan,
                    capturedJSON: json,
                    usdz: usdz
                )
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
