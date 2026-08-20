import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: STTState = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levelMeter: Float = 0

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
    @ObservedObject private var whisperModels = WhisperModelManager.shared
    /// Latest finalized transcript — exposed to the editor for insertion.
    @Published var lastFinalText: String = ""

    private var engine: STTEngine?
    private var timer: Timer?

    init() {
        rebuildEngine()
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

    /// Phase 0 no-op. Phase 1 starts AVAudioEngine + engine.start()
    func startRecording(language: String? = nil) {
        guard state == .idle else { return }
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
    func transcribeAudioFile(at url: URL, language: String? = nil) async throws -> String {
        guard let engine else { return "" }
        state = .transcribing
        defer { state = .idle }
        return try await AudioImportService.shared.transcribe(url, language: language, engine: engine)
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
