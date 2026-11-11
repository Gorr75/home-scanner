import SwiftUI
import RoomScanCore

struct SettingsView: View {
    @Environment(HomeAssistantSettings.self) private var assistant
    @Environment(HomeStore.self) private var store
    @Environment(ICloudSyncController.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var urlDraft = ""
    @State private var tokenDraft = ""
    @State private var status: String?
    @State private var testing = false
    @State private var errorMessage: String?
    @AppStorage(DaylightPreference.enabledKey) private var daylightOn = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://homeassistant.local:8123", text: $urlDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField(assistant.hasToken ? "Token saved in the Keychain" : "Long-lived access token", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Home Assistant")
                } footer: {
                    Text("Create a long-lived access token in your Home Assistant profile. It stays in the Keychain on this iPhone and is sent only to this server. It is not written into the home file.")
                }
                Section {
                    Button {
                        Task { await self.test() }
                    } label: {
                        if testing {
                            HStack {
                                ProgressView()
                                Text("Testing connection")
                            }
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(testing)
                    Button("Remove connection", role: .destructive) {
                        remove()
                    }
                    .disabled(!assistant.hasToken && urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text(status ?? assistant.serverLabel)
                }
                Section {
                    Toggle("Daylight by time of day", isOn: $daylightOn)
                } footer: {
                    Text("The 3D view warms at sunrise and sunset, stays neutral at midday, and dims to blue at night. Home Assistant's sun is used when you are connected. Otherwise the phone clock is used, with sunrise at 06:00 and sunset at 18:00. A slider on the model previews another time. Lights that are on keep their own colour.")
                }
                iCloudSection
            }
            .scrollContentBackground(.hidden)
            .paperChrome()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert("Couldn't save the connection", isPresented: errorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .tint(Theme.accent)
        .onAppear {
            if urlDraft.isEmpty {
                urlDraft = assistant.baseURLText
            }
        }
    }

    private var iCloudSection: some View {
        Group {
            Section {
                Toggle("iCloud sync", isOn: Binding(
                    get: { sync.syncEnabled },
                    set: { sync.setSyncEnabled($0) }
                ))
                .disabled(sync.isWorking)
                LabeledContent("Status", value: sync.statusText)
                Button {
                    Task { await sync.backupNow() }
                } label: {
                    if sync.isWorking {
                        HStack {
                            ProgressView()
                            Text("Backing up")
                        }
                    } else {
                        Text("Back up now")
                    }
                }
                .disabled(sync.isWorking)
            } header: {
                Text("iCloud")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Homes, room models, photos, plates, and world maps are kept in iCloud Drive and open on your iPhone and iPad. The newest copy of each file wins. An older copy stays in the home so you can choose it below. With the switch off, or when you are not signed in, homes stay on this device and the app works offline. A home deleted while sync is off can come back from iCloud the next time sync is on.")
                    if let backupMessage = sync.backupMessage {
                        Text(backupMessage)
                    }
                    if let lastError = sync.lastError {
                        Text(lastError)
                            .foregroundStyle(Theme.warn)
                    }
                }
            }
            if !sync.conflicts.isEmpty {
                Section("Conflict copies") {
                    ForEach(sync.conflicts) { copy in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(conflictTitle(copy))
                            Text("Older copy kept \(copy.loserModifiedAt.formatted(date: .abbreviated, time: .shortened)). The newer file is the one in the home.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                            HStack {
                                Button("Use this copy") { sync.adopt(copy) }
                                Button("Keep current") { sync.discard(copy) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func conflictTitle(_ copy: ConflictCopy) -> String {
        let file = copy.originalRelativePath
        guard let id = UUID(uuidString: copy.homeFolder), let home = store.home(id: id) else {
            return file
        }
        return "\(home.name) · \(file)"
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() {
        do {
            try assistant.save(baseURL: urlDraft, token: tokenDraft.isEmpty ? nil : tokenDraft)
            tokenDraft = ""
            status = assistant.isConfigured ? "Saved. \(assistant.serverLabel)" : "Saved the address. Add a token to connect."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            try assistant.save(baseURL: urlDraft, token: tokenDraft.isEmpty ? nil : tokenDraft)
            tokenDraft = ""
            let probe = try await assistant.probe()
            let place = probe.locationName ?? assistant.serverLabel
            let version = probe.version.map { " Home Assistant \($0)." } ?? ""
            if probe.uploadEndpointInstalled {
                status = "Connected to \(place).\(version) The home_scanner upload endpoint is installed."
            } else {
                status = "Connected to \(place).\(version) The token works. Install the home_scanner integration before sending a floor plan. Sharing a zip still works."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try assistant.clearConnection()
            urlDraft = ""
            tokenDraft = ""
            status = "Removed the Home Assistant address and token."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
