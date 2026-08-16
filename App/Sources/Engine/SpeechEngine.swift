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
    /// Progress through the spoken text, 0…1 (chunk-granular). Engines that
    /// can't measure progress simply never call it.
    var onProgress: ((Double) -> Void)? { get set }

    func speak(_ text: String, rateMultiplier: Double)
    func pause()
    func resume()
    func stop()
}
