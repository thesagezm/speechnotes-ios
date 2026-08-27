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
    var onError: ((String) -> Void)?

    private let logger = Logger(subsystem: "com.speechnotes.ios", category: "WhisperSTT")
    private var audioEngine: AVAudioEngine?
    private let ringLock = NSLock()
    private var ringBuffer: [Float] = []
    private let processQueue = DispatchQueue(label: "com.speechnotes.stt.whisper", qos: .userInitiated)
    private var workItem: DispatchWorkItem?

    private var pipe: WhisperKit?
    private var currentModelId: String = "tiny"
    private var loadedModelVariant: String?
    /// Language for the current session (BCP-47 or nil = auto), set in start().
    private var currentLanguage: String?
    /// Transcript of evicted (older-than-window) audio, guarded by ringLock.
    /// Chained finalization tasks append in segment order (see enqueueFinalization).
    private var finalizedText = ""
    /// Serializes evicted-segment transcriptions so appended text stays ordered.
    private var finalizeChain: Task<Void, Never> = Task {}

    /// Map our catalog ids to WhisperKit's model folder names — single
    /// source of truth lives on WhisperModelManager.
    private static var variantForId: [String: String] { WhisperModelManager.variantForId }

    private static let liveWindowSamples = 16_000 * 30   // hard cap kept in memory
    private static let liveKeepSamples = 16_000 * 20     // floor after an eviction

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
            // Prefer the folder this process recorded at download time; only
            // fall back to the model-name trigger so a cold start (no folder
            // remembered yet) asks WhisperKit to resolve it from the repo.
            if let folder = WhisperModelManager.modelFolder(forId: id) {
                let config = WhisperKitConfig(modelFolder: folder.path)
                pipe = try await WhisperKit(config)
            } else {
                let config = WhisperKitConfig(model: variant, modelRepo: "argmaxinc/whisperkit-coreml")
                pipe = try await WhisperKit(config)
            }
            loadedModelVariant = variant
            logger.info("WhisperKit ready: \(variant)")
        } catch {
            logger.error("WhisperKit init failed: \(error.localizedDescription)")
            pipe = nil
            onError?("Couldn't load the \(variant) model — try re-downloading it from Settings → Speech-to-text.")
        }
    }

    /// Resolves once the WhisperKit pipeline has finished loading — lets the
    /// coordinator show "Loading model…" instead of failing the tap on cold
    /// start (the init() Task used to race the first record button press).
    func waitUntilLoaded() async {
        while pipe == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
    }

    // MARK: - STTEngine
    func start(language: String?, prompt: String?) {
        guard currentState == .idle else { return }
        currentLanguage = language
        guard pipe != nil else {
            logger.error("Whisper model not loaded")
            currentState = .idle
            onError?("The Whisper model isn't loaded yet. Wait for the download to finish, then try again.")
            onFinal?("")
            return
        }
        ensureMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.logger.error("Microphone permission denied")
                self.currentState = .idle
                self.onError?("Microphone access is off. Enable it in Settings → Privacy & Security → Microphone.")
                self.onFinal?("")
                return
            }
            guard self.currentState == .idle else { return }   // stopped while the prompt was up
            self.finalizedText = ""
            self.setupAudioEngine()
            guard self.audioEngine != nil else {
                self.currentState = .idle
                self.onError?("Couldn't start the microphone. Try again.")
                self.onFinal?("")
                return
            }
            self.currentState = .recording
            self.scheduleProcessWindow()
        }
    }

    private func ensureMicPermission(_ completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .granted {
            completion(true)
            return
        }
        session.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
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
        AudioSessionResetter.restoreForPlayback()
        currentState = .idle
        if !snapshot.isEmpty {
            runFinal(samples: snapshot)
        } else {
            // Nothing captured (tap-and-release) — still deliver so the
            // coordinator's state machine settles and any finalized
            // segments aren't stranded.
            ringLock.lock()
            let text = finalizedText
            finalizedText = ""
            ringLock.unlock()
            onFinal?(text)
        }
    }

    func cancel() { stop() }

    // MARK: - File transcription (WhisperKit accepts Float32 arrays directly).
    func transcribeFile(samples: [Float], language: String?, progress: (@Sendable (Double) -> Void)?) async throws -> String {
        guard let pipe else { throw TranscribeFileError.unsupported }
        guard !samples.isEmpty else { return "" }
        // One inference per 30 s keeps memory and latency bounded on-device.
        let chunkSamples = 16_000 * 30
        let totalChunks = max(1, (samples.count + chunkSamples - 1) / chunkSamples)
        var parts: [String] = []
        var start = 0
        var chunkIndex = 0
        while start < samples.count {
            let end = min(start + chunkSamples, samples.count)
            let options = DecodingOptions(language: Self.whisperLanguageCode(language))
            let results = try await pipe.transcribe(audioArray: Array(samples[start..<end]), decodeOptions: options)
            let chunkText = results.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunkText.isEmpty { parts.append(chunkText) }
            start = end
            chunkIndex += 1
            progress?(Double(chunkIndex) / Double(totalChunks))
        }
        return parts.joined(separator: " ")
    }

    /// BCP-47 ("en-US") → ISO-639-1 ("en"); WhisperKit rejects region-qualified
    /// codes. nil/auto passes through as nil (language auto-detect).
    static func whisperLanguageCode(_ bcp47: String?) -> String? {
        guard let bcp47, !bcp47.isEmpty else { return nil }
        return String(bcp47.prefix(while: { $0 != "-" })).lowercased()
    }

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
                self.ringLock.unlock()
            }
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            logger.error("AVAudioEngine start failed: \(error.localizedDescription)")
            engine.stop()
            input.removeTap(onBus: 0)
            audioEngine = nil
            AudioSessionResetter.restoreForPlayback()
        }
    }

    private func scheduleProcessWindow() {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ringLock.lock()
            var evicted: [Float] = []
            if self.ringBuffer.count > Self.liveWindowSamples {
                evicted = Array(self.ringBuffer.prefix(self.ringBuffer.count - Self.liveKeepSamples))
                self.ringBuffer.removeFirst(evicted.count)
            }
            let snapshot = self.ringBuffer
            self.ringLock.unlock()
            if !evicted.isEmpty { self.enqueueFinalization(samples: evicted) }
            if !snapshot.isEmpty { self.runInference(samples: snapshot, isFinal: false) }
            self.scheduleProcessWindow()
        }
        workItem = item
        processQueue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func runInference(samples: [Float], isFinal: Bool) {
        guard let pipe else { return }
        guard !samples.isEmpty else { return }
        if isFinal { currentState = .transcribing }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let options = DecodingOptions(language: Self.whisperLanguageCode(self?.currentLanguage))
                let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
                let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    guard let self else { return }
                    if isFinal { self.currentState = .recording }
                    if !text.isEmpty {
                        self.ringLock.lock()
                        let combined = self.finalizedText + (self.finalizedText.isEmpty || text.isEmpty ? "" : " ") + text
                        self.ringLock.unlock()
                        self.onPartial?(combined)
                    }
                }
            } catch {
                self?.logger.error("WhisperKit transcribe failed: \(error.localizedDescription)")
                await MainActor.run {
                    if isFinal { self?.currentState = .recording }
                }
            }
        }
    }

    /// Transcribes one evicted segment and appends it to finalizedText. Chained
    /// onto finalizeChain so segments append strictly in recorded order even
    /// if inference finishes out of order. Emits combined partials so the UI
    /// shows the full session text.
    private func enqueueFinalization(samples: [Float]) {
        guard let pipe else { return }
        let prior = finalizeChain
        finalizeChain = Task.detached(priority: .userInitiated) { [weak self] in
            await prior.value
            guard let self else { return }
            do {
                let options = DecodingOptions(language: Self.whisperLanguageCode(self.currentLanguage))
                let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
                let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                self.ringLock.lock()
                self.finalizedText += self.finalizedText.isEmpty ? text : " " + text
                let combined = self.finalizedText
                self.ringLock.unlock()
                self.onPartial?(combined)
            } catch {
                self.logger.error("WhisperKit finalize failed: \(error.localizedDescription)")
            }
        }
    }

    /// stop() path: wait for pending finalizations, transcribe the live window,
    /// emit the WHOLE session as the final, reset.
    private func runFinal(samples: [Float]) {
        guard let pipe else { return }
        let prior = finalizeChain
        finalizeChain = Task.detached(priority: .userInitiated) { [weak self] in
            await prior.value
            guard let self else { return }
            do {
                let options = DecodingOptions(language: Self.whisperLanguageCode(self.currentLanguage))
                let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
                let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                self.ringLock.lock()
                let combined = self.finalizedText + (self.finalizedText.isEmpty || text.isEmpty ? "" : " ") + text
                self.finalizedText = ""
                self.ringLock.unlock()
                self.onFinal?(combined)
            } catch {
                self.logger.error("WhisperKit final failed: \(error.localizedDescription)")
                self.ringLock.lock()
                self.finalizedText = ""
                self.ringLock.unlock()
                self.onFinal?("")
            }
        }
    }
}
