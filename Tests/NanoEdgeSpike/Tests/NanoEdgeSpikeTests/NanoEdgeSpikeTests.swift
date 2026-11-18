import XCTest
import OnnxRuntimeBindings
import SpeechLogic

/// CI spike: proves the nano-edge-tts ONNX contract on the vendored ORT
/// 1.24.2 before any device work — the blueprint is Docs/NANO-EDGE-PORT.md,
/// pinned empirically by the Linux app's sn-tts runtime (sn-tts/src/
/// nano_edge.rs) and mirrored here against the exact SPM binary the iOS
/// app links. The question under test is the two-graph handoff: the text
/// side's dynamo export keeps the frame axis symbolic, so a short and a
/// long phoneme stream must travel the SAME sessions with only the frame
/// count moving between them — plus the decoder's four-tensor call
/// (asr [1,512,T], f0/n [1,F], s [1,128]) accepting that shape family.
///
/// The phoneme front end is NOT under test here (Misaki G2P is the app's
/// job and the kokoro path's): the spike feeds a fixed IPA string through
/// the real vocab lookup, exactly as the engine does, with the same
/// unknown→space substitution.
///
/// Asserts: files present, both sessions load, the vocab parses, both
/// lengths produce finite audible 24 kHz audio. Prints (non-gating): RTF
/// and RSS of the xctest process.
final class NanoEdgeSpikeTests: XCTestCase {

    /// Resident set of *this* xctest process in MB via ps.
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

    // MARK: - Contract constants (Docs/NANO-EDGE-PORT.md)

    static let sampleRate = 24_000
    static let styleDim = 256
    static let decoderStyleDim = 128
    static let asrDim = 512
    /// The creak-noise window's precomputed frame count (the f0 axis).
    static let maxFrames = 16_384

    func testTwoGraphChainProducesAudio() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = env["NANO_EDGE_DIR"] ?? NSHomeDirectory() + "/nano-edge-spike"
        let outPath = env["NANO_EDGE_OUT"] ?? dir + "/sample.wav"

        let fm = FileManager.default
        for file in ["text-side.onnx", "nano-decoder.onnx", "tokenizer.json"] {
            XCTAssertTrue(fm.fileExists(atPath: dir + "/" + file), "missing \(dir)/\(file)")
        }
        let voicePath = dir + "/voices/af_heart.bin"
        XCTAssertTrue(fm.fileExists(atPath: voicePath), "missing \(voicePath)")

