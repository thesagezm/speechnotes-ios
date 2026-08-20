import Foundation

enum STTState: Equatable {
    case idle
    case recording
    case transcribing
    case paused
}

protocol STTEngine: AnyObject {
    var name: String { get }
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onStateChanged: ((STTState) -> Void)? { get set }

    /// Live capture loop.
    func start(language: String?, prompt: String?)
    func stop()
    func cancel()

    /// Transcribe a pre-decoded audio buffer (16 kHz mono Float32). Used by
    /// the audio-file import path; engines that don't support it should
    /// throw `TranscribeFileError.unsupported`.
    func transcribeFile(samples: [Float], language: String?) async throws -> String
}

enum TranscribeFileError: Error {
    case unsupported
}
