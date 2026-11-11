import AVFoundation
import OnnxRuntimeBindings
import SpeechLogic

/// Phonon engine (Gradium phonon-31m-en): a 31M-param English streaming TTS
/// over TWO fp32 ONNX graphs — a causal flow transformer that emits one
/// 32-dim latent per 80 ms frame plus an end-of-speech logit, and the
/// stateless Mimi codec decoder that turns latents into 24 kHz PCM. The
/// pinned call contract lives in Docs/PHONON-PORT.md (pinned empirically
/// with ORT before any Swift; the spike re-proves it on the vendored
/// runtime every CI run).
///
/// All pipeline machinery (chunking, bounded generation-ahead pacing,
/// scheduling, play-time position tracking, WAV export, audio session +
/// interruption handling) lives in StreamingTTSPlaybackCore; this class
/// contributes model loading + synthesis, confined to the core's
/// generateQueue. Each sentence chunk gets a fresh KV/latent state — the
/// hub's own driver resets per chunk, which is also what makes successive
/// sentences join cleanly.
///
/// Rate: Phonon has NO native speed control (the flow export baked its
/// duration conditioning into a constant), so `speed` is accepted and
/// ignored — the engine speaks at its natural pace at every slider value.
/// The slider still drives the core's chunk-opener sizing.
final class PhononEngine: NSObject, SpeechEngine {
    var name = "Phonon — on-device neural (English)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    /// Play-time position (see SpeechEngine.onPlayedChars).
    var onPlayedChars: ((Int) -> Void)?
    /// Natural completion (see SpeechEngine.onFinished).
    var onFinished: (() -> Void)?

    /// Voice id — one of ModelManager.phononVoices ("default" + the hub's
    /// en-us/en-gb voice_ids). Friendly names live in VoiceCatalog.
    var voice = "default"

    /// Live rate — forwarded to the core (schedule sizing only; the model
    /// itself has no speed input, see the type doc).
    var speed: Float {
        get { core.speed }
        set { core.speed = newValue }
    }

    // Pinned graph contract — see Docs/PHONON-PORT.md for every constant's
    // provenance.
    private static let sampleRate: Double = 24_000
    private static let samplesPerFrame = 1920
    private static let latentDim = 32
    private static let framesPerCall = 8
    private static let voiceDim = 512
    private static let voiceFrames = 125
    private static let frameRate = 12.5
    private static let eosThreshold: Float = 4.0
    /// Soft-EOS safety net: two consecutive calls with their per-call eos
    /// peak above this, without a real crossing, stop the chunk (see the
    /// countdown block in generateChunk). Below every healthy x86 sweep
    /// trajectory, which only ever dips to ~+0.5 mid-run.
    private static let softEOSThreshold: Float = 1.0
    private static let temperature: Float = 0.3
    private static let attentionHeads = 8
    private static let headDim = 64
    private static let flowLayers = 6
    /// The Mimi decoder's rotary positions run over the upsampled sequence
    /// against an 8000-position cos/sin cache — empirically ~500 latents per
    /// call is safe (512 fails). The ceiling that actually bites is MEMORY:
    /// the decoder's ConvTranspose activations cost ~2.7 MB per latent
    /// (measured: 160 latents ≈ +430 MB RSS, 400 ≈ +1.1 GB — jetsam
    /// territory on the A14). `chunkMaxChars` keeps real chunks ≤ ~150
    /// latents, so this window never splits in practice; it is the safety
    /// valve for pathological tokenization, and 160 is where the memory
    /// spike stays survivable.
    private static let decodeWindow = 160

    /// Supertonic-style chunk ceiling: the hub treats ~50 tokens as one
    /// sentence chunk; ~50 tokens ≈ 200 chars, kept slightly tighter for
    /// responsiveness.
    private static let chunkMaxChars = 180

    private let core: StreamingTTSPlaybackCore

    /// How many times `validationResult()` ran the filesystem walk on this
    /// instance — the first is always logged, later ones only when they get
    /// slow. Main thread only (every `speak()`/export call is).
    private var validationCalls = 0
    /// Cached `phononFilesAreValid()` result + monotonic stamp; success
    /// latches for 30 s (the per-voice size checks live upstream of TTFA's
    /// t0). Failure is never latched — a transient blip must not brick the
    /// engine (R7).
    private var lastValidationResult: Bool?
    private var lastValidationAt: ContinuousClock.Instant?
    private static let validationTTL: TimeInterval = 30

