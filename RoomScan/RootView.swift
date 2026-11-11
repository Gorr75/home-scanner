import SwiftUI
import RoomScanCore

enum AppRoute: Hashable {
    case home(UUID)
    case room(home: UUID, room: UUID)
    case model(UUID)
    case plan(UUID)
}

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HomeStore.self) private var store
    @State private var selection: UUID?
    @State private var path: [AppRoute] = []
    @State private var resumeLaunch: ScanLaunch?
    @State private var savingRecovery = false
    @State private var recoveryError: String?
    @State private var nudge: NudgeRequest?

    private var split: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if split {
                NavigationSplitView {
                    HomeListView(showsLinks: false, selection: $selection, onOpen: { selection = $0 })
                } detail: {
                    NavigationStack {
                        detail
                            .roomScanDestinations()
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $path) {
                    HomeListView(showsLinks: true, selection: $selection, onOpen: { path.append(.home($0)) })
                        .roomScanDestinations()
                }
            }
        }
        .tint(Theme.accent)
        .onAppear { store.refreshRecovery() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshRecovery() }
        }
        .alert("Scan interrupted", isPresented: recoveryPresented) {
            if let offer = store.recovery, offer.canResume {
                Button("Resume") { resume(offer) }
            }
            if let offer = store.recovery, offer.canSave {
                Button("Save what was captured") { saveRecovery(offer) }
            }
            Button("Discard", role: .destructive) {
                if let offer = store.recovery { discard(offer) }
            }
        } message: {
            Text(store.recovery?.summary ?? "")
        }
        .fullScreenCover(item: $resumeLaunch, onDismiss: { store.refreshRecovery() }) { launch in
            ScanRoomView(launch: launch) { resumeLaunch = nil }
        }
        .sheet(item: $nudge) { request in
            RoomNudgeSheet(homeID: request.homeID, roomIDs: request.roomIDs, sharesSpace: request.sharesSpace)
        }
        .alert("Couldn't save the scan", isPresented: Binding(
            get: { recoveryError != nil },
            set: { if !$0 { recoveryError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recoveryError ?? "")
        }
        .overlay {
            if savingRecovery {
                ProgressView("Saving the scan")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var recoveryPresented: Binding<Bool> {
        Binding(
            get: { store.recovery != nil && resumeLaunch == nil && !savingRecovery && nudge == nil },
            set: { _ in }
        )
    }

    private func resume(_ offer: ScanRecoveryOffer) {
        resumeLaunch = ScanLaunch(
            homeID: offer.checkpoint.homeId,
            kind: .resume(offer.checkpoint.id),
            floor: offer.checkpoint.floor,
            replacingRoomID: offer.checkpoint.replacingRoomId
        )
    }

    private func discard(_ offer: ScanRecoveryOffer) {
        do {
            try store.discardCheckpoint(id: offer.checkpoint.id)
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    private func saveRecovery(_ offer: ScanRecoveryOffer) {
        savingRecovery = true
        Task {
            defer { savingRecovery = false }
            do {
                let pieces = try ScanCommit.load(checkpoint: offer.checkpoint, from: store.checkpoints)
                let map = ScanCommit.worldMap(for: offer.checkpoint, from: store.checkpoints)
                let result = try await ScanCommit.save(
                    pieces: pieces,
                    homeID: offer.checkpoint.homeId,
                    replacingRoomID: offer.checkpoint.replacingRoomId,
                    worldMap: map,
                    frames: [],
                    store: store
                )
                try store.discardCheckpoint(id: offer.checkpoint.id)
                if result.needsNudge {
                    nudge = NudgeRequest(
                        homeID: offer.checkpoint.homeId,
                        roomIDs: result.roomIDs,
                        sharesSpace: result.sharesSpace
                    )
                }
            } catch {
                recoveryError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, store.home(id: selection) != nil {
            HomeDetailView(homeID: selection)
        } else {
            ContentUnavailableView(
                "No home selected",
                systemImage: "house",
                description: Text("Choose a home, or open the sample apartment.")
            )
            .paperChrome()
        }
    }
}

extension View {
    func roomScanDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .home(let id):
                HomeDetailView(homeID: id)
            case .room(let home, let room):
                RoomDetailView(homeID: home, roomID: room)
            case .model(let id):
                HomeViewer(homeID: id, showsPlan: false)
            case .plan(let id):
                HomeViewer(homeID: id, showsPlan: true)
            }
        }
    }
}

enum PreviewStore {
    @MainActor static func make() -> HomeStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HomeScannerPreview", isDirectory: true)
        let repository = try! HomeRepository(root: root)
        let store = HomeStore(repository: repository)
        if store.home(id: SampleApartment.homeID) == nil {
            _ = try? store.installSample(usdz: nil)
        }
        return store
    }
}

#Preview {
    RootView()
        .environment(PreviewStore.make())
        .environment(PinBoard())
        .environment(HomeAssistantSettings(defaults: UserDefaults(suiteName: "HomeScannerPreview") ?? .standard))
}
