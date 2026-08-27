import Foundation

enum STTState: Equatable {
    case idle
    case recording
    case transcribing
}

protocol STTEngine: AnyObject {
    var name: String { get }
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onStateChanged: ((STTState) -> Void)? { get set }
    /// User-facing failure (permissions denied, mic unavailable, model not
    /// loaded). State has already returned to .idle when this fires.
    var onError: ((String) -> Void)? { get set }

    /// Live capture loop.
    func start(language: String?, prompt: String?)
    func stop()
    func cancel()

    /// Transcribe a pre-decoded audio buffer (16 kHz mono Float32). Used by
    /// the audio-file import path; engines that don't support it should
    /// throw `TranscribeFileError.unsupported`. The optional `progress`
    /// closure receives 0…1 per processed chunk — long files drive the
    /// import progress bar from it.
    func transcribeFile(samples: [Float], language: String?, progress: (@Sendable (Double) -> Void)?) async throws -> String
}

enum TranscribeFileError: Error {
    case unsupported
}
