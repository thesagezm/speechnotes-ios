import Foundation

/// Per-session playback instrumentation for `StreamingTTSPlaybackCore`.
///
/// The pipeline's timing behaviour has never been measured — there is no device
/// in the development environment and no recorded benchmark, so every claim
/// about where it loses time is arithmetic. This produces the numbers instead.
///
/// - **TTFA** — `speak()` entry to the first buffer queued on the player node.
/// - **T2B** — `speak()` entry to the *second* buffer queued, logged against
///   the first buffer's audio duration. Whether that audio covers the wait is
///   the entire first-sentence-stall question, so the line answers it directly.
/// - **Synthesis RTF** — per chunk: chars → audio seconds → generation seconds.
///   Measured around the whole `generateChunk` closure (retries included), so it
///   covers phonemization and tokenization, which the engines' own per-chunk log
///   omits. It excludes time blocked on the pacing gate by construction, so it
///   describes the model, not the pipeline.
/// - **GAP** — the node drained and had to be restarted. A lower bound: see
///   `nodeRestarted()`.
/// - **STALL** — the pipeline reports speaking, the node is silent, and it stays
///   that way. The "UI shows playing, nothing sounds" failure mode.
/// - **Session summary** — one line at finish / stop / teardown.
///
/// Every line carries the `metrics` tag, so a log can be filtered to them.
/// All durations are computed in-code from `ContinuousClock` — monotonic, and
/// it counts through device sleep so a background stall is still measured as
/// one and an NTP correction cannot invent a gap. Never diffed from log
/// timestamps, which are wall-clock. Suspension safety is load-bearing on
/// `playbackPaused()` clearing the pending gap and stall stamps.
///
/// Threading: main-thread confined, matching the core's own pipeline state —
/// a comment-only contract, same as the core's. `@MainActor` would enforce it
/// but would then reject the `DispatchQueue.main.async` call sites in the core,
/// whose closures are not main-actor-isolated in Swift 5 mode. The three
/// `static` members are the only surface touched from `generateQueue`; they
/// read a monotonic clock and return value types, so no measurement crosses a
/// thread as shared mutable state.
///
/// The log sink is injectable so the arithmetic below can be asserted without
/// the `LogStore` singleton.
final class PlaybackMetrics {
    private let prefix: String

    /// `(message, isError)`. Swappable for tests; defaults to the app log.
    var sink: (String, Bool) -> Void

    init(prefix: String) {
        self.prefix = prefix
        self.sink = { message, isError in
            if isError { Log.shared.error(message) } else { Log.shared.info(message) }
        }
    }

    // MARK: - Clock + pure decisions (safe off the main thread)

    /// Stamp the start of a measured interval. Called on `generateQueue`.
    static func monotonicNow() -> ContinuousClock.Instant { ContinuousClock.now }

    /// Seconds elapsed since `instant`. Pure — no shared state.
    static func seconds(since instant: ContinuousClock.Instant) -> Double {
        seconds(from: instant, to: ContinuousClock.now)
    }

    /// Which chunks get their own RTF line: the first few (they set TTFA and
    /// T2B and are the stall-prone ones), every 25th after that, and the last.
    ///
    /// A 200k-char chapter is ~1300 chunks. Logging all of them takes per-chunk
    /// volume to ~2600 lines, which evicts TTFA from `LogStore`'s 500-entry
    /// ring before the chapter ends — and with it the only record of whether
    /// RTF degraded across a 40-minute session (thermal throttling on a
    /// 326 MB CPU ONNX model is plausible and is exactly what the quartile
    /// lines are for).
    static func shouldLogChunk(index: Int, chunkCount: Int) -> Bool {
        if index < 4 { return true }
        if index == chunkCount - 1 { return true }
        return index % 25 == 0
    }

    /// Signed margin between the audio the first buffer carried and the wait
    /// for the second. Positive means covered; negative is silence the listener
    /// hears. Always printed — the size of the margin is the diagnostic, and a
    /// bare "covered" hides a 5 ms near-miss behind a 3 s comfortable start.
    static func marginText(audioSeconds: Double, waitSeconds: Double) -> String {
        let marginMs = Int(((audioSeconds - waitSeconds) * 1000).rounded())
        return marginMs >= 0 ? "margin +\(marginMs)ms (covered)" : "margin \(marginMs)ms (SHORT — audible silence)"
    }

