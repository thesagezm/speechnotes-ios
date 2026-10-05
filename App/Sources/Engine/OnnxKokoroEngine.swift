import AVFoundation
import MisakiSwift
import MLX
import MLXUtilsLibrary
import OnnxRuntimeBindings

/// Kokoro via ONNX Runtime on the CPU — fp32 `model.onnx` (~326 MB) or the
/// small uint8 tier `model_uint8.onnx` (~177 MB — same graph), plus the
/// shared tokenizer.json/voices.npz in Documents/KokoroOnnx. Inference spec
/// (verified against PocketPal's react-native-speech engine): inputs
/// `input_ids` int64 [1, N], `style` float32 [1, 256] (flat voice array
/// sliced at clamp(N-1, 0, 509) * 256 — Batch B2), `speed` float32 [1];
/// output `waveform` float32 @ 24 kHz. The model takes speed natively, so
/// playback is a plain player node — no time-pitch gymnastics.
///
/// All pipeline machinery (chunking, bounded generation-ahead pacing,
/// scheduling, play-time position tracking, retries, WAV export, audio
/// session + interruption handling) lives in StreamingTTSPlaybackCore; this
/// class contributes model loading and synthesis, confined to the core's
/// generateQueue.
final class OnnxKokoroEngine: NSObject, SpeechEngine {
    let name = "Kokoro ONNX (CPU)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    /// Play-time position (see SpeechEngine.onPlayedChars).
    var onPlayedChars: ((Int) -> Void)?
    /// Natural completion (see SpeechEngine.onFinished).
    var onFinished: (() -> Void)?

    var voice = "am_eric"

    /// Live rate — forwarded to the core so the NEXT chunk reflects a
    /// slider change without a restart (the model takes speed natively).
    var speed: Float {
        get { core.speed }
        set { core.speed = newValue }
    }

    /// Which model file + validator this instance serves — the fp32 tier and
    /// the small uint8 tier share one engine class.
    private let modelFileURL: URL
    private let modelFilesValid: () -> Bool

    /// How many times `validationResult()` ran the filesystem walk on this
    /// instance — the first is always logged, later ones only when they get
    /// slow. Main thread only (every `speak()`/export call is).
    private var validationCalls = 0
    /// Cached `modelFilesValid()` result + monotonic stamp. Success is
    /// latched for `validationTTL`; the expensive part of Kokoro's check is
    /// reading + JSON-parsing `tokenizer.json` (~3.5 KB) on EVERY play tap —
    /// every tap is pure TTFA overhead for a result that cannot change
    /// between two plays (nothing the user can do rewrites the files).
    /// Failure is never latched: a transient file-lock or memory-pressure
    /// blip must not disable playback like the old `modelLoadAttempted`
    /// latch (R7). *Maximum-cost* cap: a file landing mid-TTL is picked up
    /// within this window; ModelManager's onReady rebuilds the engine
    /// anyway, which clears the cache.
    private var lastValidationResult: Bool?
    private var lastValidationAt: ContinuousClock.Instant?
    private static let validationTTL: TimeInterval = 30

    private let core: StreamingTTSPlaybackCore

    private static let styleDim = 256
    private static let maxTokens = 510
    private static let chunkMaxChars = 160

    /// Tier name for the log line (Batch A3). Matched on the FILE, not on a
    /// flag the caller set, so a mistagged tier would have to be a
    /// consistently wrong filename.
    static func tierName(for url: URL) -> String {
        url.lastPathComponent == "model_uint8.onnx" ? "kokoro-small-uint8" : "kokoro-fp32"
    }

    // Model state — the core's generateQueue only.
    private var ortEnv: ORTEnv?
    private var ortSession: ORTSession?
    /// Model output tensor name — "waveform" on most exports, but some name
    /// it "audio"; resolved from the session at load (PocketPal accepts both).
    private var outputName: String = "waveform"
    private var vocab: [String: Int] = [:]
    private var voicesFlat: [String: [Float]] = [:]
    private var g2pAmerican: EnglishG2P?
    private var g2pBritish: EnglishG2P?
    private var modelLoadAttempted = false