    /// True once sessions were actually loaded this instance — the idle
    /// unload only pays off when there's something resident to free.
    var hasLoadedModel: Bool { modelLoadAttempted }

    // Model state — the core's generateQueue only.
    private var ortEnv: ORTEnv?
    private var flowSession: ORTSession?
    private var decodeSession: ORTSession?
    private var tokenizer: PhononTokenizer?
    private var loadedVoices: [String: [Float]] = [:]
    private var modelLoadAttempted = false

    /// Benchmark-only override for both sessions' `setIntraOpNumThreads`
    /// (Phase 3 harness). nil = the production policy (`min(activeProcessorCount, 6)`).
    var benchmarkIntraOpThreads: Int?

    /// NSObject's designated `init()` — a bare override is required because
    /// the signature matches the superclass one exactly (the parameterized
    /// inits of the other engines never hit this).
    override init() {
        self.core = StreamingTTSPlaybackCore(config: .init(
            sampleRate: Self.sampleRate,
            chunkMaxChars: Self.chunkMaxChars,
            // Opener seed: Phonon's RTF is unmeasured on device (the hub
            // measures several× realtime in a browser); Kokoro's seeds are
            // the closest starting point (24 kHz flow TTS, similar chunk
            // sizes). The schedule adapts from its own measurements either
            // way — these only decide the FIRST opener.
            firstMaxChars: 80,
            schedule: ChunkSchedule.State(
                targetSeconds: ChunkSchedule.initialTargetSeconds,
                fallbackCharactersPerAudioSecond: ChunkSchedule.kokoroCharactersPerAudioSecond
            ),
            exportInterChunkSilence: 0.05,
            logPrefix: "PhononEngine",
            tier: "phonon"
        ))
        super.init()

        core.isModelReady = { [weak self] in
            guard let self else { return false }
            self.loadModelIfNeeded()
            return self.flowSession != nil
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
            Log.shared.error("PhononEngine asked to speak but no Phonon model is downloaded")
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
        ) { ModelManager.phononFilesAreValid() }
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

        let onnxDir = ModelManager.phononOnnxDirectory
        guard FileManager.default.fileExists(atPath: onnxDir.appendingPathComponent("model.onnx").path),
              FileManager.default.fileExists(atPath: onnxDir.appendingPathComponent("mimi_decoder.onnx").path) else {
            Log.shared.error("PhononEngine: model files missing at \(onnxDir.path)")
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
            let flow = try ORTSession(env: env, modelPath: onnxDir.appendingPathComponent("model.onnx").path, sessionOptions: options)
            let decode = try ORTSession(env: env, modelPath: onnxDir.appendingPathComponent("mimi_decoder.onnx").path, sessionOptions: options)
            ortEnv = env
            flowSession = flow
            decodeSession = decode

            let tokenizerData = try Data(contentsOf: onnxDir.appendingPathComponent("tokenizer.json"))
            tokenizer = try PhononTokenizer(tokenizerData: tokenizerData)

            Log.shared.info("PhononEngine: 2 sessions + tokenizer loaded in \(Date().timeIntervalSince(started))s (\(threadCount) of \(cores) cores)")
            // Only latch AFTER success — a transient ORT error (memory
            // pressure, file lock) used to brick the engine until relaunch.
            modelLoadAttempted = true
        } catch {
            flowSession = nil
            decodeSession = nil
            tokenizer = nil
            Log.shared.error("PhononEngine: model load failed: \(error) — will retry on next speak")
        }
    }

