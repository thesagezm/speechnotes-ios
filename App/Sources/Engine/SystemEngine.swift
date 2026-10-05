import AVFoundation
import SpeechLogic

/// Apple's built-in text-to-speech, and the app's fallback whenever a neural
/// model is missing or unplayable.
///
/// ## Why this is chunked (2026-10-02 device report)
///
/// It used to hand the WHOLE text to `AVSpeechSynthesizer.speak` as one
/// utterance. That works for a paragraph and fails for a chapter:
/// AVSpeechSynthesizer buffers a very long utterance internally before it
/// starts producing audio, and — the part the user reported — **it can sit
/// silent for a minute or more mid-session** before resuming. On a 200 kB
/// book chapter that is most of a chapter read as dead air.
///
/// So this engine now runs the same sentence-chunk pipeline the ONNX engines
/// use (`SentenceChunker.chunks`) and keeps ONE utterance in flight at a
/// time, starting the next as the previous finishes. Apple's synthesizer
/// starts a short utterance in tens of milliseconds, so the gaps between
/// chunks are inaudible, and no chunk is ever large enough to stall.
///
/// The consequences that had to be handled:
/// - `onProgress` / `onPlayedChars` must address the WHOLE text, so every
///   chunk carries the UTF-16 offset it starts at.
/// - `pause()` at a chunk boundary must not let the queue run on: the
///   in-flight chunk is paused (at a word) and the next one is not started.
/// - A rate change mid-session re-queues from the current chunk, keeping the
///   same base offsets so the read-along highlight never rewinds.
final class SystemEngine: NSObject, SpeechEngine {
    let name = "Apple (system)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onPlayedChars: ((Int) -> Void)?
    var onFinished: (() -> Void)?

    /// A `var`, not a `let`: after a phone call AVSpeechSynthesizer goes
    /// silent with no error and no further callbacks, and the only recovery
    /// is to destroy and recreate it (the delegate must be re-installed and
    /// the queue re-driven — see `rebuildSynthesizer`).
    private var synthesizer = AVSpeechSynthesizer()

    /// Identifier of the `AVSpeechSynthesisVoice` to use (Settings → System
    /// voice). Falls back to the default en-US voice when nil, or when the
    /// identifier no longer resolves (voice deleted from the device).
    var voiceIdentifier: String?

