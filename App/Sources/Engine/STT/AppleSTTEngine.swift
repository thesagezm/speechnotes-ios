import Foundation
import Speech
import AVFoundation
import OSLog

/// Phase-1 Apple STT (Speech framework).
///
/// Strategy (per PLAN-V2.0-STT.md):
/// - iOS 26+: prefer `SpeechAnalyzer` + `SpeechTranscriber` (on-device, live partials).
/// - Fallback: `SFSpeechRecognizer` (on-device when available, cloud otherwise).
///
/// The engine captures audio via `AVAudioEngine`, feeds PCM-16 at 16 kHz,
/// and forwards transcripts via `onPartial`/`onFinal`. State changes bubble up
/// through `onStateChanged`.
final class AppleSTTEngine: STTEngine {
    let name: String = "Apple (built-in)"
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStateChanged: ((STTState) -> Void)?

    private let logger = Logger(subsystem: "com.speechnotes.ios", category: "AppleSTT")
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var currentState: STTState = .idle {
        didSet { onStateChanged?(currentState) }
    }

    // MARK: - Public API
    func start(language: String?, prompt: String?) {
        guard currentState == .idle else {
            logger.warning("start called while not idle")
            return
        }
        requestPermissionsAndStart(language: language, prompt: prompt)
    }

    func stop() {
        logger.info("stop")
        if let task = recognitionTask {
            task.cancel()
            recognitionTask = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        currentState = .idle
        onPartial?("")
    }

    func cancel() {
        logger.info("cancel")
        stop()
    }

    // MARK: - Permissions + start
    private func requestPermissionsAndStart(language: String?, prompt: String?) {
        let group = DispatchGroup()
        var micGranted = false
        var speechGranted = false

        group.enter()
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            micGranted = granted
            group.leave()
        }

        group.enter()
        SFSpeechRecognizer.requestAuthorization { auth in
            speechGranted = (auth == .authorized)
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard micGranted && speechGranted else {
                self.logger.error("Permissions denied: mic=\(micGranted) speech=\(speechGranted)")
                self.currentState = .idle
                return
            }
            self.setupSFRecognizer(language: language, prompt: prompt)
        }
    }

    // MARK: - iOS 13+ SFSpeechRecognizer fallback
    private func setupSFRecognizer(language: String?, prompt: String?) {
        let localeIdentifier = language ?? Locale.preferredLanguages.first ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer unavailable for \(localeIdentifier)")
            currentState = .idle
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if let prompt {
            request.contextualStrings = [prompt]
        }
        recognitionRequest = request

        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("AVAudioSession setup failed: \(error.localizedDescription)")
        }

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            try engine.start()
            currentState = .recording
        } catch {
            logger.error("AVAudioEngine start failed: \(error.localizedDescription)")
            currentState = .idle
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                if result.isFinal {
                    self.currentState = .idle
                    self.onFinal?(result.bestTranscription.formattedString)
                    self.stop()
                } else {
                    self.onPartial?(result.bestTranscription.formattedString)
                }
            }
            if let error {
                self.logger.error("SFSpeechRecognitionTask error: \(error.localizedDescription)")
                self.currentState = .idle
                self.stop()
            }
        }
    }
}
