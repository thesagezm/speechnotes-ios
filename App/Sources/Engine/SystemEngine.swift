import AVFoundation

/// Apple's built-in text-to-speech. Placeholder engine until Kokoro arrives in
/// Phase 2 — and after that, a useful "fallback when no Kokoro model is present".
final class SystemEngine: NSObject, SpeechEngine {
    let name = "Apple (system)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    /// Identifier of the `AVSpeechSynthesisVoice` to use (Settings → System
    /// voice). Falls back to the default en-US voice when nil, or when the
    /// identifier no longer resolves (voice deleted from the device).
    var voiceIdentifier: String?

    private var state: SpeechState = .idle {
        didSet {
            if state != oldValue {
                Log.shared.info("SystemEngine state: \(oldValue) → \(state)")
                onStateChanged?(state)
            }
        }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        do {
            // `.playback` + allowBluetooth* keeps the session valid for the
            // configured `audio` UIBackgroundMode — playback continues when
            // the user leaves the app; lock-screen controls come from the
            // NowPlayingCenter feeding below.
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            Log.shared.error("Audio session setup failed: \(error)")
        }
        Log.shared.info("SystemEngine ready")
    }

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: clean)
        // AVSpeechUtterance.rate: 0.0...1.0, default 0.5 — map our multiplier onto it.
        utterance.rate = Float(min(1.0, max(0.1, 0.5 * rateMultiplier)))
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
        synthesizer.stopSpeaking(at: .immediate)
        DispatchQueue.main.async { self.state = .idle }
    }
}

extension SystemEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.state = .speaking }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.state = .idle }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.state = .idle }
    }

    /// Fires before each spoken word-range; location+length ≈ chars spoken
    /// so far — feeds SpeechPlayer's resume bookmark.
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let total = (utterance.speechString as NSString).length
        guard total > 0, characterRange.location + characterRange.length > 0 else { return }
        let fraction = Double(characterRange.location + characterRange.length) / Double(total)
        DispatchQueue.main.async { self.onProgress?(min(1.0, fraction)) }
    }
}
