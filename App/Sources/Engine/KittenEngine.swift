import AVFoundation
import MisakiSwift
import MLXUtilsLibrary
import OnnxRuntimeBindings
import SpeechLogic

/// KittenTTS nano 0.1 — a 15M-parameter StyleTTS2-family model, ~24 MB
/// quantized, CPU-only, English. Inference contract ported from the
/// reference implementation (KittenML/KittenTTS `onnx_model.py`):
/// inputs `input_ids` int64 [1, N] (BOS 0 + symbol-table ids + EOS 10, 0),
/// `style` float32 [1, 256] (one vector per voice — the voice bank stores a
/// single row), `speed` float32 [1]; output waveform float32 @ 24 kHz with
/// the last 5,000 samples trimmed per chunk.
///
/// Phonemization reuses MisakiSwift's EnglishG2P (same IPA-with-stress
/// dialect espeak produces for the reference); symbol mapping is the
/// byte-exact `KittenTokenizer` in SpeechLogic.
///
/// Streaming architecture matches OnnxKokoroEngine: sentence chunks via
/// SpeechLogic, generation capped a few chunks ahead, played buffers
/// released, read-along ranges, interruption handling.
final class KittenEngine: NSObject, SpeechEngine {
    let name = "Kitten"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?

    var voice = KittenEngine.defaultVoice

    static let defaultVoice = "expr-voice-5-m"
    static let voiceNames: [String] = [
        "expr-voice-2-f", "expr-voice-2-m",
        "expr-voice-3-f", "expr-voice-3-m",
        "expr-voice-4-f", "expr-voice-4-m",
        "expr-voice-5-f", "expr-voice-5-m",
    ]
    /// Friendly names for the picker (pairs 2–5; f = Bella/Luna/Rosie/Kiki,
    /// m = Jasper/Bruno/Hugo/Leo — the reference's default expr-voice-5-m is
    /// documented as "Leo").
    static let friendlyNames: [String: String] = [
        "expr-voice-2-f": "Bella", "expr-voice-2-m": "Jasper",
        "expr-voice-3-f": "Luna", "expr-voice-3-m": "Bruno",
        "expr-voice-4-f": "Rosie", "expr-voice-4-m": "Hugo",
        "expr-voice-5-f": "Kiki", "expr-voice-5-m": "Leo",
    ]

    private static let sampleRate: Double = 24_000
    private static let styleDim = 256
    /// The reference trims 5,000 trailing samples (~0.2 s) from every chunk.
    private static let trailingTrim = 5_000

    /// How many chunks beyond the playback cursor the producer may generate
    /// ahead — keeps queued audio bounded on long notes.
    private static let generationAheadLimit = 3

    /// Maximum characters (~30 words) per synthesis call.
    private static let chunkMaxChars = 160

    private let engineQueue = DispatchQueue(label: "com.speechnotes.kitten", qos: .userInitiated)

    // Model state — engineQueue only.
    private var ortEnv: ORTEnv?
    private var ortSession: ORTSession?
    /// Model output tensor name — resolved from the session at load.
    private var outputName: String = "waveform"
    private var voices: [String: [Float]] = [:]
    private var g2p: EnglishG2P?
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
                Log.shared.info("KittenEngine state: \(oldValue) → \(state)")
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
            Log.shared.error("KittenEngine audio session setup failed: \(error)")
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        Log.shared.info("KittenEngine created")
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

        let modelPath = ModelManager.kittenModelFileURL
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            Log.shared.error("KittenEngine: model missing at \(modelPath.deletingLastPathComponent().path)")
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
            Log.shared.info("KittenEngine: session loaded in \(Date().timeIntervalSince(started))s (output: \(outputName))")