        let rss0 = rssMB()
        print("NANO-EDGE-SPIKE rss before load: \(String(format: "%.0f", rss0)) MB")

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let threadCap = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 6))
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(threadCap)
        let textSession = try ORTSession(env: ortEnv, modelPath: dir + "/text-side.onnx", sessionOptions: options)
        let decoderSession = try ORTSession(env: ortEnv, modelPath: dir + "/nano-decoder.onnx", sessionOptions: options)

        let tokenizerData = try Data(contentsOf: URL(fileURLWithPath: dir + "/tokenizer.json"))
        let tokenizerJSON = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any]
        let vocab = (tokenizerJSON?["model"] as? [String: Any])?["vocab"] as? [String: Int] ?? [:]
        XCTAssertGreaterThan(vocab.count, 100, "tokenizer.json has no usable vocab")
        let spaceID = vocab[" "] ?? 16

        let voiceData = try Data(contentsOf: URL(fileURLWithPath: voicePath))
        let bytesPerRow = Self.styleDim * MemoryLayout<Float>.size
        XCTAssertGreaterThan(voiceData.count, 0)
        XCTAssertEqual(voiceData.count % bytesPerRow, 0, "voice bank is not whole rows of 256 f32")
        let voiceBank = voiceData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        let rows = voiceBank.count / Self.styleDim
        print("NANO-EDGE-SPIKE voice bank: \(rows) rows")

        let rss1 = rssMB()
        print("NANO-EDGE-SPIKE rss after load: \(String(format: "%.0f", rss1)) MB (+\(String(format: "%.0f", rss1 - rss0)))")

        // Two lengths through the SAME sessions — the dynamic frame axis
        // the export kept symbolic must hold at runtime (the Rust port's
        // own test does the same pair).
        let short = "həloʊ fɹʌm ðə nano tɪɹ."
        let long = "ðə dɪkɑdəɹ ðæt mɛɪd ðɪs ɪz ə tɪni wʌn, ænd ðə tɛkst saɪd ɪz ðə wʌn ðə æp ɔlɹɛdi ɹʌnz, soʊ ə lɑŋ sɛntəns ænd ə ʃɔɹt wʌn tɹævəl ðə seɪm tuː ɡɹæfs wɪð ðə fɹeɪm kaʊnt æz ðə oʊnli θɪŋ ðæt muːvz bətwiːn ðɛm."
        let shortStarted = Date()
        let shortSamples = try Self.speak(
            phonemes: short, vocab: vocab, spaceID: spaceID, voiceBank: voiceBank,
            textSession: textSession, decoderSession: decoderSession)
        let shortElapsed = Date().timeIntervalSince(shortStarted)
        let longStarted = Date()
        let longSamples = try Self.speak(
            phonemes: long, vocab: vocab, spaceID: spaceID, voiceBank: voiceBank,
            textSession: textSession, decoderSession: decoderSession)
        let longElapsed = Date().timeIntervalSince(longStarted)
        XCTAssertGreaterThan(longSamples.count, shortSamples.count,
                             "the longer phoneme stream produced no more audio")

        try Self.writeWAV(samples: longSamples, to: outPath)
        print("NANO-EDGE-SPIKE sample written: \(outPath)")

        let rss2 = rssMB()
        print("NANO-EDGE-SPIKE rss after generate: \(String(format: "%.0f", rss2)) MB (+\(String(format: "%.0f", rss2 - rss1)))")
        let audioSeconds = Double(longSamples.count) / Double(Self.sampleRate)
        print("NANO-EDGE-SPIKE audio=\(String(format: "%.1f", audioSeconds))s "
              + "rtf=\(String(format: "%.3f", longElapsed / audioSeconds)) elapsed=\(String(format: "%.2f", longElapsed))s "
              + "short=\(String(format: "%.2f", shortElapsed))s")

        // Contract bars: finite, audible, length-plausible.
        XCTAssertTrue(longSamples.allSatisfy { $0.isFinite }, "non-finite samples")
        var sumSquares = 0.0
        for sample in longSamples { sumSquares += Double(sample) * Double(sample) }
        let rms = sqrt(sumSquares / Double(max(1, longSamples.count)))
        print("NANO-EDGE-SPIKE rms=\(String(format: "%.4f", rms)) peak=\(String(format: "%.3f", longSamples.map { abs($0) }.max() ?? 0))")
        XCTAssertGreaterThan(rms, 0.01, "audio is silent")
        XCTAssertGreaterThan(audioSeconds, 0.5, "too little audio for the reference stream")
    }

    // MARK: - The pinned recipe (mirror of Docs/NANO-EDGE-PORT.md)

    /// The engine's front end minus Misaki: clean the echo-back characters,
    /// per-char vocab lookup, unknown → space. Returns the ids AND the
    /// pre-tokenization phoneme count (the style row keys on it).
    static func tokenize(_ phonemes: String, vocab: [String: Int], spaceID: Int) -> ([Int], Int) {
        let cleaned = phonemes
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "'", with: " ")
        let phonemeChars = cleaned.unicodeScalars.count
        var ids: [Int] = []
        ids.reserveCapacity(phonemeChars)
        for scalar in cleaned.unicodeScalars {
            ids.append(vocab[String(scalar)] ?? spaceID)
        }
        return (ids, phonemeChars)
    }

    /// The two-graph chain: text side (ids + style row + speed) →
    /// asr/f0/n/s → decoder → waveform. Shapes are derived from element
    /// counts, exactly like the engine.
    static func speak(
        phonemes: String,
        vocab: [String: Int],
        spaceID: Int,
        voiceBank: [Float],
        textSession: ORTSession,
        decoderSession: ORTSession
    ) throws -> [Float] {
        let (tokens, phonemeChars) = tokenize(phonemes, vocab: vocab, spaceID: spaceID)
        XCTAssertGreaterThan(tokens.count, 1, "tokenization emptied the phoneme stream")
        XCTAssertLessThanOrEqual(tokens.count, 510, "stream past the chunk cap")
        print("NANO-EDGE-SPIKE \(phonemeChars) phoneme chars → \(tokens.count) tokens")

        // Style row by length, on the pre-tokenization count.
        let rows = max(1, voiceBank.count / styleDim)
        let adjusted = min(max(phonemeChars - 1, 0), rows - 1)
        let style = Array(voiceBank[(adjusted * styleDim)..<((adjusted + 1) * styleDim)])

        let textOutputs = try textSession.run(
            withInputs: [
                "input_ids": try int64Tensor(values: tokens.map(Int64.init), dims: [1, tokens.count]),
                "style": try floatTensor(values: style, dims: [1, styleDim]),
                "speed": try floatTensor(values: [1.0], dims: [1]),
            ],
            outputNames: ["asr", "f0", "n", "s"],
            runOptions: nil)
        let asr = try floatValues(textOutputs["asr"])
        let f0 = try floatValues(textOutputs["f0"])
        let n = try floatValues(textOutputs["n"])
        let s = try floatValues(textOutputs["s"])

        let asrFrames = asr.count / asrDim
        let f0Frames = f0.count
        print("NANO-EDGE-SPIKE asr frames \(asrFrames), f0 frames \(f0Frames)")
        XCTAssertEqual(f0Frames, n.count, "f0/n frame counts disagree")
        XCTAssertGreaterThan(asrFrames, 0)
        XCTAssertLessThanOrEqual(f0Frames, maxFrames, "frame count past the creak-noise window")

        let decoderOutputs = try decoderSession.run(
            withInputs: [
                "asr": try floatTensor(values: asr, dims: [1, asrDim, asrFrames]),
                "f0": try floatTensor(values: f0, dims: [1, f0Frames]),
                "n": try floatTensor(values: n, dims: [1, f0Frames]),
                "s": try floatTensor(values: s, dims: [1, decoderStyleDim]),
            ],
            outputNames: ["waveform"],
            runOptions: nil)
        let samples = try floatValues(decoderOutputs["waveform"])
        XCTAssertFalse(samples.isEmpty, "decoder produced no samples")
        return samples
    }

    // MARK: - Tensor plumbing (same helpers as the engine)

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

    static func floatValues(_ value: ORTValue?) throws -> [Float] {
        let raw = try XCTUnwrap(value).tensorData() as Data
        return raw.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Float.self))
        }
    }

    /// Hand-rolled 44-byte RIFF writer — the same one PhononSpike ships
    /// (SpeechLogic's StreamingWriter is nested inside WAVWriter and the
    /// spike has no business reaching into it).
    static func writeWAV(samples: [Float], to path: String) throws {
        var pcm16 = [Int16](repeating: 0, count: samples.count)
        for index in pcm16.indices {
            pcm16[index] = Int16(max(-32768, min(32767, Int(samples[index] * 32767))))
        }
        let rate = UInt32(sampleRate)
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + pcm16.count * 2))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(16); append16(1); append16(1)
        append(rate); append(rate * 2); append16(2); append16(16)
        data.append("data".data(using: .ascii)!)
        append(UInt32(pcm16.count * 2))
        pcm16.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
