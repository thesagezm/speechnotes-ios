import AVFoundation

/// Apple's built-in text-to-speech. Placeholder engine until Kokoro arrives in
/// Phase 2 — and after that, a useful "fallback when no Kokoro model is present".
final class SystemEngine: NSObject, SpeechEngine {
    let name = "Apple (system)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?
    /// Play-time signal — willSpeakRangeOfSpeechString fires per word as the
    /// audio sounds, so this is exact (see SpeechEngine.onPlayedChars).
    var onPlayedChars: ((Int) -> Void)?
    /// Natural completion (AVSpeechSynthesizerDelegate.didFinish) — exact,
    /// unlike the ONNX engines' buffer-completion signal.
    var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    /// Identifier of the `AVSpeechSynthesisVoice` to use (Settings → System
    /// voice). Falls back to the default en-US voice when nil, or when the
    /// identifier no longer resolves (voice deleted from the device).
    var voiceIdentifier: String?

    /// Mid-utterance rate changes: AVSpeechSynthesizer cannot vary the rate
    /// of an utterance that is already running, so a slider move would
    /// otherwise wait for the note to end. Instead it re-pitches the
    /// CURRENT position at the new rate — the user hears the rest of the
    /// sentence change speed, not the whole note restart.
    var speed: Float = 1.0 {
        didSet {
            guard speed != oldValue else { return }
            restartAtCurrentPosition()
        }
    }

    /// Every async state jump carries the utterance epoch it belongs to —
    /// a `speak`/`stop` interleave used to let a stale queued `idle`/`speaking`
    /// clobber the newer state (M15). Bumped on each speak() and stop().
    private var epoch = 0

    /// The text currently being spoken (the LAST speak()'s string). Kept
    /// only so a rate change mid-playback can re-speak from the current
    /// character offset.
    private var activeUtteranceText: String?

    /// UTF-16 offset where the CURRENT utterance begins inside the whole
    /// spoken string (0 for a fresh speak; the pitch boundary after a
    /// mid-playback rate change). onPlayedChars adds it so the bookmark and
    /// the read-along keep addressing the note's own char space — without
    /// it a re-pitched remainder would restart the highlight and the resume
    /// position from char 0.
    private var spokenOffsetInActiveText: Int = 0
    private var lastRangeOffset: Int = 0

    private var state: SpeechState = .idle {
        didSet {
            if state != oldValue {
                Log.shared.info("SystemEngine state: \(oldValue) → \(state)")
                onStateChanged?(state)
            }
        }
    }

    /// Per-word progress callbacks coalesced to ~3.3 Hz — each one
    /// publishes progress and invalidates observing views; word-rate
    /// emissions were measurable churn for long notes. The FINAL range is
    /// always emitted so completion progress reaches 1.0, and only
    /// STRICTLY-INCREASING counts pass the throttle so a mid-playback rate
    /// change (which re-speaks a remainder with a fresh range counter) can
    /// never move the read-along highlight backwards.
    private var lastSignalAt: Date = .distantPast
    private var lastEmittedChars: Int = 0

    private var interruptionObserver: NSObjectProtocol?

