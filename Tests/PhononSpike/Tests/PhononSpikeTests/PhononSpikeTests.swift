import XCTest
import OnnxRuntimeBindings
import SpeechLogic

/// CI spike: proves the Phonon (gradium 31M English streaming TTS) ONNX
/// contract on the vendored ORT 1.24.2 before any device work — the blueprint
/// is Docs/PHONON-PORT.md, and every number/shape in it was pinned empirically
/// with Python ORT 1.24.2 first. This spike re-runs the SAME recipe in Swift,
/// against the exact SPM binary the app links (the com.microsoft contrib ops
/// — GroupQueryAttention, RotaryEmbedding, QuickGelu, SkipLayerNormalization —
/// are the load-bearing question).
///
/// Asserts: files present, both sessions load, the tokenizer encodes, the
/// flow loop reaches EOS (logit > 4.0) within the frame budget, and the
/// decoder emits non-silent 24 kHz PCM. Prints (non-gating): RTF and RSS of
/// the xctest process — the memory-headroom signal for the A14-class device.
final class PhononSpikeTests: XCTestCase {

    /// Resident set of *this* xctest process in MB via ps (the sessions and
    /// the KV caches live here).
    private func rssMB() -> Double {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "rss=", "-p", "\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return 0 }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (Double(out) ?? 0) / 1024.0
    }

    // MARK: - Contract constants (Docs/PHONON-PORT.md)

    static let sampleRate: Double = 24_000
    static let samplesPerFrame = 1920
    static let latentDim = 32
    static let framesPerCall = 8
    static let voiceDim = 512
    static let voiceFrames = 125
    static let frameRate = 12.5
    static let eosThreshold: Float = 4.0
    static let temperature: Float = 0.3
    static let attentionHeads = 8
    static let headDim = 64
    static let flowLayers = 6
    static let decodeWindow = 400

    func testGenerateSpeech() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = env["PHONON_DIR"] ?? NSHomeDirectory() + "/phonon-spike"
        let onnxDir = dir + "/onnx"
        let outPath = env["PHONON_OUT"] ?? dir + "/sample.wav"

        let fm = FileManager.default
        for file in ["model.onnx", "model.onnx_data", "mimi_decoder.onnx",
                     "mimi_decoder.onnx_data", "tokenizer.json"] {
            XCTAssertTrue(fm.fileExists(atPath: onnxDir + "/" + file), "missing \(onnxDir)/\(file)")
        }
        let voicePath = dir + "/voices/default.bin"
        XCTAssertTrue(fm.fileExists(atPath: voicePath), "missing \(voicePath)")

