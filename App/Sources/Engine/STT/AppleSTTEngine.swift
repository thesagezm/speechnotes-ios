import Foundation
import AVFoundation

/// Stub engine for Phase 0 — no-op implementation so the coordinator compiles
/// and the app builds. Replace with AppleSTTEngine (SpeechRecognizer /
/// SpeechAnalyzer) in Phase 1 and WhisperCppEngine in Phase 2.
final class AppleSTTEngine: STTEngine {
    let name: String = "Apple (built-in)"
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStateChanged: ((STTState) -> Void)?

    private var state: STTState = .idle { didSet { onStateChanged?(state) } }

    func start(language: String?, prompt: String?) {
        // Phase 0: no-op
        state = .idle
    }

    func stop() {
        state = .idle
    }

    func cancel() {
        state = .idle
    }
}