    /// Voice embedding for the CURRENT voice, loaded on demand and cached.
    /// The .bin is raw little-endian float32 in [1, 512, 125] order — the
    /// graph takes [1, 125, 512], so this is a transpose (NOT a reshape; a
    /// reshape silently transposes the conditioning and the voice turns to
    /// mush — the contract-pinning round caught exactly that bug).
    private func voiceEmbedding() throws -> [Float] {
        if let cached = loadedVoices[voice] { return cached }
        let path = ModelManager.phononVoiceFileURL(voice: voice).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw PhononEngineError.voiceMissing(voice)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let count = data.count / MemoryLayout<Float>.size
        guard count == Self.voiceDim * Self.voiceFrames else {
            throw PhononEngineError.voiceShape(count)
        }
        let flat = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        var transposed = [Float](repeating: 0, count: count)
        for frame in 0..<Self.voiceFrames {
            for dim in 0..<Self.voiceDim {
                transposed[frame * Self.voiceDim + dim] = flat[dim * Self.voiceFrames + frame]
            }
        }
        // One resident voice per slot: switching voices frees the last one
        // (26 bins resident would be ~6.7 MB — the cache is about TTFA, not
        // capacity, but the single-slot habit keeps the footprint honest).
        loadedVoices = [voice: transposed]
        return transposed
    }

    // MARK: - Synthesis (generateQueue)

