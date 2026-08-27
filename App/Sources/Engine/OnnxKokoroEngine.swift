import AVFoundation
import MisakiSwift
import MLX
import MLXUtilsLibrary
import OnnxRuntimeBindings
import SpeechLogic

/// Plan B engine: Kokoro via ONNX Runtime on the CPU — the PocketPal AI
/// approach. Model (`model_q8f16.onnx`, ~82 MB) + tokenizer.json live in
/// Documents/KokoroOnnx; voice style vectors are reused from the existing
/// MLX voices.npz. Inference spec verified against PocketPal's
/// react-native-speech engine: inputs `input_ids` int64 [1, N],
/// `style` float32 [1, 256] (flat voice array sliced at
/// clamp(N-2, 0, 509) * 256), `speed` float32 [1]; output `waveform`
/// float32 @ 24 kHz. The model takes speed natively, so playback is a plain
/// player node — no time-pitch gymnastics.
///
/// Streaming architecture (sentence chunks via
/// SpeechLogic, generation capped a few chunks ahead, played buffers
/// released, read-along ranges, interruption handling). MLX/Metal is never
/// touched for inference — this is the escape hatch when Metal memory
/// pressure kills long notes.
final class OnnxKokoroEngine: NSObject, SpeechEngine {
    let name = "Kokoro ONNX (CPU)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?

    var voice = "am_eric"

    private static let sampleRate: Double = 24_000
    private static let styleDim = 256
    private static let maxTokens = 510

    /// How many chunks beyond the playback cursor the producer may generate
    /// ahead — keeps queued audio bounded on long notes.
    private static let generationAheadLimit = 3

    /// Maximum characters (~30 words) per synthesis call.
    private static let chunkMaxChars = 160

    private let engineQueue = DispatchQueue(label: "com.speechnotes.onnxkokoro", qos: .userInitiated)

    // Model state — engineQueue only.
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

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioNodesAttached = false
    private var audioEngineRunning = false
    private var connectedFormat: AVAudioFormat?

    private var playbackGeneration = 0

    // Streaming pipeline state — main thread only.
    private var chunks: [Chunk] = []
    private var generatedBuffers: [Int: AVAudioPCMBuffer] = [:]
    private var scheduledUpTo = -1
    private var totalChars = 1
    private var speed: Float = 1.0

    private var interruptionObserver: NSObjectProtocol?

    private var state: SpeechState = .idle {
        didSet {
            if state != oldValue {
                Log.shared.info("OnnxKokoroEngine state: \(oldValue) → \(state)")
                if state == .idle {
                    teardownPlayback()
                    onProgress?(0)
                }
                onStateChanged?(state)
            }
        }
    }

    override init() {
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            Log.shared.error("OnnxKokoroEngine audio session setup failed: \(error)")
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        Log.shared.info("OnnxKokoroEngine created")
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        if typeRaw == AVAudioSession.InterruptionType.began.rawValue {
            if state == .speaking { pause() }
        } else if typeRaw == AVAudioSession.InterruptionType.ended.rawValue,
                  optionsRaw & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 {
            if state == .paused { resume() }
        }
    }

    // MARK: - Model loading (engineQueue)

