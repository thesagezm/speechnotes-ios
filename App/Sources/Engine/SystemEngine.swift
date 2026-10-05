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
            // The tick belongs to the session that is live NOW. A speak()
            // (or stop()) within the debounce window supersedes it: the hop
            // must not fire into the new session and stomp the rate speak()
            // chose (round-4 critique, P3).
            let epochAtChange = epoch
            debouncedRateRequeue = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                // The re-queue mutates main-only state (the tag map, the
                // queue, the sounding slot) and calls into the synthesizer —
                // an unstructured Task on a nonisolated class inherits NO
                // actor and would run all of it on the global executor,
                // racing the delegate callbacks. Round-3 critique, P1.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.epoch == epochAtChange else { return }
                    self.requeueCurrentChunkAtNewRate()
                }
            }
        }
    }

    /// Batch F1: the coalescing task for a rate change. nil in the steady
    /// state, so a non-playing or paused session pays nothing.
    private var debouncedRateRequeue: Task<Void, Never>?

    /// Every async state jump carries the utterance epoch it belongs to — a
    /// `speak`/`stop` interleave used to let a stale queued `idle`/`speaking`
    /// clobber the newer state (M15). Bumped on each speak() and stop().
    ///
    /// Batch F1: the epoch is now compared, not just carried. Every
    /// utterance is tagged with the epoch it was built under, and every
    /// delegate callback checks the tag — so a `didCancel` from a
    /// superseded session cannot drive the current queue, whichever
    /// synthesizer instance delivers it. `AVSpeechUtterance` has no payload
    /// slot of its own and Apple's callbacks deliver the utterance, so the
    /// object identity is the only key that survives BOTH a session
    /// supersede and a synthesizer rebuild.
    private var epoch = 0

    /// Where each live utterance sits in `queue`, and the epoch it was
    /// built under, keyed on the utterance object. Main-thread only, like
    /// every other state in this class; entries are removed by the
    /// `didFinish`/`didCancel` that retire the utterance, so the table
    /// holds at most the lookahead.
    private struct UtteranceTag {
        let epoch: Int
        let slot: Int
    }

    private var tagByUtterance: [ObjectIdentifier: UtteranceTag] = [:]

    // MARK: - The chunk queue

    /// UTF-16 base offset and text of each queued chunk.
    private struct Queued {
        let offset: Int
        let text: String
    }

    private var queue: [Queued] = []
    private var nextIndex = 0
    /// Utterances Apple is currently holding — handed to
    /// `synthesizer.speak(_:)` but not yet finished OR cancelled. This IS
    /// the queue depth, and the lookahead gate is `startedCount < lookahead`.
    ///
    /// It advances in `startNextChunk`/`speakQueued` (a chunk was handed
    /// over) and decrements in `didFinish` and `didCancel` (the utterance
    /// left Apple's queue either way — a cancel that never decremented
    /// would close the gate permanently and strand the session in
    /// mid-chapter silence). Advancing on hand-over rather than on
    /// `didStart` matters: the gate has to hold even before Apple
    /// acknowledges the utterance, or a burst of `didStart` callbacks could
    /// refill the queue.
    private var startedCount = 0
    /// The chunk currently SOUNDING, and how many characters of it have
    /// sounded. Set from `didStart`/`willSpeakRangeOfSpeechString` via the
    /// utterance's slot tag — NOT at hand-over: with the lookahead filled,
    /// several handed chunks sit in Apple's queue ahead of the sounding
    /// one, and progress/re-queue that keyed on the last-handed chunk would
    /// pair the sounding utterance's word range with the wrong text.
    private var current: Queued?
    private var currentSlot: Int?
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
    /// The slot of the last chunk that reported `didFinish` (utterances
    /// finish in order). With `chunkFinished` it is the rebuild path's
    /// resume point: every slot after it was handed ahead but never sounded,
    /// and the rebuild's `stopSpeaking` destroyed those copies.
    private var lastFinishedSlot: Int?

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
        // Resume with exactly the text that has not sounded yet. The
        // `stopSpeaking(.immediate)` above emptied Apple's queue — the
        // sounding utterance AND every handed-but-not-started one died with
        // it — so the depth restarts from zero and the rewind must re-owe
        // everything from the sounding chunk onward, not just rewind one
        // slot:
        //  - pause mid-chunk (willSpeak advanced, didFinish not fired) →
        //    replace the sounding chunk with its unsound remainder, re-owe
        //    from its slot;
        //  - pause before the first word of a chunk (no willSpeak yet) →
        //    re-speak that chunk whole (the critique's P2: this case used
        //    to silently drop up to 320 chars);
        //  - pause at a chunk BOUNDARY (didFinish fired, next chunk held) →
        //    continue at the slot after the finished one.
        startedCount = 0
        tagByUtterance.removeAll()
        if chunkFinished, let finishedSlot = lastFinishedSlot {
            nextIndex = finishedSlot + 1
        } else if let slot = currentSlot, queue.indices.contains(slot) {
            let chunk = queue[slot]
            let spoken = currentCharsDone
            var rewindTo = slot
            if spoken > 0, spoken < chunk.text.utf16.count {
                let units = Array(chunk.text.utf16)
                let remainder = String(decoding: units[spoken...], as: UTF16.self)
                if remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // The unsound tail is nothing: the chunk is done.
                    rewindTo = slot + 1
                } else {
                    queue[slot] = Queued(offset: chunk.offset + spoken, text: remainder)
                }
            }
            // Whole chunk (nothing sounded), its remainder, or the slot
            // after a chunk whose tail was whitespace only.
            nextIndex = rewindTo
        }
        // Nothing ever sounded (paused between hand-over and the first
        // didStart): nextIndex is untouched — every handed utterance is
        // still owed and still sits in `queue`.
        currentSlot = nil
        currentCharsDone = 0
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
        // The bump above orphans every entry in `tagByUtterance` — which
        // is the point. A stale `didFinish`/`didCancel` for an utterance
        // from before this speak() now finds a mismatched tag and is
        // dropped, so a superseded session cannot drive this queue's
        // `nextIndex`.
        tagByUtterance.removeAll()

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
        currentSlot = nil
        currentCharsDone = 0
        chunkFinished = false
        lastFinishedSlot = nil
        // A new session invalidates the cached voice: the settings UI may
        // have written a different identifier between plays.
        cachedVoice = nil
        cachedVoiceIdentifier = nil
        // Batch A2: one line per session, same shape as the ONNX engines' so
        // a device log can be filtered on one string for every engine.
        metrics.beginSession(chunkCount: queue.count, rate: lastEffectiveRate)
        chunkFinishStamp = nil
        // Hands the first utterance; each `didStart` hands one more until
        // the gate holds, so Apple's queue is primed to the lookahead while
        // utterance 0 is still rendering.
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
    ///
    /// The lookahead depth. `startedCount` — handed to Apple, not yet
    /// finished or cancelled — IS Apple's queue depth from this side, and
    /// the gate holds once it reaches this. The depth is what primed
    /// queues do for the gap: `startNextChunk` is called from BOTH the
    /// finish path and the utterance-start path, and it stops once the
    /// lookahead is full.
    ///
    /// (The first F1 draft gated on `nextIndex - startedCount`, but
    /// hand-over advances BOTH counters, so that difference only grew in
    /// `didFinish` — it counted finished utterances, and the gate closed
    /// permanently a few chunks into every chapter. Round-2 critique, P1.)
    private static let lookahead = 4

    private func startNextChunk() {
        guard !pauseRequested, nextIndex < queue.count else { return }
        // Already `lookahead` utterances deep in Apple's queue: it will call
        // back as each one finishes, and that is the trigger for the next.
        guard startedCount < Self.lookahead else { return }
        let item = queue[nextIndex]
        let slot = nextIndex
        nextIndex += 1
        startedCount += 1
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.rate = Float(utteranceRate())
        utterance.voice = resolvedVoice()
        tagByUtterance[ObjectIdentifier(utterance)] = UtteranceTag(epoch: epoch, slot: slot)
        synthesizer.speak(utterance)
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
        // `AVSpeechSynthesisVoice(language:)` returns an optional — the
        // library can decline a language it has no data for. The en-US
        // default is always present on iOS, so the `?? AVSpeechSynthesisVoice()`
        // is a nil check rather than a crash: an empty initialiser is an
        // object the synthesizer will reject loudly, which is better than a
        // force-unwrap. (This cost two CI rounds: the first patch's
        // `setResourceValues`-style mistake, then this line itself.)
        return AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice()
    }

    func pause() {
        // An idle session has nothing to pause — and the queue array is NOT
        // cleared by a natural finish, so the emptiness check alone would
        // let a pause tap racing the final didFinish flip a FINISHED session
        // to .paused (and a later resume to .speaking over dead air).
        guard state != .idle, synthesizer.isSpeaking || !queue.isEmpty else { return }
        let epochAtPause = epoch
        pauseRequested = true
        synthesizer.pauseSpeaking(at: .word)
        // A pause is not a boundary: the boundary stamp is dropped so the
        // resume does not report the whole pause as inter-chunk silence.
        // The pause's own duration is not measured anywhere — it is user
        // intent, not a fault, and the session summary's wall clock says
        // everything about it.
        chunkFinishStamp = nil
        DispatchQueue.main.async { [weak self] in
            // A stop() that ran between here and the hop supersedes this
            // pause — the surface must not claim .paused over a dead session.
            guard let self, self.epoch == epochAtPause else { return }
            self.state = .paused
        }
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
        tagByUtterance.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        activeUtteranceText = nil
        queue = []
        nextIndex = 0
        startedCount = 0
        current = nil
        currentSlot = nil
        currentCharsDone = 0
        lastRangeOffset = 0
        chunkFinished = false
        lastFinishedSlot = nil
        pauseRequested = false
        chunkFinishStamp = nil
        metrics.endSession(reason: "stopped")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.epoch == epochAtStop else { return }
            self.state = .idle
        }
    }

    /// Re-queues the SOUNDING chunk's unsound remainder at the new rate.
    ///
    /// The rate itself applies FIRST, unconditionally: a change taken while
    /// paused, in a between-chunks gap, or against a chunk with nothing left
    /// to re-queue used to be silently dropped for the REST of the session —
    /// every later utterance is built from `lastEffectiveRate`, so the
    /// resumed playback continued at the old rate (round-4 critique, P2).
    /// Only the remainder re-queue is conditional on something sounding.
    private func requeueCurrentChunkAtNewRate() {
        lastEffectiveRate = Double(speed)
        guard state == .speaking,
              let slot = currentSlot,
              queue.indices.contains(slot),
              currentCharsDone > 0,
              currentCharsDone < queue[slot].text.utf16.count else { return }
        let chunk = queue[slot]
        let units = Array(chunk.text.utf16)
        let remainder = String(decoding: units[currentCharsDone...], as: UTF16.self)
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Same text, new rate: replace the sounding chunk in place so the
        // chunk's base offset is unchanged and the read-along cursor cannot
        // rewind.
        queue[slot] = Queued(offset: chunk.offset + currentCharsDone, text: remainder)
        // `stopSpeaking(at: .immediate)` below empties Apple's queue — the
        // sounding utterance AND every handed-but-not-started one die with
        // it — so everything from the sounding slot onward is re-owed, and
        // the depth restarts from zero. The tag map goes with it: the
        // cancelled utterances must not drive the refill (their slots are
        // re-handed from the rewound `nextIndex`), and the remainder's own
        // `didStart` fills the lookahead back up. `nextIndex` points PAST
        // the remainder — `speakQueued` hands it directly and does no
        // hand-over bookkeeping, so leaving `nextIndex` at the slot would
        // make the didStart cascade hand the SAME remainder again
        // (round-3 critique's double-speak).
        nextIndex = slot + 1
        startedCount = 0
        tagByUtterance.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        speakQueued(index: slot)
    }

    /// Re-speaks one queued chunk immediately (used by the rate re-queue).
    ///
    /// Batch F1: the cached voice replaces the fresh-per-utterance lookup
    /// that used to be duplicated verbatim in here and in
    /// `startNextChunk`, and the debounce means a slider drag — which emits
    /// at 0.05 steps — produces one re-queue instead of a dozen mid-word
    /// chops.
    ///
    /// This is NOT a hand-over: `nextIndex` is untouched and the CALLER has
    /// already accounted for the slot it points at (the re-queue sets it
    /// past the re-spoken slot). Only the depth counter advances here,
    /// because the utterance does go into Apple's queue.
    private func speakQueued(index: Int) {
        let item = queue[index]
        current = item
        currentSlot = index
        currentCharsDone = 0
        startedCount += 1
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.rate = Float(utteranceRate())
        utterance.voice = resolvedVoice()
        tagByUtterance[ObjectIdentifier(utterance)] = UtteranceTag(epoch: epoch, slot: index)
        synthesizer.speak(utterance)
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

    /// Fires when the utterance was cancelled. Batch F1: the epoch guard.
    ///
    /// `startNextChunk` increments `nextIndex`, and a stale cancel —
    /// `stopSpeaking(at:)` in `speak()` enqueues one, and the identity guard
    /// below only rejects cancels from an instance this engine no longer
    /// owns — can drive the NEW queue, skipping or double-starting a chunk
    /// and skewing progress for the rest of the chapter.
    ///
    /// All three callbacks check `utterance.epoch == self.epoch`, so a
    /// callback from before the current `speak()` is dropped regardless of
    /// which synthesizer instance delivered it. `didStart` used to check
    /// `epoch > 0`, which cannot reject a stale epoch — only a
    /// pre-first-speak callback.

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isCurrentSynthesizer(synthesizer),
                  let tag = self.tagByUtterance[ObjectIdentifier(utterance)],
                  tag.epoch == self.epoch else { return }
            self.state = .speaking
            // This utterance is the one sounding now — not the last-handed
            // one: with the lookahead filled, several chunks sit ahead of
            // it in Apple's queue.
            self.chunkFinished = false
            if self.queue.indices.contains(tag.slot) {
                self.current = self.queue[tag.slot]
                self.currentSlot = tag.slot
                self.currentCharsDone = 0
            }
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
            guard let self,
                  self.isCurrentSynthesizer(synthesizer),
                  let tag = self.tagByUtterance[ObjectIdentifier(utterance)],
                  tag.epoch == self.epoch else { return }
            self.tagByUtterance.removeValue(forKey: ObjectIdentifier(utterance))
            self.chunkFinished = true
            self.lastFinishedSlot = tag.slot
            // Batch F1: one fewer utterance sitting in Apple's queue — the
            // other half of the depth accounting the gate paces on.
            self.startedCount = max(0, self.startedCount - 1)
            // Nothing is sounding in the gap between this callback and the
            // next chunk's `didStart` (which fills current again). Clearing
            // it here keeps a mid-gap rate re-queue a no-op instead of
            // re-speaking this chunk's tail.
            self.current = nil
            self.currentSlot = nil
            self.currentCharsDone = 0
            // Batch A2: one stamp, one comparison. No scheduling changes here.
            self.chunkFinishStamp = ContinuousClock.now
            // Progress reaches exactly 1.0 when the LAST chunk finishes —
            // keyed on the finishing slot, not on `nextIndex >= count`,
            // which the lookahead satisfies four chunks early.
            if tag.slot == self.queue.count - 1 {
                self.onProgress?(1.0)
                self.onPlayedChars?(self.totalChars)
            }
            if self.pauseRequested {
                // Held between chunks: publish the boundary, start nothing.
                // UNLESS the queue is drained — a pause that lands after the
                // final chunk's finish is a session end, not a held boundary.
                // Without this, onFinished never fires (the finish branch is
                // below) and resume() would claim .speaking over dead air.
                if self.nextIndex >= self.queue.count {
                    self.onFinished?()
                    self.state = .idle
                    self.metrics.endSession(reason: "finished")
                }
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
            guard let self,
                  self.isCurrentSynthesizer(synthesizer),
                  let tag = self.tagByUtterance[ObjectIdentifier(utterance)],
                  tag.epoch == self.epoch else { return }
            self.tagByUtterance.removeValue(forKey: ObjectIdentifier(utterance))
            // A cancelled utterance left Apple's queue without finishing —
            // it must release its depth slot all the same, or the gate
            // ratchets shut one notch per cancel and strands the session.
            self.startedCount = max(0, self.startedCount - 1)
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
    /// so far. Offset by the SOUNDING chunk's base so the value addresses
    /// the WHOLE text (and so the bookmark / read-along / progress stay in
    /// one coordinate space across chunk boundaries).
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // Same main hop as the other three callbacks: the state this mutates
        // (currentSlot, currentCharsDone) is read on the main thread by the
        // rate re-queue and the rebuild path.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isCurrentSynthesizer(synthesizer),
                  let tag = self.tagByUtterance[ObjectIdentifier(utterance)],
                  tag.epoch == self.epoch,
                  self.queue.indices.contains(tag.slot) else { return }
            let chunk = self.queue[tag.slot]
            let total = (utterance.speechString as NSString).length
            guard total > 0, characterRange.location + characterRange.length > 0 else { return }
            self.current = chunk
            self.currentSlot = tag.slot
            self.currentCharsDone = characterRange.location
            self.lastRangeOffset = characterRange.location
            let charsDone = chunk.offset + characterRange.location + characterRange.length
            let now = Date()
            // Coalesced to ~3.3 Hz AND monotonic, so the cursor never rewinds and
            // the views are not invalidated at word rate.
            guard charsDone >= self.totalChars
                || (now.timeIntervalSince(self.lastSignalAt) >= 0.3 && charsDone > self.lastEmittedChars) else { return }
            self.lastSignalAt = now
            self.lastEmittedChars = charsDone
            let fraction = Double(charsDone) / Double(self.totalChars)
            self.onProgress?(min(1.0, fraction))
            self.onPlayedChars?(charsDone)
        }
    }
}
