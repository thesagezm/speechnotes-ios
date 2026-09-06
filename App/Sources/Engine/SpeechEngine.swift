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
    /// Play-time signal: UTF-16 character count of the spoken string whose
    /// audio is ACTUALLY sounding or has finished — never schedule-ahead
    /// (the v0.5 read-along failed by highlighting at schedule time, up to
    /// 3 chunks ahead of the audio). Optional: engines without play-time
    /// tracking keep the default no-op.
    var onPlayedChars: ((Int) -> Void)? { get set }

    func speak(_ text: String, rateMultiplier: Double)
    func pause()
    func resume()
    func stop()
}

extension SpeechEngine {
    var onPlayedChars: ((Int) -> Void)? {
        get { nil }
        set {}
    }
}
