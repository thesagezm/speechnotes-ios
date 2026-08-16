import Foundation

/// UI-facing wrapper around the active speech engine. Engines are swappable at
/// runtime from Settings: Apple's system voice, or Kokoro once its model is
/// downloaded (with transparent fallback to system until then).
@MainActor
final class SpeechPlayer: ObservableObject {
    enum EngineKind: String, CaseIterable, Identifiable {
        case system
        case kokoroOnnx
        case kitten

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "Apple (system)"
            case .kokoroOnnx: return "Kokoro (on-device, offline)"
            case .kitten: return "Kitten (experimental — tiny)"
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
            onnxEngine?.voice = voice
        }
    }
    /// Kitten voices live in a separate namespace from Kokoro voices.
    @Published var kittenVoice: String {
        didSet {
            UserDefaults.standard.set(kittenVoice, forKey: "kittenVoice")
            kittenEngine?.voice = kittenVoice
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

    /// Title of the note currently being spoken (drives the mini-player).
    @Published private(set) var nowPlayingTitle: String?
    /// Identity of the note currently being spoken — mini-player taps
    /// navigate to it.
    @Published private(set) var nowPlayingNoteId: UUID?
    /// Codename of the voice an in-picker audition is sampling, if any.
    @Published private(set) var auditioningVoice: String?
    /// Engine/voice to restore when the running audition finishes; nil once
    /// the user makes an explicit selection mid-audition.
    private var preAuditionState: (kind: EngineKind, voice: String, kittenVoice: String)?

    /// True while an audition sample is sounding.
    var isAuditioning: Bool { auditioningVoice != nil }
    /// The compact player bar is shown while real speech is active (never
    /// for picker auditions).
    var showMiniPlayer: Bool {
        (state == .speaking || state == .paused || state == .generating) && !isAuditioning
    }

    /// Friendly description of the voice the active engine will use.
    var currentVoiceDescription: String {
        switch engineKind {
        case .system:
            return "Apple voice"
        case .kokoroOnnx:
            return usingSystemFallback
                ? "Apple voice (model missing)"
                : VoiceCatalog.subtitle(for: voice, kind: .kokoroOnnx)
        case .kitten:
            return usingSystemFallback
                ? "Apple voice (model missing)"
                : VoiceCatalog.subtitle(for: kittenVoice, kind: .kitten)
        }
    }

    private var engine: (any SpeechEngine)?
    private var onnxEngine: OnnxKokoroEngine?
    private var kittenEngine: KittenEngine?
    private var systemEngine: SystemEngine?

    init() {
        let defaults = UserDefaults.standard
        rateMultiplier = defaults.object(forKey: "rateMultiplier") as? Double ?? 1.0
        // v0.6 and earlier also shipped a Metal Kokoro engine ("kokoro");
        // it was removed in v0.7 — carry that preference over to the ONNX engine.
        let storedEngine = defaults.string(forKey: "engineKind")
        if storedEngine == "kokoro" {
            defaults.set(EngineKind.kokoroOnnx.rawValue, forKey: "engineKind")
            engineKind = .kokoroOnnx
        } else {
            engineKind = EngineKind(rawValue: storedEngine ?? "") ?? .system
        }
        voice = defaults.string(forKey: "voice") ?? "am_eric"
        kittenVoice = defaults.string(forKey: "kittenVoice") ?? KittenEngine.defaultVoice
        systemVoiceIdentifier = defaults.string(forKey: "systemVoiceIdentifier")

        rebuildEngine()

        ModelManager.shared.onReady = { [weak self] in
            self?.rebuildEngine()
        }
        Log.shared.info("SpeechPlayer initialised (engine=\(engineKind.rawValue), voice=\(voice), kittenVoice=\(kittenVoice))")
    }

    var activeEngineName: String {
        engine?.name ?? "none"
    }

    private func rebuildEngine() {
        engine?.stop()

        if engineKind == .kitten, ModelManager.shared.kittenIsReady {
            if kittenEngine == nil {
                let kitten = KittenEngine()
                kitten.voice = kittenVoice
                kittenEngine = kitten
            }
            engine = kittenEngine
            usingSystemFallback = false
            Log.shared.info("SpeechPlayer: engine → Kitten (\(kittenVoice))")
        } else if engineKind == .kokoroOnnx, ModelManager.shared.isReady {
            if onnxEngine == nil {
                let onnx = OnnxKokoroEngine()
                onnx.voice = voice
                onnxEngine = onnx
            }
            engine = onnxEngine
            usingSystemFallback = false
            Log.shared.info("SpeechPlayer: engine → Kokoro ONNX (\(voice))")
        } else {
            if systemEngine == nil {
                systemEngine = SystemEngine()
            }
            systemEngine?.voiceIdentifier = systemVoiceIdentifier
            engine = systemEngine
            usingSystemFallback = (engineKind == .kokoroOnnx)
            if usingSystemFallback {
                Log.shared.info("SpeechPlayer: neural engine selected but model missing — system voice in use")
            }
        }

        engine?.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                if newState == .idle {
                    self?.spokenRange = nil
                    self?.nowPlayingTitle = nil
                    self?.nowPlayingNoteId = nil
                    self?.finishAuditionIfActive()
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

    /// Play/pause/stop the note's text. `note` feeds the mini-player's title
    /// and jump-to-note tap; omitting it plays anonymous text.
    func togglePlay(_ text: String, note: Note? = nil) {
        if isAuditioning {
            // A note taking control mid-audition ends the sample first.
            stop()
            return
        }
        switch state {
        case .generating:
            // Tapping during generation cancels it.
            stop()
        case .speaking:
            engine?.pause()
        case .paused:
            engine?.resume()
        case .idle:
            nowPlayingTitle = note?.title
            nowPlayingNoteId = note?.id
            engine?.speak(text, rateMultiplier: rateMultiplier)
        }
    }

    func stop() {
        engine?.stop()
    }

    // MARK: - Voice auditions

    /// Speaks a short sample with a voice WITHOUT committing the selection —
    /// the picker's audition button. Tapping the sounding audition stops it;
    /// engine/voice are restored when the sample ends. No-op while a note is
    /// playing or the engine's model isn't downloaded.
    func audition(voice codename: String) {
        guard state == .idle, !isExporting else { return }
        if auditioningVoice == codename {
            stop()
            return
        }
        let modelReady = engineKind == .kitten
            ? ModelManager.shared.kittenIsReady
            : ModelManager.shared.isReady
        guard modelReady else { return }

        if preAuditionState == nil {
            preAuditionState = (engineKind, voice, kittenVoice)
        }
        if engineKind == .kitten {
            kittenVoice = codename
        } else {
            voice = codename
        }
        auditioningVoice = codename
        let name = VoiceCatalog.shortName(for: codename, kind: engineKind)
        Log.shared.info("SpeechPlayer: auditioning \(codename)")
        engine?.speak(VoiceCatalog.auditionText(for: name), rateMultiplier: 1.0)
    }

    /// An explicit selection made while an audition is still sounding wins:
    /// drop the queued restore (the sample keeps playing to its end).
    func cancelAuditionRestore() {
        preAuditionState = nil
    }

    /// Idle transition hook — restores whatever the audition changed, unless
    /// the user selected a voice mid-audition.
    private func finishAuditionIfActive() {
        guard auditioningVoice != nil else { return }
        if let saved = preAuditionState {
            preAuditionState = nil
            auditioningVoice = nil
            voice = saved.voice
            kittenVoice = saved.kittenVoice
            engineKind = saved.kind
        } else {
            auditioningVoice = nil
        }
    }

    // MARK: - WAV export

    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    func export(_ text: String) {
        guard case .idle = exportState else { return }
        guard usingSystemFallback == false, engineKind != .system else {
            exportState = .failed("Export needs a neural engine — download a Kokoro model in Settings first.")
            return
        }

        stop()
        shareURL = nil
        exportState = .running(0)
        Log.shared.info("SpeechPlayer: exporting note to WAV")

        let progress: (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.isExporting else { return }
                self.exportState = .running(value)
            }
        }
        let finish: (Result<URL, Error>) -> Void = { [weak self] result in
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

        if engineKind == .kitten, let kittenEngine {
            kittenEngine.renderWAV(text: text, onChunkProgress: progress, completion: finish)
        } else if let onnxEngine {
            onnxEngine.renderWAV(text: text, onChunkProgress: progress, completion: finish)
        } else {
            exportState = .failed("No neural engine available — download a model in Settings first.")
        }
    }

    func dismissExportError() {
        if case .failed = exportState { exportState = .idle }
    }
}
