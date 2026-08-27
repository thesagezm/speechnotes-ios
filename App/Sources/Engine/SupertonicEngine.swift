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
/// Streaming architecture mirrors OnnxKokoroEngine: sentence chunks from
/// SpeechLogic, generation capped a couple of chunks ahead (each vector-
/// estimator pass is far heavier than Kokoro's single-session call), played
/// buffers released, chunk-granular read-along ranges, interruption handling.
/// The sample rate comes from tts.json at load — everything downstream
/// (AVAudioFormat, WAV export) uses the discovered value.
final class SupertonicEngine: NSObject, SpeechEngine {
    let name = "Supertonic (CPU)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?

    /// Voice style id — one of ModelManager.supertonicVoices ("M1"…"F5").
    var voice = "M1"
    /// ISO language code (AVAILABLE_LANGS in Helper.swift); "en" default.
    var lang = "en"

    /// Upstream ExampleONNX default — 8 denoising steps.
    private static let totalStep = 8
    /// The vector estimator dominates each chunk's cost; keep the production
    /// pipeline shallow so the first sentence starts fast.
    private static let generationAheadLimit = 2
    /// Supertonic's own chunker accepts up to 300 chars for non-CJK; our
    /// sentence chunks stay a bit tighter for responsiveness.
    private static let chunkMaxChars = 200

    private let engineQueue = DispatchQueue(label: "com.speechnotes.supertonic", qos: .userInitiated)

    // Model state — engineQueue only.
    private var ortEnv: ORTEnv?
    private var tts: TextToSpeech?
    private var styles: [String: Style] = [:]
    private var modelLoadAttempted = false
    /// Discovered from tts.json at load (ae.sample_rate).
    private(set) var sampleRate: Double = 24_000

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
    private var speed: Float = 1.05

    private var interruptionObserver: NSObjectProtocol?

    private var state: SpeechState = .idle {
        didSet {
            if state != oldValue {
                Log.shared.info("SupertonicEngine state: \(oldValue) → \(state)")
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
            Log.shared.error("SupertonicEngine audio session setup failed: \(error)")
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        Log.shared.info("SupertonicEngine created")
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
            sampleRate = Double(textToSpeech.sampleRate)

            // Each style must carry batch dim 1 (loadVoiceStyle sizes the
            // tensors to the number of paths it's given), so one call per voice.
            for voice in ModelManager.supertonicVoices {
                let path = ModelManager.supertonicStyleFileURL(voice: voice).path
                styles[voice] = try loadVoiceStyle([path], verbose: false)
            }
            Log.shared.info("SupertonicEngine: 4 sessions + \(styles.count) styles loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (\(Int(sampleRate)) Hz)")
        } catch {
            tts = nil
            styles = [:]
            Log.shared.error("SupertonicEngine: model load failed: \(error)")
        }
    }

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        guard ModelManager.supertonicFilesAreValid() else {
            Log.shared.error("SupertonicEngine asked to speak but its model isn't downloaded")
            state = .idle
            return
        }
        guard isValidLang(lang) else {
            Log.shared.error("SupertonicEngine: unsupported language \(lang)")
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
            guard self.tts != nil else {
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
                    let nsBuffer = Self.makeMonoBuffer(samples: buffer, sampleRate: self.sampleRate)
                    DispatchQueue.main.async {
                        guard self.playbackGeneration == generation else { return }
                        self.generatedBuffers[index] = nsBuffer
                        self.scheduleReadyChunks(generation: generation)
                    }
                } catch {
                    Log.shared.error("SupertonicEngine chunk \(index + 1) failed: \(error)")
                    DispatchQueue.main.async {
                        if self.playbackGeneration == generation { self.state = .idle }
                    }
                    return
                }
            }
        }
    }

    /// engineQueue only — one Helper `call` per sentence chunk. `call`'s own
    /// internal chunker sees a short string and runs a single inference; the
    /// returned wav is padded, so it's trimmed to the predicted duration.
    private func generateChunk(_ text: String) throws -> [Float] {
        guard let tts else { throw SupertonicEngineError.modelUnavailable }
        guard let style = styles[voice] ?? styles.values.first else {
            throw SupertonicEngineError.noVoices
        }
        let started = Date()
        let result = try tts.call(text, lang, style, Self.totalStep, speed: speed, silenceDuration: 0.05)
        let actualLen = Int(Float(tts.sampleRate) * result.duration)
        guard actualLen > 0, result.wav.count >= actualLen else {
            throw SupertonicEngineError.noOutput
        }
        let duration = Double(actualLen) / sampleRate
        Log.shared.info("SupertonicEngine: \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", Date().timeIntervalSince(started)))s (\(voice), \(lang))")
        return Array(result.wav.prefix(actualLen))
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
                Log.shared.error("SupertonicEngine: audio engine failed to start: \(error)")
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
                completion(.failure(SupertonicEngineError.emptyText))
            }
            return
        }
        guard ModelManager.supertonicFilesAreValid(), isValidLang(lang) else {
            DispatchQueue.main.async {
                completion(.failure(SupertonicEngineError.modelUnavailable))
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
            guard let tts = self.tts else {
                DispatchQueue.main.async {
                    completion(.failure(SupertonicEngineError.modelUnavailable))
                }
                return
            }

            var samples: [Float] = []
            do {
                for (index, chunk) in renderChunks.enumerated() {
                    // Chunk gap mirrors playback pacing (call's silenceDuration).
                    if index > 0 {
                        samples.append(contentsOf: [Float](repeating: 0, count: Int(0.05 * Double(tts.sampleRate))))
                    }
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
                try WAVWriter.write(samples: samples, sampleRate: Int(tts.sampleRate), to: url)
                let seconds = Double(samples.count) / Double(tts.sampleRate)
                Log.shared.info("SupertonicEngine: exported \(String(format: "%.1f", seconds))s of audio to \(url.lastPathComponent)")
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                Log.shared.error("SupertonicEngine export failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Buffers

    private static func makeMonoBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity

        let destination = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            memcpy(destination, base, samples.count * MemoryLayout<Float>.size)
        }
        return buffer
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