    /// Session category is applied on first REAL speech, not at init —
    /// doing it pre-activate logged OSStatus -50 at every cold start.
    private func configureAudioSessionIfNeeded() {
        // Same shared setup as the ONNX engines — see AudioSessionSetup.
        AudioSessionSetup.configureIfNeeded(prefix: "SystemEngine")
    }

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
                if self.state == .paused { self.resume() }
            }
        }
        Log.shared.info("SystemEngine ready")
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        configureAudioSessionIfNeeded()
        epoch += 1
        let epochAtSpeak = epoch

        let utterance = AVSpeechUtterance(string: clean)
        activeUtteranceText = clean
        // The position accounting carries over ONLY for a re-pitch remainder:
        // restartAtCurrentPosition sets `spokenOffsetInActiveText = pitch
        // boundary` immediately before calling speak(remainder) — WITHOUT
        // bumping the epoch. A fresh note speak() always bumps the epoch
        // first, so it is the only caller that must zero the accumulator.
        // Distinguishing on the epoch keeps the remainder's char math
        // continuous instead of restarting the highlight and the resume
        // position from char 0.
        if epoch == epochAtSpeak {
            spokenOffsetInActiveText = 0
        }
        lastRangeOffset = 0
        // Live speed wins over the call-site multiplier once set.
        let effectiveRate = speed == 1.0 ? rateMultiplier : Double(speed)
        lastEffectiveRate = effectiveRate
        // AVSpeechUtterance.rate: 0.0...1.0, default 0.5 — map our
        // multiplier onto it. The old mapping was `0.5 * multiplier`, so the
        // DEFAULT (1.0) spoke at 0.5 — half the system voice's normal pace —
        // and a 2× request only ever reached 1.0 (normal). Apple's scale is
        // 0.5 = the "average human" rate at which a voice is designed to be
        // intelligible; anything below it begins halving and the user's
        // "slower than Supertonic" report follows directly. Map so 1.0 →
        // AVSpeechUtteranceDefaultSpeechRate (0.5) and 2.0 → 1.0.
        let mapped = AVSpeechUtteranceDefaultSpeechRate
            + (effectiveRate - 1.0) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceDefaultSpeechRate)
        utterance.rate = Float(min(AVSpeechUtteranceMaximumSpeechRate, max(0.0, mapped)))
        if let identifier = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        synthesizer.speak(utterance)
        // State flips to .speaking via the didStart delegate callback.
    }

    func pause() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .word)
        DispatchQueue.main.async { self.state = .paused }
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
        DispatchQueue.main.async { self.state = .speaking }
    }

    func stop() {
        epoch += 1
        let epochAtStop = epoch
        synthesizer.stopSpeaking(at: .immediate)
        activeUtteranceText = nil
        lastRangeOffset = 0
        DispatchQueue.main.async { [weak self] in
            guard let self, self.epoch == epochAtStop else { return }
            self.state = .idle
        }
    }

    /// Re-speaks from the current character offset at the new rate. Only
    /// runs while actually speaking; a pause/idle session picks the rate up
    /// on its next utterance.
    private func restartAtCurrentPosition() {
        guard synthesizer.isSpeaking, let full = activeUtteranceText else { return }
        let units = Array(full.utf16)
        guard lastRangeOffset > 0, lastRangeOffset < units.count else { return }
        let remainder = String(decoding: units[lastRangeOffset...], as: UTF16.self)
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Do NOT bump the epoch: this is the same utterance continuing, and
        // the state callbacks must keep firing for it. Set the accumulator
        // BEFORE the recursive speak(): speak() zeroes it for a fresh call,
        // so ordering matters — credit first, then hand over the remainder.
        spokenOffsetInActiveText = lastRangeOffset
        lastRangeOffset = 0
        synthesizer.stopSpeaking(at: .immediate)
        speak(remainder, rateMultiplier: lastEffectiveRate)
    }

    /// The effective multiplier the utterance was started with — passed back
    /// into speak() on a mid-playback rate change so the remainder keeps
    /// whatever the LIVE speed says (speed != 1.0 wins) or the original
    /// call-site value (speed == 1.0).
    private var lastEffectiveRate: Double = 1.0

    /// AVSpeechSynthesizer's real liveness — see SpeechEngine.hasLiveSession.
    /// Our own `state` is an approximation (it flips on delegate callbacks);
    /// the synthesizer's flags are ground truth for the player's self-heal.
    var hasLiveSession: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused
    }
}

extension SystemEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.epoch > 0 else { return }
            self.state = .speaking
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onFinished?()
            self.state = .idle
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = .idle
        }
    }

    /// Fires before each spoken word-range; location+length ≈ chars spoken
    /// so far — feeds SpeechPlayer's resume bookmark. `lastRangeOffset` is
    /// stamped here too: it is the re-pitch start point for a mid-utterance
    /// rate change.
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let total = (utterance.speechString as NSString).length
        guard total > 0, characterRange.location + characterRange.length > 0 else { return }
        let charsDone = characterRange.location + characterRange.length
        lastRangeOffset = characterRange.location
        let now = Date()
        // Coalesced to ~3.3 Hz AND monotonic: a re-pitched remainder starts
        // its own range counter at 0, which would otherwise momentarily move
        // the highlight/percentage BACKWARDS until the next word fires.
        // The only emissions that beat the throttle are strictly-increasing
        // ones, so the cursor never rewinds on screen.
        guard charsDone >= total || (now.timeIntervalSince(lastSignalAt) >= 0.3 && charsDone > lastEmittedChars) else { return }
        lastSignalAt = now
        lastEmittedChars = charsDone
        let fraction = Double(charsDone) / Double(total)
        DispatchQueue.main.async {
            self.onProgress?(min(1.0, fraction))
            // Add the remainder's base so a re-pitched tail reports its
            // position inside the WHOLE note, not inside its own substring.
            self.onPlayedChars?(self.spokenOffsetInActiveText + charsDone)
        }
    }
}
