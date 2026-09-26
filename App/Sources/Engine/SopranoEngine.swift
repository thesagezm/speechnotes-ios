import AVFoundation
import OnnxRuntimeBindings
import SpeechLogic

/// Soprano 1.1-80M engine (ekwek/Soprano-1.1-80M, Apache-2.0) over the
/// community ONNX export (KevinAHM/soprano-1.1-onnx, Apache-2.0).
///
/// Architecture: a Qwen3 17-layer decoder-only backbone with a KV cache
/// (autoregressive audio-token generation) plus a Vocos-based decoder that
/// turns hidden states into 32 kHz audio — 2048 samples per token. English
/// only, one voice. There is no phonemizer: text goes through
/// `SopranoTextNormalizer` (numbers, currency, ordinals) then straight into
/// the tokenizer, which is why that normalizer lives in SpeechLogic.
///
/// All pipeline machinery (chunking, pacing, scheduling, position tracking,
/// WAV export, audio session) lives in StreamingTTSPlaybackCore, shared with
/// the other ONNX engines; this class contributes only model loading and
/// `generateChunk`, confined to the core's generateQueue.
///
/// The exact graph contract was established by `Tests/SopranoSpike` on the CI
/// runner (the spike is diagnostics, not a gate — see
/// Docs/PLAN-V1.7.0-SOPRANO.md):
///   backbone inputs  input_ids / attention_mask / position_ids (int64)
///                    + past_key_values.0..16.{key,value} (float [1,1,0,128]
///                    on the first step)
///   backbone outputs logits, present.0..16.{key,value},
///                    last_hidden_state ([1, 512, seqLen] or [1, seqLen, 512]
///                    — the export never pinned it; the layout is read from
///                    the tensor's own shape at runtime and logged once)
///   decoder          hidden_states [1, 512, 12] → audio (float32 @ 32 kHz)
final class SopranoEngine: NSObject, SpeechEngine {
    let name = "Soprano (CPU)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    /// Play-time position (see SpeechEngine.onPlayedChars).
    var onPlayedChars: ((Int) -> Void)?
    /// Natural completion (see SpeechEngine.onFinished).
    var onFinished: (() -> Void)?

    /// Live rate — forwarded to the core so the NEXT chunk reflects a slider
    /// change without a restart.
    var speed: Float {
        get { core.speed }
        set { core.speed = newValue }
    }

    /// Soprano has exactly one voice; the slot exists so the picker,
    /// auditions and the preference migration all have a value to carry.
    var voice = "soprano"

    private let core: StreamingTTSPlaybackCore

    /// How many times `speak()` has validated on this instance — the first is
    /// always logged, later ones only when they get slow (same as the other
    /// engines).
    private var validationCalls = 0

    private static let hiddenSize = 512
    /// Per-head KV dimension — config's head_dim (1 KV head × 128), NOT
    /// hidden_size. The first device build passed [1, 1, 0, 512] empty KV
    /// caches; ORT rejected the shape on step 0 and EVERY chunk died with a
    /// masked "missingOutput" ~10 ms in (the "Soprano plays nothing" report;
    /// the CI spike used 128 all along, which is why it stayed green).
    private static let kvDim = 128
    /// Decoder receptive field — 4 in the reference loop, NOT 12 (12 came from
    /// misreading the decoder's input shape; the reference trims its buffer to
    /// 2*RF + chunk and slices RF + chunk frames out of it).
    private static let decoderReceptiveField = 4
    /// Hidden-state frames fed to the decoder per call (reference: 8).
    private static let decoderChunkFrames = 8
    /// The model's own vocab size (config.json) — logits are [1, seq, 8192].
    /// tokenIDs.count is smaller than this (the dict skips gaps), so it must
    /// NEVER be used as the logits stride: the CI spike crashed sampling
    /// (Gather idx out of bounds at vocabSize=39) over exactly that mistake.
    private static let vocabSize = 8192
    private static let samplesPerToken = 2048
    /// 120, not 200: TTFA is the full autoregressive run of chunk 1 (the
    /// core schedules nothing until generateChunk returns), and sentence-
    /// bounded chunks of ~120 chars halve the steps before the first audio
    /// while staying inside the 2–15 s sentence window the model card
    /// recommends.
    private static let chunkMaxChars = 120

