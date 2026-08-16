import AVFoundation
import KokoroSwift
import MLX
import MLXUtilsLibrary
import SpeechLogic

/// On-device Kokoro text-to-speech. Model + voices live in Documents/Kokoro
/// (downloaded by ModelManager on first use).
///
/// Long notes are split into sentence chunks (SpeechLogic/SentenceChunker —
/// design ported from PocketPal AI's StreamingChunker): chunk N+1 generates
/// on the MLX queue while chunk N plays, so speech starts after the first
/// sentence instead of after the whole note. Playback runs through
/// AVAudioEngine with a time-pitch node so the speed slider changes pace
/// without changing voice pitch.
///
/// Threading: all MLX work (KokoroTTS, voice embeddings) happens on the
/// serial `ttsQueue`; all audio-graph work and streaming state on the main
/// thread. A monotonically increasing `playbackGeneration` invalidates stale
/// producers and scheduled completions after stop()/new speak/export.
final class KokoroEngine: NSObject, SpeechEngine {
    let name = "Kokoro (on-device)"

    var onStateChanged: ((SpeechState) -> Void)?
    var onProgress: ((Double) -> Void)?

    /// Called once after the model has been loaded for the first time
    /// (loading takes a few seconds; the UI can show "preparing…").
    var onModelReady: (() -> Void)?

    var voice = "am_eric"

