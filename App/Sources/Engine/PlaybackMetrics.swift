import Foundation

/// Per-session playback instrumentation for `StreamingTTSPlaybackCore`.
///
/// Why this exists: every claim in `TTS_BASELINE.md` about where the pipeline
/// loses time is currently ARITHMETIC — chars → audio seconds → generation
/// seconds at an assumed real-time factor. There is no device in this
/// environment and no benchmark has ever been recorded, so those numbers are
/// models, not measurements. This turns them into measurements the first time
/// somebody plays a note on a device and opens LogsView.
///
/// Nothing here changes playback behavior. It records timestamps and logs.
///
/// Every line carries the `metrics` tag, so an exported log can be filtered
/// down to just the instrumentation:
///
///     OnnxKokoroEngine metrics TTFA 1180ms — first buffer scheduled (84 chars)
///     OnnxKokoroEngine metrics chunk 2/12 — 160 chars → 4.20s audio in 2.11s (RTF 0.50)
///     OnnxKokoroEngine metrics GAP 0.48s of silence — node drained …
///     OnnxKokoroEngine metrics session finished — 12 chunks …
///
/// What it measures
///  - **TTFA** — `speak()` entry to the first buffer actually queued on the
///    player node. The number a listener experiences as "how long after I tap
///    play before anything sounds".
///  - **T2B** — `speak()` entry to the *second* buffer queued. This is the
///    quantity that decides the first-sentence stall: chunk 0's audio has to
///    last until chunk 1 is scheduled, or the node drains and there is
///    silence. The log line prints both halves of that comparison.
///  - **Per-chunk RTF** — chars → audio seconds → generation seconds. Measured
///    around the whole `generateChunk` closure, so it includes phonemization
///    and tokenization; the engines' own per-chunk log times only `synthesize`
///    and therefore understates the cost.
///  - **Audible gap** — the node drained and had to be restarted. Measured
///    event-to-event, not inferred.
///  - **Stall** — the pipeline believes it is speaking, the node is silent, and
///    work is still outstanding. This is the "UI says playing, nothing sounds"
///    failure mode, and it is the one thing no amount of source analysis can
///    rule out.
///  - **Session summary** — one line at natural finish, so a single grep answers
///    "was this session smooth?" without stitching per-chunk lines together.
///
/// Threading: main-thread confined, exactly like the core's own pipeline state.
/// The two `static` clock helpers are the only surface touched from
/// `generateQueue`; they read a monotonic clock and return value types, so no
/// measurement crosses a thread as shared mutable state.
final class PlaybackMetrics {
    private let prefix: String

    init(prefix: String) {
        self.prefix = prefix
    }

    // MARK: - Clock helpers (safe off the main thread)

    // `ContinuousClock` rather than `Date()`: monotonic, and it keeps counting
    // while the device sleeps, so a background stall is still measured as one
    // and an NTP correction can't invent a gap that never happened.

    /// Stamp the start of a measured interval. Called on `generateQueue`
    /// around a synthesis call.
    static func monotonicNow() -> ContinuousClock.Instant { ContinuousClock.now }

    /// Seconds elapsed since `instant`. Pure — no shared state.
    static func seconds(since instant: ContinuousClock.Instant) -> Double {
        seconds(from: instant, to: ContinuousClock.now)
    }

