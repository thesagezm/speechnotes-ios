import Foundation

/// UI-facing wrapper around the active speech engine. Engines are swappable at
/// runtime from Settings: Apple's system voice, or Kokoro once its model is
/// downloaded (with transparent fallback to system until then).
@MainActor
final class SpeechPlayer: ObservableObject {
    enum EngineKind: String, CaseIterable, Identifiable {
        case system
        case kokoro

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "Apple (system)"
            case .kokoro: return "Kokoro (on-device)"
            }
        }
    }

    @Published private(set) var state: SpeechState = .idle
    /// Speech progress 0…1 (chunk-granular) while speaking; nil otherwise.
    @Published private(set) var progress: Double?
    /// UTF-16 range of the source text currently being spoken (read-along
    /// highlighting); nil when idle.
    @Published private(set) var spokenRange: Range<Int>?
    @Published var rateMultiplier: Double {
        didSet { UserDefaults.standard.set(rateMultiplier, forKey: "rateMultiplier") }
    }
    @Published var engineKind: EngineKind {
        didSet {
            UserDefaults.standard.set(engineKind.rawValue, forKey: "engineKind")
            rebuildEngine()
        }
    }
    @Published var voice: String {
        didSet {
            UserDefaults.standard.set(voice, forKey: "voice")
            kokoroEngine?.voice = voice
        }
    }
    /// Identifier of the `AVSpeechSynthesisVoice` the system engine should
    /// use (Settings → System voice); nil = Apple's default en-US voice.
    /// Persisted, and forwarded to the engine so a change applies to the
    /// next utterance.
    @Published var systemVoiceIdentifier: String? {
        didSet {
            if let identifier = systemVoiceIdentifier {
                UserDefaults.standard.set(identifier, forKey: "systemVoiceIdentifier")
            } else {
                UserDefaults.standard.removeObject(forKey: "systemVoiceIdentifier")
            }
            systemEngine?.voiceIdentifier = systemVoiceIdentifier
        }
    }

    /// True when Kokoro is selected but its model isn't downloaded yet —
    /// the system engine is used in the meantime.
    private(set) var usingSystemFallback = false

    enum ExportState: Equatable {
        case idle
        case running(Double)
        case failed(String)
    }

    @Published private(set) var exportState: ExportState = .idle
    /// Set when a WAV export succeeds — the editor presents the share sheet
    /// and clears this when it dismisses.
    @Published var shareURL: URL?

    private var engine: (any SpeechEngine)?
    private var kokoroEngine: KokoroEngine?
    private var systemEngine: SystemEngine?

    init() {
        let defaults = UserDefaults.standard
        rateMultiplier = defaults.object(forKey: "rateMultiplier") as? Double ?? 1.0
        engineKind = EngineKind(rawValue: defaults.string(forKey: "engineKind") ?? "") ?? .system
        voice = defaults.string(forKey: "voice") ?? "am_eric"
        systemVoiceIdentifier = defaults.string(forKey: "systemVoiceIdentifier")

        rebuildEngine()

        ModelManager.shared.onReady = { [weak self] in
            self?.rebuildEngine()
        }
        Log.shared.info("SpeechPlayer initialised (engine=\(engineKind.rawValue), voice=\(voice))")
    }

    var activeEngineName: String {
        engine?.name ?? "none"
    }

    private func rebuildEngine() {
        engine?.stop()

        if engineKind == .kokoro, ModelManager.shared.isReady {
            if kokoroEngine == nil {
                let kokoro = KokoroEngine()
                kokoro.voice = voice
                kokoroEngine = kokoro
            }
            engine = kokoroEngine
            usingSystemFallback = false
            Log.shared.info("SpeechPlayer: engine → Kokoro (\(voice))")
        } else {
            if systemEngine == nil {
                systemEngine = SystemEngine()
            }
            systemEngine?.voiceIdentifier = systemVoiceIdentifier
            engine = systemEngine
            usingSystemFallback = (engineKind == .kokoro)
            if usingSystemFallback {
                Log.shared.info("SpeechPlayer: Kokoro selected but model missing — system voice in use")
            }
        }

        engine?.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                if newState == .idle {
                    self?.spokenRange = nil
                }
            }
        }
        engine?.onProgress = { [weak self] value in
            Task { @MainActor in
                self?.progress = value > 0 ? value : nil
            }
        }
        engine?.onSpokenRange = { [weak self] offset, length in
            Task { @MainActor in
                self?.spokenRange = offset >= 0 && length > 0 ? offset..<(offset + length) : nil
            }
        }
    }

    func togglePlay(_ text: String) {
        switch state {
        case .generating:
            // Tapping during generation cancels it.
            stop()
        case .speaking:
            engine?.pause()
        case .paused:
            engine?.resume()
        case .idle:
            engine?.speak(text, rateMultiplier: rateMultiplier)
        }
    }

    func stop() {
        engine?.stop()
    }

    // MARK: - WAV export

    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    func export(_ text: String) {
        guard case .idle = exportState else { return }
        guard let kokoroEngine else {
            exportState = .failed("Export needs the Kokoro engine — download the model in Settings first.")
            return
        }

        stop()
        shareURL = nil
        exportState = .running(0)
        Log.shared.info("SpeechPlayer: exporting note to WAV")

        kokoroEngine.renderWAV(
            text: text,
            onChunkProgress: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.isExporting else { return }
                    self.exportState = .running(value)
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let url):
                        self.shareURL = url
                        self.exportState = .idle
                    case .failure(let error):
                        self.exportState = .failed(error.localizedDescription)
                    }
                }
            }
        )
    }

    func dismissExportError() {
        if case .failed = exportState { exportState = .idle }
    }
}
