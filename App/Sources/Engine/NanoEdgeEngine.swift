import AVFoundation
import MisakiSwift
import OnnxRuntimeBindings
import SpeechLogic

/// nano-edge-tts: Kokoro-82M's text side with its 53.3M-parameter waveform
/// decoder replaced by drmhse's 1.75M-parameter harmonic-plus-noise decoder
/// (drmhse/nano-edge-tts, Apache-2.0, distilled from Kokoro's own decoder —
/// same voices, same pronunciation, same 24 kHz). The published weights are
/// PyTorch; the catalog installs the ONNX export (speechnotes-linux's
/// sn-tts produces it — see Docs/NANO-EDGE-PORT.md), in the same two-graph
/// split the Linux app runs:
///
/// * `text-side.onnx` — input_ids [1, N], style [1, 256], speed [1] → the
///   decoder inputs (asr [1, 512, T], f0 [1, T], n [1, T]) plus the style
///   slice the decoder itself takes (s [1, 128]). The BOS/EOS wrap the
///   reference `KModel.forward` applies lives inside the graph, so the ids
///   fed here are the same unwrapped stream the Kokoro engine feeds.
/// * `nano-decoder.onnx` — those four tensors → waveform [1, S].
///
/// Two sessions instead of one because the decoder's interpolations size
/// themselves off input shapes: the export keeps them symbolic through the
/// dynamo path, and the handoff between the graphs is where the runtime
/// meets the frame count — which is also the cap the creak-noise window was
/// precomputed at.
///
/// The voice banks, the tokenizer and the phoneme front end are kokoro's
/// own — this engine phonemizes with Misaki exactly like OnnxKokoroEngine
/// (the text side IS kokoro's, so the engines tokenize identically and a
/// voice code means the same speaker in both), while the graph chain, the
/// frame cap and the 256-wide .bin style banks follow the Linux port.
///
/// All pipeline machinery (chunking, bounded generation-ahead pacing,
/// scheduling, play-time position tracking, WAV export, audio session +
/// interruption handling) lives in StreamingTTSPlaybackCore; this class
/// contributes model loading + synthesis, confined to the core's
/// generateQueue. The model takes speed natively (a `speed` input, same as
/// Kokoro), so playback is a plain player node.
final class NanoEdgeEngine: NSObject, SpeechEngine {
    let name = "Nano Edge — on-device neural (English)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    /// Play-time position (see SpeechEngine.onPlayedChars).
    var onPlayedChars: ((Int) -> Void)?
    /// Natural completion (see SpeechEngine.onFinished).
    var onFinished: (() -> Void)?

    /// Voice code — one of ModelManager.nanoEdgeVoices, the 28 English
    /// banks of the kokoro set. Friendly names live in VoiceCatalog (the
    /// kokoro descriptors, shared by construction).
    var voice = "af_heart"

    /// Live rate — forwarded to the core so the NEXT chunk reflects a
    /// slider change without a restart (the model takes speed natively).
    var speed: Float {
        get { core.speed }
        set { core.speed = newValue }
    }

    // Pinned graph contract — Docs/NANO-EDGE-PORT.md (pinned against the
    // Linux runtime before any Swift; NanoEdgeSpike re-proves it in CI).
    private static let sampleRate: Double = 24_000
    private static let styleDim = 256
    /// The decoder's s slice — the first 128 floats of the 256-wide style
    /// row are produced by the text-side graph itself (output `s`), so the
    /// decoder never sees the bank directly.
    private static let decoderStyleDim = 128
    private static let asrDim = 512
    /// The frame count the creak-noise window was precomputed at in the
    /// export (16384 frames at 80 Hz — 204 s of audio, far past anything
    /// the 510-token chunk cap can produce). The count is the F0 axis's —
    /// the text side emits asr at half that rate, and the decoder's mapper
    /// aligns them. A text side that predicts past it has nothing to draw
    /// the jitter from; erroring the chunk beats reading the window off
    /// its end.
    private static let maxFrames = 16_384
    private static let maxTokens = 510
    private static let chunkMaxChars = 160

    private let core: StreamingTTSPlaybackCore

    /// How many times `validationResult()` ran the filesystem walk on this
    /// instance — the first is always logged, later ones only when they get
    /// slow. Main thread only (every `speak()`/export call is).
    private var validationCalls = 0
    /// Cached `nanoEdgeFilesAreValid()` result + monotonic stamp; success
    /// latches for 30 s (the same TTFA argument as Kokoro's). Failure is
    /// never latched — a transient blip must not brick the engine (R7).
    private var lastValidationResult: Bool?
    private var lastValidationAt: ContinuousClock.Instant?
    private static let validationTTL: TimeInterval = 30

