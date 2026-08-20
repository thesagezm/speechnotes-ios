import Foundation
import Speech
import AVFoundation
import OSLog

#if canImport(AVFoundation)
import AVFoundation
#endif

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
    private let speechQueue = DispatchQueue(label: "com.speechnotes.stt.apple")
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?

    private var currentState: STTState = .idle {
        didSet { onStateChanged?(currentState) }
    }

    // MARK: - Public API
    func start(language: String?, prompt: String?) {
        guard currentState == .idle else {
            logger.warning("start called while not idle (\(currentState))")
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
        audioEngine?.inputNode?.removeTap(onBus: 0)
        audioEngine = nil

        // iOS 26 analyzer teardown
        if let analyzer {
            analyzer.stopTranscribing()
        }
        analyzer = nil
        transcriber = nil

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
            self.setupAudioAndTranscribe(language: language, prompt: prompt)
        }
    }

    // MARK: - iOS 26 SpeechAnalyzer path (preferred)
    @available(iOS 26, *)
    private func setupAnalyzer(language: String?, prompt: String?) {
        do {
            let config = SpeechAnalyzer.Configuration(
                transcriber: try SpeechTranscriber.Configuration(languageHint: language ?? "en-US")
            )
            let analyzer = try SpeechAnalyzer(configuration: config)
            analyzer.delegate = self
            self.analyzer = analyzer
            self.transcriber = try SpeechTranscriber(configuration: config.transcriber)
            // Wire audio
            try startAudioEngine { [weak self] buffer in
                analyzer.transcribe(buffer: buffer)
            }
            currentState = .recording
        } catch {
            logger.error("SpeechAnalyzer init failed: \(error.localizedDescription) — falling back to SFSpeechRecognizer")
            if #available(iOS 26, *) {} // already handled
            setupSFRecognizer(language: language, prompt: prompt)
        }
    }

    // MARK: - iOS 13+ SFSpeechRecognizer fallback
    private func setupSFRecognizer(language: String?, prompt: String?) {
        let localeIdentifier = language ?? Locale.preferredLanguages.first ?? "en-US"
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer unavailable for \(localeIdentifier)")
            currentState = .idle
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        if let prompt {
            request.contextualStrings = [prompt]
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("AVAudioSession setup failed: \(error.localizedDescription)")
        }

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine, let inputNode = engine.inputNode else { return }
        let format = inputNode.outputFormat(forBus: 0)

        // Resample to 16 kHz mono Float for Speech framework
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            // NOTE: level meter can be derived from buffer here if needed
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

    // MARK: - Audio engine helper (shared for both paths)
    private func startAudioEngine(_ handler: @escaping (AVAudioPCMBuffer) -> Void) {
        let engine = AVAudioEngine()
        self.audioEngine = engine
        guard let inputNode = engine.inputNode else { return }
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            handler(buffer)
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            logger.error("AVAudioEngine start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Dispatcher
    private func setupAudioAndTranscribe(language: String?, prompt: String?) {
        if #available(iOS 26, *) {
            setupAnalyzer(language: language, prompt: prompt)
        } else {
            setupSFRecognizer(language: language, prompt: prompt)
        }
    }
}

// MARK: - SpeechAnalyzerDelegate (iOS 26)

@available(iOS 26, *)
extension AppleSTTEngine: SpeechAnalyzerDelegate {
    func speechAnalyzer(_ analyzer: SpeechAnalyzer, didGenerate partialText: String) {
        onPartial?(partialText)
        currentState = .recording
    }

    func speechAnalyzer(_ analyzer: SpeechAnalyzer, didFinalize text: String) {
        onFinal?(text)
        currentState = .idle
        stop()
    }

    func speechAnalyzer(_ analyzer: SpeechAnalyzer, didEncounterError error: Error) {
        logger.error("SpeechAnalyzer error: \(error.localizedDescription)")
        currentState = .idle
        stop()
    }
}