    /// Mid-session rate changes. AVSpeechSynthesizer cannot re-rate an
    /// utterance that is already running, so the remainder of the current
    /// chunk is re-queued at the new rate from the current word — the user
    /// hears the rest of the sentence change speed, not the whole chapter
    /// restart.
    ///
    /// Batch F1: debounced. The slider emits at 0.05 steps, and an
    /// un-debounced re-queue calls `stopSpeaking(at: .immediate)` per tick —
    /// so a drag chopped the sentence at every step instead of once.
    var speed: Float = 1.0 {
        didSet {
            guard speed != oldValue else { return }
            debouncedRateRequeue?.cancel()
            debouncedRateRequeue = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                self.requeueCurrentChunkAtNewRate()
            }
        }
    }

    /// Batch F1: the coalescing task for a rate change. nil in the steady
    /// state, so a non-playing or paused session pays nothing.
    private var debouncedRateRequeue: Task<Void, Never>?

    /// Every async state jump carries the utterance epoch it belongs to — a
    /// `speak`/`stop` interleave used to let a stale queued `idle`/`speaking`
    /// clobber the newer state (M15). Bumped on each speak() and stop().
    private var epoch = 0

    // MARK: - The chunk queue

    /// UTF-16 base offset and text of each queued chunk.
    private struct Queued {
        let offset: Int
        let text: String
    }

    private var queue: [Queued] = []
    private var nextIndex = 0
    /// Chunks handed to `synthesizer.speak(_:)` this session. The lookahead
    /// gate is `nextIndex - startedCount < lookahead`, so this is the count
    /// of utterances Apple has been given but the finish callback has not
    /// yet come back for.
    private var startedCount = 0
    /// The chunk currently in flight, and how many characters of it have
    /// sounded (`willSpeakRangeOfSpeechString` gives the latter).
    private var current: Queued?
    private var currentCharsDone = 0
    /// Total UTF-16 length of the whole spoken string — the denominator for
    /// progress.
    private var totalChars = 1
    /// The whole text this session is speaking. Kept so a rate change can
    /// re-queue the current chunk's remainder.
    private var activeUtteranceText: String?
    /// Pause intent: a pause that lands between chunks must stop the queue,
    /// not just the one utterance in flight.
    private var pauseRequested = false
    /// True once the in-flight chunk reported `didFinish` — a pause held at
    /// a chunk BOUNDARY (didFinish fired, startNextChunk withheld). The
    /// rebuild path uses it to resume with the NEXT chunk instead of
    /// re-speaking the finished one's tail.
    private var chunkFinished = false

    /// Per-word progress callbacks coalesced to ~3.3 Hz — each one publishes
    /// progress and invalidates observing views; word-rate emissions were
    /// measurable churn for long notes. Strictly-INCREASING counts only, so a
    /// re-queued chunk can never move the highlight backwards.
    private var lastSignalAt: Date = .distantPast
    private var lastEmittedChars = 0

    /// The effective multiplier the session started with — passed back into
    /// the re-queue on a rate change.
    private var lastEffectiveRate: Double = 1.0

    private var state: SpeechState = .idle {
        didSet {
            if state != oldValue {
                Log.shared.info("SystemEngine state: \(oldValue) → \(state)")
                onStateChanged?(state)
            }
        }
    }

    private var interruptionObserver: NSObjectProtocol?

    /// Session category + ACTIVATION are applied on first REAL speech, not at
    /// init — doing it pre-activate logged OSStatus -50 at every cold start.
    ///
    /// The activation half is not optional decoration. A configured-but-
    /// inactive session gets suspended by iOS seconds after the app
    /// backgrounds, which is the exact "plays two seconds then dies" the
    /// audiobook path never had (AVPlayer activates a session internally;
    /// AVSpeechSynthesizer does not). This single call is the fix.
    private func configureAudioSessionIfNeeded() {
        // Same shared setup as the ONNX engines — see AudioSessionSetup.
        AudioSessionSetup.configureAndActivate(source: .tts, prefix: "SystemEngine")
    }

    // MARK: - Batch A2 instrumentation

    /// Apple's chunk-boundary measurement, kept local on purpose.
    ///
    /// `PlaybackMetrics` is built around a producer loop this engine does
    /// not have (per-chunk generation stamps, a bank, a node), so borrowing
    /// it would mean pretending. This measures the one thing Apple's
    /// machine makes hard to see — the silence between `didFinish` on one
    /// utterance and the first audio of the next — and nothing else.
    ///
    /// Nothing here gates, reorders or delays playback. The stamps are
    /// ContinuousClock reads already paid for by the dispatch hop.
    private let metrics = SystemSpeechMetrics()

    /// Set on `didFinish`, consumed on the next `didStart`. Nil the rest of
    /// the time, so a rebuild, a stop or a pause simply records nothing.
    private var chunkFinishStamp: ContinuousClock.Instant?

    override init() {
        super.init()
        synthesizer.delegate = self
        // Phone calls must actually pause system-voice speech: without this
        // observer the session was interrupted, the utterance died, and the
        // UI stayed "speaking" with dead air and no resume (the ONNX engines
        // always handled this — parity here).
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if typeRaw == AVAudioSession.InterruptionType.began.rawValue {
                if self.state == .speaking { self.pause() }
            } else if typeRaw == AVAudioSession.InterruptionType.ended.rawValue,
                      optionsRaw & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 {
                // Two rules. (1) Only act when there is a paused session to
                // bring back — re-activating with nothing to resume grabs
                // the exclusive session and kills whatever the user played
                // during the call. (2) The session is DEACTIVATED here, and
                // resuming on the same synthesizer often works and often
                // does not: after a call the old instance can go
                // permanently silent with no error and no further delegate
                // callbacks. Recreating is cheap (a few ms) and is the
                // documented recovery.
                guard self.state == .paused else { return }
                self.rebuildSynthesizer()
            }
        }
        Log.shared.info("SystemEngine ready (chunked)")
    }

    /// Replace the synthesizer and re-drive the queue on it. Called only
    /// while paused (see the interruption handler), on the main thread.
    private func rebuildSynthesizer() {
        synthesizer.stopSpeaking(at: .immediate)
        let fresh = AVSpeechSynthesizer()
        fresh.delegate = self
        synthesizer = fresh
        // Configured sessions do not survive a rebuilt synthesizer on some
        // routes; re-applying is a no-op when the category already matches.
        AudioSessionSetup.configureAndActivate(source: .tts, prefix: "SystemEngine")
        pauseRequested = false
        // The rebuild is preceded by an interruption, not by a chunk
        // boundary: drop the stamp so the resume is not logged as a gap.
        chunkFinishStamp = nil
        // Resume with exactly the text that has not sounded yet:
        //  - pause mid-chunk (willSpeak advanced, didFinish not fired) →
        //    re-queue the unsound remainder;
        //  - pause before the first word (no willSpeak yet) → re-speak the
        //    whole chunk from its start (the critique's P2: this case
        //    silently dropped up to 320 chars);
        //  - pause at a chunk BOUNDARY (didFinish fired) → continue with
        //    the next chunk, not the finished one's tail.
        // All three collapse to: point nextIndex at the chunk that still
        // owes sound, then startNextChunk().
        if let chunk = current, !chunkFinished {
            let spoken = currentCharsDone
            if spoken > 0, spoken < chunk.text.utf16.count {
                let units = Array(chunk.text.utf16)
                let remainder = String(decoding: units[spoken...], as: UTF16.self)
                if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let index = max(0, nextIndex - 1)
                    queue[index] = Queued(offset: chunk.offset + spoken, text: remainder)
                    nextIndex = index
                }
            } else {
                // Nothing sounded yet (or the odd full-length report) — the
                // whole chunk is still owed.
                nextIndex = max(0, nextIndex - 1)
            }
            currentCharsDone = 0
        }
        // State flips to .speaking via the new instance's didStart.
        startNextChunk()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        configureAudioSessionIfNeeded()
        epoch += 1

        activeUtteranceText = clean
        totalChars = max(1, clean.utf16.count)
        lastRangeOffset = 0
        lastEmittedChars = 0
        pauseRequested = false
        lastEffectiveRate = speed == 1.0 ? rateMultiplier : Double(speed)

        // The chunker packs to `batchMaxChars` per chunk. Apple's synthesizer
        // handles a few hundred characters per utterance without a
        // perceptible gap; going much wider is what brings the stall back.
        let chunks = SentenceChunker.chunks(
            for: clean,
            firstMaxChars: 120,   // fast start: the first sentence sounds now
            batchMaxChars: 320
        )
        guard !chunks.isEmpty else { return }

        queue = Self.expanded(chunks)
        nextIndex = 0
        startedCount = 0
        current = nil
        currentCharsDone = 0
        // A new session invalidates the cached voice: the settings UI may
        // have written a different identifier between plays.
        cachedVoice = nil
        cachedVoiceIdentifier = nil
        // Batch A2: one line per session, same shape as the ONNX engines' so
        // a device log can be filtered on one string for every engine.
        metrics.beginSession(chunkCount: queue.count, rate: lastEffectiveRate)
        chunkFinishStamp = nil
        // Fills the lookahead before returning: `startNextChunk` is gated on
        // `nextIndex - startedCount < lookahead`, so this one call hands
        // Apple the first `lookahead` utterances and no more. Its queue is
        // primed while utterance 0 is still rendering.
        startNextChunk()
        // State flips to .speaking via the didStart delegate callback.
    }

    /// Chunks carry `text` plus a UTF-16 `offset` into the string they came
    /// from (see `Chunk`), so progress and the read-along can address the
    /// WHOLE text rather than the chunk. `Chunk.text` is already the literal
    /// slice, so it is used directly — no re-slicing, no drift.
    private static func expanded(_ chunks: [Chunk]) -> [Queued] {
        chunks
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { Queued(offset: $0.offset, text: $0.text) }
    }

    /// Starts the next queued chunk. Called on the main actor only (the
    /// delegate callbacks hop there, and speak()/pause() are main-actor).
    ///
    /// Batch F1: the one-in-flight rule this used to enforce is what caused
    /// the audible inter-sentence gap. Apple's own queue holds several
    /// utterances, and filling it is how the synthesizer is primed for the
    /// next chunk before the current one ends — the gap was this engine
    /// waiting for `didFinish` and only then handing Apple the next string.
    /// Now `startNextChunk` is called from BOTH the finish path and the
    /// utterance-start path, and it stops once the lookahead is full.
    private static let lookahead = 4

    private func startNextChunk() {
        guard !pauseRequested, nextIndex < queue.count else { return }
        // Already `lookahead` utterances deep in Apple's queue: it will call
        // back as each one finishes, and that is the trigger for the next.
        guard nextIndex - startedCount < Self.lookahead else { return }
        chunkFinished = false
        let item = queue[nextIndex]
        nextIndex += 1
        current = item
        currentCharsDone = 0

        let utterance = AVSpeechUtterance(string: item.text)
        utterance.rate = Float(utteranceRate())
        utterance.voice = resolvedVoice()
        synthesizer.speak(utterance)
        startedCount += 1
    }

    /// Our 0.5…2.0 multiplier mapped onto Apple's 0…1 utterance scale.
    /// 1.0 → `AVSpeechUtteranceDefaultSpeechRate` (0.5), 2.0 → Maximum.
    private func utteranceRate() -> Double {
        min(
            Double(AVSpeechUtteranceMaximumSpeechRate),
            max(Double(AVSpeechUtteranceMinimumSpeechRate),
                Double(AVSpeechUtteranceDefaultSpeechRate)
                    + (lastEffectiveRate - 1.0)
                    * (Double(AVSpeechUtteranceMaximumSpeechRate) - Double(AVSpeechUtteranceDefaultSpeechRate)))
        )
    }

    /// The `AVSpeechSynthesisVoice` for this session, built once and reused.
    ///
    /// It used to be constructed on every chunk, at two duplicated sites
    /// (`startNextChunk` and `speakQueued`), each paying the
    /// `AVSpeechSynthesisVoice(identifier:)` lookup per utterance. Cached
    /// per session keyed on `voiceIdentifier`: the settings UI writes a new
    /// identifier, which invalidates the cache on the next `speak()`.
    private var cachedVoice: AVSpeechSynthesisVoice?
    private var cachedVoiceIdentifier: String?

    private func resolvedVoice() -> AVSpeechSynthesisVoice {
        if let identifier = voiceIdentifier {
            if let cached = cachedVoice, cachedVoiceIdentifier == identifier {
                return cached
            }
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                cachedVoice = voice
                cachedVoiceIdentifier = identifier
                return voice
            }
        }
        cachedVoice = nil
        cachedVoiceIdentifier = nil
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    func pause() {
        guard synthesizer.isSpeaking || !queue.isEmpty else { return }
        pauseRequested = true
        synthesizer.pauseSpeaking(at: .word)
        // A pause is not a boundary: the boundary stamp is dropped so the
        // resume does not report the whole pause as inter-chunk silence.
        // The pause's own duration is not measured anywhere — it is user
        // intent, not a fault, and the session summary's wall clock says
        // everything about it.
        chunkFinishStamp = nil
        DispatchQueue.main.async { self.state = .paused }
    }

    func resume() {
        // A pause taken BETWEEN chunks (the utterance finished, the queue was
        // held) has nothing to continue — the next chunk is started instead.
        if synthesizer.isPaused {
            pauseRequested = false
            synthesizer.continueSpeaking()
        } else {
            pauseRequested = false
            chunkFinishStamp = nil
            startNextChunk()
        }
        DispatchQueue.main.async { self.state = .speaking }
    }

    func stop() {
        epoch += 1
        let epochAtStop = epoch
        synthesizer.stopSpeaking(at: .immediate)
        activeUtteranceText = nil
        queue = []
        nextIndex = 0
        startedCount = 0
        current = nil
        currentCharsDone = 0
        lastRangeOffset = 0
        pauseRequested = false
        chunkFinishStamp = nil
        metrics.endSession(reason: "stopped")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.epoch == epochAtStop else { return }
            self.state = .idle
        }
    }

    /// Re-queues the CURRENT chunk's unsounded remainder at the new rate.
    /// Only runs while a chunk is actually in flight; a pause/idle session
    /// picks the rate up on its next utterance, and the remaining queue is
    /// unaffected (each chunk is built when it starts).
    private func requeueCurrentChunkAtNewRate() {
        guard state == .speaking,
              let chunk = current,
              currentCharsDone > 0,
              currentCharsDone < chunk.text.utf16.count else { return }
        let units = Array(chunk.text.utf16)
        let remainder = String(decoding: units[currentCharsDone...], as: UTF16.self)
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Same text, new rate: replace the current chunk in place so the
        // chunk's base offset is unchanged and the read-along cursor cannot
        // rewind.
        let index = max(0, nextIndex - 1)
        queue[index] = Queued(offset: chunk.offset + currentCharsDone, text: remainder)
        current = queue[index]
        currentCharsDone = 0
        lastEffectiveRate = Double(speed)
        synthesizer.stopSpeaking(at: .immediate)
        speakQueued(index: index)
    }

    /// Re-speaks one queued chunk immediately (used by the rate re-queue).
    ///
    /// Batch F1: the cached voice replaces the fresh-per-utterance lookup
    /// that used to be duplicated verbatim in here and in
    /// `startNextChunk`, and the debounce means a slider drag — which emits
    /// at 0.05 steps — produces one re-queue instead of a dozen mid-word
    /// chops.
    private func speakQueued(index: Int) {
        let item = queue[index]
        current = item
        currentCharsDone = 0
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.rate = Float(utteranceRate())
        utterance.voice = resolvedVoice()
        synthesizer.speak(utterance)
        startedCount += 1
    }

    /// The word position inside the current chunk, for a re-queue.
    private var lastRangeOffset = 0

    /// AVSpeechSynthesizer's real liveness — see SpeechEngine.hasLiveSession.
    var hasLiveSession: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused || !queue.isEmpty
    }
}