    /// True once sessions were actually loaded this instance — the idle
    /// unload only pays off when there's something resident to free.
    var hasLoadedModel: Bool { modelLoadAttempted }

    // Model state — the core's generateQueue only.
    private var ortEnv: ORTEnv?
    private var textSession: ORTSession?
    private var decoderSession: ORTSession?
    /// Model output tensor name — "waveform" on the shipped export, but
    /// resolved from the session at load (Kokoro accepts both spellings
    /// and the same tolerance costs nothing here).
    private var decoderOutputName: String = "waveform"
    private var vocab: [String: Int] = [:]
    /// One resident voice bank (rows of 256 floats) — the single-slot
    /// rule Phonon's embedding cache follows. ~522 KB per bank, so the
    /// slot is about TTFA, not capacity.
    private var loadedVoiceBank: [Float] = []
    private var loadedVoiceCode: String = ""
    private var g2pAmerican: EnglishG2P?
    private var g2pBritish: EnglishG2P?
    private var modelLoadAttempted = false

    /// Batch B1's drop accounting. generateQueue-confined, never read off
    /// it — the values only feed the engine's own log lines.
    private var totalDroppedPhonemes = 0
    private var lastLoggedDropCount = -1

    /// Benchmark-only override for both sessions' `setIntraOpNumThreads`
    /// (Phase 3 harness). nil = the production policy
    /// (`min(activeProcessorCount, 6)`).
    var benchmarkIntraOpThreads: Int?

    override init() {
        self.core = StreamingTTSPlaybackCore(config: .init(
            sampleRate: Self.sampleRate,
            chunkMaxChars: Self.chunkMaxChars,
            // Kokoro's fast-start opener: the text side IS kokoro's, so a
            // 160-char batch renders at kokoro-like RTF (the decoder that
            // follows it is 33× smaller) and the same opener sizing that
            // covers kokoro's wait covers this one. The schedule adapts
            // from its own measurements either way.
            firstMaxChars: 100,
            schedule: ChunkSchedule.State(
                targetSeconds: ChunkSchedule.initialTargetSeconds,
                fallbackCharactersPerAudioSecond: ChunkSchedule.kokoroCharactersPerAudioSecond
            ),
            exportInterChunkSilence: 0,
            logPrefix: "NanoEdgeEngine",
            tier: "nano-edge"
        ))
        super.init()

        core.isModelReady = { [weak self] in
            guard let self else { return false }
            self.loadModelIfNeeded()
            return self.textSession != nil
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
            Log.shared.error("NanoEdgeEngine asked to speak but no nano-edge-tts model is downloaded")
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
        ) { ModelManager.nanoEdgeFilesAreValid() }
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

    // MARK: - Model loading (generateQueue)

    private func loadModelIfNeeded() {
        guard !modelLoadAttempted else { return }

        let modelDir = ModelManager.nanoEdgeDirectory
        let textPath = modelDir.appendingPathComponent("text-side.onnx").path
        let decoderPath = modelDir.appendingPathComponent("nano-decoder.onnx").path
        let tokenizerPath = modelDir.appendingPathComponent("tokenizer.json").path
        guard FileManager.default.fileExists(atPath: textPath),
              FileManager.default.fileExists(atPath: decoderPath),
              FileManager.default.fileExists(atPath: tokenizerPath) else {
            Log.shared.error("NanoEdgeEngine: model files missing at \(modelDir.path)")
            return
        }

        do {
            let started = Date()
            let env = try ORTEnv(loggingLevel: .warning)
            // Same thread policy as Kokoro: min(activeProcessorCount, 6) —
            // the render thread needs main-thread headroom, and more than
            // six buys nothing on a graph this small.
            let options = try ORTSessionOptions()
            let cores = ProcessInfo.processInfo.activeProcessorCount
            let threadCount = benchmarkIntraOpThreads.map(Int32.init) ?? Int32(min(cores, 6))
            try options.setIntraOpNumThreads(threadCount)
            let text = try ORTSession(env: env, modelPath: textPath, sessionOptions: options)
            let decoder = try ORTSession(env: env, modelPath: decoderPath, sessionOptions: options)
            ortEnv = env
            textSession = text
            decoderSession = decoder
            let outputNames = (try? decoder.outputNames()) ?? []
            if let first = outputNames.first {
                decoderOutputName = outputNames.contains("waveform") ? "waveform" : first
            }

            let tokenizerData = try Data(contentsOf: URL(fileURLWithPath: tokenizerPath))
            let tokenizerJSON = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any]
            vocab = (tokenizerJSON?["model"] as? [String: Any])?["vocab"] as? [String: Int] ?? [:]
            guard !vocab.isEmpty else {
                textSession = nil
                decoderSession = nil
                Log.shared.error("NanoEdgeEngine: tokenizer.json has no vocab")
                return
            }

            Log.shared.info("NanoEdgeEngine: 2 sessions loaded in \(Date().timeIntervalSince(started))s (\(vocab.count) vocab entries, \(threadCount) of \(cores) cores)")
            // Only latch AFTER success — a transient ORT error (memory
            // pressure, file lock) used to brick the engine until relaunch.
            modelLoadAttempted = true
        } catch {
            textSession = nil
            decoderSession = nil
            Log.shared.error("NanoEdgeEngine: model load failed: \(error) — will retry on next speak")
        }
    }

