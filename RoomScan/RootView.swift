import SwiftUI
import RoomScanCore

enum AppRoute: Hashable {
    case home(UUID)
    case room(home: UUID, room: UUID)
    case model(UUID)
    case plan(UUID)
    case site(UUID)
    case outdoor(home: UUID, zone: UUID)
    case facade(home: UUID, zone: UUID, wall: UUID)
}

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(HomeStore.self) private var store
    @State private var selection: UUID?
    @State private var path: [AppRoute] = []

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
            .background(Theme.paper)
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
            case .site(let id):
                SitePlanView(homeID: id)
            case .outdoor(let home, let zone):
                OutdoorZoneView(homeID: home, zoneID: zone)
            case .facade(let home, let zone, let wall):
                FacadeTextureView(homeID: home, zoneID: zone, wallID: wall)
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
}