    /// One sentence chunk: fresh KV/latent state → the pinned call loop →
    /// windowed decode → PCM. The live speed is read per chunk from the core
    /// (schedule sizing only — the model has no speed input).
    private func generateChunk(_ text: String) throws -> [Float] {
        guard let flowSession, let decodeSession, let tokenizer else {
            throw PhononEngineError.modelUnavailable
        }
        let ids = try tokenizer.encode(text)
        let T = ids.count
        guard T > 0 else { throw PhononEngineError.emptyText }
        let P = Self.voiceFrames + T + 1
        // The hub's frame budget, with a 1.5× margin: EOS timing is
        // noise-dependent and two observed runs of the same sentence landed
        // at 20/26 calls (Python seed) and past 26/26 (Swift seed) — the
        // hub's own driver logs "may be truncated" when its budget bites.
        // The countdown stops the loop the moment EOS actually crosses; the
        // margin only buys the unlucky draws.
        let budget = Int(ceil((Double(T) / 3 + 2) * Self.frameRate * 1.5))
        let framesAfterEOS = Self.words(in: text) <= 4 ? 3 : 1
        let voice = try voiceEmbedding()

        var kv: [ORTValue] = []
        kv.reserveCapacity(Self.flowLayers * 2)
        for _ in 0..<(Self.flowLayers * 2) {
            kv.append(try Self.emptyTensor(dims: [1, Self.attentionHeads, 0, Self.headDim]))
        }
        // TWO books, because the prompt K/V live in the fed-back cache from
        // the prefill on (see the KV feedback below): `kvRows` is the fed-back
        // KV row count (P + 7 after prefill, +8 per continuation call) and
        // drives attention_mask/position_ids; `latentCount` is the cumulative
        // audio_latents row count (+8 every call) and drives the latent
        // history + this call's frame slice.
        var kvRows = 0
        var latentCount = 0
        var latentHistory = try Self.emptyTensor(dims: [1, 0, Self.latentDim])

        var newLatents: [Float] = []
        newLatents.reserveCapacity(budget * Self.latentDim)
        var countdown: Int? = nil
        var rng = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970 * 1_000_000_000))
        // Diagnostics for the device log: a healthy run's eos logits sit
        // deep negative while speaking and SPIKE at the sentence end; a
        // gradual climb or a never-crossing run within budget is the
        // degenerate-context signature, and a non-finite latent means the
        // runtime itself corrupted the graph state.
        var eosPeak: Float = -.infinity
        var eosPeakCall = 0

        let started = Date()
        var crossedEOS = false
        var softEOS = false
        var callIndex = 0
        // Soft-EOS safety net (see the countdown block below).
        var softStreak = 0
        for _ in 0..<max(1, Int(ceil(Double(budget) / Double(Self.framesPerCall)))) {
            // PREFILL-ONCE (the export's own convention, per the model card's
            // driver): call 0 runs voice+text through the graph against an
            // EMPTY cache — their K/V are computed exactly like the reference
            // prefill — and every present.* output is fed back whole, so the
            // prompt K/V then sit in the cache FROZEN forever. Calls 1+ feed
            // an EMPTY prompt (input_ids [1,0], voice [1,0,512]): the graph
            // re-runs nothing but the input slot + 7 frame rows.
            //
            // Why not re-feed the prompt every call (the previous recipe):
            // the re-run block attends to the growing latent cache at layers
            // 1–5, so the text K/V the frame queries read MUTATED on every
            // call (x86 probe: prompt-row value cosine down to 0.13–0.43,
            // never settling) — an out-of-distribution, drifting text
            // representation that degraded the EOS decision. Symptom: chunks
            // over-generated at the sentence end (long tail, occasional
            // repetition, eos climbing to ~2 but never crossing 4.0). The
            // frozen-prompt recipe took the x86 sweep from 8/120 degenerate
            // runs to 0/120 with healthy spikes intact.
            let prefill = callIndex == 0
            let newRows = prefill ? P + Self.framesPerCall - 1 : Self.framesPerCall
            let total = kvRows + newRows
            let noise = (0..<(Self.framesPerCall * Self.latentDim)).map { _ -> Float in
                Float.standardNormal(using: &rng) * sqrt(Self.temperature)
            }

            var feeds: [String: ORTValue] = [:]
            // Continuation calls carry an EMPTY text/voice prompt — see the
            // prefill note above. ORT accepts zero-size tensors (the CI spike
            // re-proves this on the vendored runtime).
            feeds["input_ids"] = try prefill
                ? Self.int64Tensor(values: ids.map(Int64.init), dims: [1, T])
                : Self.int64Tensor(values: [], dims: [1, 0])
            feeds["audio_prompt_latents"] = try prefill
                ? Self.floatTensor(values: voice, dims: [1, Self.voiceFrames, Self.voiceDim])
                : Self.floatTensor(values: [], dims: [1, 0, Self.voiceDim])
            feeds["attention_mask"] = try Self.int64Tensor(values: [Int64](repeating: 1, count: total), dims: [1, total])
            // Positions: prefill pins the voice+text rows at their true
            // absolute positions 0..<P-1 (RoPE baked exactly like the
            // reference prefill, qnn/runner/phonon.cpp) with the input slot
            // at P-1 and the 7 frames after. Continuation rows ride the same
            // timeline: latent n sits at position P-1+n, and since the
            // fed-back cache holds kvRows = P-1+n rows at call n, the next 8
            // rows are simply [kvRows, kvRows+8). Non-contiguous is fine —
            // the graph only slices [0:P] for the prompt block and [P+k] for
            // the frames (the prompt-block slice is empty on continuation).
            let positionValues: [Int64] = prefill
                ? (0..<(P - 1)).map(Int64.init)
                    + ((P - 1)..<(P + Self.framesPerCall - 1)).map(Int64.init)
                : (kvRows..<(kvRows + Self.framesPerCall)).map(Int64.init)
            feeds["position_ids"] = try Self.int64Tensor(values: positionValues, dims: [1, positionValues.count])
            feeds["noise"] = try Self.floatTensor(values: noise, dims: [1, Self.framesPerCall, Self.latentDim])
            for (index, value) in kv.enumerated() {
                feeds["past_key_values.\(index / 2).\(index % 2 == 0 ? "key" : "value")"] = value
            }
            feeds["past_key_values.audio_latents"] = latentHistory

            let outputs = try flowSession.run(
                withInputs: feeds,
                outputNames: Set(["audio_latents", "present.audio_latents", "eos_logits"]
                    + (0..<Self.flowLayers).flatMap { ["present.\($0).key", "present.\($0).value"] }),
                runOptions: nil)

            // The flow's audio_latents is the CUMULATIVE latent history,
            // denormalized; only the trailing 8 rows are this call's frames.
            let cumulative = try Self.floatValues(
                outputs["audio_latents"]!, dims: [1, latentCount + Self.framesPerCall, Self.latentDim])
            let frameValues = cumulative[(latentCount * Self.latentDim)...]
            if frameValues.contains(where: { !$0.isFinite }) {
                throw PhononEngineError.corruptLatents(call: callIndex)
            }
            newLatents.append(contentsOf: frameValues)
            let eos = try Self.floatValues(outputs["eos_logits"]!, dims: [1, Self.framesPerCall])
            let callPeak = eos.max() ?? -.infinity
            if callPeak > eosPeak {
                eosPeak = callPeak
                eosPeakCall = callIndex
            }

            // KV feedback: feed the WHOLE present back as the next past —
            // the model card's driver convention ("feed every output back
            // under its past name"). The prefill call's present carries the
            // voice+text K/V computed against an empty cache (reference
            // prefill semantics), and from then on they are never recomputed:
            // fed back bitwise unchanged forever. (The previous recipe
            // dropped the prompt rows and re-ran them every call — the
            // re-run block attended to the growing latent cache at layers
            // 1–5 and the text K/V drifted call-to-call; see the loop-head
            // comment.) Whole-present feedback also lets the ORTValues pass
            // straight through — no per-head copy, and the whole class of
            // head-major striding bugs this loop used to defend against is
            // gone.
            var newKV: [ORTValue] = []
            newKV.reserveCapacity(Self.flowLayers * 2)
            for index in 0..<(Self.flowLayers * 2) {
                let name = index % 2 == 0 ? "present.\(index / 2).key" : "present.\(index / 2).value"
                newKV.append(outputs[name]!)
            }
            kv = newKV
            kvRows += newRows
            latentCount += Self.framesPerCall
            latentHistory = outputs["present.audio_latents"]!

            // EOS countdown (Python's PocketTTSEosThresholdCriteria): the
            // frame that crossed the threshold and the tail frames are kept.
            //
            // SOFT-EOS SAFETY NET: healthy runs sit deep negative (-5…-9)
            // until the final spike, but a degenerate context can leave the
            // eos logit hovering just under the threshold (~1–2, never
            // crossing 4.0) — the device saw 20–45 s tails of that. Two
            // consecutive CALLS with their per-call peak above softThreshold
            // without a real crossing = stop and keep the clean head. The
            // two-call window is load-bearing: healthy runs show single-call
            // dips up to ~+0.5 (x86 sweep), never a sustained plateau.
            var done = false
            for value in eos {
                if countdown == nil && value > Self.eosThreshold {
                    countdown = framesAfterEOS
                    crossedEOS = true
                } else if countdown != nil {
                    countdown! -= 1
                    done = countdown! <= 0
                }
            }
            if countdown == nil {
                softStreak = callPeak > Self.softEOSThreshold ? softStreak + 1 : 0
                if softStreak >= 2 {
                    softEOS = true
                    done = true
                }
            }
            callIndex += 1
            if done { break }
        }
        if softEOS {
            Log.shared.info("PhononEngine: soft-EOS stop (sustained eos > \(Self.softEOSThreshold), never crossed \(Self.eosThreshold)) — kept clean head («\(text.prefix(50))»)")
        } else if !crossedEOS {
            Log.shared.info("PhononEngine: frame budget reached before EOS — audio may be truncated («\(text.prefix(50))»)")
        }

        // Windowed decode (decoder rotary ceiling — see Self.decodeWindow).
        var pcm: [Float] = []
        let totalLatents = newLatents.count / Self.latentDim
        var start = 0
        while start < totalLatents {
            let count = min(Self.decodeWindow, totalLatents - start)
            let window = Array(newLatents[(start * Self.latentDim)..<(start * Self.latentDim + count * Self.latentDim)])
            let output = try decodeSession.run(
                withInputs: [
                    "audio_latents": try Self.floatTensor(values: window, dims: [1, count, Self.latentDim]),
                    "num_frames": try Self.int64Tensor(values: [Int64(count)], dims: [1]),
                ],
                outputNames: ["audio_values", "audio_lengths"],
                runOptions: nil)
            let lengths = try Self.int64Values(output["audio_lengths"]!, count: 1)
            let samples = Int(lengths[0])
            guard samples > 0 else { throw PhononEngineError.noOutput }
            pcm.append(contentsOf: try Self.floatValues(output["audio_values"]!, dims: [1, 1, samples]))
            start += count
        }
        guard !pcm.isEmpty else { throw PhononEngineError.noOutput }

        let duration = Double(pcm.count) / core.sampleRate
        Log.shared.info("PhononEngine: \(T) tokens → \(Self.frameString(duration))s audio (\(totalLatents) frames, \(callIndex) calls) in \(Self.frameString(Date().timeIntervalSince(started)))s, eos peak \(String(format: "%.2f", eosPeak)) at call \(eosPeakCall) (\(voiceShortName))")
        return pcm
    }

    /// The voice currently cached (the loadedVoices single-slot rule makes
    /// this the one voice this engine has resident).
    private var voiceShortName: String { VoiceCatalog.shortName(for: voice, kind: .phonon) }

    private static func frameString(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }

    private static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
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
        return flowSession != nil
    }

    /// One sustained-synthesis inference: text → samples. Returns nil tokens
    /// (Phonon has no token-count dial to record — the frame count rides the
    /// log line instead).
    func benchmarkSynthesize(text: String, speed: Float) throws
        -> (sampleCount: Int, sampleRate: Double, tokenCount: Int?)
    {
        core.speed = speed
        let samples = try generateChunk(text)
        return (samples.count, core.sampleRate, nil)
    }

    // MARK: - WAV export

    func renderWAV(
        text: String,
        title: String? = nil,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard validationResult() else {
            completion(.failure(PhononEngineError.modelUnavailable))
            return
        }
        core.renderWAV(text: text, title: title, onChunkProgress: onChunkProgress, completion: completion)
    }
}

