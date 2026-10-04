import AVFoundation
import OnnxRuntimeBindings
import SpeechLogic

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

    /// Supertonic's own chunker accepts up to 300 chars for non-CJK; our
    /// sentence chunks stay a bit tighter for responsiveness.
    private static let chunkMaxChars = 200
    /// Thermal-driven render-ahead policy — Batch B. The bank (targets,
    /// byte cap) lives in the core; the engine reads the same policy for the
    /// denoising step count: 8 upstream default, 4 under thermal pressure
    /// (the device log measured RTF 0.48 at nominal but 1.68 at critical —
    /// past 1.0 the model cannot keep real time, and halving the steps is
    /// the lever that halves per-chunk work). Duration comes from the
    /// duration predictor, not the step count, so pacing arithmetic is
    /// unaffected.
    private let bankPolicy = RenderAheadBankPolicy()

    private let core: StreamingTTSPlaybackCore

    /// How many times `validationResult()` ran the filesystem walk on this
    /// instance — the first is always logged, later ones only when they get
    /// slow. Main thread only (every `speak()`/export call is).
    private var validationCalls = 0
    /// Cached `supertonicFilesAreValid()` + monotonic stamp; success latches
    /// for 30 s (16 `attributesOfItem` syscalls live upstream of TTFA's t0,
    /// and no play path changes the model files). Failure is never latched —
    /// a transient blip must not brick the engine (R7).
    private var lastValidationResult: Bool?
    private var lastValidationAt: ContinuousClock.Instant?
    private static let validationTTL: TimeInterval = 30

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
            // Round 6 device log: a 155-char first chunk rendered 15.3 s
            // (TTFA 15.4 s) while an 11-char opener was 1.7 s. Cap the first
            // chunk so speech starts fast; the rest stay full-size.
            firstMaxChars: 60,
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
        // Validation sits upstream of TTFA's t0; the result is cached for
        // `validationTTL` so an eight-chunk layout doesn't re-stat all file
        // sizes on every play tap (R19).
        guard validationResult() else {
            Log.shared.error("SupertonicEngine asked to speak but its model isn't downloaded")
            return
        }
        guard isValidLang(lang) else {
            Log.shared.error("SupertonicEngine: unsupported language \(lang)")
            return
        }
        core.speak(text, rateMultiplier: rateMultiplier)
    }

    /// Timed validation, TTL-cached (see the property comment).
    private func validationResult() -> Bool {
        if let cached = lastValidationResult, cached,
           let stamp = lastValidationAt,
           PlaybackMetrics.seconds(since: stamp) < Self.validationTTL {
            return true
        }
        let logIt = validationCalls == 0
        validationCalls += 1
        let filesValid = PlaybackMetrics.timedValidation(
            prefix: core.config.logPrefix,
            label: "play-path file validation",
            alwaysLog: logIt
        ) { ModelManager.supertonicFilesAreValid() }
        if filesValid {
            lastValidationResult = true
            lastValidationAt = ContinuousClock.now
        }
        return filesValid
    }

    func pause() { core.pause() }
    func resume() { core.resume() }
    func stop() { core.stop() }

    /// Core liveness — see SpeechEngine.hasLiveSession (the player's wedge
    /// self-heal reads it).
    var hasLiveSession: Bool { core.hasLiveSession }

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
        // Per-chunk thermal read: the step count tracks the CURRENT state, so
        // a session that heats up mid-chapter sheds model work within one
        // chunk instead of running the RTF climb the Batch A log recorded.
        let thermal = ThermalPressure(
            thermalStateRawValue: ProcessInfo.processInfo.thermalState.rawValue)
        let step = bankPolicy.totalStep(for: thermal)
        let result = try tts.call(text, lang, style, step, speed: core.speed, silenceDuration: 0.05)
        let predictedLen = Int(Float(tts.sampleRate) * result.duration)
        if predictedLen <= 0 {
            // The duration predictor returned nothing usable — log the text so
            // a device report pinpoints the input instead of a bare skip.
            Log.shared.error("SupertonicEngine: duration predictor returned \(result.duration)s for «\(text.prefix(60))»")
            throw SupertonicEngineError.noOutput
        }
        // The vocoder's output is quantized to the latent chunk size and can
        // come back a few hundred samples SHORT of the predicted length; the
        // first device round turned that into ~20% skipped sentences. Trim to
        // whatever actually came back — shorter audio beats no audio.
        let playableLen = min(predictedLen, result.wav.count)
        guard playableLen > 0 else {
            throw SupertonicEngineError.noOutput
        }
        let duration = Double(playableLen) / core.sampleRate
        // Thermal throttling is the prime suspect whenever the RTF climbs
        // WITHIN a session (0.5 → 5.3 on device, recovered next chunk); the
        // step count rides along in the line so a device log shows whether
        // Batch B's 8→4 shed was active when a slow chunk happened.
        Log.shared.info("SupertonicEngine: \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", Date().timeIntervalSince(started)))s (\(voice), \(lang), thermal \(thermal), steps \(step))")
        return Array(result.wav.prefix(playableLen))
    }

    // MARK: - WAV export

    func renderWAV(
        text: String,
        title: String? = nil,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard validationResult(), isValidLang(lang) else {
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