    /// Times a synchronous model-file validation performed on the play path and
    /// logs the cost under the `metrics` tag.
    ///
    /// Why this is instrumented separately from TTFA: both ONNX engines
    /// validate their model files on the main thread inside their own `speak()`,
    /// BEFORE handing off to the core — so the cost sits upstream of TTFA's t0
    /// and would otherwise be invisible. Kokoro's path is 3 `attributesOfItem`
    /// syscalls plus a full read-and-parse of `tokenizer.json`; Supertonic's is
    /// roughly 16 syscalls across its four sessions. Neither result can change
    /// between two taps seconds apart, which makes both pure overhead on the
    /// critical path and gives a caching change a measured before/after instead
    /// of a guess.
    ///
    /// `alwaysLog` is true for the first call in an engine's life and false
    /// afterwards, so a 300-chapter book doesn't push 300 identical lines
    /// through a 500-entry ring buffer. Anything at or over
    /// `slowThresholdSeconds` logs regardless — that's the case worth seeing.
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

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let interval = a.duration(to: b)
        return Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1_000_000_000_000_000_000
    }

    // MARK: - Session state (main thread only)

    private var sessionActive = false
    private var sessionStart: ContinuousClock.Instant?
    private var chunkCount = 0
    private var firstChunkChars = 0
    private var firstChunkAudioSeconds: Double = 0
    private var sessionRate: Float = 1.0

    private var firstAudioAt: ContinuousClock.Instant?
    private var secondBufferAt: ContinuousClock.Instant?
    private var scheduledBuffers = 0

    private var generatedChunks = 0
    private var skippedChunks = 0
    private var totalGenerationSeconds: Double = 0
    private var totalAudioSeconds: Double = 0

    private var lastBufferEndedAt: ContinuousClock.Instant?
    private var gapCount = 0
    private var worstGapSeconds: Double = 0

    private var stallStart: ContinuousClock.Instant?
    private var lastStallLoggedSeconds: Double = 0

    // MARK: - Session lifecycle

    /// Called from `speak(_:)`. Ends any session left open (a second play tap
    /// supersedes the first without going through `stop()`) and stamps t0.
    func beginSession(chunkCount: Int, firstChunkChars: Int, rate: Float) {
        if sessionActive { endSession(reason: "superseded") }

        sessionActive = true
        sessionStart = ContinuousClock.now
        self.chunkCount = chunkCount
        self.firstChunkChars = firstChunkChars
        self.firstChunkAudioSeconds = 0
        self.sessionRate = rate
        firstAudioAt = nil
        secondBufferAt = nil
        scheduledBuffers = 0
        generatedChunks = 0
        skippedChunks = 0
        totalGenerationSeconds = 0
        totalAudioSeconds = 0
        lastBufferEndedAt = nil
        gapCount = 0
        worstGapSeconds = 0
        stallStart = nil
        lastStallLoggedSeconds = 0

        Log.shared.info("\(prefix) metrics session start — \(chunkCount) chunks, first \(firstChunkChars) chars, rate \(twoDP(Double(rate)))")
    }

    /// One summary line, then the session goes quiet. `reason` distinguishes a
    /// natural finish from a user stop from a teardown nobody asked for — the
    /// last of those is the interesting one.
    func endSession(reason: String) {
        guard sessionActive else { return }
        sessionActive = false

        let summary: String
        if let start = sessionStart {
            let wall = Self.seconds(from: start, to: ContinuousClock.now)
            let pipelineRTF = totalAudioSeconds > 0 ? totalGenerationSeconds / totalAudioSeconds : 0
            summary = "\(prefix) metrics session \(reason) — \(generatedChunks) chunks (\(skippedChunks) skipped), "
                + "\(twoDP(totalAudioSeconds))s audio, \(twoDP(totalGenerationSeconds))s gen, pipeline RTF \(twoDP(pipelineRTF)), "
                + "TTFA \(ttfaText), T2B \(t2bText), gaps \(gapCount) (worst \(twoDP(worstGapSeconds))s), wall \(twoDP(wall))s, rate \(twoDP(Double(sessionRate)))"
        } else {
            summary = "\(prefix) metrics session \(reason) — no start stamp"
        }
        Log.shared.info(summary)

        sessionStart = nil
        firstAudioAt = nil
        secondBufferAt = nil
        stallStart = nil
        lastBufferEndedAt = nil
        lastStallLoggedSeconds = 0
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
    /// `generateQueue` around the whole `generateChunk` closure — retries
    /// included, since a retry IS part of what the listener waits for.
    func chunkGenerated(index: Int, chars: Int, generationSeconds: Double, audioSeconds: Double) {
        guard sessionActive else { return }
        generatedChunks += 1
        totalGenerationSeconds += generationSeconds
        totalAudioSeconds += audioSeconds
        if index == 0 { firstChunkAudioSeconds = audioSeconds }

        let rtf = audioSeconds > 0 ? generationSeconds / audioSeconds : 0
        Log.shared.info("\(prefix) metrics chunk \(index + 1)/\(chunkCount) — \(chars) chars → \(twoDP(audioSeconds))s audio in \(twoDP(generationSeconds))s (RTF \(twoDP(rtf)))")
    }

    /// Synthesis failed twice and the chunk was skipped. Logged separately from
    /// the error line the core already emits: the error says WHY, this says
    /// what it cost the session accounting (chars that will never sound).
    func chunkSkipped(index: Int, chars: Int) {
        guard sessionActive else { return }
        skippedChunks += 1
        Log.shared.info("\(prefix) metrics chunk \(index + 1)/\(chunkCount) SKIPPED — \(chars) chars will not sound")
    }

    // MARK: - Scheduling

    /// A buffer was queued on the player node. The first call in a session
    /// stamps TTFA; the second stamps T2B.
    func bufferScheduled(chars: Int) {
        guard sessionActive, let start = sessionStart else { return }
        scheduledBuffers += 1
        let now = ContinuousClock.now

        if scheduledBuffers == 1 {
            firstAudioAt = now
            Log.shared.info("\(prefix) metrics TTFA \(milliseconds(from: start, to: now))ms — first buffer scheduled (\(chars) chars)")
            return
        }
        if scheduledBuffers == 2 {
            secondBufferAt = now
            // The whole first-stall hypothesis in one line: chunk 0's audio
            // duration versus how long chunk 1 took to arrive. When the wait
            // exceeds the audio, the difference is silence the listener hears.
            let waitFromFirst = firstAudioAt.map { self.milliseconds(from: $0, to: now) } ?? 0
            let audioMs = Int((firstChunkAudioSeconds * 1000).rounded())
            let verdict = audioMs > waitFromFirst ? "covered" : "SHORT by \(waitFromFirst - audioMs)ms"
            Log.shared.info("\(prefix) metrics T2B \(milliseconds(from: start, to: now))ms — second buffer \(waitFromFirst)ms after the first; chunk 0 was \(firstChunkChars) chars / \(twoDP(firstChunkAudioSeconds))s of audio (\(audioMs)ms) → \(verdict)")
        }
    }

    /// A buffer finished rendering out of the node.
    func bufferEnded() {
        guard sessionActive else { return }
        lastBufferEndedAt = ContinuousClock.now
    }

    /// The node had drained and is being restarted. Whatever elapsed since the
    /// last buffer ended was audible silence — this is a measured gap, not an
    /// estimate, and it is the ground truth for the stall model.
    func nodeRestarted() {
        guard sessionActive, let ended = lastBufferEndedAt else { return }
        let gap = Self.seconds(from: ended, to: ContinuousClock.now)
        gapCount += 1
        worstGapSeconds = max(worstGapSeconds, gap)
        lastBufferEndedAt = nil
        Log.shared.error("\(prefix) metrics GAP \(twoDP(gap))s of silence — node drained after \(scheduledBuffers) buffers, restarted for buffer \(scheduledBuffers + 1)")
    }

    // MARK: - Pause

    /// Pause discards the pending-gap timestamp so a 30 s pause followed by a
    /// resume is never reported as a 30 s audible gap.
    func playbackPaused() {
        lastBufferEndedAt = nil
        stallStart = nil
        lastStallLoggedSeconds = 0
    }

    // MARK: - Stall watchdog

    /// Ticked at 1 Hz by the core's watchdog while a session is live.
    ///
    /// A stall is all three of: the pipeline reports `.speaking`, the node is
    /// silent, and chunks are still outstanding. Before the first buffer this
    /// is just TTFA (measured separately), so `scheduledBuffers > 0` is part of
    /// the condition — otherwise every session "stalls" for its whole warm-up.
    ///
    /// Logs on detection and then once every 5 s while it lasts. A permanent
    /// silence behind a playing UI is the worst outcome this pipeline can have
    /// and should not be quiet about it — but the log ring buffer holds 500
    /// entries, so a per-second cadence would let a backgrounded stall evict
    /// the very log that was supposed to explain it. The "stall cleared" line
    /// carries the exact total either way.
    func checkStall(stateIsSpeaking: Bool, nodeIsPlaying: Bool, pendingChunks: Int) {
        guard sessionActive else { return }

        let stalling = stateIsSpeaking && !nodeIsPlaying && scheduledBuffers > 0 && pendingChunks > 0
        guard stalling else {
            if let start = stallStart {
                let duration = Self.seconds(from: start, to: ContinuousClock.now)
                stallStart = nil
                lastStallLoggedSeconds = 0
                if duration >= 0.5 {
                    Log.shared.info("\(prefix) metrics stall cleared after \(twoDP(duration))s")
                }
            }
            return
        }

        let now = ContinuousClock.now
        let duration: Double
        if let start = stallStart {
            duration = Self.seconds(from: start, to: now)
            guard duration >= lastStallLoggedSeconds + 5.0 else { return }
        } else {
            stallStart = now
            duration = 0
        }
        lastStallLoggedSeconds = duration
        Log.shared.error("\(prefix) metrics STALL \(twoDP(duration))s — state speaking, node silent, \(pendingChunks) chunks outstanding (\(scheduledBuffers)/\(chunkCount) scheduled)")
    }

    // MARK: - Formatting

    private func milliseconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Int {
        Int((Self.seconds(from: a, to: b) * 1000).rounded())
    }

    private func twoDP(_ value: Double) -> String { String(format: "%.2f", value) }
}
