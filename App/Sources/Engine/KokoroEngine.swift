import AVFoundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// On-device Kokoro text-to-speech. Model + voices live in Documents/Kokoro
/// (downloaded by ModelManager on first use). Generation runs on a background
/// queue via MLX/Metal; playback through AVAudioEngine with a time-pitch node
/// so the speed slider changes pace without changing voice pitch.
final class KokoroEngine: NSObject, SpeechEngine {
    let name = "Kokoro (on-device)"

    var onStateChanged: ((SpeechState) -> Void)?

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
    private var playbackGeneration = 0
    private var audioEngineRunning = false

    private var state: SpeechState = .idle {
        didSet {
            if state != oldValue {
                Log.shared.info("KokoroEngine state: \(oldValue) → \(state)")
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
        Log.shared.info("KokoroEngine created")
    }

    // MARK: - Model loading

    private var isModelPresent: Bool {
        ModelManager.shared.isReady
    }

    private func loadModelIfNeeded() {
        guard !modelLoadAttempted else { return }
        modelLoadAttempted = true

        let modelPath = ModelManager.shared.modelPath
        let voicesPath = ModelManager.shared.voicesPath
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

    // MARK: - SpeechEngine

    func speak(_ text: String, rateMultiplier: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        guard isModelPresent else {
            Log.shared.error("KokoroEngine asked to speak but no model is downloaded")
            state = .idle
            return
        }

        if clean.count > 800 {
            Log.shared.info("KokoroEngine: long text (\(clean.count) chars) — generation will take a while (chunking comes in Phase 4)")
        }

        DispatchQueue.main.async { self.state = .generating }

        let generation = playbackGeneration + 1
        playbackGeneration = generation

        ttsQueue.async { [weak self] in
            guard let self else { return }
            self.loadModelIfNeeded()
            guard let tts = self.tts else {
                DispatchQueue.main.async { self.state = .idle }
                return
            }

            let voiceKey = self.voices[self.voice + ".npy"] != nil
                ? self.voice + ".npy"
                : self.voices.keys.sorted().first ?? ""
            guard let voiceEmbedding = self.voices[voiceKey] else {
                Log.shared.error("KokoroEngine: no voices available")
                DispatchQueue.main.async { self.state = .idle }
                return
            }

            // Voice naming convention: a* = American English, b* = British.
            let language: Language = voiceKey.hasPrefix("b") ? .enGB : .enUS

            let started = Date()
            do {
                let (audio, _) = try tts.generateAudio(
                    voice: voiceEmbedding,
                    language: language,
                    text: clean
                )
                let elapsed = Date().timeIntervalSince(started)
                let duration = Double(audio.count) / Double(KokoroTTS.Constants.samplingRate)
                Log.shared.info("KokoroEngine: generated \(String(format: "%.1f", duration))s of audio in \(String(format: "%.1f", elapsed))s (RTF \(String(format: "%.2f", elapsed / duration)))")

                let buffer = Self.makeMonoBuffer(samples: audio)
                DispatchQueue.main.async {
                    guard self.playbackGeneration == generation else { return }
                    self.play(buffer: buffer, rateMultiplier: rateMultiplier)
                }
            } catch {
                Log.shared.error("KokoroEngine generation failed: \(error)")
                DispatchQueue.main.async { self.state = .idle }
            }
        }
    }

    func pause() {
        guard audioEngineRunning, playerNode.isPlaying else { return }
        playerNode.pause()
        state = .paused
    }

    func resume() {
        guard audioEngineRunning, !playerNode.isPlaying else { return }
        playerNode.play()
        state = .speaking
    }

    func stop() {
        playbackGeneration += 1
        if audioEngineRunning {
            playerNode.stop()
        }
        state = .idle
    }

    // MARK: - Playback

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

    private func play(buffer: AVAudioPCMBuffer, rateMultiplier: Double) {
        timePitch.rate = Float(min(2.0, max(0.5, rateMultiplier)))

        if !audioEngineRunning {
            audioEngine.attach(playerNode)
            audioEngine.attach(timePitch)
            audioEngine.connect(playerNode, to: timePitch, format: buffer.format)
            audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: buffer.format)
            do {
                try audioEngine.start()
                audioEngineRunning = true
            } catch {
                Log.shared.error("KokoroEngine: audio engine failed to start: \(error)")
                state = .idle
                return
            }
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playerNode.isPlaying == false else { return }
                // Finished naturally (stop() flips state separately).
                if self.state == .speaking {
                    self.state = .idle
                }
            }
        }
        playerNode.play()
        state = .speaking
    }
}
