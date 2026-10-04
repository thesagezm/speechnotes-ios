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
/// Pacing (Batch B, the render-ahead bank): the producer may synthesize the
/// next chunk while the BANK — generated-but-unplayed audio, measured in
/// SECONDS — is below the target from `RenderAheadBankPolicy`, which sizes
/// the target from thermal state and caps it in bytes. Chunk count was the
/// wrong unit: chunk audio length varies ~40×, so "2 chunks ahead" was
/// anywhere from 2 s to 40 s of protection against the 8–35 s main-thread
/// stalls the device log records. The bank drains from the playhead
/// (PlayPositionTracker's heartbeat reports played samples); the semaphore
/// is only a wakeup token, never credit — every pass re-reads the bank, so
/// a surplus signal is inert and a missed one costs at most the 2 s
/// re-check. Live rate: `speed` is read per chunk on generateQueue, so
/// slider changes apply from the next sentence without restarting playback.
final class StreamingTTSPlaybackCore: NSObject {

    struct Config {
        /// Output sample rate of the engine's PCM (24 kHz Kokoro, tts.json Supertonic).
        let sampleRate: Double
        /// Max characters (~words) handed to one synthesis call — also the
        /// packing ceiling for every chunk past the first (the model's
        /// token-budget ceiling; see SentenceChunker.chunks `batchMaxChars`).
        let chunkMaxChars: Int
        /// Max UTF-16 length of the fast-start FIRST chunk only — time-to-first-
        /// audio is the first chunk's render time, so a small opener starts
        /// speech quickly while chunk 1 packs to `chunkMaxChars` to cover the
        /// following-sentence wait (restores the v0.4 first/batch asymmetry —
        /// TTS_BASELINE §2). Nil = chunkMaxChars.
        var firstMaxChars: Int? = nil
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
    /// generateQueue-confined (written only inside `renderWAV`'s
    /// generateQueue block, read from `generateChunk` on the same serial
    /// queue): true while a WAV export loop is running. An export has no
    /// real-time constraint — RTF > 1 costs nothing offline — so engines use
    /// this to skip real-time-only degradations: Supertonic renders exports
    /// at its full-quality step count instead of shedding to 4 under
    /// thermal pressure (a long export is itself the heat source; shedding
    /// would only lower the file's quality for zero benefit).
    var isExporting = false

    // Callbacks — main thread.
    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onPlayedChars: ((Int) -> Void)?
    /// Natural completion — the final buffer has played out. Replaces the
    /// old 0.98 progress heuristic so book auto-advance fires exactly when
    /// the audio ends (the last short chunk no longer strands the book).
    var onFinished: (() -> Void)?

    private let generateQueue = DispatchQueue(label: "com.speechnotes.streaming-core", qos: .userInitiated)

