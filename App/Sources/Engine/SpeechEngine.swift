import Foundation

enum SpeechState: Equatable {
    case idle
    case generating
    case speaking
    case paused
}

/// Anything that can turn text into spoken audio.
/// Implementations: SystemEngine (Apple TTS) and OnnxKokoroEngine (Kokoro on CPU).
protocol SpeechEngine: AnyObject {
    var name: String { get }
    var onStateChanged: ((SpeechState) -> Void)? { get set }
    /// Progress through the spoken text, 0…1 (chunk-granular). Engines that
    /// can't measure progress simply never call it.
    var onProgress: ((Double) -> Void)? { get set }
    /// The UTF-16 range (offset, length) of the source text currently being
    /// spoken — drives read-along highlighting. Engines that can't map audio
    /// back to text simply never call it.
    var onSpokenRange: ((Int, Int) -> Void)? { get set }

    func speak(_ text: String, rateMultiplier: Double)
    func pause()
    func resume()
    func stop()
}
