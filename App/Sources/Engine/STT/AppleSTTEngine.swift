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

        // Restore the playback category so the TTS engine's AVAudioEngine
        // can initialise its output node. Without this, Supertonic /
        // Kokoro / Apple TTS surfaces `kAUInitialize` -10851 until the user
        // flips to another engine and back.
        AudioSessionResetter.restoreForPlayback()

        currentState = .idle
        onPartial?("")
    }

    func cancel() {
        logger.info("cancel")
        stop()
    }

    // MARK: - File transcription (uses SFSpeechURLRecognitionRequest).
    func transcribeFile(samples: [Float], language: String?) async throws -> String {
        // SFSpeechRecognizer prefers a file URL; we hand the samples back
        // by writing them to a temp WAV and pointing the recogniser at it.
        let wavURL = try Self.writeTempWAV(samples: samples)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        return try await transcribeFile(at: wavURL, language: language)
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
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
        var data = Data()
        let sampleRate: UInt32 = 16_000
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count * MemoryLayout<Int16>.size)

        func appendString(_ s: String) {
            data.append(contentsOf: s.utf8)
        }
        func appendUInt32LE(_ v: UInt32) {
            var be = v.littleEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        func appendUInt16LE(_ v: UInt16) {
            var be = v.littleEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendUInt32LE(36 + dataSize)
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32LE(16)
        appendUInt16LE(1) // PCM
        appendUInt16LE(numChannels)
        appendUInt32LE(sampleRate)
        appendUInt32LE(byteRate)
        appendUInt16LE(blockAlign)
        appendUInt16LE(bitsPerSample)
        appendString("data")
        appendUInt32LE(dataSize)
        for s in pcm {
            var little = s.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
        return url
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
