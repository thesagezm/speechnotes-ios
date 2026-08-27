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
    /// User-facing error from the engine (permissions, mic, missing model).
    /// Views show it as an alert; cleared on the next startRecording.
    @Published var lastError: String?
    /// Latest finalized transcript — exposed to the editor for insertion.
    @Published var lastFinalText: String = ""

    private var engine: STTEngine?
    private var lastWhisperModelId: String?
    private var timer: Timer?
    private var startedAt: Date?

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

    /// Start recording once the engine's model is actually loaded. WhisperKit
    /// model load is async; calling engine.start() before it resolves used to
    /// fail silently ("model isn't loaded") on the very first tap after a
    /// fresh download or cold start.
    func startRecording(language: String? = nil) {
        guard state == .idle else { return }
        rebuildEngine()
        lastError = nil
        lastFinalText = ""
        partialText = ""
        state = .recording
        startedAt = Date()
        startTimer()
        if let whisper = engine as? WhisperCppEngine {
            state = .transcribing                      // "Loading model…" UX
            Task { @MainActor in
                await whisper.waitUntilLoaded()
                guard self.state == .transcribing else { return }   // user cancelled
                self.state = .recording
                whisper.start(language: language, prompt: nil)
            }
        } else {
            engine?.start(language: language, prompt: nil)
        }
    }

    private func rebuildEngine() {
        // Reconcile the engine with the CURRENT selection: the Apple engine
        // is cheap to rebuild; the Whisper engine only when the model id
        // actually changed (WhisperKit reload is expensive).
        switch engineKind {
        case .apple:
            engine = AppleSTTEngine()
        case .whisper:
            if !(engine is WhisperCppEngine) || lastWhisperModelId != whisperModels.activeModelId {
                lastWhisperModelId = whisperModels.activeModelId
                engine = WhisperCppEngine(modelId: whisperModels.activeModelId)
            }
        }
        wireEngineCallbacks()
    }

    private func wireEngineCallbacks() {
        engine?.onPartial = { [weak self] text in
            self?.hopToMain { self?.partialText = text }
        }
        engine?.onFinal = { [weak self] text in
            self?.hopToMain {
                self?.partialText = ""
                self?.lastFinalText = text
                self?.state = .idle
                self?.stopTimer()
            }
        }
        engine?.onStateChanged = { [weak self] s in
            self?.hopToMain { self?.state = s }
        }
        engine?.onError = { [weak self] message in
            self?.hopToMain {
                self?.lastError = message
                self?.stopTimer()
            }
        }
    }

    /// Engine callbacks arrive from mixed threads. When already on main (the
    /// common case — stop() is UI-driven and the Apple engine synthesizes its
    /// final synchronously) run the handler NOW instead of next runloop tick,
    /// so callers that stop and immediately consume the transcript see it.
    private func hopToMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }

    func stopRecording() {
        engine?.stop()
        state = .idle
        stopTimer()
        // NOTE: partialText is intentionally NOT cleared here. The Apple
        // engine delivers its final synchronously from stop(); Whisper's
        // final lands a moment later — until then the visible partial IS the
        // transcript, and consumeFinalOrPartial() uses it as the fallback.
    }

    /// Returns the session transcript: the engine final when it has arrived,
    /// otherwise the last visible partial (the complete text for Whisper —
    /// its partials cover the whole session). Clears both. The editor's
    /// "insert at cursor" and the tab's "Save as note" both go through this.
    func consumeFinalOrPartial() -> String {
        let final = lastFinalText
        lastFinalText = ""
        let text = final.isEmpty ? partialText : final
        partialText = ""
        return text
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

        importProgress = 0.1
        let samples = try await AudioImportService.samples(from: url)
        importProgress = 0.3
        importProgressLabel = "Running transcription…"
        let text = try await engine.transcribeFile(samples: samples, language: language) { [weak self] value in
            Task { @MainActor in
                self?.importProgress = 0.3 + value * 0.7
            }
        }
        importProgress = 1.0
        importProgressLabel = "Done"
        return text
    }

    /// Shared STT language catalog — one list for all pickers so a choice
    /// made in Settings shows up in the sheet and tab identically.
    static let languages: [(code: String, label: String)] = [
        ("auto", "Auto"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("ja-JP", "Japanese"),
        ("zh-CN", "Chinese"),
    ]

    /// Rebuild the engine after each timer tick from wall-clock time, not
    /// from accumulated ticks — Timer slack (50–100 ms on iOS) otherwise
    /// makes the readout drift long.
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
    }
}