            // 8 voices, each a single [1, 256] float row.
            let npzVoices = NpyzReader.read(fileFromPath: ModelManager.kittenVoicesFileURL) ?? [:]
            var flat: [String: [Float]] = [:]
            for (key, array) in npzVoices {
                flat[key] = array.asArray(Float.self)
            }
            voices = flat
            Log.shared.info("KittenEngine: \(flat.count) voices ready")
            // Debugging aid for voice-quality reports: the first four style
            // floats, comparable against the kitten-spike CI log line.
            if let sample = flat["expr-voice-5-m.npy"] ?? flat.first?.value {
                let head = sample.prefix(4).map { String(format: "%.4f", $0) }.joined(separator: ",")
                Log.shared.info("KittenEngine: voice head [\(head)] count \(sample.count)")
            }
            guard !flat.isEmpty else {
                ortSession = nil
                Log.shared.error("KittenEngine: voice bank is empty or unreadable")
                return
            }
        } catch {
            ortSession = nil
            Log.shared.error("KittenEngine: model load failed: \(error)")
        }
    }

    /// engineQueue only — phonemize with Misaki (espeak-compatible IPA).
    private func phonemize(_ text: String) -> String? {
        if g2p == nil { g2p = EnglishG2P(british: false) }
        guard let g2p else { return nil }
        return try? g2p.phonemize(text: text).0
    }

    /// engineQueue only — text → phonemes → tokens (with BOS/EOS wrappers).
    private func tokenize(_ phonemes: String) -> [Int] {
        KittenTokenizer.tokenize(phonemes)
    }

    /// engineQueue only — the core ONNX inference call.
    private func synthesize(tokens: [Int], voiceFlat: [Float]) throws -> [Float] {
        guard let session = ortSession else {
            throw KittenEngineError.modelUnavailable
        }
        guard tokens.count > 3 else {
            throw KittenEngineError.tokenCount(tokens.count)
        }

        // Style: the bank stores one row per voice; keep the reference's
        // row-selection math for banks that ever grow more rows.
        let rows = max(1, voiceFlat.count / Self.styleDim)
        let adjusted = min(max(tokens.count - 1, 0), rows - 1)
        let offset = adjusted * Self.styleDim
        guard offset + Self.styleDim <= voiceFlat.count else {
            throw KittenEngineError.voiceShape(voiceFlat.count)
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
            throw KittenEngineError.noOutput
        }
        let raw = try waveform.tensorData()
        let data = raw as Data
        let samples = data.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Float.self))
        }
        // Reference trims the trailing 5,000 samples of every chunk — but a
        // guard on samples.count > trailingTrim bricks very short outputs
        // ("OK.", numbers). Trim the tail only when the output comfortably
        // exceeds it; gracefully pass through whatever we got otherwise.
        if samples.count > Self.trailingTrim * 2 {
            return Array(samples[0..<(samples.count - Self.trailingTrim)])
        }
        return samples
    }

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        guard ModelManager.kittenFilesAreValid() else {
            Log.shared.error("KittenEngine asked to speak but its model isn't downloaded")
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
                    Log.shared.error("KittenEngine chunk \(index + 1) failed: \(error)")
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
        let voiceKey = voices[voice + ".npy"] != nil
            ? voice + ".npy"
            : voices.keys.sorted().first ?? ""
        guard let voiceFlat = voices[voiceKey] else {
            throw KittenEngineError.noVoices
        }
        guard let phonemes = phonemize(text), !phonemes.isEmpty else {
            throw KittenEngineError.phonemizationFailed
        }
        // Debugging aid for voice-quality reports: the exact phoneme string
        // fed to the tokenizer (compare against the spike's espeak dialect).
        Log.shared.info("KittenEngine: phonemes «\(phonemes)»")
        let tokens = tokenize(phonemes)
        let started = Date()
        let samples = try synthesize(tokens: tokens, voiceFlat: voiceFlat)
        let duration = Double(samples.count) / Self.sampleRate
        Log.shared.info("KittenEngine: \(tokens.count) tokens → \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
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
                Log.shared.error("KittenEngine: audio engine failed to start: \(error)")
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
                completion(.failure(KittenEngineError.emptyText))
            }
            return
        }
        guard ModelManager.kittenFilesAreValid() else {
            DispatchQueue.main.async {
                completion(.failure(KittenEngineError.modelUnavailable))
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
                    completion(.failure(KittenEngineError.modelUnavailable))
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
                Log.shared.info("KittenEngine: exported \(String(format: "%.1f", seconds))s of audio to \(url.lastPathComponent)")
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                Log.shared.error("KittenEngine export failed: \(error)")
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

/// User-facing failures for the Kitten path.
enum KittenEngineError: LocalizedError {
    case modelUnavailable
    case noVoices
    case phonemizationFailed
    case tokenCount(Int)
    case voiceShape(Int)
    case noOutput
    case emptyText

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "The Kitten model isn't downloaded or failed to load."
        case .noVoices: return "No Kitten voice vectors available — re-download the model."
        case .phonemizationFailed: return "Couldn't convert the text to phonemes."
        case .tokenCount(let n): return "Chunk token count out of range (\(n))."
        case .voiceShape(let n): return "Kitten voice vector has an unexpected size (\(n))."
        case .noOutput: return "The model returned no audio."
        case .emptyText: return "The note is empty."
        }
    }
}