    /// Batch B1's drop accounting. generateQueue-confined, never read off it
    /// — the values only feed the engine's own log lines.
    private var totalDroppedPhonemes = 0
    private var lastLoggedDropCount = -1

    init(
        modelFileURL: URL = ModelManager.onnxModelFileURL,
        modelFilesValid: @escaping () -> Bool = { ModelManager.onnxFilesAreValid() },
        /// Which tier this instance serves — printed on every session line
        /// (Batch A3). Derived from the file so the two instances cannot
        /// disagree with the file they were built for.
        tier: String? = nil
    ) {
        self.modelFileURL = modelFileURL
        self.modelFilesValid = modelFilesValid
        self.core = StreamingTTSPlaybackCore(config: .init(
            sampleRate: 24_000,
            chunkMaxChars: Self.chunkMaxChars,
            // Fast-start first chunk: render a short opener now, and the
            // NEXT chunk packs to the full 160-char batch ceiling while it
            // sounds — chunk 0 covers chunk 1's generation instead of
            // exposing it. SentenceChunker keeps the 510-token ceiling via
            // `batchMaxChars`; this only re-opens the v0.4 fast-start.
            //
            // Batch B3: this is `RTF · c1` with RTF assumed at 0.53
            // (TTS_BASELINE §2). Batch A3 now prints the real RTF per tier on
            // every session, so the first device session settles this number
            // and the constant gets retuned from a measurement. If measured
            // RTF ≥ 1.0 the fast-start premise is dead — no legal
            // `firstMaxChars` reaches break-even against a 160-char
            // `chunkMaxChars` — and the bounded prebuffer gate becomes the
            // primary fix instead. The two exist side by side for now, and
            // the constant is left at its measured-reasonable value.
            firstMaxChars: 100,
            exportInterChunkSilence: 0,
            logPrefix: "OnnxKokoroEngine",
            tier: tier ?? Self.tierName(for: modelFileURL)
        ))
        super.init()

        core.isModelReady = { [weak self] in
            guard let self else { return false }
            self.loadModelIfNeeded()
            return self.ortSession != nil
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

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard validationResult() else {
            Log.shared.error("OnnxKokoroEngine asked to speak but no ONNX model is downloaded")
            return
        }
        core.speak(text, rateMultiplier: rateMultiplier)
    }

    /// Timed validation, TTL-cached. See the property comment for the
    /// success-only latch and why this sits upstream of TTFA's t0.
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
        ) { self.modelFilesValid() }
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

    /// True once the model was actually loaded this instance — only then is
    /// there anything resident to free (mirrors SupertonicEngine).
    var hasLoadedModel: Bool { modelLoadAttempted }

    // MARK: - Model loading (generateQueue)