    /// Voice bank for the CURRENT voice, loaded on demand and cached
    /// (single-slot — see the property comment). A headerless plane of
    /// little-endian f32, 256 wide: the same published banks the kokoro
    /// set ships, so one voice code is one speaker in both engines.
    /// Whole rows only, and at least one row — a truncated download fails
    /// HERE, at use, never as a mid-sentence garbage render.
    private func voiceBank() throws -> [Float] {
        if loadedVoiceCode == voice, !loadedVoiceBank.isEmpty { return loadedVoiceBank }
        let path = ModelManager.nanoEdgeVoiceFileURL(voice: voice).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw NanoEdgeEngineError.voiceMissing(voice)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let bytesPerRow = Self.styleDim * MemoryLayout<Float>.size
        guard data.count > 0, data.count % bytesPerRow == 0 else {
            throw NanoEdgeEngineError.voiceShape(data.count)
        }
        let flat = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        loadedVoiceBank = flat
        loadedVoiceCode = voice
        return flat
    }

    // MARK: - Synthesis (generateQueue)

    /// Phonemize with Misaki (same G2P the Kokoro engine uses — the text
    /// side is kokoro's, so the pronunciation must match it).
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

    /// Phonemes → token IDs (per-character vocab lookup), unknown
    /// graphemes as spaces — never deletions (deleting silently shortens
    /// the stream and the word comes out wrong with nothing in the log;
    /// the space is the one substitution that keeps the token count equal
    /// to the input length). Same contract as OnnxKokoroEngine.tokenize.
    private func tokenize(_ phonemes: String) -> [Int] {
        // id 16 is the space in this vocab; fall back to the vocab's own
        // " " entry only if a future vocab renumbering moves it.
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
        totalDroppedPhonemes += dropped.count
        // Rate-limited: a new log line only when the drop set CHANGES, so
        // a caller feeding the same bad character every chunk logs once.
        if !dropped.isEmpty, dropped.count != lastLoggedDropCount {
            lastLoggedDropCount = dropped.count
            let escaped = dropped.map { String($0) }.joined(separator: " ")
            Log.shared.error("NanoEdgeEngine: phoneme(s) not in vocab, substituted with space: \(escaped) (session total: \(totalDroppedPhonemes))")
        }
        return ids
    }

    /// Text → phonemes → tokens → text-side graph → decoder graph →
    /// samples. The live speed is read per chunk from the core, so slider
    /// changes apply from the next sentence. The benchmark harness calls
    /// the Detailed form on its own queue through `benchmarkSynthesize`.
    private func generateChunk(_ text: String) throws -> [Float] {
        try generateChunkDetailed(text).samples
    }