    // Playback state — main thread only. The engine/node pair is RECREATED
    // after a media-services reset (`rebuildAudioGraph`): Apple's guidance is
    // to discard and recreate AVAudioEngines after that event, and reusing
    // the old object is the `required condition is false: _engine != nil`
    // crash on the next play tap.
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
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
    /// Playback generation when `storedSpeed` last changed. The producer uses
    /// this to drain stale-rate buffers: buffers scheduled BEFORE a rate
    /// change carry the old speed, and waiting for every banked old-rate
    /// buffer to play out made a 1.0→2.0 slider move take seconds of audible
    /// old-rate speech to catch up (rate is baked in at synthesis). Written
    /// under rateLock (main), read under rateLock (generateQueue).
    private var speedChangedGeneration = 0
    /// Live: assigning mid-playback takes effect from the very next chunk.
    var speed: Float {
        get { rateLock.lock(); defer { rateLock.unlock() }; return storedSpeed }
        set {
            rateLock.lock()
            let clamped = Float(min(2.0, max(0.5, newValue)))
            if clamped != storedSpeed {
                storedSpeed = clamped
                speedChangedGeneration = playbackGeneration
            }
            rateLock.unlock()
        }
    }
    /// Producer-side read on generateQueue: (current speed, generation in
    /// which it last changed). One lock acquisition, one coherent pair.
    private var speedSnapshot: (speed: Float, changedIn: Int) {
        rateLock.lock(); defer { rateLock.unlock() }
        return (storedSpeed, speedChangedGeneration)
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

    // Pacing — the render-ahead bank. The gate is created per generation
    // and used ONLY as a wakeup token; the bank is the actual throttle. Bank
    // state is main-thread, mirrored to the producer (generateQueue) through
    // `bankLock` as one coherent snapshot pair:
    //   banked = (generatedFrames − playedFrames) / sampleRate
    // generatedFrames grows when a finished buffer enters `bufferPool`;
    // both counters are zeroed together (with the tracker's coordinate
    // system) on a new session, a rate-change purge and teardown, so the
    // pair always shares one coordinate system. playedFrames follows the
    // playhead via PlayPositionTracker's onPlayedFrames heartbeat.
    private var pacingGate: DispatchSemaphore?
    private let bankPolicy = RenderAheadBankPolicy()
    private var generatedFrames: Int64 = 0
    private var playedFrames: Int64 = 0
    private let bankLock = NSLock()
    private var bankedSecondsSnapshot: Double = 0
    private var bankTargetSecondsSnapshot: Double = 0
    /// Last recompute found NO room — the edge that arms the producer's
    /// wakeup signal for when the bank drains back below target. Main only.
    private var bankHadNoRoom = false
    /// Wakeup-token flood size for generation bumps (stop/supersede/reset):
    /// enough signals to un-park a producer from any wait; the loop
    /// re-checks, so surplus tokens are inert.
    private static let gateFloodCount = 8

    /// TTFA / T2B / RTF / gap / stall instrumentation. Records and logs only
    /// — it never gates playback, so an instrumented build behaves exactly
    /// like an uninstrumented one.
    private let metrics: PlaybackMetrics
    /// 1 Hz stall watchdog, live only while a session is. Same shape as
    /// `PlayPositionTracker`'s heartbeat: a main-runloop timer in `.common`
    /// mode, so it keeps ticking while the UI is scrolling.
    private var stallWatchdog: Timer?

    private var interruptionObserver: NSObjectProtocol?
    /// Engine-configuration and media-services-reset observers. The
    /// configuration-change one is the hand-wired-AVAudioEngine equivalent of
    /// what AVPlayer does implicitly: a hardware sample-rate change (a call,
    /// a Bluetooth headset arriving, AirPods, an alarm) invalidates the
    /// connection made with the old format, and without a repair the node
    /// goes silent until the whole engine is rebuilt.
    private var configChangeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    // MARK: - Rate-change buffer drain

    /// True once per session: a rate change was committed and the pending
    /// old-rate purge has been issued. Reset by `speak()`.
    private var rateDrainArmed = false

    /// Drop every scheduled-but-not-yet-playing buffer, rebase the position
    /// tracker at the first DELETED chunk (so the read-along cursor and the
    /// progress % continue from the same text the user heard), signal the
    /// producer semaphore for the purged lanes, and log the transition.
    /// Main thread only — called from the producer hop on the rate-change
    /// boundary. The single already-playing buffer (index `< firstPurged`)
    /// finishes audibly; everything after it is re-synthesized at the new
    /// rate from the SAME chunk list.
    private func purgeStaleRateBuffers(from firstPurged: Int, generation: Int) {
        guard playbackGeneration == generation else { return }
        // Nothing to do if the purge point is already past the schedule
        // cursor (session was torn down / restarted in between).
        guard firstPurged <= scheduledUpTo else { return }

        let purgedCount = scheduledUpTo - firstPurged + 1
        var purgedFrames: Int64 = 0
        for idx in firstPurged...scheduledUpTo {
            let slot = bufferSlots[idx]
            if slot >= 0, let buffer = bufferPool[slot] {
                purgedFrames += Int64(buffer.frameLength)
            }
        }
        let purgedAudioSeconds = Double(purgedFrames) / sampleRate

        for idx in firstPurged...scheduledUpTo {
            let slot = bufferSlots[idx]
            if slot >= 0 {
                bufferPool.removeValue(forKey: slot)
            }
            bufferSlots[idx] = Self.slotPending
        }
        scheduledUpTo = firstPurged - 1
        playTracker.reset()
        // The purged buffers leave the bank, and the tracker reset re-zeroed
        // the playhead coordinate system against the live node clock — so the
        // bank restarts empty here. (The still-playing old-rate buffer's
        // unplayed remainder is under-counted: it will drain from the bank as
        // if it had never been banked. The bias is toward generating a beat
        // early, which is the safe direction. The read-along cursor has the
        // mirror-image defect for the same reason — it leads the audio by up
        // to that one buffer's remainder until the next reset — bounded, and
        // strictly better than reading the whole running clock as played.)
        // The explicit signal is promptness: the producer may be parked on
        // the gate with a full-bank snapshot that this purge just invalidated.
        resetBank()
        pacingGate?.signal()

        Log.shared.info("\(config.logPrefix) rate change — purged \(purgedCount) stale-rate buffer(s) (\(String(format: "%.1f", purgedAudioSeconds))s of buffered audio), regenerating from chunk \(firstPurged)")
    }

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

    /// Audio-session category + ACTIVATION applied lazily on first actual
    /// playback — configuring it in init landed an OSStatus -50 at every cold
    /// start (the session isn't attachable before the app is fully active).
    ///
    /// The activation half is the background-persistence fix: a configured
    /// but INACTIVE session is suspended by iOS seconds after the app
    /// backgrounds. `AVAudioEngine.start()` does not activate it (AVPlayer
    /// does, which is why the audiobook path never had this failure), so
    /// without this call every ONNX engine spoke two sentences and stopped.
    private func configureAudioSessionIfNeeded() {
        // Shared with the other engines: one category, applied lazily on the
        // first real playback, with a fallback ladder for the routes that
        // reject the preferred option set (the OSStatus -50 in the logs).
        AudioSessionSetup.configureAndActivate(source: .tts, prefix: config.logPrefix)
    }

    init(config: Config) {
        self.config = config
        self.storedSampleRate = config.sampleRate
        self.metrics = PlaybackMetrics(prefix: config.logPrefix)
        super.init()
        wirePlayTracker()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset()
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
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        if let mediaResetObserver {
            NotificationCenter.default.removeObserver(mediaResetObserver)
        }
        // Backstop for the audio graph: every deliberate path stops it via
        // teardownPlayback(), but a core dropped by a path that skipped that
        // (an idler nil, an engine swap racing a session) must not have
        // AVAudioEngine deallocate with a graph still attached. The hop to
        // main also moves the engine/node pair's deallocation off whatever
        // thread ran this deinit.
        let engine = audioEngine
        let node = playerNode
        DispatchQueue.main.async {
            node.stop()
            engine.stop()
        }
    }

    private func handleInterruption(_ notification: Notification) {
        let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if typeRaw == AVAudioSession.InterruptionType.began.rawValue {
            if state == .speaking { pause() }
        } else if typeRaw == AVAudioSession.InterruptionType.ended.rawValue,
                  optionsRaw & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 {
            // iOS leaves the session INACTIVE after an interruption. Without
            // re-activating, `playerNode.play()` succeeds and no sound comes
            // out — and in the background the process is suspended seconds
            // later. But re-activating with nothing to resume grabs the
            // exclusive session and kills whatever the user started during
            // the interruption (Music after a call) while playing nothing of
            // ours — so only activate when a resume will actually happen.
            guard state == .paused else { return }
            AudioSessionSetup.activate(prefix: config.logPrefix)
            resume()
        }
    }

    /// The hardware's sample rate changed (a call, a Bluetooth headset
    /// arriving or leaving, AirPods, an alarm). The connection this engine
    /// made with the old format is no longer valid, so the node goes silent
    /// until it is re-made. `AVPlayer` rebuilds its own pipeline and never
    /// sees this; a hand-wired engine has to do it itself.
    ///
    /// Buffers already scheduled survive the reconnect — the node's queue is
    /// untouched by `connect` — but anything not yet scheduled has to be
    /// pushed through `scheduleReadyChunks` again, because the schedule
    /// cursor stops advancing once the node stops draining.
    private func handleEngineConfigurationChange() {
        let wasRunning = audioEngineRunning
        let format = connectedFormat
        Log.shared.info("\(config.logPrefix) engine configuration change (format \(format?.sampleRate ?? -1) Hz) — reconnecting")
        guard wasRunning, state != .idle else { return }

        audioEngineRunning = false
        // Force the reconnect: a configuration change can invalidate the
        // graph even when the node→mixer format is unchanged, and
        // `connect` is cheap idempotence compared to a silent node.
        connectedFormat = nil
        if let format {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            connectedFormat = format
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            audioEngineRunning = true
        } catch {
            Log.shared.error("\(config.logPrefix) restart after configuration change failed: \(error)")
            state = .idle
            return
        }
        if state == .speaking {
            if !playerNode.isPlaying { playerNode.play() }
            // Re-drive the schedule in case the node drained while it was
            // misconfigured.
            scheduleReadyChunks(generation: playbackGeneration)
        }
        // .paused stays paused: a route change must never restart speech in
        // the user's pocket (the critique's P1 — the play button would also
        // die, because resume() guards on !playerNode.isPlaying).
    }

    /// The media server died: the session category, the audio engine and
    /// every scheduled buffer are void.
    ///
    /// Apple's documentation is explicit that an app "shouldn't restart your
    /// media playback, recording, or processing until initiated by user
    /// action", so this does NOT auto-resume — it re-arms the machinery,
    /// ends the dead session so the UI stops claiming speech that nothing is
    /// producing, and leaves the bookmark in place for the reader's play
    /// button. The audiobook path's cold-resume (`AudioBookPlayer.
    /// handleMediaServicesReset`) predates this and is left alone here; see
    /// the plan doc.
    private func handleMediaServicesReset() {
        Log.shared.error("\(config.logPrefix) media services reset — tearing down the dead session (no auto-resume; Apple requires user action)")
        AudioSessionSetup.invalidateConfiguration()
        // Buffers were decoded against the old engine configuration and
        // cannot be trusted; drop the whole pipeline.
        playbackGeneration += 1
        for _ in 0..<Self.gateFloodCount {
            pacingGate?.signal()
        }
        stopStallWatchdog()
        // state = .idle fires teardownPlayback(), which ends the metrics
        // session under its own catch-all — no separate endSession here.
        state = .idle
        // A media-services reset invalidates every AVAudioEngine in the
        // process, and Apple's guidance is to DISCARD and recreate them —
        // the old object's internals are gone, and the next attach/connect/
        // start on it is the `required condition is false: _engine != nil`
        // crash the device reported on every tap after the event. Rebuild
        // the graph now so the reader's play button works.
        rebuildAudioGraph()
    }

    /// Main thread. Wires the tracker callback — the bank drains from the
    /// playhead: the tracker's heartbeat (~3 Hz) reports played samples,
    /// which recomputeBank turns into a banked-seconds figure and, at the
    /// target crossing, a producer wakeup.
    private func wirePlayTracker() {
        playTracker.onPlayedFrames = { [weak self] frames in
            self?.handlePlayedFrames(frames)
        }
    }

    /// Main thread. Discards the audio graph and builds a fresh one: new
    /// engine, new node, new tracker, fresh attach/format state, and the
    /// configuration-change observer re-registered on the NEW engine.
    /// Called only from the media-services-reset path, with the pipeline
    /// already torn down (.idle) and no buffers in flight.
    private func rebuildAudioGraph() {
        audioEngine.stop()
        playerNode.stop()
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        audioNodesAttached = false
        audioEngineRunning = false
        connectedFormat = nil
        playTracker = PlayPositionTracker(playerNode: playerNode)
        wirePlayTracker()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
        Log.shared.info("\(config.logPrefix) audio graph rebuilt after media-services reset")
    }

    /// How long the producer waits per pass before re-checking. A bounded
    /// wait, not `wait()` forever: the gate is signalled only from the MAIN
    /// queue, so a frozen process parks here indefinitely — the exact
    /// mechanism behind regression R9, where a superseded session's producer
    /// blocked forever on a semaphore nobody would ever signal. The loop
    /// re-checks the generation each pass, so a superseded or stopped
    /// session always wakes and exits. A LIVE session holds the chunk for as
    /// long as it takes: timing out is never a reason to lose text (see
    /// `waitForBankRoom`'s ledger). A permanently wedged main thread does
    /// park the producer on this serial queue — acceptable, because a
    /// permanently wedged main thread has stopped the app anyway.
    private static let pacingWaitTimeout: DispatchTimeInterval = .seconds(2)

/// generateQueue. Marks `index` as skipped so the schedule cursor steps
    /// over it, beeps once, and accounts the chars so the read-along cursor
    /// keeps moving past text that will not sound. `chunkCount` is passed in
    /// rather than read from `chunks` — that array is main-thread state.
    private func reportChunkSkipped(index: Int, chunkCount: Int, chars: Int, generation: Int, message: String) {
        Log.shared.error("\(config.logPrefix) chunk \(index + 1) of \(chunkCount) skipped (\(message))")
        // The tone is the ONLY signal the listener gets, so it is posted from
        // here rather than from the main-queue bookkeeping below: the queue
        // hop is milliseconds either way, and this keeps the sound tied to
        // the failure that caused it.
        BeepPlayer.playSkipTone()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.playbackGeneration == generation,
                  index < self.bufferSlots.count else { return }
            self.bufferSlots[index] = Self.slotSkipped
            self.scheduleReadyChunks(generation: generation)
            self.metrics.chunkSkipped(index: index, chars: chars)
        }
    }

