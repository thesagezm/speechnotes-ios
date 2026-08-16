import AVFoundation

/// Apple's built-in text-to-speech. Placeholder engine until Kokoro arrives in
/// Phase 2 — and after that, a useful "fallback when no Kokoro model is present".
final class SystemEngine: NSObject, SpeechEngine {
    let name = "Apple (system)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
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
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
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
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
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
}
