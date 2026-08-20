import Foundation
import AVFoundation
import OSLog

/// Phase-2 Whisper STT. Pulls PCM-16 mono audio at 16 kHz from
/// `DictationCoordinator`, hands it to whisper.cpp via the Objective-C bridge
/// (`WhisperBridge`), and publishes partial/final transcripts back through
/// `onPartial` / `onFinal`. The C context is loaded once per model file.
///
/// Until Phase 2's vendored bridge lands, the engine is a no-op stub that
/// still publishes state transitions so the coordinator and UI work
/// end-to-end (matching the Apple engine's behaviour).
final class WhisperCppEngine: STTEngine {
    let name: String = "Whisper (offline)"
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStateChanged: ((STTState) -> Void)?

    private let logger = Logger(subsystem: "com.speechnotes.ios", category: "WhisperSTT")
    private var audioEngine: AVAudioEngine?
    private var ringBuffer: [Float] = []
    private let ringLock = NSLock()
    private var workItem: DispatchWorkItem?
    private let processQueue = DispatchQueue(label: "com.speechnotes.stt.whisper", qos: .userInitiated)

    private var currentState: STTState = .idle {
        didSet { onStateChanged?(currentState) }
    }

    /// Path to the active `.bin` model. Set via `loadModel(id:)`.
    private var modelPath: String?

    init(modelId: String = "tiny") {
        loadModel(id: modelId)
    }

    func loadModel(id: String) {
        if let url = WhisperModelManager.modelURL(for: id),
           FileManager.default.fileExists(atPath: url.path) {
            modelPath = url.path
            logger.info("Whisper ready: model id=\(id) path=\(url.lastPathComponent)")
        } else {
            modelPath = nil
            logger.warning("Whisper model not installed: \(id)")
        }
    }

    // MARK: - STTEngine
    func start(language: String?, prompt: String?) {
        guard currentState == .idle else { return }
        guard modelPath != nil else {
            logger.error("No Whisper model available — cannot start")
            currentState = .idle
            onFinal?("")
            return
        }
        setupAudioEngine()
        currentState = .recording
        scheduleProcessWindow()
    }

    func stop() {
        workItem?.cancel()
        workItem = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        ringLock.lock()
        let snapshot = ringBuffer
        ringBuffer.removeAll(keepingCapacity: true)
        ringLock.unlock()
        if !snapshot.isEmpty { runInference(samples: snapshot, isFinal: true) }
        currentState = .idle
    }

    func cancel() { stop() }

    // MARK: - Audio capture + ring buffer
    private func setupAudioEngine() {
        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Resample to 16 kHz mono Float32 by installing a tap and using
        // AVAudioConverter. Falls back to direct append if the format is
        // already 16 kHz mono.
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let converter = AVAudioConverter(from: format, to: target)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converter else { return }
            let ratio = target.sampleRate / format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }
            var error: NSError?
            var fed = false
            converter.convert(to: outBuf, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, let channelData = outBuf.floatChannelData?[0] {
                let frames = Int(outBuf.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: frames))
                self.ringLock.lock()
                self.ringBuffer.append(contentsOf: samples)
                // Cap ring buffer at ~30 s of audio to bound RAM.
                let maxSamples = 16_000 * 30
                if self.ringBuffer.count > maxSamples {
                    self.ringBuffer.removeFirst(self.ringBuffer.count - maxSamples)
                }
                self.ringLock.unlock()
            }
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            logger.error("AVAudioEngine start failed: \(error.localizedDescription)")
            currentState = .idle
        }
    }

    /// Re-transcribe the rolling window every 1.5 s. The text we surface is
    /// the union of stable segments at the bottom of each pass — crude but
    /// useful as a streaming approximation.
    private func scheduleProcessWindow() {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ringLock.lock()
            let snapshot = self.ringBuffer
            self.ringLock.unlock()
            self.runInference(samples: snapshot, isFinal: false)
            self.scheduleProcessWindow()
        }
        workItem = item
        processQueue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func runInference(samples: [Float], isFinal: Bool) {
        guard let path = modelPath else { return }
        // Phase 2 wiring: hand off to the C bridge. Until the vendored
        // bridge is in, we emit an empty partial and rely on the final
        // call to surface the captured text via a dummy echo so the UI flow
        // can be exercised end-to-end.
        let text = Self.placeholderTranscribe(path: path, samples: samples)
        if !text.isEmpty {
            currentState = .transcribing
            onPartial?(text)
        }
        if isFinal {
            onFinal?(text)
            currentState = .idle
        }
    }

    /// Stub transcription. Replaced by `WhisperBridge.transcribe(...)` once
    /// the vendored C bridge is wired.
    private static func placeholderTranscribe(path: String, samples: [Float]) -> String {
        // Length-based hint keeps the UI responsive without faking words.
        let seconds = Double(samples.count) / 16_000
        return seconds > 0.5 ? "(\(String(format: "%.1f", seconds)) s captured)" : ""
    }
}
