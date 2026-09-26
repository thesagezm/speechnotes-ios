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
///                    last_hidden_state ([1, 512, seqLen])
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
    private static let chunkMaxChars = 200

    // Model state — the core's generateQueue only.
    private var ortEnv: ORTEnv?
    private var backbone: ORTSession?
    private var decoder: ORTSession?
    private var tokenIDs: [String: Int] = [:]
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
    private func generateChunk(_ text: String) throws -> [Float] {
        guard let backbone, let decoder else { throw SopranoEngineError.modelUnavailable }
        guard !tokenIDs.isEmpty else { throw SopranoEngineError.noVocab }

        // The reference generation loop (KevinAHM/soprano-web-onnx, Apache-2.0):
        // prompt = [STOP][TEXT] + tokens + [START] in ONE prefill, then one
        // token per step. [STOP] also ENDS generation when the model emits it
        // (it is the eos/pad token, id 3); the old loop fed it back as the
        // decode "pad token" and generated 512 steps of junk. Numbers: the
        // eos id is taken from the tokenizer's added_tokens so a re-export
        // with different ids stays correct, and the STRIDE over the logits is
        // the model's vocab size (8192), never tokenIDs.count.
        let normalized = SopranoTextNormalizer.normalize(text)
        var ids = Self.greedyEncode(normalized, vocab: tokenIDs)
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
        var finished = false
        do {
        while step < maxTokens, !finished {
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
                    inputs[name] = try Self.floatTensor([], shape: [NSNumber(value: 1), NSNumber(value: 1), NSNumber(value: 0), NSNumber(value: Self.hiddenSize)])
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
            let outputs = try backbone.run(
                withInputs: inputs,
                outputNames: Set(backboneOutputNames),
                runOptions: nil
            )

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
            let stepHidden = Self.floats(from: hiddenData)
            // The graph returns the whole sequence's hidden states ([1,
            // seqLen, 512]) every step — keep only the LAST position's frame,
            // exactly like the reference's slice((seqLen-1)*512, seqLen*512).
            guard stepHidden.count >= Self.hiddenSize else {
                throw SopranoEngineError.missingOutput
            }
            let lastFrame = Array(stepHidden.suffix(Self.hiddenSize))
            // The reference skips the prefill's own frame (i > 0) so the
            // prompt never sounds; only generated-token frames reach the
            // decoder.
            if step > 0 {
                hiddenRing.append(lastFrame)
            }
            let ringCapacity = 2 * Self.decoderReceptiveField + Self.decoderChunkFrames
            if hiddenRing.count > ringCapacity {
                hiddenRing.removeFirst(hiddenRing.count - ringCapacity)
            }

            // Decoder: once the ring holds receptive field + chunk frames,
            // feed it all (shape [1, 512, frames]) and keep the slice the
            // reference keeps — the last (RF + chunk − 1) tokens' worth minus
            // the trailing RF tail, offset by one token so the edges line up.
            if hiddenRing.count >= Self.decoderReceptiveField + Self.decoderChunkFrames {
                let frames = hiddenRing
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
                var audio = Self.floats(from: audioData)
                // Slice per the reference: keep [ (RF + chunk − 1) tokens in
                // from the start, end RF tokens in from the end ] — a +1-token
                // offset on both edges.
                let startIdx = audio.count - (Self.decoderReceptiveField + Self.decoderChunkFrames - 1) * Self.samplesPerToken + Self.samplesPerToken
                let endIdx = audio.count - Self.decoderReceptiveField * Self.samplesPerToken + Self.samplesPerToken
                if startIdx >= 0, endIdx > startIdx, endIdx <= audio.count {
                    audio = Array(audio[startIdx..<endIdx])
                }
                samples.append(contentsOf: audio)
                // A finish-decode consumes the ring; a mid-stream chunk
                // decode keeps the tail (the reference's chunkCounter carries
                // the partial window into the next decode).
                if finished {
                    hiddenRing.removeAll(keepingCapacity: true)
                }
            }

            // Next token from the last position's logits; [STOP] ends the
            // chunk. Repetition penalty 1.2 over seen tokens (reference).
            step += 1
            if step >= maxTokens { break }
            guard let logitsValue = outputs["logits"] else { break }
            let logitsData: Data = try logitsValue.tensorData() as Data
            let next = Self.nextToken(
                logits: logitsData,
                vocabSize: Self.vocabSize,
                fallback: stopID,
                temperature: 0.3,
                topK: 50,
                repetitionPenalty: 1.2,
                seenTokens: seenTokens,
                rng: &rng
            )
            if next == stopID {
                finished = true
                break
            }
            seenTokens.insert(next)
            ids = [next]
            sequenceLen += 1
        }
        } catch let sopranoError as SopranoEngineError {
            throw sopranoError
        } catch {
            // A chunk the model cannot synthesize is skipped upstream (the
            // core logs, beeps once, and steps over it) — surface the failure
            // as an ordinary error and let that machinery work.
            throw SopranoEngineError.missingOutput
        }

        let duration = Double(samples.count) / core.sampleRate
        Log.shared.info("SopranoEngine: \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
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

    /// Temperature + top-k sampling over the LAST position's logits (the
    /// graph returns [1, seqLen, vocab] with the model's vocab size as the
    /// stride — never tokenIDs.count, which is smaller and produced the
    /// out-of-bounds Gather crash). Repetition penalty follows the HF
    /// convention the reference uses: seen logits are scaled, not masked.
    static func nextToken(
        logits: Data,
        vocabSize: Int,
        fallback: Int,
        temperature: Double,
        topK: Int,
        repetitionPenalty: Double = 1.0,
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
        if repetitionPenalty != 1.0 {
            for token in seenTokens where token >= 0 && token < last.count {
                if last[token] < 0 {
                    last[token] *= Float(repetitionPenalty)
                } else {
                    last[token] /= Float(repetitionPenalty)
                }
            }
        }
        let sorted = last.indices.sorted { last[$0] > last[$1] }
        let k = min(topK, last.count)
        let top = Array(sorted.prefix(k))
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
