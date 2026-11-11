import ARKit
import Foundation
import RoomPlan
import SwiftUI
import RoomScanCore

struct ScanLaunch: Identifiable, Equatable {
    enum Kind: Equatable {
        case room
        case wholeFloor
        case resume(UUID)
    }

    var id = UUID()
    var homeID: UUID
    var kind: Kind
    var floor: Int?
    var replacingRoomID: UUID?

    var preservesCheckpointOnCancel: Bool {
        if case .resume = kind { return true }
        return false
    }
}

enum ScanCamera {
    case none
    case relocalizing
    case capturing
}

/// Runs a RoomCaptureSession, writes a checkpoint while it is open, and can
/// keep one ARSession across rooms or relocalize into a saved ARWorldMap.
final class ScanSessionController: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate, ARSessionDelegate {
    enum Phase: Equatable {
        case preparing
        case relocalizing
        case scanning
        case betweenRooms
        case processing
        case finished
        case failed(String)
    }

    private enum StopIntent {
        case none
        case finishRoom
        case nextSection
        case finishFloor
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var instruction = "Walk slowly and point the camera along the walls."
    @Published private(set) var trackingGuidance = "Point at a wall or doorway you scanned before."
    @Published private(set) var guardMessage: String?
    @Published private(set) var frames: [ScanHeldFrame] = []
    @Published var autoTexture = true
    @Published var captureNote: String?
    @Published private(set) var generation = 0
    @Published private(set) var camera: ScanCamera = .none
    @Published private(set) var holdPreview = false
    @Published private(set) var relocalized = false
    @Published private(set) var relocalizationFailed = false
    @Published private(set) var finishedSectionCount = 0
    @Published private(set) var mode: ScanCheckpointMode = .singleRoom

    private(set) var checkpointID: UUID?
    private(set) var preservesCheckpointOnCancel = false
    private var checkpoint = ScanCheckpoint(
        id: UUID(),
        homeId: UUID(),
        mode: .singleRoom,
        phase: .scanning,
        startedAt: Date(),
        updatedAt: Date()
    )
    private var checkpoints: ScanCheckpointStore?
    private var floor: Int?
    private var spaceId = UUID()
    private var worldMap: ARWorldMap?
    private var pendingWorldMap: Data?
    private var arSession: ARSession?
    private var sharesCaptureSession = false
    private weak var captureView: RoomCaptureView?
    private var held: [UUID: CapturedRoom] = [:]
    private var latestRoom: CapturedRoom?
    private var activeSectionID: UUID?
    private var stopIntent: StopIntent = .none
    private var started = false
    private var cancelled = false
    private var didStop = false
    private var didWriteRoom = false
    private var attachedPreview = false
    private var normalSince: Date?
    private var checkpointTimer: Timer?
    private var worldMapTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    var phaseIsProcessing: Bool {
        switch phase {
        case .betweenRooms, .processing:
            return true
        default:
            return false
        }
    }

    var showsNextRoom: Bool {
        mode == .wholeFloor && phase == .scanning
    }

    var captureARSession: ARSession? {
        sharesCaptureSession ? arSession : nil
    }

    var savedSections: [ScanCheckpointSection] {
        checkpoint.sections
    }

    override init() {
        super.init()
    }

    /// RoomCaptureViewDelegate and RoomCaptureSessionDelegate inherit NSCoding.
    /// This controller is never archived.
    required init?(coder: NSCoder) {
        fatalError("ScanSessionController does not support NSCoding")
    }

    func encode(with coder: NSCoder) {}

    func start(launch: ScanLaunch, checkpoints: ScanCheckpointStore, homeMap: Data?) {
        guard !started else { return }
        started = true
        self.checkpoints = checkpoints
        floor = launch.floor
        preservesCheckpointOnCancel = launch.preservesCheckpointOnCancel
        installObservers()

        var resumeMap: Data?
        switch launch.kind {
        case .resume(let id):
            guard let existing = checkpoints.loadAll().first(where: { $0.id == id }) else {
                phase = .failed("That scan is no longer on this iPhone.")
                return
            }
            checkpoint = existing
            checkpoint.phase = .scanning
            mode = existing.mode
            floor = launch.floor ?? existing.floor
            relocalized = false
            if let relative = existing.worldMap {
                resumeMap = try? checkpoints.data(existing.id, relative: relative)
            }
            spaceId = UUID()
        case .room:
            mode = homeMap == nil ? .singleRoom : .extendHome
            checkpoint = makeCheckpoint(homeID: launch.homeID, mode: mode, floor: launch.floor, replacing: launch.replacingRoomID)
        case .wholeFloor:
            mode = .wholeFloor
            checkpoint = makeCheckpoint(homeID: launch.homeID, mode: .wholeFloor, floor: launch.floor, replacing: nil)
        }
        checkpointID = checkpoint.id
        try? checkpoints.save(checkpoint)
        finishedSectionCount = checkpoint.sections.filter(\.finished).count

        let mapData = resumeMap ?? homeMap
        if let mapData, let map = Self.unarchive(mapData) {
            worldMap = map
            pendingWorldMap = mapData
            phase = .relocalizing
            camera = .relocalizing
            instruction = "Find a room you already scanned."
            trackingGuidance = "Point at a wall or doorway you scanned before, and walk a short way."
        } else {
            beginCapture(sharing: mode == .wholeFloor)
        }
        evaluateGuard()
    }

