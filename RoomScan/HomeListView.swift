import SwiftUI
import RoomScanCore

struct HomeListView: View {
    @Environment(HomeStore.self) private var store
    var showsLinks: Bool
    @Binding var selection: UUID?
    var onOpen: (UUID) -> Void

    @State private var creating = false
    @State private var draftName = ""
    @State private var pendingDelete: Home?
    @State private var errorMessage: String?

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
                        Text("No homes yet")
                            .font(.system(.title3, design: .serif))
                        Text("Scan a room, or open the sample apartment to try the model and floor plan.")
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
                Text("Scans, floor plans, and device pins stay in Files on this iPhone. There is no account and no cloud upload.")
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
        .background(Theme.paper)
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
                layers: PlanLayers.rooms(home.rooms, unified: home.coordinatesAreUnified),
                pins: home.pins,
                showPins: home.coordinatesAreUnified,
                selectedPinID: nil,
                placing: false,
                interactive: false
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
