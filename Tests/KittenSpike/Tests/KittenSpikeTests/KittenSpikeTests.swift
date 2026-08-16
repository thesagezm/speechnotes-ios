import XCTest
import OnnxRuntimeBindings
import SpeechLogic

/// CI spike: proves the KittenTTS nano ONNX contract on the macOS runner
/// before any device build — model loads, inputs are `input_ids`/`style`/
/// `speed`, our byte-exact KittenTokenizer produces accepted ids, and the
/// output is audible-length non-silent audio. No MLX/Misaki here: phonemes
/// are hardcoded (espeak en-us dialect) to keep the spike dependency-free.
final class KittenSpikeTests: XCTestCase {

    func testGenerateSpeech() throws {
        let env = ProcessInfo.processInfo.environment
        let modelPath = env["KITTEN_MODEL"] ?? NSHomeDirectory() + "/kitten-spike/model.onnx"
        let voicePath = env["KITTEN_VOICE"] ?? NSHomeDirectory() + "/kitten-spike/voice.f32"
        let outPath = env["KITTEN_OUT"] ?? NSHomeDirectory() + "/kitten-spike/sample.wav"

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: modelPath), "model missing at \(modelPath)")
        XCTAssertTrue(fm.fileExists(atPath: voicePath), "voice vector missing at \(voicePath)")

        // Voice vector: 256 float32 little-endian (1024 bytes), pre-extracted
        // from voices.npz by the workflow.
        let voiceData = try Data(contentsOf: URL(fileURLWithPath: voicePath))
        XCTAssertEqual(voiceData.count, 256 * 4, "voice file must be exactly one 256-float row")
        let style = voiceData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        let session = try ORTSession(env: ortEnv, modelPath: modelPath, sessionOptions: options)

        let inputNames = (try? session.inputNames()) ?? []
        print("KITTEN-SPIKE inputs: \(inputNames)")
        let outputNames = (try? session.outputNames()) ?? []
        print("KITTEN-SPIKE outputs: \(outputNames)")
        XCTAssertTrue(inputNames.contains("input_ids"), "expected input_ids, got \(inputNames)")
        XCTAssertTrue(inputNames.contains("style"), "expected style, got \(inputNames)")
        XCTAssertTrue(inputNames.contains("speed"), "expected speed, got \(inputNames)")

        // espeak en-us phonemes for "Hello world, this is Kitten." —
        // the same dialect MisakiSwift emits in the app.
        let phonemes = "həloʊ wɜːld, ðɪs ɪz kɪtən."
        let tokens = KittenTokenizer.tokenize(phonemes)
        print("KITTEN-SPIKE tokens (\(tokens.count)): \(tokens)")
        XCTAssertGreaterThan(tokens.count, 10)
        XCTAssertEqual(tokens.first, KittenTokenizer.bosToken)
        XCTAssertEqual(tokens.suffix(2), KittenTokenizer.eosTokens)

        let tokens64 = tokens.map(Int64.init)
        let tokensData = NSMutableData(bytes: tokens64, length: tokens64.count * MemoryLayout<Int64>.size)
        var speedValue: Float = 1.0
        let speedData = NSMutableData(bytes: &speedValue, length: MemoryLayout<Float>.size)

        let tokensTensor = try ORTValue(
            tensorData: tokensData,
            elementType: .int64,
            shape: [1, NSNumber(value: tokens.count)]
        )
        let styleTensor = try ORTValue(
            tensorData: NSMutableData(bytes: style, length: style.count * MemoryLayout<Float>.size),
            elementType: .float,
            shape: [1, 256]
        )
        let speedTensor = try ORTValue(
            tensorData: speedData,
            elementType: .float,
            shape: [1]
        )

        let started = Date()
        let outputs = try session.run(
            withInputs: [
                "input_ids": tokensTensor,
                "style": styleTensor,
                "speed": speedTensor,
            ],
            outputNames: Set(outputNames),
            runOptions: nil
        )
        guard let waveform = outputs[outputNames.first ?? ""] else {
            XCTFail("no output tensor")
            return
        }
        let raw = try waveform.tensorData() as Data
        var samples = raw.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Float.self))
        }
        let elapsed = Date().timeIntervalSince(started)
        print("KITTEN-SPIKE raw samples: \(samples.count)")

        // Reference trims the trailing 5,000 samples.
        if samples.count > 5_000 {
            samples = Array(samples[0..<(samples.count - 5_000)])
        }
        let duration = Double(samples.count) / 24_000
        var sumSquares: Double = 0
        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }
        let rms = sqrt(sumSquares / Double(max(1, samples.count)))
        let durationText = String(format: "%.2f", duration)
        let rtf = elapsed / max(duration, 0.001)
        let rtfText = String(format: "%.3f", rtf)
        let rmsText = String(format: "%.4f", rms)
        print("KITTEN-SPIKE duration=\(durationText)s rtf=\(rtfText) rms=\(rmsText)")

        XCTAssertGreaterThan(samples.count, 24_000, "expected at least 1s of audio")
        XCTAssertGreaterThan(rms, 0.005, "audio looks silent")

        try WAVWriter.write(samples: samples, sampleRate: 24_000, to: URL(fileURLWithPath: outPath))
        print("KITTEN-SPIKE wrote \(outPath)")
    }
}