    func noteRelocalizationIsSlow() {
        guard phase == .relocalizing else { return }
        trackingGuidance = "Still looking for the saved scan. Keep moving, or scan and align the room afterwards."
    }

    func skipRelocalization() {
        guard phase == .relocalizing else { return }
        relocalizationFailed = true
        relocalized = false
        arSession?.pause()
        arSession = nil
        attachedPreview = false
        holdPreview = false
        spaceId = UUID()
        beginCapture(sharing: mode == .wholeFloor)
    }

    func beginRelocalization(on view: ARSCNView) {
        guard !attachedPreview, phase == .relocalizing else { return }
        attachedPreview = true
        let session = view.session
        session.delegate = self
        arSession = session
        guard let worldMap else {
            skipRelocalization()
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = worldMap
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func attach(_ view: RoomCaptureView) {
        if captureView === view { return }
        if captureView != nil && !didStop { return }
        captureView = view
        view.delegate = self
        view.captureSession.delegate = self
        if sharesCaptureSession {
            arSession = view.captureSession.arSession
        }
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = !relocalized && mode != .wholeFloor
        view.captureSession.run(configuration: configuration)
        didStop = false
        openSectionIfNeeded()
        startTimers()
    }

    func finish() {
        guard phase == .scanning else { return }
        arSession = captureView?.captureSession.arSession ?? arSession
        if mode == .wholeFloor {
            stopIntent = .finishFloor
            phase = .processing
            stopSession(pauseARSession: false)
            return
        }
        stopIntent = .finishRoom
        phase = .processing
        stopSession(pauseARSession: true)
    }

    func nextRoom() {
        guard showsNextRoom else { return }
        stopIntent = .nextSection
        phase = .betweenRooms
        arSession = captureView?.captureSession.arSession ?? arSession
        sharesCaptureSession = true
        stopSession(pauseARSession: false)
    }

    func cancel(discard: Bool) {
        guard !cancelled else { return }
        cancelled = true
        invalidateTimers()
        stopSession(pauseARSession: true)
        arSession?.pause()
        guard let checkpoints else { return }
        if discard {
            try? checkpoints.discard(checkpoint.id)
        } else {
            writeCheckpoint(markInterrupted: true)
        }
    }

    func sceneMovedToBackground(_ background: Bool) {
        guard started, !cancelled else { return }
        if background {
            writeCheckpoint(markInterrupted: true)
            refreshWorldMap()
        } else if phase == .scanning || phase == .relocalizing || phase == .betweenRooms {
            checkpoint.phase = .scanning
            try? checkpoints?.save(checkpoint)
        }
    }

    func applyNames(_ names: [UUID: String]) {
        for index in checkpoint.sections.indices {
            guard let name = names[checkpoint.sections[index].id] else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                checkpoint.sections[index].name = trimmed
            }
        }
        try? checkpoints?.save(checkpoint)
    }

    func makePieces() throws -> [ScanPiece] {
        guard let checkpoints else { throw ScanCommitError.empty }
        var pieces: [ScanPiece] = []
        for section in checkpoint.sections {
            let room: CapturedRoom
            if let held = held[section.id] {
                room = held
            } else {
                let data: Data
                do {
                    data = try checkpoints.data(checkpoint.id, relative: section.capturedRoom)
                } catch {
                    continue
                }
                room = try ScanArchive.decodeRoom(data)
            }
            let json = try ScanArchive.encodeRoom(room)
            pieces.append(ScanPiece(
                section: section,
                room: room,
                plan: FloorPlanExtractor.floorPlan(from: room),
                json: json,
                usdz: try? ScanArchive.usdzData(for: room)
            ))
        }
        guard !pieces.isEmpty else { throw ScanCommitError.empty }
        return pieces
    }

    func latestWorldMap() async -> Data? {
        let session = arSession ?? captureView?.captureSession.arSession
        guard let session else { return pendingWorldMap }
        return await withCheckedContinuation { continuation in
            session.getCurrentWorldMap { [weak self] map, _ in
                let archived = map.flatMap(Self.archive)
                continuation.resume(returning: archived ?? self?.pendingWorldMap)
            }
        }
    }

    func markSaved() {
        cancelled = true
        invalidateTimers()
        if !didStop {
            didStop = true
            captureView?.captureSession.stop(pauseARSession: true)
        }
        arSession?.pause()
        try? checkpoints?.discard(checkpoint.id)
    }

    func captureFrame(manual: Bool) {
        guard phase == .scanning, !didStop, let frame = captureView?.captureSession.arSession.currentFrame else {
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
        let heldFrame = ScanHeldFrame(id: UUID(), jpeg: jpeg, pose: ScanFrameImage.pose(from: frame), manual: manual)
        publish {
            if manual {
                self.frames.append(heldFrame)
                self.captureNote = "Saved a frame. It is matched to a wall when you save the room."
            } else {
                let automatic = self.frames.filter { !$0.manual }
                if automatic.count >= 8, let index = self.frames.firstIndex(where: { !$0.manual }) {
                    self.frames.remove(at: index)
                }
                self.frames.append(heldFrame)
            }
        }
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if stopIntent == .nextSection || stopIntent == .finishFloor {
            return false
        }
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
            if self.stopIntent == .nextSection || self.stopIntent == .finishFloor { return }
            if let message {
                self.phase = .failed(message)
            } else {
                self.closeSection(with: processedResult)
                self.phase = .finished
                self.invalidateTimers()
            }
        }
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        publish {
            guard self.phase == .scanning else { return }
            self.latestRoom = room
            if !self.didWriteRoom {
                self.didWriteRoom = true
                self.writeCheckpoint(markInterrupted: false)
            }
        }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text = Self.text(for: instruction)
        publish {
            guard self.phase == .scanning else { return }
            self.instruction = text
        }
    }

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        publish { self.holdPreview = false }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        let intent = stopIntent
        if intent == .nextSection || intent == .finishFloor {
            Task {
                do {
                    if let error { throw error }
                    let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                    DispatchQueue.main.async {
                        self.completeHandoff(room, intent: intent)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard !self.cancelled else { return }
                        self.writeCheckpoint(markInterrupted: true)
                        if self.held.isEmpty && !self.checkpoint.hasCapturedRoom {
                            self.phase = .failed(error.localizedDescription)
                        } else {
                            self.captureNote = error.localizedDescription
                            self.phase = .finished
                            self.invalidateTimers()
                        }
                    }
                }
            }
            return
        }
        guard let message = error?.localizedDescription else { return }
        publish {
            guard !self.cancelled else { return }
            if case .finished = self.phase { return }
            if case .processing = self.phase { return }
            self.phase = .failed(message)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        publish {
            guard self.phase == .relocalizing else { return }
            self.trackingGuidance = Self.guidance(for: camera.trackingState)
            if case .normal = camera.trackingState {
                if self.normalSince == nil { self.normalSince = Date() }
                if let since = self.normalSince, Date().timeIntervalSince(since) >= 0.8 {
                    self.lockRelocalization()
                }
            } else {
                self.normalSince = nil
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        publish {
            guard self.phase == .relocalizing else { return }
            self.trackingGuidance = "The camera could not start. You can scan and align the room afterwards."
        }
    }

    deinit {
        invalidateTimers()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func beginCapture(sharing: Bool) {
        sharesCaptureSession = sharing
        if sharing && arSession == nil {
            arSession = ARSession()
        }
        phase = .scanning
        camera = .capturing
        generation += 1
    }

    private func lockRelocalization() {
        guard phase == .relocalizing else { return }
        relocalized = true
        relocalizationFailed = false
        for index in checkpoint.sections.indices {
            checkpoint.sections[index].sharesHomeMap = true
        }
        checkpoint.relocalized = true
        sharesCaptureSession = true
        holdPreview = true
        phase = .scanning
        camera = .capturing
        generation += 1
        instruction = "The room is locked. Keep tracing the walls."
        try? checkpoints?.save(checkpoint)
    }

    private func openSectionIfNeeded() {
        guard activeSectionID == nil else { return }
        let id = UUID()
        let relative = "sections/\(id.uuidString).captured.json"
        let section = ScanCheckpointSection(
            id: id,
            name: "Room \(checkpoint.sections.count + 1)",
            capturedRoom: relative,
            finished: false,
            floor: floor,
            spaceId: spaceId,
            sharesHomeMap: relocalized
        )
        checkpoint.sections.append(section)
        activeSectionID = id
        didWriteRoom = false
        latestRoom = nil
    }

    private func closeSection(with room: CapturedRoom) {
        latestRoom = room
        if let id = activeSectionID, let index = checkpoint.sections.firstIndex(where: { $0.id == id }) {
            checkpoint.sections[index].finished = true
            held[id] = room
        }
        finishedSectionCount = checkpoint.sections.filter(\.finished).count
        writeCheckpoint(markInterrupted: false)
    }

    private func completeHandoff(_ room: CapturedRoom, intent: StopIntent) {
        guard !cancelled else { return }
        closeSection(with: room)
        activeSectionID = nil
        latestRoom = nil
        if intent == .finishFloor {
            phase = .finished
            invalidateTimers()
            refreshWorldMap()
            arSession?.pause()
            return
        }
        stopIntent = .none
        captureView = nil
        didStop = false
        sharesCaptureSession = true
        generation += 1
        phase = .scanning
        camera = .capturing
    }

    private func writeCheckpoint(markInterrupted: Bool) {
        guard started, !cancelled, let checkpoints else { return }
        if let room = latestRoom,
           let id = activeSectionID,
           let section = checkpoint.sections.first(where: { $0.id == id }),
           let data = try? ScanArchive.encodeRoom(room) {
            try? checkpoints.writePayload(checkpoint.id, relative: section.capturedRoom, data: data)
            held[id] = room
        }
        if let pendingWorldMap {
            try? checkpoints.writePayload(
                checkpoint.id,
                relative: ScanCheckpoint.worldMapFilename,
                data: pendingWorldMap
            )
            checkpoint.worldMap = ScanCheckpoint.worldMapFilename
        }
        checkpoint.phase = markInterrupted ? .interrupted : .scanning
        checkpoint.updatedAt = Date()
        checkpoint.relocalized = relocalized
        try? checkpoints.save(checkpoint)
    }

    private func refreshWorldMap() {
        let session = arSession ?? captureView?.captureSession.arSession
        session?.getCurrentWorldMap { [weak self] map, _ in
            guard let self, let map, let data = Self.archive(map) else { return }
            DispatchQueue.main.async {
                guard !self.cancelled else { return }
                self.pendingWorldMap = data
                self.writeCheckpoint(markInterrupted: self.checkpoint.phase == .interrupted)
            }
        }
    }

    private func startTimers() {
        guard checkpointTimer == nil else { return }
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.writeCheckpoint(markInterrupted: false)
            self?.evaluateGuard()
        }
        worldMapTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            self?.refreshWorldMap()
        }
    }

    private func invalidateTimers() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        worldMapTimer?.invalidate()
        worldMapTimer = nil
    }

    private func stopSession(pauseARSession: Bool) {
        guard !didStop else { return }
        didStop = true
        captureView?.captureSession.stop(pauseARSession: pauseARSession)
    }

    private func evaluateGuard() {
        let advice = ScanGuardAdvice.evaluate(ScanDevice.conditions())
        if advice.checkpointNow {
            writeCheckpoint(markInterrupted: false)
            refreshWorldMap()
        }
        publish { self.guardMessage = advice.message }
    }

    private func installObservers() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.evaluateGuard()
            }
            observers.append(token)
        }
    }

    private func makeCheckpoint(
        homeID: UUID,
        mode: ScanCheckpointMode,
        floor: Int?,
        replacing: UUID?
    ) -> ScanCheckpoint {
        let now = Date()
        return ScanCheckpoint(
            id: UUID(),
            homeId: homeID,
            mode: mode,
            phase: .scanning,
            startedAt: now,
            updatedAt: now,
            floor: floor,
            replacingRoomId: replacing
        )
    }

    private func publish(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private static func archive(_ map: ARWorldMap) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) -> ARWorldMap? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    private static func guidance(for state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "The room is locked. Starting the scan."
        case .limited(.initializing):
            return "Move the phone slowly until the room is recognized."
        case .limited(.relocalizing):
            return "Point at a wall or doorway you scanned before, and walk a short way."
        case .limited(.excessiveMotion):
            return "Slow down so the camera can match the saved scan."
        case .limited(.insufficientFeatures):
            return "Point at a surface with more detail, such as a door frame or furniture."
        case .notAvailable:
            return "Tracking is unavailable. You can scan and align the room afterwards."
        default:
            return "Keep moving until the saved scan locks in."
        }
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

enum ScanDevice {
    static func conditions() -> ScanConditions {
        let thermal: ThermalBand
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .fair
        }
        let level = UIDevice.current.batteryLevel
        let fraction: Double? = level >= 0 ? Double(level) : nil
        let state = UIDevice.current.batteryState
        let charging = state == .charging || state == .full
        return ScanConditions(
            thermal: thermal,
            batteryFraction: fraction,
            isCharging: charging,
            freeBytes: freeBytes()
        )
    }

    static func freeBytes() -> Int64? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

struct RoomCaptureRepresentable: UIViewRepresentable {
    let controller: ScanSessionController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view: RoomCaptureView
        if let session = controller.captureARSession {
            view = RoomCaptureView(frame: .zero, arSession: session)
        } else {
            view = RoomCaptureView(frame: .zero)
        }
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct RelocalizationRepresentable: UIViewRepresentable {
    let controller: ScanSessionController

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = false
        controller.beginRelocalization(on: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
