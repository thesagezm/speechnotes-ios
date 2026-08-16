import Foundation

/// UI-facing wrapper around the active speech engine. The engine is swappable:
/// Phase 1 uses SystemEngine; Phase 2 swaps in KokoroEngine behind this same API.
@MainActor
final class SpeechPlayer: ObservableObject {
    @Published private(set) var state: SpeechState = .idle
    @Published var rateMultiplier: Double = 1.0

    let engine: any SpeechEngine

    init(engine: (any SpeechEngine)? = nil) {
        let resolved = engine ?? SystemEngine()
        self.engine = resolved
        resolved.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
            }
        }
        Log.shared.info("SpeechPlayer initialised with engine: \(resolved.name)")
    }

    func togglePlay(_ text: String) {
        switch state {
        case .speaking:
            engine.pause()
        case .paused:
            engine.resume()
        case .idle:
            engine.speak(text, rateMultiplier: rateMultiplier)
        }
    }

    func stop() {
        engine.stop()
    }
}
