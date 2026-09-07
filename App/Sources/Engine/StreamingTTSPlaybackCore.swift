import AVFoundation
import SpeechLogic

/// Shared streaming-playback machinery for the ONNX engines
/// (OnnxKokoroEngine, SupertonicEngine — the two engines that synthesize
/// Float PCM through their own model sessions). Owns the sentence-chunk
/// pipeline, bounded generation-ahead pacing, buffer scheduling with
/// play-time position tracking, interruption-safe pause/resume/stop, and
/// chunked WAV export. The engine keeps model loading + synthesis and hands
/// the core one closure.
///
/// Threading contract (mirrors the engines this replaces):
///  - MAIN THREAD: pipeline state, AVAudioEngine/node management, state
///    transitions, all callbacks.
///  - `generateQueue`: model state + synthesis. The engine's `generateChunk`
///    and `isModelReady` closures are ONLY ever called there, which is what
///    makes the engines' model state single-thread-confined.
///
/// Pacing: the producer may hold at most `generationAheadLimit` generated-
/// but-not-yet-scheduled chunks; instead of polling (the old 50 ms
/// Thread.sleep spin), it blocks on a semaphore signaled once per scheduled
/// chunk. Live rate: `speed` is read per chunk on generateQueue, so slider
/// changes apply from the next sentence without restarting playback.
final class StreamingTTSPlaybackCore: NSObject {

    struct Config {
        /// Output sample rate of the engine's PCM (24 kHz Kokoro, tts.json Supertonic).
        let sampleRate: Double
        /// Max characters (~words) handed to one synthesis call.
        let chunkMaxChars: Int
        /// How many chunks beyond the playback cursor the producer may run.
        let generationAheadLimit: Int
        /// Silence appended BETWEEN chunks in WAV exports (mirrors playback
        /// chunk gaps; 0 for Kokoro, the Helper's silenceDuration for Supertonic).
        let exportInterChunkSilence: Float
        let logPrefix: String
    }

    let config: Config

    /// generateQueue-only: one chunk of text → mono Float samples. Throwing
    /// triggers the retry-then-silence resilience rule.
    var generateChunk: (String) throws -> [Float] = { _ in
        throw StreamingCoreError.notConfigured
    }
    /// generateQueue-only: cheap availability check before a session starts.
    var isModelReady: () -> Bool = { false }

    // Callbacks — main thread.
    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onPlayedChars: ((Int) -> Void)?
    /// Natural completion — the final buffer has played out. Replaces the
    /// old 0.98 progress heuristic so book auto-advance fires exactly when
    /// the audio ends (the last short chunk no longer strands the book).
    var onFinished: (() -> Void)?

    private let generateQueue = DispatchQueue(label: "com.speechnotes.streaming-core", qos: .userInitiated)

    // Playback state — main thread only.
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioNodesAttached = false
    private var audioEngineRunning = false
    private var connectedFormat: AVAudioFormat?
    private lazy var playTracker = PlayPositionTracker(playerNode: playerNode)

    private var playbackGeneration = 0

    private var chunks: [Chunk] = []
    private var generatedBuffers: [Int: AVAudioPCMBuffer] = [:]
    private var scheduledUpTo = -1
    private var totalChars = 1

    /// Spoken-text speed — written from main (the rate slider), read per
    /// chunk on generateQueue. Lock-guarded because it crosses threads.
    private let rateLock = NSLock()
    private var storedSpeed: Float = 1.0
    var speed: Float {
        get { rateLock.lock(); defer { rateLock.unlock() }; return storedSpeed }
        set { rateLock.lock(); storedSpeed = Float(min(2.0, max(0.5, newValue))); rateLock.unlock() }
    }

    /// Active PCM sample rate. Starts at the config default; an engine whose
    /// rate is discovered at load (Supertonic's tts.json) publishes it here —
    /// always BEFORE any buffer is built, since generation cannot start until
    /// that same load reports ready.
    private var storedSampleRate: Double
    var sampleRate: Double {
        get { rateLock.lock(); defer { rateLock.unlock() }; return storedSampleRate }
    }
    func setSampleRate(_ rate: Double) {
        rateLock.lock(); storedSampleRate = rate; rateLock.unlock()
    }

    // Pacing — `freeChunksRemaining` is generateQueue-only; the gate is
    // created per generation and signaled once per scheduled chunk (main).
    private var pacingGate: DispatchSemaphore?
    private var freeChunksRemaining = 0

    private var interruptionObserver: NSObjectProtocol?

