import AVFoundation
import Foundation
import Speech

/// Records a voice note, plays it back, and transcribes it on the device in Swedish or English.
@MainActor
final class VoiceNoteRecorder: ObservableObject {
    @Published var recording = false
    @Published var playing = false
    @Published var localeID: String
    @Published var message: String?
    @Published private(set) var hasAudio = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var playbackDelegate: PlaybackEnder?
    private var fileURL: URL?
    private var task: SFSpeechRecognitionTask?

    init() {
        let code = Locale.current.language.languageCode?.identifier
        localeID = code == "sv" ? "sv-SE" : "en-US"
    }

    func load(data: Data) {
        stopPlayback()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
            hasAudio = true
        } catch {
            message = "Could not open that recording."
        }
    }

    func audioData() -> Data? {
        guard let fileURL else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func togglePlayback() {
        if playing {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    func discard() {
        stopRecording()
        stopPlayback()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        hasAudio = false
    }

    func transcribe(into transcript: @escaping (String) -> Void) {
        guard let fileURL, hasAudio else {
            message = "Record a voice note first."
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.message = "Speech recognition is off. The recording stays on this iPhone."
                    return
                }
                self.recognize(url: fileURL, into: transcript)
            }
        }
    }

    private func startRecording() {
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            fileURL = url
            recording = true
            hasAudio = false
            message = nil
        } catch {
            message = "The microphone could not start."
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        recording = false
        hasAudio = fileURL != nil
    }

    private func startPlayback() {
        guard let fileURL, !recording else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            let ender = PlaybackEnder { [weak self] in
                Task { @MainActor in self?.playing = false }
            }
            player.delegate = ender
            playbackDelegate = ender
            player.play()
            self.player = player
            playing = true
        } catch {
            message = "Could not play that recording."
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playbackDelegate = nil
        playing = false
    }

    private func recognize(url: URL, into transcript: @escaping (String) -> Void) {
        task?.cancel()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            message = "That language is not available on this iPhone."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            message = "Download the on-device \(localeID == "sv-SE" ? "Swedish" : "English") speech model, then try again."
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        message = "Transcribing on this iPhone…"
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let finished = result?.isFinal == true
            let failed = error != nil && text == nil
            Task { @MainActor in
                if let text, finished || !text.isEmpty {
                    transcript(text)
                    if finished { self.message = nil }
                } else if failed {
                    self.message = "Could not transcribe that recording on this device."
                }
            }
        }
    }
}

private final class PlaybackEnder: NSObject, AVAudioPlayerDelegate {
    var onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