    /// Blocks until the bank has room for the next chunk. Returns false only
    /// when the caller should exit the producer: a superseded generation, or
    /// a pipeline that is actually dead (.idle). A TIMEOUT IS NEVER A SKIP —
    /// the ledger from the chunk-count gate carries over: the bank drains
    /// only from the playhead, whose reports come through the MAIN queue, so
    /// while the main thread is stalled (the device log shows 8–35 s ones)
    /// the snapshot is frozen and the producer parks here. Skipping then
    /// would permanently lose the sentence; waiting costs nothing the
    /// listener hears (the node holds the banked audio).
    ///
    /// The semaphore is a wakeup token, not credit: every pass re-reads the
    /// bank snapshot, so a surplus signal is inert and a missed one costs at
    /// most `pacingWaitTimeout` of latency. On a healthy session the
    /// recompute edge-signals the moment the bank drains below target, so
    /// the wait ends in well under a second; a TIMEOUT means the main thread
    /// is not recompute-ing at all — logged once per hold, it is the same
    /// information the old `pacing wait extended` line carried.
    private func waitForBankRoom(generation: Int) -> Bool {
        var loggedExtension = false
        while true {
            bankLock.lock()
            let banked = bankedSecondsSnapshot
            let target = bankTargetSecondsSnapshot
            bankLock.unlock()
            if RenderAheadBankPolicy.allows(bankedSeconds: banked, targetSeconds: target) {
                return playbackGeneration == generation
            }
            if playbackGeneration != generation { return false }
            if state == .idle { return false }
            let result = pacingGate?.wait(timeout: .now() + Self.pacingWaitTimeout)
            if playbackGeneration != generation { return false }
            if result == .success { continue }
            if !loggedExtension {
                loggedExtension = true
                if state == .paused {
                    // A parked-during-pause hold is the steady state of a
                    // paused session (the bank stays full; the tracker
                    // reports nothing) — not a stall. Name it as one.
                    Log.shared.info("\(config.logPrefix) producer holding while paused — the bank is full; nothing to do until playback resumes")
                } else {
                    Log.shared.info("\(config.logPrefix) bank hold extended — main thread stalled or the process suspended; holding the chunk rather than losing it")
                }
            }
        }
    }

