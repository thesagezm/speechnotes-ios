import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: STTState = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levelMeter: Float = 0

    enum EngineKind: String, CaseIterable, Identifiable {
        case apple
        case whisper

        var id: String { rawValue }
        var label: String {
            switch self {
            case .apple: return "Apple (built-in)"
            case .whisper: return "Whisper (offline)"
            }
        }
    }

    @AppStorage("sttEngineKind") var engineKind: EngineKind = .apple

    private var engine: STTEngine?
    private var timer: Timer?

    init() {
        rebuildEngine()
    }

    private func rebuildEngine() {
        switch engineKind {
        case .apple:
            engine = AppleSTTEngine()
        case .whisper:
            engine = WhisperCppEngine()
        }
        engine?.onPartial = { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        engine?.onFinal = { [weak self] text in
            Task { @MainActor in
                self?.partialText = ""
                self?.state = .idle
                self?.stopTimer()
            }
        }
        engine?.onStateChanged = { [weak self] s in
            Task { @MainActor in self?.state = s }
        }
    }

    /// Phase 0 no-op. Phase 1 starts AVAudioEngine + engine.start()
    func startRecording(language: String? = nil) {
        guard state == .idle else { return }
        state = .recording
        startTimer()
        engine?.start(language: language, prompt: nil)
    }

    func stopRecording() {
        engine?.stop()
        state = .idle
        partialText = ""
        stopTimer()
    }

    private func startTimer() {
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsed += 0.1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
    }
}
