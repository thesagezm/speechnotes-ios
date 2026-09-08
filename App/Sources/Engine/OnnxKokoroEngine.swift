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
/// sliced at clamp(N-2, 0, 509) * 256), `speed` float32 [1]; output
/// `waveform` float32 @ 24 kHz. The model takes speed natively, so playback
/// is a plain player node — no time-pitch gymnastics.
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

    private let core: StreamingTTSPlaybackCore

    private static let styleDim = 256
    private static let maxTokens = 510
    private static let chunkMaxChars = 160

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

    init(
        modelFileURL: URL = ModelManager.onnxModelFileURL,
        modelFilesValid: @escaping () -> Bool = { ModelManager.onnxFilesAreValid() }
    ) {
        self.modelFileURL = modelFileURL
        self.modelFilesValid = modelFilesValid
        self.core = StreamingTTSPlaybackCore(config: .init(
            sampleRate: 24_000,
            chunkMaxChars: Self.chunkMaxChars,
            generationAheadLimit: 3,
            exportInterChunkSilence: 0,
            logPrefix: "OnnxKokoroEngine"
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
        guard modelFilesValid() else {
            Log.shared.error("OnnxKokoroEngine asked to speak but no ONNX model is downloaded")
            return
        }
        core.speak(text, rateMultiplier: rateMultiplier)
    }

    func pause() { core.pause() }
    func resume() { core.resume() }
    func stop() { core.stop() }

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
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(4)
            let session = try ORTSession(env: env, modelPath: modelPath.path, sessionOptions: options)
            ortEnv = env
            ortSession = session
            let outputNames = (try? session.outputNames()) ?? []
            if let first = outputNames.first {
                outputName = outputNames.contains("waveform") ? "waveform" : first
            }
            Log.shared.info("OnnxKokoroEngine: session loaded in \(Date().timeIntervalSince(started))s (output: \(outputName))")

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
    private func tokenize(_ phonemes: String) -> [Int] {
        phonemes.map { vocab[String($0)] }.compactMap { $0 }
    }

    /// The core ONNX inference call.
    private func synthesize(tokens: [Int], voiceFlat: [Float]) throws -> [Float] {
        guard let session = ortSession else {
            throw OnnxEngineError.modelUnavailable
        }
        guard tokens.count > 1, tokens.count <= Self.maxTokens else {
            throw OnnxEngineError.tokenCount(tokens.count)
        }

        // Style slice: clamp(N - 2, 0, rows - 1) * 256.
        let rows = max(1, voiceFlat.count / Self.styleDim)
        let adjusted = min(max(tokens.count - 2, 0), rows - 1)
        let offset = adjusted * Self.styleDim
        guard offset + Self.styleDim <= voiceFlat.count else {
            throw OnnxEngineError.voiceShape(voiceFlat.count)
        }
        let style = Array(voiceFlat[offset..<(offset + Self.styleDim)])

        let tokens64 = tokens.map(Int64.init)
        let tokensData = NSMutableData(
            bytes: tokens64,
            length: tokens64.count * MemoryLayout<Int64>.size
        )
        var speedValue = core.speed
        let speedData = NSMutableData(
            bytes: &speedValue,
            length: MemoryLayout<Float>.size
        )

        let tokensTensor = try ORTValue(
            tensorData: tokensData,
            elementType: .int64,
            shape: [1, NSNumber(value: tokens.count)]
        )
        let styleTensor = try ORTValue(
            tensorData: NSMutableData(bytes: style, length: style.count * MemoryLayout<Float>.size),
            elementType: .float,
            shape: [1, NSNumber(value: Self.styleDim)]
        )
        let speedTensor = try ORTValue(
            tensorData: speedData,
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
        let tokens = tokenize(phonemes)
        let started = Date()
        let samples = try synthesize(tokens: tokens, voiceFlat: voiceFlat)
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
        guard modelFilesValid() else {
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
