import AVFoundation
import OnnxRuntimeBindings

/// Supertonic engine (Supertone supertonic-3): flow-matching TTS over 4 ONNX
/// sessions, CPU-only, driven entirely by the vendored upstream Helper.swift
/// (loadTextToSpeech / loadVoiceStyle / TextToSpeech.call — see
/// Docs/SUPERTONIC-PORT.md). 31 languages via the unicode indexer (no G2P),
/// 10 voice styles (M1–M5 male, F1–F5 female), native speed control through
/// the duration predictor.
///
/// All pipeline machinery lives in StreamingTTSPlaybackCore (shared with
/// OnnxKokoroEngine); this class contributes model loading + synthesis,
/// confined to the core's generateQueue. The sample rate comes from tts.json
/// at load and is published to the core before the first buffer is built.
final class SupertonicEngine: NSObject, SpeechEngine {
    let name = "Supertonic (CPU)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    /// Play-time position (see SpeechEngine.onPlayedChars).
    var onPlayedChars: ((Int) -> Void)?
    /// Natural completion (see SpeechEngine.onFinished).
    var onFinished: (() -> Void)?

    /// Voice style id — one of ModelManager.supertonicVoices ("M1"…"F5").
    var voice = "M1"
    /// ISO language code (AVAILABLE_LANGS in Helper.swift); "en" default.
    var lang = "en"

    /// Live rate — forwarded to the core so the NEXT chunk reflects a
    /// slider change without a restart (duration predictor takes speed).
    var speed: Float {
        get { core.speed }
        set { core.speed = newValue }
    }

    /// Upstream ExampleONNX default — 8 denoising steps.
    private static let totalStep = 8
    /// Supertonic's own chunker accepts up to 300 chars for non-CJK; our
    /// sentence chunks stay a bit tighter for responsiveness.
    private static let chunkMaxChars = 200

    private let core: StreamingTTSPlaybackCore

    /// How many times `speak()` has validated on this instance — the first is
    /// always logged, later ones only when they get slow. Main thread only
    /// (every `speak()` call is), like the rest of the engine's non-model state.
    private var validationCalls = 0

    /// True once sessions were actually loaded this instance — the idle
    /// unload only pays off when there's something resident to free.
    var hasLoadedModel: Bool { modelLoadAttempted }

    // Model state — the core's generateQueue only.
    private var ortEnv: ORTEnv?
    private var tts: TextToSpeech?
    private var styles: [String: Style] = [:]
    private var modelLoadAttempted = false

    override init() {
        self.core = StreamingTTSPlaybackCore(config: .init(
            sampleRate: 24_000, // provisional; tts.json's value is published at load
            chunkMaxChars: Self.chunkMaxChars,
            generationAheadLimit: 2,
            exportInterChunkSilence: 0.05,
            logPrefix: "SupertonicEngine"
        ))
        super.init()

        core.isModelReady = { [weak self] in
            guard let self else { return false }
            self.loadModelIfNeeded()
            return self.tts != nil
        }
        core.generateChunk = { [weak self] text in
            guard let self else { throw StreamingCoreError.notConfigured }
            return try self.generateChunk(text)
        }
        core.onStateChanged = { [weak self] state in self?.onStateChanged?(state) }
        core.onProgress = { [weak self] progress in self?.onProgress?(progress) }
        core.onPlayedChars = { [weak self] chars in self?.onPlayedChars?(chars) }
        core.onFinished = { [weak self] in self?.onFinished?() }
    }

    // MARK: - Model loading (generateQueue)

