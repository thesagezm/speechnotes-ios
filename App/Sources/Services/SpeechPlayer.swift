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

    /// True when Kokoro is selected but its model isn't downloaded yet —
    /// the system engine is used in the meantime.
    private(set) var usingSystemFallback = false

    private var engine: (any SpeechEngine)?
    private var kokoroEngine: KokoroEngine?
    private var systemEngine: SystemEngine?

    init() {
        let defaults = UserDefaults.standard
        rateMultiplier = defaults.object(forKey: "rateMultiplier") as? Double ?? 1.0
        engineKind = EngineKind(rawValue: defaults.string(forKey: "engineKind") ?? "") ?? .system
        voice = defaults.string(forKey: "voice") ?? "am_eric"

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
            engine = systemEngine
            usingSystemFallback = (engineKind == .kokoro)
            if usingSystemFallback {
                Log.shared.info("SpeechPlayer: Kokoro selected but model missing — system voice in use")
            }
        }

        engine?.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
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
}