    /// Main thread. Recomputes the bank snapshot the producer paces on:
    /// banked seconds, the effective target at the CURRENT thermal state,
    /// and an edge-triggered wakeup when room re-appears. Thermal state is
    /// read here — per heartbeat (~3 Hz) and per scheduling event — so the
    /// bank re-sizes within a heartbeat of a thermal transition, which is
    /// the point of thermal sizing.
    private func recomputeBank() {
        let rate = sampleRate
        let thermal = ThermalPressure(
            thermalStateRawValue: ProcessInfo.processInfo.thermalState.rawValue)
        let target = bankPolicy.effectiveTargetSeconds(thermal: thermal, sampleRate: rate)
        let bankedFrames = max(0, generatedFrames - playedFrames)
        let banked = Double(bankedFrames) / max(1, rate)
        bankLock.lock()
        bankedSecondsSnapshot = banked
        bankTargetSecondsSnapshot = target
        bankLock.unlock()
        let hasRoom = RenderAheadBankPolicy.allows(bankedSeconds: banked, targetSeconds: target)
        if hasRoom, bankHadNoRoom {
            pacingGate?.signal()
        }
        bankHadNoRoom = !hasRoom
    }

    /// Locked banked-seconds read for the drain classification in `schedule`.
    private func bankedSeconds() -> Double {
        bankLock.lock(); defer { bankLock.unlock() }
        return bankedSecondsSnapshot
    }

