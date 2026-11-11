import SwiftUI
import RoomScanCore

struct HomeListView: View {
    @Environment(HomeStore.self) private var store
    @Environment(ICloudSyncController.self) private var sync
    var showsLinks: Bool
    @Binding var selection: UUID?
    var onOpen: (UUID) -> Void

    @State private var creating = false
    @State private var draftName = ""
    @State private var pendingDelete: Home?
    @State private var errorMessage: String?
    @State private var showSettings = false

    var body: some View {
        List(selection: listSelection) {
            if let loadError = store.loadError {
                Section {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(Theme.warn)
                }
            }
            if !LiDARSupport.canScan {
                Section {
                    LiDARNotice()
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                if store.homes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(emptyTitle)
                            .font(.system(.title3, design: .serif))
                        Text(emptyMessage)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(store.homes) { home in
                    row(home)
                        .tag(home.id)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                pendingDelete = home
                            }
                        }
                }
            } header: {
                Text("Homes")
            } footer: {
                Text("Homes are stored on this device. With iCloud sync on, the same library opens on your iPad. Connect Home Assistant in Settings to link entities and, when you choose, send a floor plan.")
            }
            if !store.warnings.isEmpty {
                Section("Couldn't read") {
                    ForEach(store.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Home Scanner")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draftName = ""
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New home")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Sample") { openSample() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("New home", isPresented: $creating) {
            TextField("Ground floor", text: $draftName)
            Button("Create") { createHome() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A home is one floor. Scan its rooms, then combine them.")
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "this home")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    delete(pendingDelete)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .paperChrome()
    }

    private var emptyTitle: String {
        if sync.syncEnabled && sync.phase == .uploading {
            return "Downloading homes"
        }
        return "No homes yet"
    }

    private var emptyMessage: String {
        if sync.syncEnabled && !sync.accountAvailable {
            return "Sign in to iCloud to restore homes from another device. You can still create homes on this one."
        }
        if sync.syncEnabled && sync.phase == .uploading {
            return "iCloud is bringing homes onto this device. You can still scan a room while that finishes."
        }
        if sync.syncEnabled && sync.phase == .offline {
            return "Homes already in iCloud show up when the connection returns. You can still scan a room on this device."
        }
        return "Scan a room, or open the sample apartment to try the model and floor plan."
    }

    private var listSelection: Binding<UUID?>? {
        showsLinks ? nil : $selection
    }

    @ViewBuilder
    private func row(_ home: Home) -> some View {
        if showsLinks {
            NavigationLink(value: AppRoute.home(home.id)) {
                HomeRow(home: home)
            }
        } else {
            HomeRow(home: home)
        }
    }

    private func createHome() {
        do {
            let home = try store.createHome(named: draftName)
            onOpen(home.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSample() {
        do {
            if let existing = store.home(id: SampleApartment.homeID) {
                onOpen(existing.id)
                return
            }
            let home = try store.installSample(usdz: SampleBundle.usdzData())
            onOpen(home.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ home: Home) {
        do {
            try store.deleteHome(id: home.id)
            if selection == home.id {
                selection = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingDelete = nil
    }
}

private struct HomeRow: View {
    let home: Home

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FloorPlanCanvas(
                layers: PlanLayers.forHome(home),
                pins: home.pins,
                showPins: PlanLayers.showsDevicePins(home),
                selectedPinID: nil,
                placing: false,
                interactive: false,
                markup: .structure
            )
            .frame(width: 84, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(home.name)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(Theme.ink)
                Text(meta)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                Text(home.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let rooms = home.rooms.count == 1 ? "1 room" : "\(home.rooms.count) rooms"
        let devices = home.pins.count == 1 ? "1 device" : "\(home.pins.count) devices"
        return "\(rooms) · \(devices)"
    }
}
