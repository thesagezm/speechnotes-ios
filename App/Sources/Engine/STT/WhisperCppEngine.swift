import Foundation

/// Placeholder for Whisper.cpp bridge. Phase 0 builds the protocol and UI
/// scaffolding without linking native code. Phase 2 will vend in:
/// - whisper.h + whisper.cpp single file
/// - WhisperBridge.m (Objective-C++ glue)
/// - WhisperCppEngine actor wrapping the C context
final class WhisperCppEngine: STTEngine {
    let name: String = "Whisper (offline)"
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStateChanged: ((STTState) -> Void)?

    private var state: STTState = .idle { didSet { onStateChanged?(state) } }

    func start(language: String?, prompt: String?) {
        // Phase 0: no-op
        state = .idle
    }

    func stop() { state = .idle }
    func cancel() { state = .idle }
}
