import Foundation
import AVFoundation
import OSLog
import WhisperKit

/// Phase-4 Whisper STT backed by WhisperKit (Argmax, MIT). WhisperKit
/// handles model loading, Core ML execution, and inference. We capture
/// audio via AVAudioEngine, resample to 16 kHz mono Float32, accumulate
/// a rolling buffer, and re-transcribe the window every ~1.5 s — emitting
/// partials through `onPartial` and the final result through `onFinal`
/// when the user stops.
final class WhisperCppEngine: STTEngine {
    let name: String = "Whisper (offline)"
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStateChanged: ((STTState) -> Void)?

    private let logger = Logger(subsystem: "com.speechnotes.ios", category: "WhisperSTT")
    private var audioEngine: AVAudioEngine?
    private let ringLock = NSLock()
    private var ringBuffer: [Float] = []
    private let processQueue = DispatchQueue(label: "com.speechnotes.stt.whisper", qos: .userInitiated)
    private var workItem: DispatchWorkItem?

    private var pipe: WhisperKit?
    private var currentModelId: String = "tiny"
    private var loadedModelVariant: String?

    /// Map our catalog ids to WhisperKit's model folder names. WhisperKit
    /// downloads from `argmaxinc/whisperkit-coreml` on Hugging Face.
    private static let variantForId: [String: String] = [
        "tiny": "tiny",
        "tiny.en": "tiny.en",
        "base": "base",
        "base.en": "base.en",
        "small": "small",
        "small.en": "small.en",
        "large-v3-turbo": "large-v3-turbo",
        "large-v3": "large-v3",
    ]

    private var currentState: STTState = .idle {
        didSet { onStateChanged?(currentState) }
    }

    init(modelId: String = "tiny") {
        self.currentModelId = modelId
        Task { @MainActor in await loadModel(id: modelId) }
    }

    @MainActor
    func loadModel(id: String) async {
        guard let variant = Self.variantForId[id] else {
            logger.error("Unknown Whisper model id: \(id)")
            return
        }
        currentModelId = id
        if pipe != nil, loadedModelVariant == variant { return }
        do {
            let config = WhisperKitConfig(model: variant, modelRepo: "argmaxinc/whisperkit-coreml")
            pipe = try await WhisperKit(config)
            loadedModelVariant = variant
            logger.info("WhisperKit ready: \(variant)")
        } catch {
            logger.error("WhisperKit init failed: \(error.localizedDescription)")
            pipe = nil
        }
    }

    // MARK: - STTEngine
    func start(language: String?, prompt: String?) {
        guard currentState == .idle else { return }
        guard pipe != nil else {
            logger.error("Whisper model not loaded")
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
        AudioSessionResetter.restoreForPlayback()
        currentState = .idle
    }

    func cancel() { stop() }

    // MARK: - Audio capture
    private func setupAudioEngine() {
        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let converter = AVAudioConverter(from: format, to: target) else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = target.sampleRate / format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }
            var error: NSError?
            var inputProvided = false
            let supply: AVAudioConverterInputBlock = { _, status in
                if inputProvided {
                    status.pointee = .endOfStream
                    return nil
                }
                inputProvided = true
                status.pointee = .haveData
                return buffer
            }
            converter.convert(to: outBuf, error: &error, withInputFrom: supply)
            if error == nil, let channelData = outBuf.floatChannelData?[0] {
                let frames = Int(outBuf.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: frames))
                self.ringLock.lock()
                self.ringBuffer.append(contentsOf: samples)
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
        guard let pipe else { return }
        guard !samples.isEmpty else { return }
        currentState = .transcribing
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let options = DecodingOptions(language: nil)
                let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
                let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    guard let self else { return }
                    if !text.isEmpty { self.onPartial?(text) }
                    if isFinal {
                        self.onFinal?(text)
                        self.currentState = .idle
                    } else {
                        self.currentState = .recording
                    }
                }
            } catch {
                self?.logger.error("WhisperKit transcribe failed: \(error.localizedDescription)")
                await MainActor.run {
                    if isFinal {
                        self?.onFinal?("")
                        self?.currentState = .idle
                    } else {
                        self?.currentState = .recording
                    }
                }
            }
        }
    }
}