    private func loadModelIfNeeded() {
        guard !modelLoadAttempted else { return }

        let modelPath = modelFileURL
        let tokenizerPath = ModelManager.onnxTokenizerFileURL
        guard FileManager.default.fileExists(atPath: modelPath.path),
              FileManager.default.fileExists(atPath: tokenizerPath.path) else {
            Log.shared.error("OnnxKokoroEngine: model files missing at \(modelPath.deletingLastPathComponent().path)")
            return
        }

        do {
            let started = Date()
            let env = try ORTEnv(loggingLevel: .warning)
            // Batch C1. The only option set used to be
            // `setIntraOpNumThreads(4)` — a fixed number, regardless of the
            // device, and nothing else.
            //
            // The thread count is now `min(activeProcessorCount, 6)`:
            // on the A-series this lands at 4–6 rather than 4, and it stops
            // pinning a 6-core Pro at half its width while leaving a 2-core
            // SE oversubscribed. Six is the ceiling because the render
            // thread needs headroom for the main thread's scheduling, and
            // Kokoro's graph is intra-op-shaped enough that more than six
            // buys nothing.
            //
            // Two options from the brief are NOT set, because the pinned
            // binding does not expose them. onnxruntime-swift-package-manager
            // 1.24.2's `ORTSessionOptions` declares exactly:
            // setIntraOpNumThreads, setGraphOptimizationLevel,
            // setOptimizedModelFilePath, setLogID, setLogSeverityLevel,
            // addConfigEntry, registerCustomOpsUsingFunction,
            // enableOrtExtensionsCustomOps. There is no
            // setInterOpNumThreads and no setIntraOpAllowSpinning, so
            // spinning cannot be switched off and the thermal-headroom
            // argument for it is recorded as an open item, not a change.
            // Inter-op is already 1 by ORT's default, which is what the brief
            // asked for anyway.
            let options = try ORTSessionOptions()
            let cores = ProcessInfo.processInfo.activeProcessorCount
            try options.setIntraOpNumThreads(Int32(min(cores, 6)))
            let session = try ORTSession(env: env, modelPath: modelPath.path, sessionOptions: options)
            ortEnv = env
            ortSession = session
            let outputNames = (try? session.outputNames()) ?? []
            if let first = outputNames.first {
                outputName = outputNames.contains("waveform") ? "waveform" : first
            }
            Log.shared.info("OnnxKokoroEngine: session loaded in \(Date().timeIntervalSince(started))s (output: \(outputName), \(min(cores, 6)) of \(cores) cores)")

            let tokenizerData = try Data(contentsOf: tokenizerPath)
            let tokenizerJSON = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any]
            vocab = (tokenizerJSON?["model"] as? [String: Any])?["vocab"] as? [String: Int] ?? [:]
            guard !vocab.isEmpty else {
                ortSession = nil
                Log.shared.error("OnnxKokoroEngine: tokenizer.json has no vocab")
                return
            }

            // Reuse the MLX download's voice bank — same style vectors.
            let npzVoices = NpyzReader.read(fileFromPath: ModelManager.voicesFileURL) ?? [:]
            var flat: [String: [Float]] = [:]
            for (key, array) in npzVoices {
                flat[key] = array.asArray(Float.self)
            }
            voicesFlat = flat
            Log.shared.info("OnnxKokoroEngine: \(vocab.count) vocab entries, \(flat.count) voices ready")
            // Only latch AFTER success — a transient ORT error (memory
            // pressure, file lock) used to brick the engine until relaunch.
            modelLoadAttempted = true
        } catch {
            ortSession = nil
            Log.shared.error("OnnxKokoroEngine: model load failed: \(error) — will retry on next speak")
        }
    }

    // MARK: - Synthesis (generateQueue)

    /// Phonemize with Misaki (same G2P the MLX engine lineage uses).
    private func phonemize(_ text: String) -> String? {
        let british = voice.hasPrefix("b")
        let g2p: EnglishG2P?
        if british {
            if g2pBritish == nil { g2pBritish = EnglishG2P(british: true) }
            g2p = g2pBritish
        } else {
            if g2pAmerican == nil { g2pAmerican = EnglishG2P(british: false) }
            g2p = g2pAmerican
        }
        guard let g2p else { return nil }
        return try? g2p.phonemize(text: text).0
    }

    /// Phonemes → token IDs (per-character vocab lookup, matching the
    /// reference tokenizer for this model).
    ///
    /// Batch B1. The old body was
    ///
    /// ```swift
    /// phonemes.map { vocab[String($0)] }.compactMap { $0 }
    /// ```
    ///
    /// which is silent: a character the vocab lacks is DELETED, the token
    /// count shrinks, and a shorter phoneme string is handed to the model
    /// with no error and no log. The word that comes out is a real word,
    /// spoken wrong — which is one way to describe the gibberish reports.
    ///
    /// A1 established that this can rarely fire: tokenizer.json's own
    /// normalizer deletes every character outside a 115-entry class, and all
    /// 115 have vocab ids, so a legitimately phonemized stream drops
    /// nothing. The drops that DO happen come from what the phonemizer hands
    /// back verbatim when it does not recognize input — `-` and `'` above
    /// all, which the normalizer removes but the app never applied.
    ///
    /// So the substitution is a SPACE, the model's own word separator (id
    /// 16), not an invented `[UNK]`: the vocab has no unknown token, and a
    /// space is the one character that keeps the token count equal to the
    /// input length and leaves the rest of the utterance's timing intact.
    private func tokenize(_ phonemes: String) -> [Int] {
        // id 16 is the space in this vocab; fall back to the vocab's own
        // "space" entry only if a future vocab renumbering moves it.
        let spaceID = vocab[" "] ?? 16
        var ids: [Int] = []
        var dropped: Set<Character> = []
        ids.reserveCapacity(phonemes.unicodeScalars.count)
        for scalar in phonemes.unicodeScalars {
            if let id = vocab[String(scalar)] {
                ids.append(id)
            } else {
                dropped.insert(Character(scalar))
                ids.append(spaceID)
            }
        }
        // Thread-confined by construction: the whole synthesis path runs on
        // the core's generateQueue.
        totalDroppedPhonemes += dropped.count
        // Rate-limited: a new log line only when the drop set CHANGES, so a
        // caller feeding the same bad character every chunk logs once
        // instead of at chunk rate.
        if !dropped.isEmpty, dropped.count != lastLoggedDropCount {
            lastLoggedDropCount = dropped.count
            let escaped = dropped.map { String($0) }.joined(separator: " ")
            Log.shared.error("OnnxKokoroEngine: phoneme(s) not in vocab, substituted with space: \(escaped) (session total: \(totalDroppedPhonemes))")
        }
        return ids
    }

    /// The core ONNX inference call.
    ///
    /// `phonemeChars` is the phoneme string's length BEFORE tokenization —
    /// the input to the style-row arithmetic (Batch B2). It is passed in
    /// rather than derived from `tokens` so a substitution cannot move the
    /// speaker.
    private func synthesize(tokens: [Int], voiceFlat: [Float], phonemeChars: Int) throws -> [Float] {
        guard let session = ortSession else {
            throw OnnxEngineError.modelUnavailable
        }
        guard tokens.count > 1, tokens.count <= Self.maxTokens else {
            throw OnnxEngineError.tokenCount(tokens.count)
        }

        // Style row: clamp(N - 1, 0, rows - 1) * 256, where N is the
        // phoneme-string length. Batch B2.
        //
        // Upstream (hexgrad/kokoro, pipeline.py) selects the reference style
        // vector BY LENGTH, on purpose:
        //
        //     return model(ps, pack[len(ps)-1], speed, return_output=True)
        //
        // Each voice bank is [510, 256] — ~510 reference utterances of
        // varying length, and the row picks a similar-length reference for
        // that same speaker. BOS/EOS are added INSIDE model(), after the row
        // is chosen, so `len(ps)` is the un-wrapped phoneme string.
        //
        // The previous code computed `min(max(tokens.count - 2, 0), rows-1)`,
        // which is kokoro.js's `input_ids.dims.at(-1) - 2` — a compensation
        // for the [0, *ids, 0] wrap that JS adds and this engine does not.
        // The app was therefore two rows short of upstream on every chunk,
        // and because tokens.count counted POST-substitution ids, a dropped
        // phoneme also moved the speaker.
        let rows = max(1, voiceFlat.count / Self.styleDim)
        let adjusted = min(max(phonemeChars - 1, 0), rows - 1)
        let offset = adjusted * Self.styleDim
        guard offset + Self.styleDim <= voiceFlat.count else {
            throw OnnxEngineError.voiceShape(voiceFlat.count)
        }
        var speedValue = core.speed
        let speedData = Data(bytes: &speedValue,
                             count: MemoryLayout<Float>.size)
        let styleSlice = voiceFlat[offset..<(offset + Self.styleDim)]
        let styleData = styleSlice.withUnsafeBufferPointer { src in
            Data(bytes: src.baseAddress!, count: src.count * MemoryLayout<Float>.size)
        }

        // One allocation, one copy: the token ids. The old path drained a
        // temporary [Int64] per chunk — GC churn at 1-2 Hz per engine.
        // (Data(unsafeUninitializedCapacity:initializingWith:) is Swift 6+;
        // this target compiles in Swift 5 mode, so build the Int64 array
        // once and take a single copy of its bytes.)
        var tokens64 = [Int64]()
        tokens64.reserveCapacity(tokens.count)
        for t in tokens { tokens64.append(Int64(t).littleEndian) }
        let tokensData = tokens64.withUnsafeBufferPointer { src in
            Data(bytes: src.baseAddress!, count: src.count * MemoryLayout<Int64>.size)
        }

        let tokensTensor = try ORTValue(
            tensorData: NSMutableData(data: tokensData),
            elementType: .int64,
            shape: [1, NSNumber(value: tokens.count)]
        )
        let styleTensor = try ORTValue(
            tensorData: NSMutableData(data: styleData),
            elementType: .float,
            shape: [1, NSNumber(value: Self.styleDim)]
        )
        let speedTensor = try ORTValue(
            tensorData: NSMutableData(data: speedData),
            elementType: .float,
            shape: [1]
        )

        let outputs = try session.run(
            withInputs: [
                "input_ids": tokensTensor,
                "style": styleTensor,
                "speed": speedTensor,
            ],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let waveform = outputs[outputName] else {
            throw OnnxEngineError.noOutput
        }
        let raw = try waveform.tensorData()
        let data = raw as Data
        return data.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Float.self))
        }
    }

    /// Text → phonemes → tokens → samples. The live speed is read per chunk
    /// from the core, so slider changes apply from the next sentence.
    private func generateChunk(_ text: String) throws -> [Float] {
        let voiceKey = voicesFlat[voice + ".npy"] != nil
            ? voice + ".npy"
            : voicesFlat.keys.sorted().first ?? ""
        guard let voiceFlat = voicesFlat[voiceKey] else {
            throw OnnxEngineError.noVoices
        }
        guard let phonemes = phonemize(text), !phonemes.isEmpty else {
            throw OnnxEngineError.phonemizationFailed
        }
        // Batch B1's engine-scoped pre-pass. The phonemizer echoes back what
        // it cannot classify, so a hyphen or an apostrophe that survived the
        // shared sanitizer reaches the vocab lookup as a raw character. The
        // reference tokenizer deletes those upstream; without this pass the
        // app's own substitute would fire on every "don't" and
        // "well-known" in every note.
        let cleaned = phonemes.replacingOccurrences(of: "-", with: " ")
                             .replacingOccurrences(of: "'", with: " ")
        let phonemeChars = cleaned.unicodeScalars.count
        let tokens = tokenize(cleaned)
        let started = Date()
        let samples: [Float]
        do {
            samples = try synthesize(tokens: tokens, voiceFlat: voiceFlat, phonemeChars: phonemeChars)
        } catch {
            // The error carries the token count already; the phoneme count is
            // what says whether a drop (or a substitution) caused it.
            Log.shared.error("OnnxKokoroEngine: synthesize failed after \(tokens.count) tokens from \(phonemeChars) phoneme chars")
            throw error
        }
        let duration = Double(samples.count) / core.sampleRate
        Log.shared.info("OnnxKokoroEngine: \(tokens.count) tokens → \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return samples
    }

    // MARK: - WAV export

    func renderWAV(
        text: String,
        title: String? = nil,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard validationResult() else {
            completion(.failure(OnnxEngineError.modelUnavailable))
            return
        }
        core.renderWAV(text: text, title: title, onChunkProgress: onChunkProgress, completion: completion)
    }
}

/// User-facing failures for the ONNX path.
enum OnnxEngineError: LocalizedError {
    case modelUnavailable
    case noVoices
    case phonemizationFailed
    case tokenCount(Int)
    case voiceShape(Int)
    case noOutput
    case emptyText

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "The ONNX Kokoro model isn't downloaded or failed to load."
        case .noVoices: return "No voice style vectors available — download the Kokoro voice bank."
        case .phonemizationFailed: return "Couldn't convert the text to phonemes."
        case .tokenCount(let n): return "Chunk token count out of range (\(n))."
        case .voiceShape(let n): return "Voice style vector has an unexpected size (\(n))."
        case .noOutput: return "The model returned no audio."
        case .emptyText: return "The note is empty."
        }
    }
}