    /// Playhead advanced (tracker heartbeat, main thread).
    private func handlePlayedFrames(_ frames: Int64) {
        playedFrames = max(0, frames)
        recomputeBank()
    }

    /// Zero the bank for a fresh coordinate system — a new session or a
    /// rate-change purge, both of which reset the play tracker. Counters
    /// start empty and the first post-reset tracker reports continue from
    /// there. Main thread only.
    private func resetBank() {
        generatedFrames = 0
        playedFrames = 0
        bankHadNoRoom = false
        recomputeBank()
    }

    // MARK: - SpeechEngine surface

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        speed = Float(min(2.0, max(0.5, rateMultiplier)))

        let allChunks = SentenceChunker.chunks(
            for: clean,
            firstMaxChars: config.firstMaxChars ?? config.chunkMaxChars,
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
        for _ in 0..<Self.gateFloodCount {
            pacingGate?.signal()
        }

        chunks = allChunks
        bufferSlots = [Int](repeating: Self.slotPending, count: allChunks.count)
        bufferPool = [:]
        scheduledUpTo = -1
        totalChars = max(1, clean.utf16.count)
        playTracker.reset()
        rateDrainArmed = false
        // A new session inherits its starting rate as the baseline: a rate
        // scribbled between taps isn't a "change" for the purge, so the very
        // first chunk isn't pointlessly regenerated when it was synthesized
        // at the rate the user already set.
        rateLock.lock()
        speedChangedGeneration = generation
        rateLock.unlock()
        // Fresh bank: an empty bank lets the producer start on chunk 0
        // immediately (TTFA is untouched by the bank) and fills toward the
        // thermal target from there.
        resetBank()

        // Fresh gate per generation. The bank is the throttle; the gate is
        // only the producer's wakeup token (recomputeBank edge-signals it
        // when the bank drains below target). stop() floods the gate so a
        // blocked producer always wakes and exits.
        pacingGate = DispatchSemaphore(value: 0)

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
                guard self.waitForBankRoom(generation: generation) else {
                    // Superseded, stopped, or the pipeline went .idle: no
                    // buffer will ever be scheduled from here, so exit the
                    // producer QUIETLY — a skip tone and bookkeeping would
                    // fire against a pipeline that no longer exists (the
                    // critique's P3: the tone was the only part of the skip
                    // path that still landed).
                    return
                }
                // Rate change: buffers synthesized BEFORE the slider moved
                // carry the OLD speed. Waiting for every banked old-rate
                // buffer to play out made 1.0→2.0 take seconds to land —
                // audible dead-air transition latency. Instead of waiting we
                // drop the not-yet-playing ones (the producer regenerates
                // them at the new rate from the same chunk list), reset the
                // play-position tracker on the far side of the boundary so
                // the cursor never steps back, and release the producer back
                // into its loop. One dispatch per rate change, never in the
                // steady-state loop.
                let snap = self.speedSnapshot
                if snap.changedIn == generation, index > 0, !self.rateDrainArmed {
                    self.rateDrainArmed = true
                    let purgingFrom = index
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.playbackGeneration == generation else { return }
                        self.purgeStaleRateBuffers(from: purgingFrom, generation: generation)
                    }
                }
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
                        // The chunk's frames enter the bank the moment they
                        // exist in memory — that is the jetsam-relevant
                        // instant, and the byte cap is about memory, not
                        // scheduling. `generatedFrames` is session-cumulative;
                        // the playhead side drains it. The recompute runs
                        // BEFORE the schedule below: schedule()'s drain
                        // classification reads this snapshot and subtracts
                        // THIS buffer's seconds, which is only coherent if
                        // the buffer is already in it.
                        self.generatedFrames += Int64(buffer.frameLength)
                        self.recomputeBank()
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
                    reportChunkSkipped(
                        index: index,
                        chunkCount: allChunks.count,
                        chars: chunk.length,
                        generation: generation,
                        message: "\(error): «\(chunk.text.prefix(60))»"
                    )
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
        for _ in 0..<Self.gateFloodCount {
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
            // ACTUALLY sounding, not the schedule cursor (which runs as far
            // ahead as the render-ahead bank is deep).
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
        // Order matters: the gap is labeled with the buffer count as it
        // stood BEFORE this one is added to it, and the bank depth compared
        // is the snapshot minus THIS buffer — its frames are in the bank
        // (generated, unplayed) but had not reached the node when the drain
        // happened. An empty bank at the drain is synthesis-bound silence
        // (`bank exhausted` — the thermal-pressure signature Batch B exists
        // for); banked audio that scheduling could not reach is the
        // main-thread-stall GAP. Both are audible silence and both count in
        // the session's gap figure; the split names the cause.
        if restartedAfterDrain {
            let thisBufferSeconds = Double(buffer.frameLength) / buffer.format.sampleRate
            let bankedBeforeThis = max(0, bankedSeconds() - thisBufferSeconds)
            if RenderAheadBankPolicy.isExhausted(bankedSeconds: bankedBeforeThis) {
                let thermal = ThermalPressure(
                    thermalStateRawValue: ProcessInfo.processInfo.thermalState.rawValue)
                metrics.bankExhausted(thermal: "\(thermal)", bankedSeconds: bankedBeforeThis)
            } else {
                metrics.nodeRestarted()
            }
        }
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
        // Re-assert on EVERY schedule, not just the first: an interruption,
        // a media-services reset or a route change can leave the session
        // inactive behind our back, and a session that is configured but
        // not active is suspended by iOS seconds after the app backgrounds.
        AudioSessionSetup.activate(prefix: config.logPrefix)
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
        // Session dead — zero the bank counters so a stale snapshot can never
        // pace a session that no longer exists (a new session re-zeros again).
        resetBank()
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
            firstMaxChars: config.firstMaxChars ?? config.chunkMaxChars,
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
            // Export-only state, generateQueue-confined (see the property
            // doc). Cleared when this block exits, however it exits.
            self.isExporting = true
            defer { self.isExporting = false }

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
        // A zero-frame capacity init returns nil and the force-unwrap would
        // crash — an engine that legitimately produced no samples (e.g.
        // A chunk whose engine emitted [STOP] on step 0) schedules as a one-frame silent
        // buffer instead.
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, AVAudioFrameCount(samples.count)))!
        buffer.frameLength = min(AVAudioFrameCount(samples.count), buffer.frameCapacity)

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
