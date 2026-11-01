import SwiftUI
import RoomScanCore

struct PinEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HomeAssistantSettings.self) private var assistant
    @State private var draft: DevicePin
    @State private var entityField: String
    @State private var confirmingDelete = false
    @State private var suggestions: [HAEntityRecord] = []
    @State private var showSettings = false

    var snapshot: EntitySnapshot?
    var onToggle: () -> Void
    var onSave: (DevicePin) -> Void
    var onDelete: () -> Void

    init(
        pin: DevicePin,
        snapshot: EntitySnapshot?,
        onToggle: @escaping () -> Void,
        onSave: @escaping (DevicePin) -> Void,
        onDelete: @escaping () -> Void
    ) {
        _draft = State(initialValue: pin)
        _entityField = State(initialValue: pin.entityId ?? "")
        self.snapshot = snapshot
        self.onToggle = onToggle
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Name", text: $draft.name)
                    Picker("Type", selection: $draft.kind) {
                        ForEach(DeviceKind.allCases, id: \.self) { kind in
                            Label(kind.label, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                }
                Section {
                    TextField("light.kitchen", text: $entityField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    entityCaption
                } header: {
                    Text("Home Assistant entity id")
                } footer: {
                    Text(assistant.isConfigured
                        ? "Suggestions come from your Home Assistant server. The token stays in the Keychain on this iPhone."
                        : "Optional until you connect Home Assistant in Settings. The id is stored on this iPhone.")
                }
                if assistant.isConfigured {
                    Section {
                        if suggestions.isEmpty {
                            Text(assistant.catalogError ?? "No matching entities yet.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(suggestions) { record in
                            Button {
                                apply(record)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.friendlyName ?? record.entityId)
                                        .foregroundStyle(Theme.ink)
                                    Text("\(record.entityId) · \(record.state)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                        Button("Reload entities") {
                            Task { await assistant.refreshEntities() }
                        }
                    } header: {
                        Text("Home Assistant entities")
                    }
                } else {
                    Section {
                        Button("Connect Home Assistant") { showSettings = true }
                    }
                }
                if let snapshot {
                    Section(assistant.isConfigured ? "Home Assistant" : "Sample state") {
                        LabeledContent("State", value: snapshot.displayState)
                        if snapshot.isToggleable {
                            Button(snapshot.isOn ? "Turn off" : "Turn on", action: onToggle)
                        }
                        Text(assistant.isConfigured
                            ? "This reading comes from Home Assistant."
                            : "This reading is mock data, not a live Home Assistant state.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Section("Position (meters)") {
                    coordinate("X", value: $draft.position.x)
                    coordinate("Z", value: $draft.position.z)
                    VStack(alignment: .leading) {
                        Text("Height \(draft.position.y, format: .number.precision(.fractionLength(2))) m")
                        Slider(value: $draft.position.y, in: 0...3, step: 0.05)
                    }
                    Button("Use a typical \(draft.kind.label.lowercased()) height") {
                        draft.position.y = draft.kind.defaultHeight
                    }
                }
                Section {
                    Button("Delete device", role: .destructive) {
                        confirmingDelete = true
                    }
                }
            }
            .navigationTitle("Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var pin = draft
                        pin.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if pin.name.isEmpty { pin.name = pin.kind.label }
                        pin.entityId = resolvedEntityID()
                        onSave(pin)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete this device?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task(id: entityField) {
                suggestions = await assistant.searchEntities(matching: entityField)
            }
        }
        .tint(Theme.accent)
    }

    private func apply(_ record: HAEntityRecord) {
        let previousLabel = draft.kind.label
        entityField = record.entityId
        draft.kind = record.suggestedKind
        let currentName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentName.isEmpty || currentName == previousLabel || currentName == record.suggestedKind.label {
            draft.name = record.friendlyName ?? record.suggestedKind.label
        }
    }

    @ViewBuilder
    private var entityCaption: some View {
        switch EntityIDRules.check(entityField) {
        case .unset:
            Text("Leave this blank if the device is not in Home Assistant yet.")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
        case .valid(let id):
            Text("Will be stored as \(id).")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
        case .invalid:
            Text("Use a lowercase domain and name, such as light.kitchen or sensor.hall_temperature.")
                .font(.footnote)
                .foregroundStyle(Theme.warn)
        }
    }

    private func resolvedEntityID() -> String? {
        switch EntityIDRules.check(entityField) {
        case .unset:
            return nil
        case .valid(let id):
            return id
        case .invalid:
            let trimmed = entityField.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func coordinate(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: -50...50, step: 0.05) {
            Text("\(title)  \(value.wrappedValue, format: .number.precision(.fractionLength(2)))")
                .monospacedDigit()
        }
    }
}