extension SystemEngine: AVSpeechSynthesizerDelegate {
    /// Every callback carries a synthesizer-identity guard: `rebuildSynthesizer`
    /// stops the OLD instance, whose enqueued `didCancel`/`didFinish` can land
    /// AFTER the new one has started speaking — without the guard a stale
    /// cancel would drive the NEW instance's queue (skipping a chunk or
    /// double-starting one).
    private func isCurrentSynthesizer(_ synthesizer: AVSpeechSynthesizer) -> Bool {
        synthesizer === self.synthesizer
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentSynthesizer(synthesizer), self.epoch > 0 else { return }
            self.state = .speaking
            // Batch F1: fill the lookahead from the START path too, not only
            // the finish path. This is the actual gap fix — the utterance has
            // begun sounding and the queue is still a chunk short, so the
            // next one is handed to Apple now rather than seconds later.
            self.startNextChunk()
            // Batch A2: the missing half of the boundary pair. `didFinish`
            // above stamps the end of this boundary, so the two together give
            // the inter-chunk gap for the only engine with no instrumentation.
            if let started = self.chunkFinishStamp {
                self.metrics.recordBoundary(startedAt: started)
            }
            self.chunkFinishStamp = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentSynthesizer(synthesizer) else { return }
            self.chunkFinished = true
            // Batch A2: one stamp, one comparison. No scheduling changes here.
            self.chunkFinishStamp = ContinuousClock.now
            // Progress reaches exactly 1.0 on the last chunk before the
            // completion signal fires.
            if self.nextIndex >= self.queue.count {
                self.onProgress?(1.0)
                self.onPlayedChars?(self.totalChars)
            }
            if self.pauseRequested {
                // Held between chunks: publish the boundary, start nothing.
                return
            }
            if self.nextIndex < self.queue.count {
                self.startNextChunk()
            } else {
                self.onFinished?()
                self.state = .idle
                // Batch A2: the session's summary line. `didFinish` is Apple's
                // only natural-end signal, so this is where it belongs.
                self.metrics.endSession(reason: "finished")
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentSynthesizer(synthesizer) else { return }
            // A cancel from stop() is not a completion. A cancel with the queue
            // still holding work means an interruption killed the utterance —
            // run the rest rather than leaving the UI claiming speech.
            if !self.queue.isEmpty, self.nextIndex < self.queue.count, self.state != .idle {
                self.startNextChunk()
            } else {
                self.state = .idle
            }
        }
    }

    /// Fires before each spoken word-range; location+length ≈ chars spoken
    /// so far. Offset by the current chunk's base so the value addresses the
    /// WHOLE text (and so the bookmark / read-along / progress stay in one
    /// coordinate space across chunk boundaries).
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard let chunk = current, isCurrentSynthesizer(synthesizer) else { return }
        let total = (utterance.speechString as NSString).length
        guard total > 0, characterRange.location + characterRange.length > 0 else { return }
        currentCharsDone = characterRange.location
        lastRangeOffset = characterRange.location
        let charsDone = chunk.offset + characterRange.location + characterRange.length
        let now = Date()
        // Coalesced to ~3.3 Hz AND monotonic, so the cursor never rewinds and
        // the views are not invalidated at word rate.
        guard charsDone >= self.totalChars
            || (now.timeIntervalSince(lastSignalAt) >= 0.3 && charsDone > lastEmittedChars) else { return }
        lastSignalAt = now
        lastEmittedChars = charsDone
        let fraction = Double(charsDone) / Double(totalChars)
        DispatchQueue.main.async {
            self.onProgress?(min(1.0, fraction))
            self.onPlayedChars?(charsDone)
        }
    }
}
