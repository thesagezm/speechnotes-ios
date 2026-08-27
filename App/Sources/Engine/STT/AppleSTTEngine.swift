import Foundation
import Speech
import AVFoundation
import OSLog
import SpeechLogic

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
    var onError: ((String) -> Void)?

    private let logger = Logger(subsystem: "com.speechnotes.ios", category: "AppleSTT")
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    /// Best transcript of the CURRENT recognition segment, updated on every
    /// partial/final callback — lets stop() deliver the text SFSpeech would
    /// otherwise discard when the task is cancelled.
    private var latestTranscript = ""
    /// Text from completed (rolled-over) segments; combined with the live
    /// `latestTranscript` when stop() synthesizes a final.
    private var accumulatedSegments = ""
    /// True once this session's final has been delivered (stop() must not
    /// deliver twice; cancel() must not deliver at all).
    private var deliveredFinal = false
    /// True while the user has not requested stop/cancel — gates the ~1-min
    /// SFSpeech rollover (FIX-5).
    private var stillRecording = false
    /// True once stop() has been called — distinguishes "final because we're
    /// done" from "final because the 1-min rollover kicked in".
    private var stopRequested = false

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
        stopRequested = true
        stillRecording = false
        if let task = recognitionTask {
            task.cancel()
            recognitionTask = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Restore the playback category so the TTS engine's AVAudioEngine
        // can initialise its output node. Without this, Supertonic /
        // Kokoro / Apple TTS surfaces `kAUInitialize` -10851 until the user
        // flips to another engine and back.
        AudioSessionResetter.restoreForPlayback()

        currentState = .idle
        // Graceful stop: SFSpeech discards the in-flight transcript when the
        // task is cancelled — deliver what we recognized so the caller's
        // save/insert path has text.
        if !deliveredFinal {
            deliveredFinal = true
            let combined = accumulatedSegments + (accumulatedSegments.isEmpty || latestTranscript.isEmpty ? "" : " ") + latestTranscript
            onFinal?(combined)
        }
    }

    func cancel() {
        logger.info("cancel")
        deliveredFinal = true   // discard, don't deliver
        stop()
    }

    // MARK: - File transcription (uses SFSpeechURLRecognitionRequest).
    func transcribeFile(samples: [Float], language: String?, progress: (@Sendable (Double) -> Void)?) async throws -> String {
        guard !samples.isEmpty else { return "" }
        try await Self.ensureSpeechAuthorization()
        // SFSpeech caps one request around a minute of audio — transcribe in
        // 50 s chunks and join.
        let chunkSamples = 16_000 * 50
        let totalChunks = max(1, (samples.count + chunkSamples - 1) / chunkSamples)
        var parts: [String] = []
        var start = 0
        var chunkIndex = 0
        while start < samples.count {
            let end = min(start + chunkSamples, samples.count)
            let wavURL = try Self.writeTempWAV(samples: Array(samples[start..<end]))
            do {
                parts.append(try await transcribeFile(at: wavURL, language: language))
            } catch {
                try? FileManager.default.removeItem(at: wavURL)
                throw error
            }
            try? FileManager.default.removeItem(at: wavURL)
            start = end
            chunkIndex += 1
            progress?(Double(chunkIndex) / Double(totalChunks))
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func ensureSpeechAuthorization() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted: Bool = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { auth in
                    cont.resume(returning: auth == .authorized)
                }
            }
            if !granted { throw AppleSTTError.notAuthorized }
        default:
            throw AppleSTTError.notAuthorized
        }
    }

    private enum AppleSTTError: LocalizedError {
        case notAuthorized
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Speech recognition not authorised. Enable it in Settings → Privacy."
            }
        }
    }

    private func transcribeFile(at url: URL, language: String?) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let localeIdentifier = language ?? Locale.preferredLanguages.first ?? "en-US"
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
                continuation.resume(throwing: TranscribeFileError.unsupported)
                return
            }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }

    /// Tiny 16-bit PCM mono WAV writer — only used by the file-import path
    /// so SFSpeechURLRecognitionRequest has something on disk to read.
    private static func writeTempWAV(samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechnotes-import-\(UUID().uuidString).wav")
        try WAVWriter.write(samples: samples, sampleRate: 16_000, to: url)
        return url
    }

    // MARK: - Permissions + start
    private func requestPermissionsAndStart(language: String?, prompt: String?) {
        // SFSpeech authorization must be requested on the main actor; the
        // callback API is older than Swift Concurrency so we bridge via
        // `MainActor.assumeIsolated` and a continuation.
        Task { @MainActor in
            do { try await Self.ensureSpeechAuthorization() } catch {
                self.logger.error("Speech recognition denied: \(error.localizedDescription)")
                self.currentState = .idle
                self.onError?("Speech recognition is off. Enable it in Settings → Privacy & Security → Speech Recognition.")
                self.onFinal?("")
                return
            }
            self.requestMicPermission { micGranted in
                guard micGranted else {
                    self.logger.error("Microphone permission denied")
                    self.currentState = .idle
                    self.onError?("Microphone access is off. Enable it in Settings → Privacy & Security → Microphone.")
                    self.onFinal?("")
                    return
                }
                self.setupSFRecognizer(language: language, prompt: prompt)
            }
        }
    }

    private func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .granted {
            completion(true)
            return
        }
        session.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - iOS 13+ SFSpeechRecognizer fallback
    private func setupSFRecognizer(language: String?, prompt: String?) {
        let localeIdentifier = language ?? Locale.preferredLanguages.first ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer unavailable for \(localeIdentifier)")
            currentState = .idle
            onError?("Speech recognition isn't available for \(localeIdentifier) on this device.")
            onFinal?("")
            return
        }
        // Reset per-session state so the final we synthesize from stop() is
        // composed from exactly this session's text.
        self.recognizer = recognizer
        latestTranscript = ""
        accumulatedSegments = ""
        deliveredFinal = false
        stillRecording = true
        stopRequested = false

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
            onError?("Couldn't start the microphone. Try again.")
            onFinal?("")
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latestTranscript = result.bestTranscription.formattedString
                if result.isFinal {
                    if self.stillRecording && !self.stopRequested {
                        // ~1-minute SFSpeech per-task limit: roll over into a
                        // new request and keep transcribing (FIX-5).
                        self.restartRecognition()
                    } else {
                        self.finishSession()
                    }
                } else {
                    let combined = self.accumulatedSegments + (self.accumulatedSegments.isEmpty ? "" : " ") + self.latestTranscript
                    self.onPartial?(combined)
                }
            }
            if let error {
                self.logger.error("SFSpeechRecognitionTask error: \(error.localizedDescription)")
                if self.stillRecording && !self.stopRequested {
                    self.restartRecognition()
                } else {
                    self.finishSession()
                }
            }
        }
    }

    /// Closes the current session and delivers the combined transcript as the
    /// final, exactly once.
    private func finishSession() {
        stillRecording = false
        if !deliveredFinal {
            deliveredFinal = true
            let combined = accumulatedSegments + (accumulatedSegments.isEmpty || latestTranscript.isEmpty ? "" : " ") + latestTranscript
            onFinal?(combined)
        }
        currentState = .idle
        // Don't double-deliver from stop() — but do release the audio
        // session so the next start() can install a fresh tap.
        if let task = recognitionTask {
            task.cancel()
            recognitionTask = nil
        }
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        AudioSessionResetter.restoreForPlayback()
    }

    /// Starts a fresh recognition request on the live mic tap. The audio tap
    /// reads `recognitionRequest` per buffer, so it keeps feeding the new
    /// request; the previous segment's text moves to `accumulatedSegments`.
    private func restartRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            finishSession()
            return
        }
        // Roll the just-finalized segment into accumulatedSegments.
        let trimmed = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            accumulatedSegments = accumulatedSegments.isEmpty ? trimmed : accumulatedSegments + " " + trimmed
        }
        latestTranscript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        recognitionTask?.cancel()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latestTranscript = result.bestTranscription.formattedString
                if result.isFinal {
                    if self.stillRecording && !self.stopRequested {
                        self.restartRecognition()
                    } else {
                        self.finishSession()
                    }
                } else {
                    let combined = self.accumulatedSegments + (self.accumulatedSegments.isEmpty ? "" : " ") + self.latestTranscript
                    self.onPartial?(combined)
                }
            }
            if let error {
                self.logger.error("SFSpeechRecognitionTask error: \(error.localizedDescription)")
                if self.stillRecording && !self.stopRequested {
                    self.restartRecognition()
                } else {
                    self.finishSession()
                }
            }
        }
    }
}
