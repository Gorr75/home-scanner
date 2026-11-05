import SwiftUI
import RoomScanCore

struct SettingsView: View {
    @Environment(HomeAssistantSettings.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    @State private var urlDraft = ""
    @State private var tokenDraft = ""
    @State private var status: String?
    @State private var testing = false
    @State private var errorMessage: String?

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