        let rss0 = rssMB()
        print("PHONON-SPIKE rss before load: \(String(format: "%.0f", rss0)) MB")

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let threadCap = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 6))
        let flowOptions = try ORTSessionOptions()
        try flowOptions.setIntraOpNumThreads(threadCap)
        let flowSession = try ORTSession(env: ortEnv, modelPath: onnxDir + "/model.onnx", sessionOptions: flowOptions)
        let decodeOptions = try ORTSessionOptions()
        try decodeOptions.setIntraOpNumThreads(threadCap)
        let decodeSession = try ORTSession(env: ortEnv, modelPath: onnxDir + "/mimi_decoder.onnx", sessionOptions: decodeOptions)

        let tokenizer = try PhononTokenizer(tokenizerData: try Data(contentsOf: URL(fileURLWithPath: onnxDir + "/tokenizer.json")))
        let voice = try Self.loadVoice(path: voicePath)
        XCTAssertEqual(voice.count, Self.voiceFrames * Self.voiceDim)

        let rss1 = rssMB()
        print("PHONON-SPIKE rss after load: \(String(format: "%.0f", rss1)) MB (+\(String(format: "%.0f", rss1 - rss0)))")

        // The hub's reference sentence.
        let text = "This morning, I took a walk in the park, and the sound of the birds and the breeze was so pleasant that I stopped for a long time just to listen."
        let ids = try tokenizer.encode(text)
        print("PHONON-SPIKE tokens: \(ids.count)")

        let started = Date()
        let pcm = try Self.speak(
            text: text, ids: ids, voice: voice,
            flowSession: flowSession, decodeSession: decodeSession,
            onCall: { call, pastKV, eos in
                print("PHONON-SPIKE call \(call): past_kv=\(pastKV) eos=\(eos.map { String(format: "%.1f", $0) }.joined(separator: " "))")
            })
        let elapsed = Date().timeIntervalSince(started)

        let rss2 = rssMB()
        print("PHONON-SPIKE rss after generate: \(String(format: "%.0f", rss2)) MB (+\(String(format: "%.0f", rss2 - rss1)))")

        let frames = pcm.count / Self.samplesPerFrame
        let audioSeconds = Double(frames) / Self.frameRate
        print("PHONON-SPIKE frames=\(frames) audio=\(String(format: "%.1f", audioSeconds))s "
              + "rtf=\(String(format: "%.3f", elapsed / audioSeconds)) elapsed=\(String(format: "%.2f", elapsed))s")

        try Self.writeWAV(pcm: pcm, to: outPath)
        print("PHONON-SPIKE sample written: \(outPath)")

        // Contract bars (the spike, not the phone bench): EOS reached, audio
        // finite, audible, length-plausible.
        XCTAssertGreaterThan(frames, 10, "too little audio for the reference sentence")
        XCTAssertLessThan(frames, 400, "EOS never crossed the threshold in budget")
        var sumSquares = 0.0
        for sample in pcm { sumSquares += Double(sample) * Double(sample) }
        let rms = sqrt(sumSquares / Double(max(1, pcm.count)))
        print("PHONON-SPIKE rms=\(String(format: "%.4f", rms)) peak=\(String(format: "%.3f", pcm.map { abs($0) }.max() ?? 0))")
        XCTAssertGreaterThan(rms, 0.01, "audio is silent")
        XCTAssertTrue(pcm.allSatisfy { $0.isFinite }, "non-finite samples")
    }

    // MARK: - The pinned recipe (mirror of Docs/PHONON-PORT.md)

    /// `voices/*.bin` are raw little-endian float32 in [1, 512, 125] order;
    /// the graph takes [1, 125, 512] — a transpose, not a reshape.
    static func loadVoice(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let count = data.count / MemoryLayout<Float>.size
        precondition(count == voiceDim * voiceFrames, "unexpected voice size \(count)")
        let flat = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        var out = [Float](repeating: 0, count: count)
        // out[frame * 512 + dim] = flat[dim * 125 + frame]
        for frame in 0..<voiceFrames {
            for dim in 0..<voiceDim {
                out[frame * voiceDim + dim] = flat[dim * voiceFrames + frame]
            }
        }
        return out
    }

    /// The flow loop: 1 prefill + 7 AR frames per call, EOS countdown, then
    /// windowed decode. Shapes are tracked locally (pastKV count), never read
    /// back off tensors — the vendored binding is only used for data in/out.
    static func speak(
        text: String,
        ids: [Int],
        voice: [Float],
        flowSession: ORTSession,
        decodeSession: ORTSession,
        onCall: (Int, Int, [Float]) -> Void = { _, _, _ in }
    ) throws -> [Float] {
        let T = ids.count
        let P = voiceFrames + T + 1
        let budget = Int(ceil((Double(T) / 3 + 2) * frameRate))
        let maxCalls = max(1, Int(ceil(Double(budget) / Double(framesPerCall))))
        let framesAfterEOS = words(in: text) <= 4 ? 3 : 1

        var kv: [ORTValue] = []
        kv.reserveCapacity(flowLayers * 2)
        for _ in 0..<(flowLayers * 2) {
            kv.append(try emptyTensor(dims: [1, attentionHeads, 0, headDim]))
        }
        var pastKVCount = 0
        var latentHistory = try emptyTensor(dims: [1, 0, latentDim])
        var latentHistoryCount = 0

        var newLatents: [Float] = []
        var countdown: Int? = nil
        var rng = SeededGenerator(seed: 0x9E3779B97F4A7C15)

        for call in 0..<maxCalls {
            let total = pastKVCount + P + (framesPerCall - 1)
            let noise = (0..<(framesPerCall * latentDim)).map { _ -> Float in
                Float.standardNormal(using: &rng) * sqrt(temperature)
            }

            var feeds: [String: ORTValue] = [:]
            feeds["input_ids"] = try int64Tensor(values: ids.map(Int64.init), dims: [1, T])
            feeds["audio_prompt_latents"] = try floatTensor(values: voice, dims: [1, voiceFrames, voiceDim])
            feeds["attention_mask"] = try int64Tensor(values: [Int64](repeating: 1, count: total), dims: [1, total])
            feeds["position_ids"] = try int64Tensor(
                values: (pastKVCount..<(pastKVCount + P + framesPerCall - 1)).map(Int64.init),
                dims: [1, P + framesPerCall - 1])
            feeds["noise"] = try floatTensor(values: noise, dims: [1, framesPerCall, latentDim])
            for (index, value) in kv.enumerated() {
                feeds["past_key_values.\(index / 2).\(index % 2 == 0 ? "key" : "value")"] = value
            }
            feeds["past_key_values.audio_latents"] = latentHistory

            let outputs = try flowSession.run(
                withInputs: feeds,
                outputNames: ["audio_latents", "present.audio_latents", "eos_logits"]
                    + (0..<flowLayers).flatMap { ["present.\($0).key", "present.\($0).value"] },
                runOptions: nil)

            // The flow's audio_latents is the CUMULATIVE latent history,
            // denormalized; only the trailing 8 rows are this call's frames.
            let cumulative = try floatValues(
                outputs["audio_latents"]!, dims: [1, pastKVCount + framesPerCall, latentDim])
            newLatents.append(contentsOf: cumulative[(pastKVCount * latentDim)...])
            let eos = try floatValues(outputs["eos_logits"]!, dims: [1, framesPerCall])
            onCall(call, pastKVCount, eos)

            // KV feedback: keep the latent K/Vs, drop the re-run prompt
            // block [past_kv : past_kv + P) of each present cache.
            let presentTotal = pastKVCount + P + (framesPerCall - 1)
            var newKV: [ORTValue] = []
            newKV.reserveCapacity(flowLayers * 2)
            for index in 0..<(flowLayers * 2) {
                let name = index % 2 == 0 ? "present.\(index / 2).key" : "present.\(index / 2).value"
                let values = try floatValues(outputs[name]!, dims: [1, attentionHeads, presentTotal, headDim])
                let keepHead = pastKVCount
                let keepTail = framesPerCall - 1
                let stride = attentionHeads * headDim
                var kept: [Float] = []
                kept.reserveCapacity((keepHead + keepTail) * stride)
                if keepHead > 0 {
                    kept.append(contentsOf: values[0..<(keepHead * stride)])
                }
                let tailStart = (presentTotal - keepTail) * stride
                kept.append(contentsOf: values[tailStart..<(tailStart + keepTail * stride)])
                newKV.append(try floatTensor(values: kept, dims: [1, attentionHeads, keepHead + keepTail, headDim]))
            }
            kv = newKV
            pastKVCount += framesPerCall - 1
            latentHistory = outputs["present.audio_latents"]!
            latentHistoryCount += framesPerCall

            // EOS countdown — the frame that crossed the threshold and the
            // tail frames are all kept (Python's PocketTTSEosThresholdCriteria).
            var done = false
            for value in eos {
                if countdown == nil && value > eosThreshold {
                    countdown = framesAfterEOS
                } else if countdown != nil {
                    countdown! -= 1
                    done = countdown! <= 0
                }
            }
            if done { break }
        }

        // Windowed decode (decoder rotary ceiling ≈ 500 latents per call).
        var pcm: [Float] = []
        let totalLatents = newLatents.count / latentDim
        var start = 0
        while start < totalLatents {
            let count = min(decodeWindow, totalLatents - start)
            let window = Array(newLatents[(start * latentDim)..<(start * latentDim + count * latentDim)])
            let output = try decodeSession.run(
                withInputs: [
                    "audio_latents": try floatTensor(values: window, dims: [1, count, latentDim]),
                    "num_frames": try int64Tensor(values: [Int64(count)], dims: [1]),
                ],
                outputNames: ["audio_values", "audio_lengths"],
                runOptions: nil)
            let samples = try int64Values(output["audio_lengths"]!, count: 1)[0]
            pcm.append(contentsOf: try floatValues(output["audio_values"]!, dims: [1, 1, Int(samples)]))
            start += count
        }
        return pcm
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Tensor plumbing (shapes tracked by the caller, never read back)

    static func emptyTensor(dims: [Int]) throws -> ORTValue {
        try ORTValue(tensorData: NSMutableData(data: Data()), elementType: .float,
                     shape: dims.map { NSNumber(value: $0) })
    }

    static func int64Tensor(values: [Int64], dims: [Int]) throws -> ORTValue {
        var littleEndian = values
        for index in littleEndian.indices { littleEndian[index] = values[index].littleEndian }
        let data = littleEndian.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Int64>.size)
        }
        return try ORTValue(tensorData: NSMutableData(data: data), elementType: .int64,
                            shape: dims.map { NSNumber(value: $0) })
    }

    static func floatTensor(values: [Float], dims: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        return try ORTValue(tensorData: NSMutableData(data: data), elementType: .float,
                            shape: dims.map { NSNumber(value: $0) })
    }

    static func floatValues(_ value: ORTValue, dims: [Int]) throws -> [Float] {
        let raw = try value.tensorData() as Data
        let expected = dims.reduce(1, *)
        precondition(raw.count == expected * MemoryLayout<Float>.size,
                     "unexpected tensor size \(raw.count) for \(dims)")
        return raw.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Float.self))
        }
    }

    static func int64Values(_ value: ORTValue, count: Int) throws -> [Int64] {
        let raw = try value.tensorData() as Data
        precondition(raw.count == count * MemoryLayout<Int64>.size)
        return raw.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Int64.self)).map { Int64(littleEndian: $0) }
        }
    }

    static func writeWAV(pcm: [Float], to path: String) throws {
        var pcm16 = [Int16](repeating: 0, count: pcm.count)
        for index in pcm.indices {
            pcm16[index] = Int16(max(-32768, min(32767, Int(pcm[index] * 32767))))
        }
        let sampleRate = UInt32(sampleRate)
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + pcm16.count * 2))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(16); append16(1); append16(1)
        append(sampleRate); append(sampleRate * 2); append16(2); append16(16)
        data.append("data".data(using: .ascii)!)
        append(UInt32(pcm16.count * 2))
        pcm16.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}

/// Box-Muller standard normal from a seeded SplitMix64 — deterministic
/// across runs so spike failures are reproducible.
struct SeededGenerator {
    private var state: UInt64
    private var hasSpare = false
    private var spare: Float = 0

    init(seed: UInt64) {
        self.state = seed
    }

    private mutating func nextUniform() -> Float {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Float(z >> 11) / Float(1 << 53)
    }

    mutating func next() -> Float {
        if hasSpare {
            hasSpare = false
            return spare
        }
        let u1 = max(nextUniform(), 1e-12)
        let u2 = nextUniform()
        let magnitude = sqrt(-2 * log(1 - u1))
        spare = magnitude * cos(2 * Float.pi * u2)
        hasSpare = true
        return magnitude * sin(2 * Float.pi * u2)
    }
}

extension Float {
    static func standardNormal(using generator: inout SeededGenerator) -> Float {
        generator.next()
    }
}
