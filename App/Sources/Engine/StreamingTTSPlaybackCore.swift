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
        /// Inter-chunk pause baked into WAV exports only (playback itself
        /// schedules back-to-back). Kept small so a skipped chunk reads as a
        /// breath, not dead air.
        let exportInterChunkSilence: Float
        let logPrefix: String
    }

    let config: Config

    /// generateQueue-only: one chunk of text → mono Float samples. A throw is
    /// reported once and the chunk is skipped — no retry and no pause, because
    /// a sentence the model cannot say is a gap the listener hears once (with
    /// a soft tone) rather than dead air they wait through.
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
    /// Slot states: -1 pending, -2 skipped, ≥0 = id into `bufferPool`.
    /// Skipped chunks (synthesis failed) step the schedule cursor over them
    /// so one bad sentence never deadlocks the pipeline.
    private var bufferSlots: [Int] = []
    private var bufferPool: [Int: AVAudioPCMBuffer] = [:]
    private var nextBufferId = 0
    private var scheduledUpTo = -1
    private var totalChars = 1
    private static let slotPending = -1
    private static let slotSkipped = -2

    /// Spoken-text speed — written from main (the rate slider), read per
    /// chunk on generateQueue. Lock-guarded because it crosses threads.
    private let rateLock = NSLock()
    private var storedSpeed: Float = 1.0
    /// Live: assigning mid-playback takes effect from the very next chunk.
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

    /// TTFA / T2B / RTF / gap / stall instrumentation. Records and logs only
    /// — it never gates playback, so an instrumented build behaves exactly
    /// like an uninstrumented one.
    private let metrics: PlaybackMetrics
    /// 1 Hz stall watchdog, live only while a session is. Same shape as
    /// `PlayPositionTracker`'s heartbeat: a main-runloop timer in `.common`
    /// mode, so it keeps ticking while the UI is scrolling.
    private var stallWatchdog: Timer?

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

    /// Audio-session category applied lazily on first actual playback —
    /// configuring it in init landed an OSStatus -50 at every cold start
    /// (the session isn't attachable before the app is fully active).
    private func configureAudioSessionIfNeeded() {
        // Shared with the other engines: one category, applied lazily on the
        // first real playback, with a fallback ladder for the routes that
        // reject the preferred option set (the OSStatus -50 in the logs).
        AudioSessionSetup.configureIfNeeded(prefix: config.logPrefix)
    }

    init(config: Config) {
        self.config = config
        self.storedSampleRate = config.sampleRate
        self.metrics = PlaybackMetrics(prefix: config.logPrefix)
        super.init()
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
        // Best-effort only: `Timer.invalidate()` is not documented as safe from
        // a thread other than the one that installed it, and deinit runs on
        // whatever released the last reference. The real invalidation points are
        // `stopStallWatchdog()` from teardownPlayback() and from stop(); this
        // is the backstop for a core dropped without either.
        stallWatchdog?.invalidate()
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

        // t0 for TTFA. Note the boundary: this is core entry, which is AFTER
        // the engine's own `speak()` has validated its model files on the main
        // thread (for Kokoro that includes a full JSON parse of
        // tokenizer.json). A measured TTFA is therefore a LOWER BOUND on
        // tap-to-audio — see TTS_BASELINE.md §"What TTFA does not include".
        metrics.beginSession(
            chunkCount: allChunks.count,
            firstChunkChars: allChunks[0].length,
            rate: speed
        )
        startStallWatchdog()

        DispatchQueue.main.async { self.state = .generating }

        let generation = playbackGeneration + 1
        playbackGeneration = generation
        // Supersede any in-flight producer: signal the gate it may be
        // blocked on BEFORE replacing it, so it wakes, reads the bumped
        // generation, and exits instead of leaking until stop().
        for _ in 0...(config.generationAheadLimit + 1) {
            pacingGate?.signal()
        }

        chunks = allChunks
        bufferSlots = [Int](repeating: Self.slotPending, count: allChunks.count)
        bufferPool = [:]
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
            // Timed separately because a cold session hides a multi-second
            // model load inside TTFA and nothing else explains it.
            let readyStart = PlaybackMetrics.monotonicNow()
            let modelReady = self.isModelReady()
            let readySeconds = PlaybackMetrics.seconds(since: readyStart)
            DispatchQueue.main.async {
                guard self.playbackGeneration == generation else { return }
                self.metrics.modelReady(seconds: readySeconds)
            }
            guard modelReady else {
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
                // A chunk the model cannot synthesize is skipped on the FIRST
                // failure. There is no retry: a second attempt at the same
                // text fails the same way (the input is what is wrong — see
                // SpeechSanitizer), and the wait for it is silence the
                // listener pays for. The slot gets the skipped sentinel so the
                // schedule cursor steps past it, the listener hears one soft
                // tone, and the read-along char math still accounts for the
                // text that will not sound.
                do {
                    let generationStart = PlaybackMetrics.monotonicNow()
                    let samples = try self.generateChunk(chunk.text)
                    let outputRate = self.sampleRate
                    let buffer = Self.makeMonoBuffer(samples: samples, sampleRate: outputRate)
                    // Wall time the listener actually waits for this chunk —
                    // retries and back-off sleeps included. The engines' own
                    // per-chunk log times only `synthesize`, which omits
                    // phonemization and tokenization.
                    let generationSeconds = PlaybackMetrics.seconds(since: generationStart)
                    let audioSeconds = Double(buffer.frameLength) / outputRate
                    DispatchQueue.main.async {
                        guard self.playbackGeneration == generation else { return }
                        let id = self.nextBufferId
                        self.nextBufferId += 1
                        self.bufferPool[id] = buffer
                        self.bufferSlots[index] = id
                        // Schedule FIRST. The log call is a DateFormatter, a
                        // UUID, two String(format:) and two GCD dispatches —
                        // tens of microseconds of main-thread work, but it
                        // would sit between "buffer ready" and the call that
                        // actually queues audio, which is the one thing this
                        // block must not delay. Logging after also puts the
                        // chunk lines in schedule order rather than
                        // generation order.
                        self.scheduleReadyChunks(generation: generation)
                        self.metrics.chunkGenerated(
                            index: index,
                            chars: chunk.length,
                            generationSeconds: generationSeconds,
                            audioSeconds: audioSeconds
                        )
                    }
                } catch {
                    Log.shared.error("\(self.config.logPrefix) chunk \(index + 1) of \(allChunks.count) skipped (\(error)): «\(chunk.text.prefix(60))»")
                    // The tone is the ONLY signal the listener gets, so it
                    // is posted from here rather than from the main-queue
                    // bookkeeping below: the queue hop is milliseconds either
                    // way, and this keeps the sound tied to the failure that
                    // caused it.
                    BeepPlayer.playSkipTone()
                    DispatchQueue.main.async {
                        guard self.playbackGeneration == generation else { return }
                        self.bufferSlots[index] = Self.slotSkipped
                        self.scheduleReadyChunks(generation: generation)
                        self.metrics.chunkSkipped(index: index, chars: chunk.length)
                    }
                }
            }
        }
    }

    func pause() {
        guard audioEngineRunning, playerNode.isPlaying else { return }
        playerNode.pause()
        metrics.playbackPaused()
        state = .paused
    }

    func resume() {
        guard audioEngineRunning, !playerNode.isPlaying, state == .paused else { return }
        playerNode.play()
        // Closes the paused-time bank so `wall` in the session summary can be
        // read honestly next to the audio figure.
        metrics.playbackResumed()
        state = .speaking
    }

    func stop() {
        playbackGeneration += 1
        // Unblock a producer waiting on the gate; it re-checks the
        // generation and exits. A handful of signals is always enough.
        for _ in 0...(config.generationAheadLimit + 1) {
            pacingGate?.signal()
        }
        // Invalidated here, not only via `teardownPlayback()`: speak() starts
        // the watchdog before it defers `state = .generating` to a later
        // main-queue turn, so a stop() landing in between finds state already
        // .idle, the assignment is a no-op, the didSet never fires and
        // teardown never runs — the timer would tick for the process lifetime.
        stopStallWatchdog()
        // Before the state flip: `state = .idle` tears down, and teardown ends
        // the session under its own catch-all reason.
        metrics.endSession(reason: "stopped")
        state = .idle
    }

    // MARK: - Streaming playback (main thread)

    private func scheduleReadyChunks(generation: Int) {
        guard playbackGeneration == generation else { return }
        while true {
            let next = scheduledUpTo + 1
            guard next < chunks.count else { return }
            let slot = bufferSlots[next]
            guard slot != Self.slotPending else { return } // producer hasn't resolved this chunk yet
            if slot == Self.slotSkipped {
                // Failed chunk: step over it so the chain advances and the
                // natural-finish path still fires when the LAST chunk was
                // skipped. The play tracker still counts the chunk's chars
                // (charsDone below includes it via the chunks array), which
                // keeps the read-along cursor moving past unspeakable text.
                scheduledUpTo = next
                pacingGate?.signal()
                if next == chunks.count - 1 { finishLastChunk(generation: generation) }
                continue
            }
            guard let buffer = bufferPool[slot] else { return }
            scheduledUpTo = next
            pacingGate?.signal()
            schedule(buffer: buffer, index: next, isLast: next == chunks.count - 1, generation: generation)
        }
    }

    private func schedule(buffer: AVAudioPCMBuffer, index: Int, isLast: Bool, generation: Int) {
        ensureAudioEngineRunning(format: buffer.format)

        // Play-end char position includes skipped chunks (their text counts
        // as "passed" so the read-along cursor never stalls on a sentence
        // that produced no audio).
        let charsDone = chunks[...scheduledUpTo].reduce(0) { $0 + $1.length }
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
                self.metrics.bufferEnded()
                self.bufferPool[self.bufferSlots[index]] = nil
                if isLast {
                    self.finishLastChunk(generation: generation)
                    return
                }
                self.scheduleReadyChunks(generation: generation)
            }
        }

        // `state == .speaking` with a node that is NOT playing means the node
        // drained: everything already queued ran out before the producer caught
        // up. That is audible silence, measured here rather than inferred from
        // chunk sizes — but measured event-to-event on the main queue, so it is
        // a LOWER BOUND (see PlaybackMetrics.nodeRestarted()).
        let restartedAfterDrain = state == .speaking && !playerNode.isPlaying
        if state == .generating {
            state = .speaking
            playerNode.play()
        } else if restartedAfterDrain {
            playerNode.play()
        }
        // Order matters: nodeRestarted labels the gap with the buffer count as
        // it stood BEFORE this one is added to it.
        if restartedAfterDrain { metrics.nodeRestarted() }
        metrics.bufferScheduled(
            chars: chunks[index].length,
            audioSeconds: Double(buffer.frameLength) / buffer.format.sampleRate
        )
    }

    /// The natural-completion path — reached from the last chunk's buffer
    /// callback OR synchronously when the last chunk was skipped.
    private func finishLastChunk(generation: Int) {
        guard playbackGeneration == generation else { return }
        guard state == .speaking || state == .paused || state == .generating else { return }
        onProgress?(1.0)
        playTracker.finish(totalChars: totalChars)
        // `onFinished` is called BEFORE the session is closed, so it must not
        // re-enter this pipeline: SpeechPlayer's handler advances to the next
        // chapter and calls speak() again, and a speak() that landed first
        // would have its brand-new session closed by the endSession below.
        // Safe today because that handler dispatches the next chapter
        // asynchronously — the dependency is worth stating rather than
        // relying on.
        onFinished?()
        // Before the state flip — `state = .idle` tears down, and teardown's
        // catch-all endSession must find the session already closed.
        metrics.endSession(reason: "finished")
        state = .idle
    }

    /// The core's own liveness — the player's self-heal checks this when its
    /// state claims speech. A core in .idle with no session in flight is
    /// exactly the "wedged player" signature (engine swap left the UI
    /// claiming speech nothing was producing).
    var hasLiveSession: Bool { state != .idle }

    // MARK: - Stall watchdog

    private func startStallWatchdog() {
        stopStallWatchdog()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.metrics.checkStall(
                stateIsSpeaking: self.state == .speaking,
                nodeIsPlaying: self.playerNode.isPlaying,
                pendingChunks: max(0, self.chunks.count - self.scheduledUpTo - 1)
            )
        }
        // `.common` mode, matching PlayPositionTracker's heartbeat: the default
        // mode stops firing while the user scrolls, which is exactly when a
        // background stall would go unreported.
        RunLoop.main.add(timer, forMode: .common)
        stallWatchdog = timer
    }

    private func stopStallWatchdog() {
        stallWatchdog?.invalidate()
        stallWatchdog = nil
    }

    private func ensureAudioEngineRunning(format: AVAudioFormat) {
        configureAudioSessionIfNeeded()
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
        stopStallWatchdog()
        playTracker.reset()
        playerNode.stop()
        audioEngine.stop()
        audioEngineRunning = false
        // Do NOT deactivate the shared session here: in LiveContainer the
        // category transition can fail — deactivation from idle is the OS's
        // job, and forcing it re-created background-audio edge cases.
        bufferPool = [:]
        bufferSlots = []
        scheduledUpTo = -1
        // Catch-all: a natural finish and a user stop both close the session
        // first, so reaching here with one still open means the pipeline was
        // torn down underneath it (model not ready, engine failed to start).
        metrics.endSession(reason: "teardown")
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
                var failedChunks = 0
                for (index, chunk) in renderChunks.enumerated() {
                    if index > 0, self.config.exportInterChunkSilence > 0 {
                        try writer.append([Float](
                            repeating: 0,
                            count: Int(self.config.exportInterChunkSilence * Float(self.sampleRate))
                        ))
                    }
                    do {
                        try writer.append(try self.generateChunk(chunk.text))
                    } catch {
                        // Same policy as playback: one attempt, then move on.
                        // The export stays a single pass over the chapter; a
                        // failed chunk leaves a short silence in the file
                        // rather than stalling the render on a retry that
                        // cannot succeed (the input is what is wrong). No tone
                        // — an export is silent by definition, and the count
                        // lands in the log line below.
                        failedChunks += 1
                        Log.shared.error("\(self.config.logPrefix) export chunk \(index + 1) of \(renderChunks.count) failed (\(error)): «\(chunk.text.prefix(60))» — silence written")
                        try writer.append([Float](repeating: 0, count: Int(self.sampleRate) / 4))
                    }
                    charsDone += chunk.length
                    let progress = min(1.0, Double(charsDone) / Double(total))
                    DispatchQueue.main.async { onChunkProgress?(progress) }
                }
                try writer.close()
                let seconds = Double(writer.sampleCount) / self.sampleRate
                if failedChunks > 0 {
                    Log.shared.info("\(self.config.logPrefix) exported \(String(format: "%.1f", seconds))s of audio to \(url.lastPathComponent) with \(failedChunks) failed chunk(s) written as silence")
                } else {
                    Log.shared.info("\(self.config.logPrefix) exported \(String(format: "%.1f", seconds))s of audio to \(url.lastPathComponent)")
                }
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
