import Foundation

enum SpeechState: Equatable {
    case idle
    case generating
    case speaking
    case paused
}

/// Anything that can turn text into spoken audio.
/// Implementations: SystemEngine (Apple TTS, Phase 1) → KokoroEngine (Phase 2+).
protocol SpeechEngine: AnyObject {
    var name: String { get }
    var onStateChanged: ((SpeechState) -> Void)? { get set }

    func speak(_ text: String, rateMultiplier: Double)
    func pause()
    func resume()
    func stop()
}