/// User-facing failures for the Phonon path.
enum PhononEngineError: LocalizedError {
    case modelUnavailable
    case voiceMissing(String)
    case voiceShape(Int)
    case noOutput
    case emptyText
    /// Non-finite latents out of the flow graph — the runtime corrupted the
    /// graph state (never seen on x86; a device log with this is the
    /// numeric-divergence signal, not a content problem).
    case corruptLatents(call: Int)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "The Phonon model isn't downloaded or failed to load."
        case .voiceMissing(let id): return "Phonon voice \(id) isn't downloaded — re-download the model."
        case .voiceShape(let n): return "Phonon voice embedding has an unexpected size (\(n))."
        case .noOutput: return "Phonon returned no audio for this chunk."
        case .emptyText: return "The note is empty."
        case .corruptLatents(let call): return "Phonon produced non-finite audio state at call \(call)."
        }
    }
}

// MARK: - Shared tensor plumbing + seeded noise
//
// Shapes are tracked by the caller and passed IN — the vendored binding is
// only used for bytes in/out (the spike carries the same helpers).

extension PhononEngine {
    static func emptyTensor(dims: [Int]) throws -> ORTValue {
        try ORTValue(tensorData: NSMutableData(data: Data()), elementType: .float,
                     shape: dims.map { NSNumber(value: $0) })
    }