    private func loadModelIfNeeded() {
        guard !modelLoadAttempted else { return }
        modelLoadAttempted = true

        let modelPath = ModelManager.onnxModelFileURL
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
        } catch {
            ortSession = nil
            Log.shared.error("OnnxKokoroEngine: model load failed: \(error)")
        }
    }

    /// engineQueue only — phonemize with Misaki (same G2P the MLX engine uses).
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

    /// engineQueue only — phonemes → token IDs (per-character vocab lookup,
    /// matching the reference tokenizer for this model).
    private func tokenize(_ phonemes: String) -> [Int] {
        phonemes.map { vocab[String($0)] }.compactMap { $0 }
    }

    /// engineQueue only — the core ONNX inference call.
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
        var speedValue = speed
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

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        guard ModelManager.onnxFilesAreValid() else {
            Log.shared.error("OnnxKokoroEngine asked to speak but no ONNX model is downloaded")
            state = .idle
            return
        }

        let allChunks = SentenceChunker.chunks(
            for: clean,
            firstMaxChars: Self.chunkMaxChars,
            batchMaxChars: Self.chunkMaxChars
        )
        guard !allChunks.isEmpty else { return }

        DispatchQueue.main.async { self.state = .generating }

        let generation = playbackGeneration + 1
        playbackGeneration = generation

        chunks = allChunks
        generatedBuffers = [:]
        scheduledUpTo = -1
        totalChars = max(1, clean.utf16.count)
        speed = Float(min(2.0, max(0.5, rateMultiplier)))

        engineQueue.async { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.loadModelIfNeeded()
            guard self.ortSession != nil else {
                DispatchQueue.main.async {
                    if self.playbackGeneration == generation { self.state = .idle }
                }
                return
            }

            for (index, chunk) in allChunks.enumerated() {
                while self.playbackGeneration == generation,
                      index > self.scheduledUpTo + Self.generationAheadLimit {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard self.playbackGeneration == generation else { return }
                do {
                    let buffer = try self.generateChunk(chunk.text)
                    let nsBuffer = Self.makeMonoBuffer(samples: buffer)
                    DispatchQueue.main.async {
                        guard self.playbackGeneration == generation else { return }
                        self.generatedBuffers[index] = nsBuffer
                        self.scheduleReadyChunks(generation: generation)
                    }
                } catch {
                    Log.shared.error("OnnxKokoroEngine chunk \(index + 1) failed: \(error)")
                    DispatchQueue.main.async {
                        if self.playbackGeneration == generation { self.state = .idle }
                    }
                    return
                }
            }
        }
    }

    /// engineQueue only — text → phonemes → tokens → samples.
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
        let duration = Double(samples.count) / Self.sampleRate
        Log.shared.info("OnnxKokoroEngine: \(tokens.count) tokens → \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return samples
    }

    func pause() {
        guard audioEngineRunning, playerNode.isPlaying else { return }
        playerNode.pause()
        state = .paused
    }

    func resume() {
        guard audioEngineRunning, !playerNode.isPlaying, state == .paused else { return }
        playerNode.play()
        state = .speaking
    }

    func stop() {
        playbackGeneration += 1
        state = .idle
    }

    // MARK: - Streaming playback (main thread)

    private func scheduleReadyChunks(generation: Int) {
        guard playbackGeneration == generation else { return }
        while true {
            let next = scheduledUpTo + 1
            guard next < chunks.count, let buffer = generatedBuffers[next] else { return }
            scheduledUpTo = next
            schedule(buffer: buffer, index: next, isLast: next == chunks.count - 1, generation: generation)
        }
    }

    private func schedule(buffer: AVAudioPCMBuffer, index: Int, isLast: Bool, generation: Int) {
        ensureAudioEngineRunning(format: buffer.format)

        let charsDone = chunks.prefix(scheduledUpTo + 1).reduce(0) { $0 + $1.length }
        onProgress?(min(1.0, Double(charsDone) / Double(totalChars)))

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.generatedBuffers[index] = nil
                if isLast {
                    if self.state == .speaking || self.state == .paused || self.state == .generating {
                        self.onProgress?(1.0)
                        self.state = .idle
                    }
                    return
                }
                self.scheduleReadyChunks(generation: generation)
            }
        }

        if state == .generating {
            state = .speaking
            playerNode.play()
        } else if state == .speaking, !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func ensureAudioEngineRunning(format: AVAudioFormat) {
        if !audioNodesAttached {
            audioEngine.attach(playerNode)
            audioNodesAttached = true
        }
        if connectedFormat != format {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                audioEngineRunning = true
            } catch {
                Log.shared.error("OnnxKokoroEngine: audio engine failed to start: \(error)")
                state = .idle
            }
        }
    }

    private func teardownPlayback() {
        playerNode.stop()
        audioEngine.stop()
        audioEngineRunning = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        generatedBuffers = [:]
        scheduledUpTo = -1
    }

    // MARK: - WAV export

    func renderWAV(
        text: String,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(OnnxEngineError.emptyText))
            }
            return
        }
        guard ModelManager.onnxFilesAreValid() else {
            DispatchQueue.main.async {
                completion(.failure(OnnxEngineError.modelUnavailable))
            }
            return
        }

        playbackGeneration += 1
        DispatchQueue.main.async { self.state = .idle }

        let renderChunks = SentenceChunker.chunks(
            for: clean,
            firstMaxChars: Self.chunkMaxChars,
            batchMaxChars: Self.chunkMaxChars
        )
        let total = max(1, clean.utf16.count)

        engineQueue.async { [weak self] in
            guard let self else { return }
            self.loadModelIfNeeded()
            guard self.ortSession != nil else {
                DispatchQueue.main.async {
                    completion(.failure(OnnxEngineError.modelUnavailable))
                }
                return
            }

            var samples: [Float] = []
            do {
                for (index, chunk) in renderChunks.enumerated() {
                    samples.append(contentsOf: try self.generateChunk(chunk.text))
                    let charsDone = renderChunks.prefix(index + 1).reduce(0) { $0 + $1.length }
                    let progress = min(1.0, Double(charsDone) / Double(total))
                    DispatchQueue.main.async { onChunkProgress?(progress) }
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let exportsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
                let url = exportsDir.appendingPathComponent("Note-\(formatter.string(from: Date())).wav")
                try WAVWriter.write(samples: samples, sampleRate: 24_000, to: url)
                let seconds = Double(samples.count) / Self.sampleRate
                Log.shared.info("OnnxKokoroEngine: exported \(String(format: "%.1f", seconds))s of audio to \(url.lastPathComponent)")
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                Log.shared.error("OnnxKokoroEngine export failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Buffers

    private static func makeMonoBuffer(samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity

        let destination = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { source in
            memcpy(destination, source.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        return buffer
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