    /// A gap only escalates to ERROR at half a second. The first-sentence drain
    /// is a known, expected, sub-half-second event today; logging it at ERROR on
    /// every play would drain the level of meaning, and this repo otherwise
    /// reserves `.error` for real failures.
    static func gapIsError(_ seconds: Double) -> Bool { seconds >= 0.5 }

    /// Re-log a continuing stall at most every 5 s. At 1 Hz a backgrounded
    /// stall would evict the 500-entry ring buffer — the log that was supposed
    /// to explain it — in about 8 minutes; at 5 s it takes ~42, and the
    /// persisted 300-line tail covers ~25.
    static func stallShouldLog(elapsedSeconds: Double, lastLoggedSeconds: Double) -> Bool {
        elapsedSeconds >= lastLoggedSeconds + 5.0
    }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let interval = a.duration(to: b)
        return Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1_000_000_000_000_000_000
    }

    // MARK: - Session state (main thread only)

    private var sessionActive = false
    private var sessionStart: ContinuousClock.Instant?
    private var chunkCount = 0
    private var sessionRate: Float = 1.0

    /// Facts about the buffer that ACTUALLY sounded first — not chunk index 0,
    /// which can be skipped, in which case its char count would be printed
    /// against audio it never produced.
    private var firstScheduledChars = 0
    private var firstScheduledAudioSeconds: Double = 0

    private var firstAudioAt: ContinuousClock.Instant?
    private var secondBufferAt: ContinuousClock.Instant?
    private var scheduledBuffers = 0

    private var generatedChunks = 0
    private var skippedChunks = 0
    private var totalGenerationSeconds: Double = 0
    private var totalAudioSeconds: Double = 0
    private var fastestChunkRTF: Double = 0
    private var slowestChunkRTF: Double = 0
    private var lastQuartileLogged = 0

    private var lastBufferEndedAt: ContinuousClock.Instant?
    private var gapCount = 0
    private var worstGapSeconds: Double = 0

    private var pausedAt: ContinuousClock.Instant?
    private var pausedSeconds: Double = 0
    private var pauseCount = 0

    private var stallStart: ContinuousClock.Instant?
    private var stallTicks = 0
    /// Seconds-of-stall at the last STALL line. nil means none has been
    /// emitted for the current stall, which is what lets the first one go
    /// out immediately while the repeats stay on the 5 s cadence.
    private var lastStallLoggedSeconds: Double?

    private func reset() {
        sessionStart = ContinuousClock.now
        firstScheduledChars = 0
        firstScheduledAudioSeconds = 0
        firstAudioAt = nil
        secondBufferAt = nil
        scheduledBuffers = 0
        generatedChunks = 0
        skippedChunks = 0
        totalGenerationSeconds = 0
        totalAudioSeconds = 0
        fastestChunkRTF = 0
        slowestChunkRTF = 0
        lastQuartileLogged = 0
        lastBufferEndedAt = nil
        gapCount = 0
        worstGapSeconds = 0
        pausedAt = nil
        pausedSeconds = 0
        pauseCount = 0
        stallStart = nil
        stallTicks = 0
        lastStallLoggedSeconds = nil
    }

    // MARK: - Session lifecycle

    /// Called from `speak(_:)`. Closes any session left open — a second play
    /// tap supersedes the first without going through `stop()` — then stamps t0.
    func beginSession(chunkCount: Int, firstChunkChars: Int, rate: Float) {
        if sessionActive { endSession(reason: "superseded") }

        sessionActive = true
        self.chunkCount = chunkCount
        self.sessionRate = rate
        reset()

        emit("session start — \(chunkCount) chunks, chunk 0 is \(firstChunkChars) chars, rate@start \(twoDP(Double(rate)))")
    }

    /// One summary line, then the session goes quiet. `reason` separates a
    /// natural finish from a user stop from a teardown nobody asked for; the
    /// last is the interesting one.
    ///
    /// `wall` is speak-entry to now on a clock that counts through sleep, and
    /// it INCLUDES every pause — so it is not comparable to the `audio` figure
    /// beside it. The paused total and pause count are printed for exactly that
    /// reason.
    func endSession(reason: String) {
        guard sessionActive else { return }
        sessionActive = false
        closeOpenPause()

        guard let start = sessionStart else {
            emit("session \(reason) — no start stamp")
            return
        }
        let wall = Self.seconds(from: start, to: ContinuousClock.now)
        let synthesisRTF = totalAudioSeconds > 0 ? totalGenerationSeconds / totalAudioSeconds : 0
        let rtfRange = slowestChunkRTF > 0
            ? "chunk RTF \(twoDP(fastestChunkRTF))–\(twoDP(slowestChunkRTF))"
            : "chunk RTF n/a"
        emit("session \(reason) — \(generatedChunks) chunks (\(skippedChunks) skipped), "
            + "\(twoDP(totalAudioSeconds))s audio, \(twoDP(totalGenerationSeconds))s gen, "
            + "synthesis RTF \(twoDP(synthesisRTF)) [\(rtfRange)], "
            + "TTFA \(ttfaText), T2B \(t2bText), gaps \(gapCount) (worst \(twoDP(worstGapSeconds))s, lower bound), "
            + "wall \(twoDP(wall))s incl. \(twoDP(pausedSeconds))s paused across \(pauseCount) pause(s), "
            + "rate@start \(twoDP(Double(sessionRate)))")
    }

    /// Model readiness resolved on `generateQueue`. Separates a cold session
    /// (Kokoro: a 326 MB ONNX session load plus a tokenizer parse) from a warm
    /// one — otherwise a 25 s cold TTFA and a 1.2 s warm TTFA land in the same
    /// field with the same label and nothing explains the difference.
    func modelReady(seconds: Double) {
        guard sessionActive else { return }
        let cold = seconds >= 1.0
        // Not an error even when cold: the first play after launch always
        // pays the model load, so routing it to the error channel would
        // make every normal cold start look like a fault. The label carries
        // the distinction.
        emit("model-ready \(twoDP(seconds))s (\(cold ? "COLD — includes the model load, inside TTFA" : "warm"))")
    }

    private var ttfaText: String {
        guard let start = sessionStart, let first = firstAudioAt else { return "n/a" }
        return "\(milliseconds(from: start, to: first))ms"
    }

    private var t2bText: String {
        guard let start = sessionStart, let second = secondBufferAt else { return "n/a" }
        return "\(milliseconds(from: start, to: second))ms"
    }

    // MARK: - Generation

    /// A chunk came back from the model. `generationSeconds` was measured on
    /// `generateQueue` around the whole `generateChunk` closure — retries and
    /// their back-off sleeps included, since a retry is part of what the
    /// listener waits for, but time blocked on the pacing gate excluded, since
    /// that is the pipeline waiting on playback and not the model working.
    func chunkGenerated(index: Int, chars: Int, generationSeconds: Double, audioSeconds: Double) {
        guard sessionActive else { return }
        generatedChunks += 1
        totalGenerationSeconds += generationSeconds
        totalAudioSeconds += audioSeconds

        let rtf = audioSeconds > 0 ? generationSeconds / audioSeconds : 0
        if audioSeconds > 0 {
            fastestChunkRTF = fastestChunkRTF > 0 ? min(fastestChunkRTF, rtf) : rtf
            slowestChunkRTF = max(slowestChunkRTF, rtf)
        }
        if Self.shouldLogChunk(index: index, chunkCount: chunkCount) {
            emit("chunk \(index + 1)/\(chunkCount) — \(chars) chars → \(twoDP(audioSeconds))s audio in \(twoDP(generationSeconds))s (RTF \(twoDP(rtf)))")
        }
        logQuartileIfNeeded()
    }

    /// Synthesis failed twice and the chunk was skipped. The core already logs
    /// WHY at error level; this records what it cost the session accounting.
    func chunkSkipped(index: Int, chars: Int) {
        guard sessionActive else { return }
        skippedChunks += 1
        emit("chunk \(index + 1)/\(chunkCount) SKIPPED — \(chars) chars will not sound")
    }

    /// Running-mean RTF at each quartile of a session long enough for the
    /// trend to mean something. Comparing these four lines is how a device
    /// session answers "does synthesis slow down as the chapter goes on?".
    private func logQuartileIfNeeded() {
        guard chunkCount >= 16 else { return }
        let quartile = (generatedChunks * 4) / chunkCount
        guard quartile > lastQuartileLogged, quartile < 4 else { return }
        lastQuartileLogged = quartile
        let mean = totalAudioSeconds > 0 ? totalGenerationSeconds / totalAudioSeconds : 0
        emit("RTF at \(quartile * 25)% — \(generatedChunks)/\(chunkCount) chunks, mean RTF \(twoDP(mean)), "
            + "chunk RTF \(twoDP(fastestChunkRTF))–\(twoDP(slowestChunkRTF)), "
            + "\(twoDP(totalAudioSeconds))s audio / \(twoDP(totalGenerationSeconds))s gen")
    }

    // MARK: - Scheduling

    /// A buffer was queued on the player node. The first call stamps TTFA, the
    /// second stamps T2B.
    func bufferScheduled(chars: Int, audioSeconds: Double) {
        guard sessionActive, let start = sessionStart else { return }
        scheduledBuffers += 1
        let now = ContinuousClock.now

        if scheduledBuffers == 1 {
            firstAudioAt = now
            firstScheduledChars = chars
            firstScheduledAudioSeconds = audioSeconds
            emit("TTFA \(milliseconds(from: start, to: now))ms — first buffer scheduled (\(chars) chars → \(twoDP(audioSeconds))s audio)")
            return
        }
        guard scheduledBuffers == 2, let first = firstAudioAt else { return }
        secondBufferAt = now
        let wait = Self.seconds(from: first, to: now)
        emit("T2B \(milliseconds(from: start, to: now))ms — second buffer \(milliseconds(from: first, to: now))ms after the first; "
            + "the first was \(firstScheduledChars) chars / \(twoDP(firstScheduledAudioSeconds))s of audio → "
            + Self.marginText(audioSeconds: firstScheduledAudioSeconds, waitSeconds: wait))
    }

    /// A buffer finished rendering out of the node.
    func bufferEnded() {
        guard sessionActive else { return }
        lastBufferEndedAt = ContinuousClock.now
    }

    /// The node had drained and is being restarted; whatever elapsed since the
    /// last buffer ended was audible silence.
    ///
    /// A LOWER BOUND, for two reasons. (1) Both endpoints are stamped on the
    /// main queue, not in the render callback, so each carries main-queue
    /// dispatch latency and the two do not cancel. (2) A drain across a
    /// pause/resume is dropped: `playbackPaused()` clears the pending stamp so
    /// a 10-minute pause is never reported as a 10-minute gap, and nothing
    /// re-arms it on resume.
    func nodeRestarted() {
        guard sessionActive, let ended = lastBufferEndedAt else { return }
        let gap = Self.seconds(from: ended, to: ContinuousClock.now)
        gapCount += 1
        worstGapSeconds = max(worstGapSeconds, gap)
        lastBufferEndedAt = nil
        emit("GAP \(twoDP(gap))s of silence — node drained after \(scheduledBuffers) buffers, restarted for buffer \(scheduledBuffers + 1)",
             isError: Self.gapIsError(gap))
    }

    // MARK: - Pause

    /// Clears the pending gap and stall stamps so a pause is never reported as
    /// either, and starts banking paused time.
    func playbackPaused() {
        // Stamps are cleared whether or not a session is open: a pause must
        // never be re-reported as a gap or a stall. The banking below is
        // session-scoped — `pauseCount` and `pausedSeconds` only mean anything
        // inside one summary line, and `reset()` clears them at the next start.
        lastBufferEndedAt = nil
        stallStart = nil
        stallTicks = 0
        lastStallLoggedSeconds = nil
        guard sessionActive, pausedAt == nil else { return }
        pausedAt = ContinuousClock.now
        pauseCount += 1
    }

    func playbackResumed() {
        closeOpenPause()
    }

    private func closeOpenPause() {
        guard let paused = pausedAt else { return }
        pausedSeconds += Self.seconds(from: paused, to: ContinuousClock.now)
        pausedAt = nil
    }

    // MARK: - Stall watchdog

    /// Ticked at 1 Hz by the core's watchdog while a session is live.
    ///
    /// A stall is: the pipeline reports `.speaking`, the node is silent, audio
    /// has already started, and that has held for two consecutive ticks.
    ///
    /// - `scheduledBuffers > 0` because before the first buffer this is just
    ///   TTFA — without it every session "stalls" for its whole warm-up.
    /// - Two ticks because a drain of D seconds straddles a 1 Hz tick with
    ///   probability ≈ D, so a single-tick trigger reports an ordinary 0.3 s
    ///   boundary drain as a stall roughly a third of the time.
    /// - Deliberately NOT conditioned on chunks still being outstanding. The
    ///   terminal case this exists for is a hang AFTER the last schedule — a
    ///   route or engine-configuration change kills the audio graph, the last
    ///   buffer's completion never fires, `state` stays `.speaking`, the UI
    ///   shows playing and the book never advances. Requiring pending chunks
    ///   would make the detector silent in exactly that case.
    func checkStall(stateIsSpeaking: Bool, nodeIsPlaying: Bool, pendingChunks: Int) {
        guard sessionActive else { return }

        let stalling = stateIsSpeaking && !nodeIsPlaying && scheduledBuffers > 0
        guard stalling else {
            // Report a clearance only for a stall that was actually reported,
            // so the two lines always pair. `stallStart` is stamped at
            // detection rather than at drain onset, so its duration carries the
            // watchdog's ±1 s quantisation — printing that for an ordinary
            // 0.3 s boundary drain would both overstate the drain and add a
            // line at roughly a third of all chunk boundaries, which is exactly
            // the volume the thinning in TTS_BASELINE.md §6 exists to prevent.
            // Hence "≥": like the gap figure, this is a lower bound.
            if let start = stallStart, lastStallLoggedSeconds != nil {
                emit("stall cleared after ≥\(twoDP(Self.seconds(from: start, to: ContinuousClock.now)))s")
            }
            // Reset UNCONDITIONALLY. `stallTicks` is incremented on the first
            // tick, before `stallStart` is ever read back, so gating the reset
            // on `stallStart` would let a count survive a clearance: tick 1 of
            // one drain, a recovery, then tick 1 of an unrelated drain would
            // add up to two and log — reintroducing the single-tick false
            // positive the two-tick condition exists to prevent.
            stallStart = nil
            stallTicks = 0
            lastStallLoggedSeconds = nil
            return
        }

        stallTicks += 1
        let now = ContinuousClock.now
        // Stamped on FIRST detection, not on first log, so the reported duration
        // is real rather than 0.00s — the stall began a tick ago.
        if stallStart == nil { stallStart = now }
        guard stallTicks >= 2, let start = stallStart else { return }

        let duration = Self.seconds(from: start, to: now)
        // nil means "not yet logged this stall": the first line goes out as soon
        // as the two-tick condition is met, and only the repeats are throttled.
        if let last = lastStallLoggedSeconds,
           !Self.stallShouldLog(elapsedSeconds: duration, lastLoggedSeconds: last) {
            return
        }
        lastStallLoggedSeconds = duration
        emit("STALL \(twoDP(duration))s — state speaking, node silent, \(scheduledBuffers)/\(chunkCount) buffers scheduled, \(pendingChunks) chunks outstanding",
             isError: true)
    }

    // MARK: - Play-path validation (called from the engines)

    /// Times a synchronous model-file validation performed on the play path.
    ///
    /// Both ONNX engines validate their model files on the main thread inside
    /// their own `speak()`, BEFORE handing off to the core — so the cost sits
    /// upstream of TTFA's t0 and would otherwise be invisible. Kokoro's path is
    /// three `attributesOfItem` syscalls plus reading and JSON-parsing
    /// `tokenizer.json` (~3.5 KB); Supertonic's is roughly sixteen syscalls
    /// across four ONNX sessions. Neither result can change between two taps
    /// seconds apart, which makes both pure overhead on the critical path and
    /// gives a caching change a measured before/after instead of a guess.
    ///
    /// `alwaysLog` is true for an engine's first call and false afterwards, so a
    /// 300-chapter book does not push 300 identical lines through a 500-entry
    /// ring buffer. Anything at or over `slowThresholdSeconds` logs regardless.
    static func timedValidation(
        prefix: String,
        label: String,
        alwaysLog: Bool,
        slowThresholdSeconds: Double = 0.010,
        body: () -> Bool
    ) -> Bool {
        let start = ContinuousClock.now
        let result = body()
        let elapsed = seconds(from: start, to: ContinuousClock.now)
        if alwaysLog || elapsed >= slowThresholdSeconds {
            let ms = Int((elapsed * 1000).rounded())
            Log.shared.info("\(prefix) metrics \(label) \(ms)ms → \(result ? "valid" : "INVALID")")
        }
        return result
    }

    // MARK: - Output

    private func emit(_ message: String, isError: Bool = false) {
        sink("\(prefix) metrics \(message)", isError)
    }

    private func milliseconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Int {
        Int((Self.seconds(from: a, to: b) * 1000).rounded())
    }

    private func twoDP(_ value: Double) -> String { String(format: "%.2f", value) }
}