    static func int64Tensor(values: [Int64], dims: [Int]) throws -> ORTValue {
        // Empty tensors (the continuation calls' [1,0] input_ids) must take
        // this path: an empty Swift array's buffer baseAddress is nil.
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

    static func floatTensor(values: [Float], dims: [Int]) throws -> ORTValue {
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

    static func floatValues(_ value: ORTValue, dims: [Int]) throws -> [Float] {
        let raw = try value.tensorData() as Data
        let expected = dims.reduce(1, *)
        precondition(raw.count == expected * MemoryLayout<Float>.size,
                     "unexpected tensor size \(raw.count) for \(dims)")
        return raw.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Float.self))
        }
    }

    static func int64Values(_ value: ORTValue, count: Int) throws -> [Int64] {
        let raw = try value.tensorData() as Data
        precondition(raw.count == count * MemoryLayout<Int64>.size)
        return raw.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Int64.self)).map { Int64(littleEndian: $0) }
        }
    }
}

/// Deterministic SplitMix64 → Box-Muller standard normal. Shared with the
/// CI spike (Tests/PhononSpike) so the two run the same noise recipe.
struct SeededGenerator {
    private var state: UInt64
    private var hasSpare = false
    private var spare: Float = 0

    init(seed: UInt64) {
        self.state = seed
    }

    private mutating func nextUniform() -> Float {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Float(z >> 11) / Float(1 << 53)
    }

    mutating func next() -> Float {
        if hasSpare {
            hasSpare = false
            return spare
        }
        let u1 = max(nextUniform(), 1e-12)
        let u2 = nextUniform()
        let magnitude = sqrt(-2 * log(1 - u1))
        spare = magnitude * cos(2 * Float.pi * u2)
        hasSpare = true
        return magnitude * sin(2 * Float.pi * u2)
    }
}

extension Float {
    static func standardNormal(using generator: inout SeededGenerator) -> Float {
        generator.next()
    }
}