    private func loadModelIfNeeded() {
        guard !modelLoadAttempted else { return }

        guard ModelManager.supertonicFilesAreValid() else {
            Log.shared.error("SupertonicEngine: model files missing or invalid at \(ModelManager.supertonicDirectory.path)")
            return
        }

        do {
            let started = Date()
            let env = try ORTEnv(loggingLevel: .warning)
            let textToSpeech = try loadTextToSpeech(ModelManager.supertonicOnnxDirectory.path, false, env)
            ortEnv = env
            tts = textToSpeech
            core.setSampleRate(Double(textToSpeech.sampleRate))

            // Each style must carry batch dim 1 (loadVoiceStyle sizes the
            // tensors to the number of paths it's given), so one call per voice.
            for voice in ModelManager.supertonicVoices {
                let path = ModelManager.supertonicStyleFileURL(voice: voice).path
                styles[voice] = try loadVoiceStyle([path], verbose: false)
            }
            Log.shared.info("SupertonicEngine: 4 sessions + \(styles.count) styles loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (\(textToSpeech.sampleRate) Hz)")
            // Only latch AFTER success — a transient load failure (jettison
            // mid-load, file lock) used to brick the engine until relaunch.
            modelLoadAttempted = true
        } catch {
            tts = nil
            styles = [:]
            Log.shared.error("SupertonicEngine: model load failed: \(error) — will retry on next speak")
        }
    }

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // Timed because it sits upstream of TTFA's t0 — see PlaybackMetrics.
        // Supertonic's check is the heavier of the two: one `attributesOfItem`
        // per model file across four ONNX sessions.
        let logIt = validationCalls == 0
        validationCalls += 1
        let filesValid = PlaybackMetrics.timedValidation(
            prefix: core.config.logPrefix,
            label: "play-path file validation",
            alwaysLog: logIt
        ) { ModelManager.supertonicFilesAreValid() }
        guard filesValid else {
            Log.shared.error("SupertonicEngine asked to speak but its model isn't downloaded")
            return
        }
        guard isValidLang(lang) else {
            Log.shared.error("SupertonicEngine: unsupported language \(lang)")
            return
        }
        core.speak(text, rateMultiplier: rateMultiplier)
    }

    func pause() { core.pause() }
    func resume() { core.resume() }
    func stop() { core.stop() }

    // MARK: - Synthesis (generateQueue)

    /// One Helper `call` per sentence chunk. `call`'s own internal chunker
    /// sees a short string and runs a single inference; the returned wav is
    /// padded, so it's trimmed to the predicted duration. The live speed is
    /// read per chunk from the core, so slider changes apply from the next
    /// sentence.
    private func generateChunk(_ text: String) throws -> [Float] {
        guard let tts else { throw SupertonicEngineError.modelUnavailable }
        guard let style = styles[voice] ?? styles.values.first else {
            throw SupertonicEngineError.noVoices
        }
        let started = Date()
        let result = try tts.call(text, lang, style, Self.totalStep, speed: core.speed, silenceDuration: 0.05)
        let actualLen = Int(Float(tts.sampleRate) * result.duration)
        guard actualLen > 0, result.wav.count >= actualLen else {
            throw SupertonicEngineError.noOutput
        }
        let duration = Double(actualLen) / core.sampleRate
        Log.shared.info("SupertonicEngine: \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", Date().timeIntervalSince(started)))s (\(voice), \(lang))")
        return Array(result.wav.prefix(actualLen))
    }

    // MARK: - WAV export

    func renderWAV(
        text: String,
        title: String? = nil,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard ModelManager.supertonicFilesAreValid(), isValidLang(lang) else {
            completion(.failure(SupertonicEngineError.modelUnavailable))
            return
        }
        core.renderWAV(text: text, title: title, onChunkProgress: onChunkProgress, completion: completion)
    }
}

/// User-facing failures for the Supertonic path.
enum SupertonicEngineError: LocalizedError {
    case modelUnavailable
    case noVoices
    case noOutput
    case emptyText

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "The Supertonic model isn't downloaded or failed to load."
        case .noVoices: return "No voice styles available — re-download the Supertonic model."
        case .noOutput: return "Supertonic returned no audio for this chunk."
        case .emptyText: return "The note is empty."
        }
    }
}