    private var state: SpeechState = .idle {
        didSet {
            if state != oldValue {
                Log.shared.info("\(config.logPrefix) state: \(oldValue) → \(state)")
                if state == .idle {
                    teardownPlayback()
                    onProgress?(0)
                }
                onStateChanged?(state)
            }
        }
    }

    init(config: Config) {
        self.config = config
        self.storedSampleRate = config.sampleRate
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            Log.shared.error("\(config.logPrefix) audio session setup failed: \(error)")
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        Log.shared.info("\(config.logPrefix) core created")
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

    // MARK: - SpeechEngine surface

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        speed = Float(min(2.0, max(0.5, rateMultiplier)))

        let allChunks = SentenceChunker.chunks(
            for: clean,
            firstMaxChars: config.chunkMaxChars,
            batchMaxChars: config.chunkMaxChars
        )
        guard !allChunks.isEmpty else { return }

        DispatchQueue.main.async { self.state = .generating }

        let generation = playbackGeneration + 1
        playbackGeneration = generation

        chunks = allChunks
        generatedBuffers = [:]
        scheduledUpTo = -1
        totalChars = max(1, clean.utf16.count)
        playTracker.reset()

        // Fresh gate per generation: the first generationAheadLimit chunks
        // pass free, every later one waits for a schedule signal. stop()
        // floods the gate so a blocked producer always wakes and exits.
        pacingGate = DispatchSemaphore(value: 0)
        freeChunksRemaining = config.generationAheadLimit

        generateQueue.async { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            guard self.isModelReady() else {
                Log.shared.error("\(self.config.logPrefix) asked to speak but the model isn't ready")
                DispatchQueue.main.async {
                    if self.playbackGeneration == generation { self.state = .idle }
                }
                return
            }

            for (index, chunk) in allChunks.enumerated() {
                if self.freeChunksRemaining > 0 {
                    self.freeChunksRemaining -= 1
                } else {
                    self.pacingGate?.wait()
                }
                guard self.playbackGeneration == generation else { return }
                // One flaky chunk must never end a reading: retry, then
                // insert 0.5 s of silence and keep going.
                let samples: [Float]
                do {
                    samples = try Self.generateWithRetry(self, chunk.text, attempts: 3)
                } catch {
                    Log.shared.error("\(self.config.logPrefix) chunk \(index + 1) failed after retries (\(error)): «\(chunk.text.prefix(60))» — inserting 0.5s silence")
                    samples = Array(repeating: Float(0), count: Int(self.sampleRate) / 2)
                }
                let buffer = Self.makeMonoBuffer(samples: samples, sampleRate: self.sampleRate)
                DispatchQueue.main.async {
                    guard self.playbackGeneration == generation else { return }
                    self.generatedBuffers[index] = buffer
                    self.scheduleReadyChunks(generation: generation)
                }
            }
        }
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
        // Unblock a producer waiting on the gate; it re-checks the
        // generation and exits. A handful of signals is always enough.
        for _ in 0...(config.generationAheadLimit + 1) {
            pacingGate?.signal()
        }
        state = .idle
    }

    // MARK: - Streaming playback (main thread)

    private func scheduleReadyChunks(generation: Int) {
        guard playbackGeneration == generation else { return }
        while true {
            let next = scheduledUpTo + 1
            guard next < chunks.count, let buffer = generatedBuffers[next] else { return }
            scheduledUpTo = next
            pacingGate?.signal()
            schedule(buffer: buffer, index: next, isLast: next == chunks.count - 1, generation: generation)
        }
    }

    private func schedule(buffer: AVAudioPCMBuffer, index: Int, isLast: Bool, generation: Int) {
        ensureAudioEngineRunning(format: buffer.format)

        let charsDone = chunks.prefix(scheduledUpTo + 1).reduce(0) { $0 + $1.length }
        playTracker.onPlayedChars = { [weak self] playedChars in
            guard let self else { return }
            // Play-accurate progress: derived from the position that is
            // ACTUALLY sounding, not the schedule cursor (which runs up to
            // generationAheadLimit chunks ahead of the ears).
            self.onProgress?(min(1.0, Double(playedChars) / Double(self.totalChars)))
            self.onPlayedChars?(playedChars)
        }
        playTracker.willSchedule(buffer: buffer, endChar: charsDone, totalChars: totalChars)

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.generatedBuffers[index] = nil
                if isLast {
                    if self.state == .speaking || self.state == .paused || self.state == .generating {
                        self.onProgress?(1.0)
                        self.playTracker.finish(totalChars: self.totalChars)
                        self.onFinished?()
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
                Log.shared.error("\(config.logPrefix) audio engine failed to start: \(error)")
                state = .idle
            }
        }
    }