    private func generateChunkDetailed(_ text: String) throws -> (samples: [Float], tokenCount: Int) {
        guard let textSession, let decoderSession else {
            throw NanoEdgeEngineError.modelUnavailable
        }
        let voiceFlat = try voiceBank()
        guard let phonemes = phonemize(text), !phonemes.isEmpty else {
            throw NanoEdgeEngineError.phonemizationFailed
        }
        // The phonemizer echoes back what it cannot classify — hyphens and
        // apostrophes above all — and the reference tokenizer deletes those
        // upstream. Replace BEFORE counting, so the style row sees the same
        // length the vocab lookup does (the kokoro engine's Batch B1/B2
        // lesson).
        let cleaned = phonemes.replacingOccurrences(of: "-", with: " ")
                             .replacingOccurrences(of: "'", with: " ")
        let phonemeChars = cleaned.unicodeScalars.count
        let tokens = tokenize(cleaned)
        guard tokens.count > 1, tokens.count <= Self.maxTokens else {
            throw NanoEdgeEngineError.tokenCount(tokens.count)
        }

        // The full 256-wide style row, by phoneme length — the reference
        // pipeline's ref_s; the text-side graph slices the decoder's half.
        // Each bank is [510, 256] — ~510 reference utterances of varying
        // length, and the row picks a similar-length reference for that
        // same speaker (upstream kokoro's pipeline.py, keyed on the
        // UN-wrapped phoneme string).
        let rows = max(1, voiceFlat.count / Self.styleDim)
        let adjusted = min(max(phonemeChars - 1, 0), rows - 1)
        let offset = adjusted * Self.styleDim
        guard offset + Self.styleDim <= voiceFlat.count else {
            throw NanoEdgeEngineError.voiceShape(voiceFlat.count)
        }
        let styleSlice = Array(voiceFlat[offset..<(offset + Self.styleDim)])

        let started = Date()
        let textOutputs = try textSession.run(
            withInputs: [
                "input_ids": try Self.int64Tensor(values: tokens.map(Int64.init), dims: [1, tokens.count]),
                "style": try Self.floatTensor(values: styleSlice, dims: [1, Self.styleDim]),
                "speed": try Self.floatTensor(values: [core.speed], dims: [1]),
            ],
            outputNames: ["asr", "f0", "n", "s"],
            runOptions: nil
        )
        let asr = try Self.floatValues(textOutputs["asr"], name: "asr")
        let f0 = try Self.floatValues(textOutputs["f0"], name: "f0")
        let n = try Self.floatValues(textOutputs["n"], name: "n")
        let s = try Self.floatValues(textOutputs["s"], name: "s")

        // Shapes are derived from element counts — the vendored binding is
        // only used for bytes in/out (the Phonon engine's convention): asr
        // is [1, 512, T] so T is the count over its dim, f0/n are [1, F].
        let asrFrames = asr.count / Self.asrDim
        let f0Frames = f0.count
        guard asrFrames > 0, f0Frames > 0 else {
            throw NanoEdgeEngineError.noOutput
        }
        guard f0Frames == n.count else {
            throw NanoEdgeEngineError.frameMismatch(f0: f0Frames, n: n.count)
        }
        // The text side emits asr at half the F0 frame count (the duration
        // expansion keys the prosody predictor at 80 Hz, the text encoder
        // at 40); the decoder's mapper upsamples asr internally, so each
        // tensor feeds at its own length. The creak-noise window is
        // precomputed at maxFrames against THIS axis (f0, the 80 Hz one).
        guard f0Frames <= Self.maxFrames else {
            throw NanoEdgeEngineError.frameOverflow(frames: f0Frames)
        }
        guard s.count == Self.decoderStyleDim else {
            throw NanoEdgeEngineError.voiceShape(s.count)
        }

        let decoderOutputs = try decoderSession.run(
            withInputs: [
                "asr": try Self.floatTensor(values: asr, dims: [1, Self.asrDim, asrFrames]),
                "f0": try Self.floatTensor(values: f0, dims: [1, f0Frames]),
                "n": try Self.floatTensor(values: n, dims: [1, f0Frames]),
                "s": try Self.floatTensor(values: s, dims: [1, Self.decoderStyleDim]),
            ],
            outputNames: [decoderOutputName],
            runOptions: nil
        )
        guard let waveform = decoderOutputs[decoderOutputName] else {
            throw NanoEdgeEngineError.noOutput
        }
        let samples = (try waveform.tensorData()) as Data
        let floats: [Float] = samples.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        guard !floats.isEmpty else {
            throw NanoEdgeEngineError.noOutput
        }

        let duration = Double(floats.count) / core.sampleRate
        Log.shared.info("NanoEdgeEngine: \(tokens.count) tokens → \(String(format: "%.1f", duration))s audio (\(f0Frames) frames) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s (\(VoiceCatalog.shortName(for: voice, kind: .nanoEdge)))")
        return (floats, tokens.count)
    }

    // MARK: - Benchmark (Phase 3 harness)

