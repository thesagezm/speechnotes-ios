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

    func start(language: String?, prompt: String?)
    func stop()
    func cancel()
}