    private func teardownPlayback() {
        playTracker.reset()
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
        title: String? = nil,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            DispatchQueue.main.async { completion(.failure(StreamingCoreError.emptyText)) }
            return
        }

        playbackGeneration += 1
        DispatchQueue.main.async { self.state = .idle }

        let renderChunks = SentenceChunker.chunks(
            for: clean,
            firstMaxChars: config.chunkMaxChars,
            batchMaxChars: config.chunkMaxChars
        )
        let total = max(1, clean.utf16.count)

        generateQueue.async { [weak self] in
            guard let self else { return }
            guard self.isModelReady() else {
                DispatchQueue.main.async {
                    completion(.failure(StreamingCoreError.modelUnavailable))
                }
                return
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let exportsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exports")
            do {
                try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
                // Exports are named for the content now — "Note-2026…" told
                // the user nothing two days later.
                let base = Self.sanitizedFilename(title ?? "Note")
                let url = exportsDir.appendingPathComponent("\(base)-\(formatter.string(from: Date())).wav")

                // STREAMED: one chunk in memory at a time. The old path
                // accumulated every sample — a 200k-char chapter was ~1.1 GB.
                let writer = try WAVWriter.StreamingWriter(url: url, sampleRate: Int(self.sampleRate))
                var charsDone = 0
                for (index, chunk) in renderChunks.enumerated() {
                    if index > 0, self.config.exportInterChunkSilence > 0 {
                        try writer.append([Float](
                            repeating: 0,
                            count: Int(self.config.exportInterChunkSilence * Float(self.sampleRate))
                        ))
                    }
                    do {
                        try writer.append(try Self.generateWithRetry(self, chunk.text, attempts: 3))
                    } catch {
                        Log.shared.error("\(self.config.logPrefix) export chunk failed after retries (\(error)): «\(chunk.text.prefix(60))» — silence inserted")
                        try writer.append([Float](repeating: 0, count: Int(self.sampleRate) / 2))
                    }
                    charsDone += chunk.length
                    let progress = min(1.0, Double(charsDone) / Double(total))
                    DispatchQueue.main.async { onChunkProgress?(progress) }
                }
                try writer.close()
                let seconds = Double(writer.sampleCount) / self.sampleRate
                Log.shared.info("\(self.config.logPrefix) exported \(String(format: "%.1f", seconds))s of audio to \(url.lastPathComponent)")
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                Log.shared.error("\(self.config.logPrefix) export failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// "Chapter One: The Beginning" → "Chapter_One__The_Beginning" (≤40
    /// chars) — letters/digits survive, everything else becomes "_".
    private static func sanitizedFilename(_ text: String, maxLen: Int = 40) -> String {
        let truncated = text.count > maxLen ? String(text.prefix(maxLen)) : text
        let cleaned = truncated.reduce(into: "") { partial, char in
            partial.append(char.isLetter || char.isNumber ? char : "_")
        }
        return cleaned.isEmpty ? "Note" : cleaned
    }

    // MARK: - Retry + buffers

    /// Retries `generateChunk` — transient inference flakes (Kokoro's empty
    /// output, Supertonic's zero-length duration prediction) usually succeed
    /// on a second attempt.
    private static func generateWithRetry(
        _ core: StreamingTTSPlaybackCore,
        _ text: String,
        attempts: Int
    ) throws -> [Float] {
        var lastError: Error?
        for attempt in 1...attempts {
            do { return try core.generateChunk(text) }
            catch {
                lastError = error
                Log.shared.info("\(core.config.logPrefix) chunk attempt \(attempt)/\(attempts) failed (\(error)) — «\(text.prefix(60))»")
                Thread.sleep(forTimeInterval: 0.15 * Double(attempt))
            }
        }
        throw lastError ?? StreamingCoreError.noOutput
    }

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

/// Failures that originate in the core itself (the engines surface their own
/// model/synthesis errors through their closures).
enum StreamingCoreError: LocalizedError {
    case notConfigured
    case modelUnavailable
    case noOutput
    case emptyText

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "The streaming playback core was used without a synthesis handler."
        case .modelUnavailable: return "The speech model isn't downloaded or failed to load."
        case .noOutput: return "The model returned no audio."
        case .emptyText: return "The text is empty."
        }
    }
}