    private let ttsQueue = DispatchQueue(label: "com.speechnotes.kokoro", qos: .userInitiated)
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]
    private var modelLoadAttempted = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioNodesAttached = false
    private var audioEngineRunning = false

    private var playbackGeneration = 0

    // Streaming pipeline state — main thread only.
    private var chunks: [Chunk] = []
    private var generatedBuffers: [Int: AVAudioPCMBuffer] = [:]
    private var scheduledUpTo = -1
    private var totalChars = 1
    private var rate: Float = 1.0

    private var interruptionObserver: NSObjectProtocol?

    private var state: SpeechState = .idle {
        didSet {
            if state != oldValue {
                Log.shared.info("KokoroEngine state: \(oldValue) → \(state)")
                if state == .idle {
                    teardownPlayback()
                    onProgress?(0)
                }
                onStateChanged?(state)
            }
        }
    }

    override init() {
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
        } catch {
            Log.shared.error("KokoroEngine audio session setup failed: \(error)")
        }
        // PocketPal lesson: pause on calls/Siri, resume only when iOS says
        // it is appropriate (shouldResume option).
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        Log.shared.info("KokoroEngine created")
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        if typeRaw == AVAudioSession.InterruptionType.began.rawValue {
            if state == .speaking { pause() }
        } else if typeRaw == AVAudioSession.InterruptionType.ended.rawValue,
                  optionsRaw & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 {
            if state == .paused { resume() }
        }
    }

    // MARK: - Model loading

    private var isModelPresent: Bool {
        FileManager.default.fileExists(atPath: ModelManager.modelFileURL.path)
            && FileManager.default.fileExists(atPath: ModelManager.voicesFileURL.path)
    }

    private func loadModelIfNeeded() {
        guard !modelLoadAttempted else { return }
        modelLoadAttempted = true

        let modelPath = ModelManager.modelFileURL
        let voicesPath = ModelManager.voicesFileURL
        guard FileManager.default.fileExists(atPath: modelPath.path),
              FileManager.default.fileExists(atPath: voicesPath.path) else {
            Log.shared.error("KokoroEngine: model files missing at \(modelPath.deletingLastPathComponent().path)")
            return
        }

        let started = Date()
        voices = NpyzReader.read(fileFromPath: voicesPath) ?? [:]
        Log.shared.info("KokoroEngine: loaded \(voices.count) voices in \(Date().timeIntervalSince(started))s")

        let modelStarted = Date()
        tts = KokoroTTS(modelPath: modelPath)
        Log.shared.info("KokoroEngine: model loaded in \(Date().timeIntervalSince(modelStarted))s")

        DispatchQueue.main.async { [weak self] in
            self?.onModelReady?()
        }
    }

    /// ttsQueue only — resolves the current voice's embedding + language.
    private func resolveVoice() -> (embedding: MLXArray, language: Language)? {
        // Voice naming convention: a* = American English, b* = British.
        let voiceKey = voices[voice + ".npy"] != nil
            ? voice + ".npy"
            : voices.keys.sorted().first ?? ""
        guard let embedding = voices[voiceKey] else {
            Log.shared.error("KokoroEngine: no voices available")
            return nil
        }
        let language: Language = voiceKey.hasPrefix("b") ? .enGB : .enUS
        return (embedding, language)
    }

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        guard isModelPresent else {
            Log.shared.error("KokoroEngine asked to speak but no model is downloaded")
            state = .idle
            return
        }

        let allChunks = SentenceChunker.chunks(for: clean)
        guard !allChunks.isEmpty else { return }

        DispatchQueue.main.async { self.state = .generating }

        let generation = playbackGeneration + 1
        playbackGeneration = generation

        chunks = allChunks
        generatedBuffers = [:]
        scheduledUpTo = -1
        totalChars = max(1, clean.utf16.count)
        rate = Float(min(2.0, max(0.5, rateMultiplier)))

        if allChunks.count > 1 {
            Log.shared.info("KokoroEngine: streaming \(allChunks.count) chunks (first: \(allChunks[0].text.count) chars)")
        }

        ttsQueue.async { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.loadModelIfNeeded()
            guard let tts = self.tts, let (embedding, language) = self.resolveVoice() else {
                DispatchQueue.main.async {
                    if self.playbackGeneration == generation { self.state = .idle }
                }
                return
            }

            // Producer: generate chunks in order while the consumer plays them.
            for (index, chunk) in allChunks.enumerated() {
                guard self.playbackGeneration == generation else { return }
                do {
                    let started = Date()
                    let (audio, _) = try tts.generateAudio(
                        voice: embedding,
                        language: language,
                        text: chunk.text
                    )
                    let elapsed = Date().timeIntervalSince(started)
                    let duration = Double(audio.count) / Double(KokoroTTS.Constants.samplingRate)
                    Log.shared.info("KokoroEngine: chunk \(index + 1)/\(allChunks.count) — \(String(format: "%.1f", duration))s audio in \(String(format: "%.1f", elapsed))s")
                    let buffer = Self.makeMonoBuffer(samples: audio)
                    DispatchQueue.main.async {
                        guard self.playbackGeneration == generation else { return }
                        self.generatedBuffers[index] = buffer
                        self.scheduleReadyChunks(generation: generation)
                    }
                } catch {
                    Log.shared.error("KokoroEngine chunk \(index + 1) generation failed: \(error)")
                    DispatchQueue.main.async {
                        if self.playbackGeneration == generation { self.state = .idle }
                    }
                    return
                }
            }
        }
    }

    func pause() {
        guard audioEngineRunning, playerNode.isPlaying else { return }
        playerNode.pause()
        state = .paused
    }

    func resume() {
        guard audioEngineRunning, !playerNode.isPlaying, state == .paused else { return }
        playerNode.play()
        state = .speaking
    }

    func stop() {
        playbackGeneration += 1
        state = .idle
    }

    // MARK: - Streaming playback (main thread)

    /// Schedules every generated-but-not-yet-scheduled chunk in order onto the
    /// player node. Called whenever a new buffer lands or a chunk finishes.
    private func scheduleReadyChunks(generation: Int) {
        guard playbackGeneration == generation else { return }
        while true {
            let next = scheduledUpTo + 1
            guard next < chunks.count, let buffer = generatedBuffers[next] else { return }
            scheduledUpTo = next
            schedule(buffer: buffer, isLast: next == chunks.count - 1, generation: generation)
        }
    }

    private func schedule(buffer: AVAudioPCMBuffer, isLast: Bool, generation: Int) {
        ensureAudioEngineRunning(format: buffer.format)

        let charsDone = chunks.prefix(scheduledUpTo + 1).reduce(0) { $0 + $1.length }
        onProgress?(min(1.0, Double(charsDone) / Double(totalChars)))

        // No .interrupts flag: consecutive chunks must queue gaplessly.
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                if isLast {
                    if self.state == .speaking || self.state == .paused || self.state == .generating {
                        self.onProgress?(1.0)
                        self.state = .idle
                    }
                    return
                }
                self.scheduleReadyChunks(generation: generation)
            }
        }

        if state == .generating {
            state = .speaking
            playerNode.play()
        }
    }

    private func ensureAudioEngineRunning(format: AVAudioFormat) {
        if !audioNodesAttached {
            audioEngine.attach(playerNode)
            audioEngine.attach(timePitch)
            audioNodesAttached = true
        }
        audioEngine.connect(playerNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
        timePitch.rate = rate
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                audioEngineRunning = true
            } catch {
                Log.shared.error("KokoroEngine: audio engine failed to start: \(error)")
                state = .idle
            }
        }
    }

    /// Stops the audio graph and releases the session so other apps get their
    /// volume back (we hold .duckOthers while speaking).
    private func teardownPlayback() {
        playerNode.stop()
        audioEngine.stop()
        audioEngineRunning = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        generatedBuffers = [:]
        scheduledUpTo = -1
    }

    // MARK: - WAV export

    /// Renders the full text to a WAV file at natural speed for the Share
    /// Sheet. Cancels any in-flight playback. `completion` fires on the main
    /// thread; `onChunkProgress` reports 0…1 on the main thread.
    func renderWAV(
        text: String,
        onChunkProgress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(ExportIssue(message: "The note is empty.")))
            }
            return
        }
        guard isModelPresent else {
            DispatchQueue.main.async {
                completion(.failure(ExportIssue(message: "Kokoro model not downloaded.")))
            }
            return
        }

        // Export owns the engine: cancel any playback in flight.
        playbackGeneration += 1
        DispatchQueue.main.async { self.state = .idle }

        let renderChunks = SentenceChunker.chunks(for: clean)
        let total = max(1, clean.utf16.count)

        ttsQueue.async { [weak self] in
            guard let self else { return }
            self.loadModelIfNeeded()
            guard let tts = self.tts, let (embedding, language) = self.resolveVoice() else {
                DispatchQueue.main.async {
                    completion(.failure(ExportIssue(message: "Kokoro model could not be loaded.")))
                }
                return
            }

            var samples: [Float] = []
            samples.reserveCapacity(24000 * 300)
            do {
                for (index, chunk) in renderChunks.enumerated() {
                    let (audio, _) = try tts.generateAudio(
                        voice: embedding,
                        language: language,
                        text: chunk.text
                    )
                    samples.append(contentsOf: audio)
                    let charsDone = renderChunks.prefix(index + 1).reduce(0) { $0 + $1.length }
                    let progress = min(1.0, Double(charsDone) / Double(total))
                    DispatchQueue.main.async { onChunkProgress?(progress) }
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let exportsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
                let url = exportsDir.appendingPathComponent("Note-\(formatter.string(from: Date())).wav")
                try WAVWriter.write(
                    samples: samples,
                    sampleRate: KokoroTTS.Constants.samplingRate,
                    to: url
                )
                let seconds = Double(samples.count) / Double(KokoroTTS.Constants.samplingRate)
                Log.shared.info("KokoroEngine: exported \(String(format: "%.1f", seconds))s of audio to \(url.lastPathComponent)")
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                Log.shared.error("KokoroEngine export failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Buffers

    private static func makeMonoBuffer(samples: [Float]) -> AVAudioPCMBuffer {
        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity

        let destination = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { source in
            memcpy(destination, source.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        return buffer
    }
}

/// Simple user-facing error for export failures.
private struct ExportIssue: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