    // Model state — the core's generateQueue only.
    private var ortEnv: ORTEnv?
    private var backbone: ORTSession?
    private var decoder: ORTSession?
    private var tokenIDs: [String: Int] = [:]
    /// The model's real BPE tokenizer (vocab + 135 merges from
    /// tokenizer.json). Nil until load; generateChunk falls back to greedy
    /// longest-match if the merges failed to parse.
    private var bpeTokenizer: SopranoBPETokenizer?
    private var modelLoadAttempted = false

    override init() {
        self.core = StreamingTTSPlaybackCore(config: .init(
            sampleRate: 32_000,
            chunkMaxChars: Self.chunkMaxChars,
            generationAheadLimit: 2,
            exportInterChunkSilence: 0.05,
            logPrefix: "SopranoEngine"
        ))
        super.init()

        core.isModelReady = { [weak self] in
            guard let self else { return false }
            self.loadModelIfNeeded()
            return self.backbone != nil && self.decoder != nil
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

    /// True once sessions were actually loaded this instance — the idle
    /// unload only pays off when there's something resident to free.
    var hasLoadedModel: Bool { modelLoadAttempted }

    // MARK: - Model loading (generateQueue)

    private func loadModelIfNeeded() {
        guard !modelLoadAttempted else { return }

        guard ModelManager.sopranoFilesAreValid() else {
            Log.shared.error("SopranoEngine: model files missing or invalid at \(ModelManager.sopranoDirectory.path)")
            return
        }

        do {
            let started = Date()
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(4)
            let backboneSession = try ORTSession(
                env: env,
                modelPath: ModelManager.sopranoBackboneFileURL.path,
                sessionOptions: options
            )
            let decoderSession = try ORTSession(
                env: env,
                modelPath: ModelManager.sopranoDecoderFileURL.path,
                sessionOptions: options
            )
            ortEnv = env
            backbone = backboneSession
            decoder = decoderSession

            tokenIDs = ModelManager.sopranoTokenizerVocabulary() ?? [:]
            guard !tokenIDs.isEmpty else {
                backbone = nil
                decoder = nil
                Log.shared.error("SopranoEngine: tokenizer.json has no usable vocab")
                return
            }
            bpeTokenizer = SopranoBPETokenizer(
                vocab: tokenIDs,
                merges: ModelManager.sopranoTokenizerMerges()
            )
            // Only latch AFTER success — a transient ORT error (memory
            // pressure, file lock) must not brick the engine until relaunch.
            modelLoadAttempted = true
            Log.shared.info("SopranoEngine: 2 sessions + \(tokenIDs.count) vocab entries loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch {
            backbone = nil
            decoder = nil
            Log.shared.error("SopranoEngine: model load failed: \(error) — will retry on next speak")
        }
    }

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let logIt = validationCalls == 0
        validationCalls += 1
        let filesValid = PlaybackMetrics.timedValidation(
            prefix: core.config.logPrefix,
            label: "play-path file validation",
            alwaysLog: logIt
        ) { ModelManager.sopranoFilesAreValid() }
        guard filesValid else {
            Log.shared.error("SopranoEngine asked to speak but its model isn't downloaded")
            return
        }
        core.speak(text, rateMultiplier: rateMultiplier)
    }

    func pause() { core.pause() }
    func resume() { core.resume() }
    func stop() { core.stop() }

    /// Core liveness — see SpeechEngine.hasLiveSession.
    var hasLiveSession: Bool { core.hasLiveSession }

    // MARK: - Synthesis (generateQueue)

    /// Text → normalise → tokenize → autoregressive backbone → decoder
    /// windows → samples. The live speed is read per chunk from the core.
    ///
    /// The decode schedule is the reference's (ekwek1/soprano `infer_stream`,
    /// pinned here after the original web repo vanished): a `chunk_counter`
    /// gates the decoder to run once every `decoderChunkFrames` decode-ready
    /// steps, and each run keeps ONLY the `decoderChunkFrames` tokens that
    /// just gained their receptive field of future context — emitted audio
    /// lags the newest frame by RF − 1 tokens. The first version of this
    /// loop decoded EVERY step and sliced an overlapping window, re-emitting
    /// ~7 copies of each token's audio (the "repeats the same syllable"
    /// device report) while spending ~8× the decoder time. Every exit path
    /// ends with the reference's finish decode — (RF + counter − 2) tokens
    /// of the final ring, exactly the frames no mid-stream window covered —
    /// so nothing duplicates and nothing cuts off mid-word.
    private func generateChunk(_ text: String) throws -> [Float] {
        guard let backbone, let decoder else { throw SopranoEngineError.modelUnavailable }
        guard !tokenIDs.isEmpty else { throw SopranoEngineError.noVocab }

        // The reference generation loop: prompt = [STOP][TEXT] + tokens +
        // [START] in ONE prefill, then one token per step. [STOP] also ENDS
        // generation when the model emits it (it is the eos/pad token, id 3).
        // Numbers: the eos id is taken from the tokenizer's added_tokens so a
        // re-export with different ids stays correct, and the STRIDE over the
        // logits is the model's vocab size (8192), never tokenIDs.count.
        let normalized = SopranoTextNormalizer.normalize(text)
        // The model's real BPE (vocab + merges); greedy longest-match is the
        // fallback when the merges didn't parse — it produces valid ids but
        // sequences BPE would never build, which degrades the voice.
        var ids: [Int]
        if let bpeTokenizer {
            ids = bpeTokenizer.encode(normalized)
        } else {
            ids = Self.greedyEncode(normalized, vocab: tokenIDs)
        }
        guard !ids.isEmpty else { throw SopranoEngineError.tokenizationFailed }
        let stopID = Self.specialID(named: "[STOP]", in: tokenIDs) ?? 3
        let startID = Self.specialID(named: "[START]", in: tokenIDs) ?? 2
        ids.insert(stopID, at: 0)
        ids.append(startID)

        // A chunk the model fully speaks is roughly 2-4 s of audio; the
        // sentence chunker keeps our inputs short, but the token ceiling is a
        // hard stop either way (the graph's position window).
        let maxTokens = 512
        var pastKeys: [ORTValue] = []
        var pastValues: [ORTValue] = []
        /// Rolling tail of hidden-state frames (last token's 512 floats per
        /// step). The reference trims to 2*RF + chunk frames.
        var hiddenRing: [[Float]] = []
        var samples: [Float] = []
        var rng = SystemRandomNumberGenerator()
        var sequenceLen = ids.count
        var seenTokens = Set<Int>()
        seenTokens.formUnion(ids)
        let started = Date()

        var step = 0
        var endReason = "maxTokens"
        /// Reference chunk_counter: starts at `decoderChunkFrames` so the
        /// first decode fires as soon as the ring holds RF + chunk frames,
        /// then resets to 0 on every decode and ticks once per decode-ready
        /// step — the decoder runs on every `decoderChunkFrames`-th step.
        var chunkCounter = Self.decoderChunkFrames
        var decodeRuns = 0
        var prefillSeconds: TimeInterval = 0
        /// Recent samples for the loop detector (see nextToken call site).
        var recentTokens: [Int] = []
        var lastLoopPattern: Set<Int>?
        var loopBreaks = 0

        // Decode the current ring and append only the slice the reference
        // keeps. `tailTokens` = nil for a mid-stream window (fixed slice,
        // lagging RF−1 tokens behind the frontier), or the token count for
        // the finish decode (the reference's `audio[-((RF+counter−2)·T):]`).
        func decodeRing(tailTokens: Int?) throws {
            let frames = hiddenRing
            guard !frames.isEmpty else { return }
            let decodeStart = Date()
            let windowFrames = frames.reduce(into: [Float]()) { $0.append(contentsOf: $1) }
            let frameCount = frames.count
            let decoderOutput = try decoder.run(
                withInputs: ["hidden_states": try Self.floatTensor(
                    windowFrames,
                    shape: [NSNumber(value: 1), NSNumber(value: Self.hiddenSize), NSNumber(value: frameCount)]
                )],
                outputNames: Self.decoderOutputNames(for: decoder),
                runOptions: nil
            )
            let audioName = ((try? decoder.outputNames()) ?? []).first ?? "audio"
            guard let audioValue = decoderOutput[audioName] else {
                throw SopranoEngineError.missingOutput
            }
            let audioData: Data = try audioValue.tensorData() as Data
            let audio = Self.floats(from: audioData)
            let kept: ArraySlice<Float>
            if let tailTokens {
                // Finish: keep everything the mid-stream windows have not
                // emitted yet — the tail of the final window. A negative
                // start clamps to 0 (the reference's python slice does).
                let start = max(0, audio.count - tailTokens * Self.samplesPerToken)
                kept = audio[start...]
            } else {
                // Mid-stream: keep the decoderChunkFrames tokens whose
                // receptive field of future context just completed — the
                // window's local [(RF+chunk−1) … (RF−1)] tokens from the end.
                let start = audio.count - (Self.decoderReceptiveField + Self.decoderChunkFrames - 1) * Self.samplesPerToken
                let end = audio.count - (Self.decoderReceptiveField - 1) * Self.samplesPerToken
                if start >= 0, end > start, end <= audio.count {
                    kept = audio[start..<end]
                } else {
                    // A decoder that returned fewer samples than its frames
                    // imply has nothing safely sliceable — emit nothing
                    // rather than a duplicate of the previous window.
                    kept = audio[0..<0]
                }
            }
            let keptArray = Array(kept)
            decodeRuns += 1
            samples.append(contentsOf: keptArray)
            Log.shared.info("SopranoEngine: decode #\(decodeRuns) in \(String(format: "%.2f", Date().timeIntervalSince(decodeStart)))s: \(frameCount) frames → +\(keptArray.count) samples (\(String(format: "%.1f", Double(samples.count) / core.sampleRate))s total)")
        }

        // The model's position window (config max_position_embeddings): the
        // rope table gathers at position_ids, so prompt + generated beyond
        // this throws mid-loop. Emit what we have instead of losing the chunk.
        let positionCeiling = 512
        do {
            while step < maxTokens {
                if sequenceLen >= positionCeiling {
                    endReason = "positionCeiling"
                    Log.shared.info("SopranoEngine: chunk hit the \(positionCeiling)-position ceiling after \(step) generated tokens")
                    break
                }
                let inputIDs: [Int64] = step == 0 ? ids.map(Int64.init) : [Int64(ids[ids.count - 1])]
                let mask = Array(repeating: Int64(1), count: sequenceLen)
                let positionStart = step == 0 ? 0 : sequenceLen - 1
                let positionIDs = Array(stride(from: positionStart, through: sequenceLen - 1, by: 1)).map(Int64.init)

                var inputs: [String: ORTValue] = [:]
                inputs["input_ids"] = try Self.int64Tensor(inputIDs, shape: [1, NSNumber(value: inputIDs.count)])
                inputs["attention_mask"] = try Self.int64Tensor(mask, shape: [1, NSNumber(value: mask.count)])
                inputs["position_ids"] = try Self.int64Tensor(positionIDs, shape: [1, NSNumber(value: positionIDs.count)])
                let backboneInputNames = (try? backbone.inputNames()) ?? []
                if step == 0 {
                    for name in backboneInputNames where name.contains(".key") || name.contains(".value") {
                        inputs[name] = try Self.floatTensor([], shape: [NSNumber(value: 1), NSNumber(value: 1), NSNumber(value: 0), NSNumber(value: Self.kvDim)])
                    }
                } else {
                    var keyIndex = 0
                    var valueIndex = 0
                    for name in backboneInputNames {
                        if name.contains(".key"), keyIndex < pastKeys.count {
                            inputs[name] = pastKeys[keyIndex]
                            keyIndex += 1
                        } else if name.contains(".value"), valueIndex < pastValues.count {
                            inputs[name] = pastValues[valueIndex]
                            valueIndex += 1
                        }
                    }
                }

                let backboneOutputNames = (try? backbone.outputNames()) ?? []
                let stepStart = Date()
                let outputs = try backbone.run(
                    withInputs: inputs,
                    outputNames: Set(backboneOutputNames),
                    runOptions: nil
                )
                if step == 0 {
                    prefillSeconds = Date().timeIntervalSince(stepStart)
                }

                // Refresh the caches (the export returns present.N.{key,value}).
                pastKeys = []
                pastValues = []
                for name in backboneOutputNames {
                    guard let value = outputs[name] else { continue }
                    if name.contains(".key") { pastKeys.append(value) }
                    if name.contains(".value") { pastValues.append(value) }
                }

                guard let hiddenName = backboneOutputNames.contains("last_hidden_state")
                        ? Optional("last_hidden_state")
                        : (backboneOutputNames.contains("hidden_states") ? Optional("hidden_states") : nil),
                      let hiddenValue = outputs[hiddenName] else {
                    throw SopranoEngineError.missingOutput
                }
                let hiddenData: Data = try hiddenValue.tensorData() as Data
                // The export's layout was never pinned (the spike header and
                // the old slicing code contradict each other) — read the
                // tensor's actual shape and take the last position's frame
                // in whichever orientation it really is.
                let lastFrame = try lastHiddenFrame(
                    tensorData: hiddenData,
                    shape: ((try? hiddenValue.tensorTypeAndShapeInfo())?.shape ?? []).map { $0.intValue }
                )
                // The prefill's own frame (the [START] prompt position) never
                // sounds — only generated-token frames reach the decoder.
                if step > 0 {
                    hiddenRing.append(lastFrame)
                }
                let ringCapacity = 2 * Self.decoderReceptiveField + Self.decoderChunkFrames
                if hiddenRing.count > ringCapacity {
                    hiddenRing.removeFirst(hiddenRing.count - ringCapacity)
                }

                // Reference decode gate — every decoderChunkFrames-th
                // decode-ready step, NEVER every step.
                if hiddenRing.count >= Self.decoderReceptiveField + Self.decoderChunkFrames {
                    if chunkCounter == Self.decoderChunkFrames {
                        try decodeRing(tailTokens: nil)
                        chunkCounter = 0
                    }
                    chunkCounter += 1
                }

                // Next token from the last position's logits; [STOP] ends the
                // chunk. Repetition penalty 1.2 over seen tokens (reference).
                step += 1
                if step >= maxTokens { break }
                guard let logitsValue = outputs["logits"] else {
                    endReason = "noLogits"
                    break
                }
                let logitsData: Data = try logitsValue.tensorData() as Data
                // Sampling-loop insurance: the reference's repetition penalty
                // is presence-based (a token in the set is penalized once,
                // however often it repeats), so a 1-3-token cycle never
                // escalates on its own. Detect the cycle and break it this
                // step with an escalated penalty; top_p 0.95 (the model
                // card's setting) additionally cuts the tail that feeds such
                // loops.
                let loopTokens = Self.loopPatternTokens(in: recentTokens)
                if !loopTokens.isEmpty, loopTokens != lastLoopPattern {
                    loopBreaks += 1
                    Log.shared.warning("SopranoEngine: token loop #\(loopBreaks) — breaking repeated pattern \(loopTokens.sorted()) at step \(step)")
                }
                lastLoopPattern = loopTokens.isEmpty ? nil : loopTokens
                let next = Self.nextToken(
                    logits: logitsData,
                    vocabSize: Self.vocabSize,
                    fallback: stopID,
                    temperature: 0.3,
                    topK: 50,
                    topP: 0.95,
                    repetitionPenalty: 1.2,
                    loopPenaltyTokens: loopTokens,
                    seenTokens: seenTokens,
                    rng: &rng
                )
                recentTokens.append(next)
                if recentTokens.count > 16 {
                    recentTokens.removeFirst(recentTokens.count - 16)
                }
                if next == stopID {
                    endReason = "[STOP]"
                    break
                }
                seenTokens.insert(next)
                ids = [next]
                sequenceLen += 1
            }

            // The reference's finish decode: emit the frames no mid-stream
            // window covered — (RF + counter − 2) tokens of the final ring,
            // exactly the stragglers past the last emitted slice.
            if !hiddenRing.isEmpty {
                try decodeRing(tailTokens: max(1, Self.decoderReceptiveField + chunkCounter - 2))
            }
        } catch let sopranoError as SopranoEngineError {
            throw sopranoError
        } catch {
            // The core skips the chunk (one log, one beep) — but the REAL
            // error must not die here: the first device round lost a whole
            // engine to a masked ORT shape error ("missingOutput" on every
            // chunk, no way to tell why). Log the underlying error verbatim.
            Log.shared.error("SopranoEngine: chunk generation failed at step \(step): \(error)")
            throw SopranoEngineError.missingOutput
        }

        let duration = Double(samples.count) / core.sampleRate
        let wall = Date().timeIntervalSince(started)
        let rtf = wall / max(duration, 0.01)
        Log.shared.info("SopranoEngine: chunk done — \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", wall))s (RTF \(String(format: "%.1f", rtf)), prefill \(String(format: "%.0f", prefillSeconds * 1000)) ms, \(step) steps, \(decodeRuns) decodes, \(loopBreaks) loop breaks, end: \(endReason))")
        guard !samples.isEmpty else {
            Log.shared.error("SopranoEngine: chunk produced no audio (\(endReason)) — «\(text.prefix(60))»")
            throw SopranoEngineError.missingOutput
        }
        return samples
    }

    // MARK: - WAV export

    func renderWAV(
        text: String,
        title: String? = nil,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard ModelManager.sopranoFilesAreValid() else {
            completion(.failure(SopranoEngineError.modelUnavailable))
            return
        }
        core.renderWAV(text: text, title: title, onChunkProgress: onChunkProgress, completion: completion)
    }

    // MARK: - Static helpers

    /// True once the hidden-state tensor layout was logged this session.
    private var loggedHiddenLayout = false

    /// The LAST position's hidden frame, respecting the tensor's actual
    /// layout. The spike header claimed `last_hidden_state` is
    /// [1, 512, seqLen] (channel-first) while the old slicing code assumed
    /// [1, seqLen, 512] (token-first) — the two contradict, and the wrong
    /// assumption feeds the vocoder CHANNEL SLICES as if they were frames:
    /// structured garbage that sounds like syllables repeated with slight
    /// variation. The layout is read from the value itself and logged once.
    private func lastHiddenFrame(tensorData: Data, shape: [Int]) throws -> [Float] {
        let values = Self.floats(from: tensorData)
        let hiddenSize = Self.hiddenSize
        guard shape.count == 3, shape[0] == 1, values.count == shape[1] * shape[2] else {
            Log.shared.error("SopranoEngine: hidden-state shape unreadable (\(shape), \(values.count) floats) — assuming token-first")
            guard values.count >= hiddenSize else { throw SopranoEngineError.missingOutput }
            return Array(values.suffix(hiddenSize))
        }
        if shape[2] == hiddenSize {
            // [1, seqLen, hidden] — token-first: frames are contiguous.
            let seqLen = shape[1]
            if !loggedHiddenLayout {
                loggedHiddenLayout = true
                Log.shared.info("SopranoEngine: hidden-state tensor is token-first [1, \(seqLen), \(hiddenSize)]")
            }
            return Array(values[(seqLen - 1) * hiddenSize..<(seqLen * hiddenSize)])
        }
        if shape[1] == hiddenSize {
            // [1, hidden, seqLen] — channel-first: the last position is a
            // strided gather (element [c, seq-1] lives at c*seqLen + seq-1).
            let seqLen = shape[2]
            if !loggedHiddenLayout {
                loggedHiddenLayout = true
                Log.shared.warning("SopranoEngine: hidden-state tensor is CHANNEL-first [1, \(hiddenSize), \(seqLen)] — every prior build sliced it wrong")
            }
            var frame = [Float](repeating: 0, count: hiddenSize)
            for channel in 0..<hiddenSize {
                frame[channel] = values[channel * seqLen + seqLen - 1]
            }
            return frame
        }
        Log.shared.error("SopranoEngine: unexpected hidden-state shape \(shape) — assuming token-first")
        guard values.count >= hiddenSize else { throw SopranoEngineError.missingOutput }
        return Array(values.suffix(hiddenSize))
    }

    private static func decoderOutputNames(for session: ORTSession) -> Set<String> {
        Set((try? session.outputNames()) ?? [])
    }

    static func int64Tensor(_ values: [Int64], shape: [NSNumber]) throws -> ORTValue {
        try ORTValue(
            tensorData: NSMutableData(bytes: values, length: values.count * MemoryLayout<Int64>.size),
            elementType: .int64,
            shape: shape
        )
    }

    static func floatTensor(_ values: [Float], shape: [NSNumber]) throws -> ORTValue {
        if values.isEmpty {
            // Zero-length tensors are valid (empty KV caches).
            return try ORTValue(
                tensorData: NSMutableData(),
                elementType: .float,
                shape: shape
            )
        }
        return try ORTValue(
            tensorData: NSMutableData(bytes: values, length: values.count * MemoryLayout<Float>.size),
            elementType: .float,
            shape: shape
        )
    }

    static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            return Array(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Float.self),
                count: data.count / MemoryLayout<Float>.size
            ))
        }
    }

    static func specialID(named name: String, in vocab: [String: Int]) -> Int? {
        vocab[name]
    }

    /// Longest-match greedy tokenization — the app's real pre-tokenizer is a
    /// future refinement; the vocab is a plain {token: id} map, and greedy
    /// longest-match over it is lossless for English prose.
    static func greedyEncode(_ text: String, vocab: [String: Int]) -> [Int] {
        var ids: [Int] = []
        var i = text.startIndex
        while i < text.endIndex {
            var matched = false
            var length = text.distance(from: i, to: text.endIndex)
            while length > 0 {
                let end = text.index(i, offsetBy: length)
                if let id = vocab[String(text[i..<end])] {
                    ids.append(id)
                    i = end
                    matched = true
                    break
                }
                length -= 1
            }
            if !matched { i = text.index(after: i) }
        }
        return ids
    }

    /// Temperature + top-k + nucleus (top-p) sampling over the LAST
    /// position's logits (the graph returns [1, seqLen, vocab] with the
    /// model's vocab size as the stride — never tokenIDs.count, which is
    /// smaller and produced the out-of-bounds Gather crash). Repetition
    /// penalty follows the HF convention the reference uses: seen logits are
    /// scaled, not masked. `loopPenaltyTokens` (a detected repeating cycle)
    /// take an extra hard cut for this step only.
    static func nextToken(
        logits: Data,
        vocabSize: Int,
        fallback: Int,
        temperature: Double,
        topK: Int,
        topP: Double = 1.0,
        repetitionPenalty: Double = 1.0,
        loopPenaltyTokens: Set<Int> = [],
        seenTokens: Set<Int> = [],
        rng: inout SystemRandomNumberGenerator
    ) -> Int {
        guard !logits.isEmpty, vocabSize > 0 else { return fallback }
        let values = floats(from: logits)
        let start = values.count - vocabSize
        guard start >= 0 else { return fallback }
        var last = Array(values[start...])
        guard last.count >= vocabSize else { return fallback }
        last = Array(last.prefix(vocabSize))
        // A NaN/Inf row (an ORT numerical hiccup) makes `sorted` undefined
        // and the softmax total 0 — bail to the fallback token instead of
        // looping on garbage.
        guard last.allSatisfy({ $0.isFinite }) else { return fallback }
        if repetitionPenalty != 1.0 {
            for token in seenTokens where token >= 0 && token < last.count {
                if last[token] < 0 {
                    last[token] *= Float(repetitionPenalty)
                } else {
                    last[token] /= Float(repetitionPenalty)
                }
            }
        }
        if !loopPenaltyTokens.isEmpty {
            // Presence-based penalties never escalate on a cycle; this one
            // does, for exactly one step.
            for token in loopPenaltyTokens where token >= 0 && token < last.count {
                last[token] /= 3
            }
        }
        let sorted = last.indices.sorted { last[$0] > last[$1] }
        let k = min(topK, last.count)
        var top = Array(sorted.prefix(k))
        if topP < 1.0, !top.isEmpty {
            // Nucleus filter (model card: top_p 0.95): keep the smallest
            // prefix of the sorted candidates whose softmax mass reaches
            // topP — the long tail that feeds degenerate loops is cut while
            // expressiveness stays.
            let scale = max(0.05, temperature)
            let maxScaled = Double(last[top[0]]) / scale
            let exps = top.map { Foundation.exp(Double(last[$0]) / scale - maxScaled) }
            let total = exps.reduce(0, +)
            if total > 0 {
                var cumulative = 0.0
                var cutoff = top.count
                for (index, weight) in exps.enumerated() {
                    cumulative += weight / total
                    if cumulative >= topP {
                        cutoff = index + 1
                        break
                    }
                }
                top = Array(top.prefix(max(1, cutoff)))
            }
        }
        let scaled = top.map { Double(last[$0]) / max(0.05, temperature) }
        let maxScaled = scaled.max() ?? 0
        let exps = scaled.map { Foundation.exp($0 - maxScaled) }
        let total = exps.reduce(0, +)
        guard total > 0 else { return top.isEmpty ? fallback : top[0] }
        var draw = Double.random(in: 0..<1, using: &rng) * total
        for (index, weight) in exps.enumerated() {
            draw -= weight
            if draw <= 0 { return top[index] }
        }
        return top[0]
    }

    /// The tokens of a 1-3-token pattern repeating 4× consecutively at the
    /// end of the recent history — the fingerprint of a sampling loop. The
    /// caller escalates their penalty for one step, which slides the pattern
    /// out of the window naturally (or keeps it suppressed until it does).
    static func loopPatternTokens(in recent: [Int]) -> Set<Int> {
        for length in 1...3 {
            let window = 4 * length
            guard recent.count >= window else { continue }
            let tail = Array(recent.suffix(window))
            let pattern = Array(tail[(tail.count - length)...])
            var isLoop = true
            var offset = 0
            while offset < tail.count {
                if Array(tail[offset..<(offset + length)]) != pattern {
                    isLoop = false
                    break
                }
                offset += length
            }
            if isLoop { return Set(pattern) }
        }
        return []
    }
}

/// User-facing failures for the Soprano path.
enum SopranoEngineError: LocalizedError {
    case modelUnavailable
    case noVocab
    case tokenizationFailed
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "The Soprano model isn't downloaded or failed to load."
        case .noVocab: return "The Soprano tokenizer has no vocabulary — re-download the model."
        case .tokenizationFailed: return "Couldn't convert the text to tokens."
        case .missingOutput: return "The model returned no usable output for this chunk."
        }
    }
}