    /// Loads the model if needed. Returns false only when the model cannot
    /// serve (not downloaded / load failed) — the harness treats that as a
    /// failed session, not a skipped chunk.
    ///
    /// The benchmark owns its engine instance EXCLUSIVELY and calls every
    /// benchmark entry point from its own serial queue, so the usual
    /// generateQueue confinement is satisfied by that ownership.
    func benchmarkPrepare() -> Bool {
        loadModelIfNeeded()
        return textSession != nil
    }

    /// One sustained-synthesis inference: text → samples. The token count
    /// is the vocab-lookup count AFTER space substitution, i.e. what the
    /// model actually saw.
    func benchmarkSynthesize(text: String, speed: Float) throws
        -> (sampleCount: Int, sampleRate: Double, tokenCount: Int?)
    {
        core.speed = speed
        let result = try generateChunkDetailed(text)
        return (result.samples.count, core.sampleRate, result.tokenCount)
    }

    // MARK: - WAV export

    func renderWAV(
        text: String,
        title: String? = nil,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard validationResult() else {
            completion(.failure(NanoEdgeEngineError.modelUnavailable))
            return
        }
        core.renderWAV(text: text, title: title, onChunkProgress: onChunkProgress, completion: completion)
    }

    // MARK: - Tensor plumbing

    // Shapes are tracked by the caller and passed IN — the vendored binding
    // is only used for bytes in/out (same helpers as the Phonon engine).

    private static func int64Tensor(values: [Int64], dims: [Int]) throws -> ORTValue {
        guard !values.isEmpty else {
            return try ORTValue(tensorData: NSMutableData(data: Data()), elementType: .int64,
                                shape: dims.map { NSNumber(value: $0) })
        }
        var littleEndian = values
        for index in littleEndian.indices { littleEndian[index] = values[index].littleEndian }
        let data = littleEndian.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Int64>.size)
        }
        return try ORTValue(tensorData: NSMutableData(data: data), elementType: .int64,
                            shape: dims.map { NSNumber(value: $0) })
    }

    private static func floatTensor(values: [Float], dims: [Int]) throws -> ORTValue {
        guard !values.isEmpty else {
            return try ORTValue(tensorData: NSMutableData(data: Data()), elementType: .float,
                                shape: dims.map { NSNumber(value: $0) })
        }
        let data = values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        return try ORTValue(tensorData: NSMutableData(data: data), elementType: .float,
                            shape: dims.map { NSNumber(value: $0) })
    }

    private static func floatValues(_ value: ORTValue?, name: String) throws -> [Float] {
        guard let value else { throw NanoEdgeEngineError.missingOutput(name) }
        let raw = try value.tensorData() as Data
        guard raw.count % MemoryLayout<Float>.size == 0 else {
            throw NanoEdgeEngineError.noOutput
        }
        return raw.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Float.self))
        }
    }
}

/// User-facing failures for the nano-edge-tts path.
enum NanoEdgeEngineError: LocalizedError {
    case modelUnavailable
    case voiceMissing(String)
    /// A bank that is not whole rows of 256 f32 (a truncated download), or
    /// a graph output that disagrees with the pinned shape.
    case voiceShape(Int)
    case phonemizationFailed
    case tokenCount(Int)
    /// f0 and n disagreed on the frame count — the text side ran off-spec.
    case frameMismatch(f0: Int, n: Int)
    /// The chunk predicts past the precomputed creak-noise window (see
    /// `maxFrames`); erroring the chunk beats reading off the window's end.
    case frameOverflow(frames: Int)
    case missingOutput(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "The nano-edge-tts model isn't downloaded or failed to load."
        case .voiceMissing(let id): return "Nano Edge voice \(id) isn't downloaded — re-download the model."
        case .voiceShape(let n): return "Nano Edge voice bank has an unexpected size (\(n) bytes) — not whole rows of 256 floats."
        case .phonemizationFailed: return "Couldn't convert the text to phonemes."
        case .tokenCount(let n): return "Chunk token count out of range (\(n))."
        case .frameMismatch(let f0, let n): return "Nano Edge text side: f0 (\(f0)) and n (\(n)) frame counts disagree."
        case .frameOverflow(let frames): return "Chunk predicts \(frames) frames, past the 16384-frame creak-noise window."
        case .missingOutput(let name): return "The text-side graph gave no '\(name)' output."
        case .noOutput: return "The model returned no audio."
        }
    }
}
