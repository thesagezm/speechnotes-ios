import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: STTState = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levelMeter: Float = 0
    /// 0…1 while the engine is processing a non-live request (audio file
    /// import). nil otherwise.
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressLabel: String = ""

    enum EngineKind: String, CaseIterable, Identifiable {
        case apple
        case whisper

        var id: String { rawValue }
        var label: String {
            switch self {
            case .apple: return "Apple (built-in)"
            case .whisper: return "Whisper (offline)"
            }
        }
    }

    @AppStorage("sttEngineKind") var engineKind: EngineKind = .apple
    @AppStorage("sttLanguage") var languageHint: String = "auto"
    @ObservedObject private var whisperModels = WhisperModelManager.shared
    /// Latest finalized transcript — exposed to the editor for insertion.
    @Published var lastFinalText: String = ""

    private var engine: STTEngine?
    private var timer: Timer?

    init() {
        rebuildEngine()
        NotificationCenter.default.addObserver(
            self, selector: #selector(whisperModelDidBecomeReady),
            name: .whisperModelReady, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func whisperModelDidBecomeReady() {
        Task { @MainActor in self.rebuildEngine() }
    }

    private func rebuildEngine() {
        switch engineKind {
        case .apple:
            engine = AppleSTTEngine()
        case .whisper:
            engine = WhisperCppEngine(modelId: whisperModels.activeModelId)
        }
        engine?.onPartial = { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        engine?.onFinal = { [weak self] text in
            Task { @MainActor in
                self?.partialText = ""
                self?.lastFinalText = text
                self?.state = .idle
                self?.stopTimer()
            }
        }
        engine?.onStateChanged = { [weak self] s in
            Task { @MainActor in self?.state = s }
        }
    }

    func startRecording(language: String? = nil) {
        guard state == .idle else { return }
        // The previous Apple engine could be torn down here; rebuild for
        // each session so the SFSpeechRecognizer picks up the latest
        // language/voice preferences.
        if engineKind == .apple { rebuildEngine() }
        state = .recording
        startTimer()
        engine?.start(language: language, prompt: nil)
    }

    func stopRecording() {
        engine?.stop()
        state = .idle
        partialText = ""
        stopTimer()
    }

    /// Editor consumes the last finalized text and clears it.
    func consumeFinal() -> String {
        let t = lastFinalText
        lastFinalText = ""
        return t
    }

    /// File-import transcription (audio recordings dropped into the app).
    /// Publishes `importProgress` so the UI can show a real progress bar
    /// while WhisperKit streams partial results.
    func transcribeAudioFile(at url: URL, language: String? = nil) async throws -> String {
        guard let engine else { return "" }
        state = .transcribing
        importProgress = 0
        importProgressLabel = "Decoding audio…"
        defer {
            state = .idle
            importProgress = nil
            importProgressLabel = ""
        }

        let progress: @Sendable (Double, String) -> Void = { [weak self] value, label in
            Task { @MainActor in
                self?.importProgress = value
                self?.importProgressLabel = label
            }
        }
        progress(0.1, "Decoding audio…")
        let samples = try await AudioImportService.samples(from: url)
        progress(0.3, "Running transcription…")
        let text = try await AudioImportService.shared.runTranscription(
            samples: samples, language: language, engine: engine, progress: { value in
                Task { @MainActor in self.importProgress = 0.3 + value * 0.7 }
            }
        )
        progress(1.0, "Done")
        return text
    }

    var currentEngine: STTEngine? { engine }

    private func startTimer() {
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsed += 0.1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
    }
}
