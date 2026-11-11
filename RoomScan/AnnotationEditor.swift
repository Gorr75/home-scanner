import PhotosUI
import SwiftUI
import RoomScanCore

struct AnnotationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HomeStore.self) private var store
    @StateObject private var voice = VoiceNoteRecorder()

    let homeID: UUID
    let roomName: String
    @State private var draft: RoomAnnotation
    @State private var photoImage: UIImage?
    @State private var photoChanged = false
    @State private var audioChanged = false
    @State private var showCamera = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var confirmingDelete = false

    var onSave: (RoomAnnotation) -> Void
    var onDelete: (RoomAnnotation) -> Void

    init(homeID: UUID, roomName: String, note: RoomAnnotation, onSave: @escaping (RoomAnnotation) -> Void, onDelete: @escaping (RoomAnnotation) -> Void) {
        self.homeID = homeID
        self.roomName = roomName
        _draft = State(initialValue: note)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(draft.kind == .measurement ? "Label" : "Note", text: $draft.text, axis: .vertical)
                        .lineLimit(3...6)
                    if let measurement = draft.measurement {
                        LabeledContent("Distance", value: MeasureSnap.label(from: measurement.start, to: measurement.end))
                    }
                    Text(roomName)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                } header: {
                    Text(draft.kind == .measurement ? "Measurement" : "Note")
                }
                Section("Photo") {
                    if let photoImage {
                        Image(uiImage: photoImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if SnapshotImage.cameraAvailable {
                        Button("Take photo") { showCamera = true }
                    }
                    PhotosPicker(selection: $libraryItem, matching: .images) {
                        Label("Choose photo", systemImage: "photo")
                    }
                    if photoImage != nil {
                        Button("Remove photo", role: .destructive) {
                            photoImage = nil
                            photoChanged = true
                            draft.photo = nil
                        }
                    }
                }
                Section {
                    Picker("Language", selection: $voice.localeID) {
                        Text("Svenska").tag("sv-SE")
                        Text("English").tag("en-US")
                    }
                    Button(voice.recording ? "Stop recording" : "Record voice note") {
                        voice.toggleRecording()
                        audioChanged = true
                    }
                    Button(voice.playing ? "Stop" : "Play") { voice.togglePlayback() }
                        .disabled(!voice.hasAudio || voice.recording)
                    Button("Transcribe on this iPhone") {
                        voice.transcribe { draft.transcript = $0 }
                    }
                    .disabled(!voice.hasAudio || voice.recording)
                    if let transcript = draft.transcript {
                        TextField("Transcript", text: Binding(
                            get: { transcript },
                            set: { draft.transcript = $0 }
                        ), axis: .vertical)
                        .lineLimit(2...6)
                    }
                    if let message = voice.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                } header: {
                    Text("Voice note")
                } footer: {
                    Text("Recording and transcription stay on this iPhone. Swedish and English use the on-device speech model.")
                }
                Section {
                    Button("Delete note", role: .destructive) { confirmingDelete = true }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(draft.kind == .measurement ? "Measurement" : "Note")
            .navigationBarTitleDisplayMode(.inline)
            .paperChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete(draft)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    photoImage = image
                    photoChanged = true
                }
                .ignoresSafeArea()
            }
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        photoImage = image
                        photoChanged = true
                    }
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func loadExisting() {
        if let photo = draft.photo, let data = store.mediaData(homeId: homeID, relative: photo) {
            photoImage = UIImage(data: data)
        }
        if let audio = draft.audio, let data = store.mediaData(homeId: homeID, relative: audio) {
            voice.load(data: data)
        }
    }

    private func save() {
        if photoChanged {
            if let photoImage, let jpeg = SnapshotImage.jpeg(from: photoImage) {
                let relative = draft.photo ?? MediaPaths.annotationPhoto(draft.id)
                do {
                    try store.writeMedia(homeId: homeID, relative: relative, data: jpeg)
                    draft.photo = relative
                } catch {
                    draft.photo = nil
                }
            } else if let previous = draft.photo {
                store.removeMedia(homeId: homeID, relative: previous)
                draft.photo = nil
            }
        }
        if audioChanged {
            if voice.hasAudio, let data = voice.audioData() {
                let relative = draft.audio ?? MediaPaths.annotationAudio(draft.id)
                do {
                    try store.writeMedia(homeId: homeID, relative: relative, data: data)
                    draft.audio = relative
                } catch {
                    draft.audio = nil
                }
            } else if let previous = draft.audio {
                store.removeMedia(homeId: homeID, relative: previous)
                draft.audio = nil
            }
        }
        let trimmed = draft.transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.transcript = (trimmed?.isEmpty == false) ? trimmed : nil
        onSave(draft)
        dismiss()
    }
}

struct NotesListSheet: View {
    let roomName: String
    var notes: [RoomAnnotation]
    var onSelect: (RoomAnnotation) -> Void

    var body: some View {
        NavigationStack {
            List {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "note.text",
                        description: Text("Tap Measure or Add a note on the plan or the model.")
                    )
                }
                ForEach(notes) { note in
                    Button {
                        onSelect(note)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.text.isEmpty ? (note.kind == .measurement ? "Measurement" : "Note") : note.text)
                                .foregroundStyle(Theme.ink)
                            HStack(spacing: 8) {
                                if note.kind == .measurement, let measurement = note.measurement {
                                    Text(MeasureSnap.label(from: measurement.start, to: measurement.end))
                                }
                                if note.photo != nil { Image(systemName: "photo") }
                                if note.audio != nil { Image(systemName: "waveform") }
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(roomName)
            .navigationBarTitleDisplayMode(.inline)
            .paperChrome()
        }
    }
}
