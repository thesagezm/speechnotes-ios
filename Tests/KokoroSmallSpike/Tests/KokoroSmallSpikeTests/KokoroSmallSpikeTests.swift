import XCTest
import OnnxRuntimeBindings
import SpeechLogic

/// CI spike: proves the small Kokoro tier (uint8, ~177 MB) runs on ONNX
/// Runtime CPU before any device build — the model loads, the
/// input_ids/style/speed contract holds, tokenizer.json's vocab accepts the
/// app's per-character lookup, and the output is audible-length non-silent
/// audio written as a WAV. This gate caught the fp16 variant producing NaN
/// on ORT CPU (CI 34008548349) — the proven uint8 build ships instead.
final class KokoroSmallSpikeTests: XCTestCase {

    func testGenerateSpeech() throws {
        let env = ProcessInfo.processInfo.environment
        let modelPath = env["KOKORO_MODEL"] ?? NSHomeDirectory() + "/kokoro-small-spike/model_uint8.onnx"
        let voicePath = env["KOKORO_VOICE"] ?? NSHomeDirectory() + "/kokoro-small-spike/voice.f32"
        let tokenizerPath = env["KOKORO_TOKENIZER"] ?? NSHomeDirectory() + "/kokoro-small-spike/tokenizer.json"
        let outPath = env["KOKORO_OUT"] ?? NSHomeDirectory() + "/kokoro-small-spike/sample.wav"

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: modelPath), "model missing at \(modelPath)")
        XCTAssertTrue(fm.fileExists(atPath: voicePath), "voice matrix missing at \(voicePath)")
        XCTAssertTrue(fm.fileExists(atPath: tokenizerPath), "tokenizer missing at \(tokenizerPath)")

        // Voice matrix: the full [rows, 256] float32 bank for one voice —
        // the engine slices row clamp(N-2, 0, rows-1) per inference.
        let voiceData = try Data(contentsOf: URL(fileURLWithPath: voicePath))
        let voiceFlat = voiceData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        let rows = voiceFlat.count / 256
        XCTAssertTrue(rows >= 100, "expected a multi-row style matrix, got \(rows) rows")

        // Tokenizer: exactly the app's per-character vocab lookup.
        let tokenizerData = try Data(contentsOf: URL(fileURLWithPath: tokenizerPath))
        let json = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any]
        let vocab = (json?["model"] as? [String: Any])?["vocab"] as? [String: Int]
        XCTAssertNotNil(vocab, "tokenizer.json has no model.vocab")
        XCTAssertGreaterThan(vocab!.count, 100)

        // espeak-style IPA for "Hello world, this is the small Kokoro test."
        // — the same dialect MisakiSwift emits in the app. Unknown
        // characters are dropped, exactly like OnnxKokoroEngine.tokenize.
        let phonemes = "həlˈoʊ wˈɜːld, ðɪs ɪz ðə smˈɔːl kəkˈoʊɹoʊ spˈiːkɪŋ tˈɛst."
        let tokens = phonemes.map { vocab?[String($0)] }.compactMap { $0 }
        print("KOKORO-SMALL-SPIKE tokens (\(tokens.count)) from \(phonemes.count) phoneme chars")
        XCTAssertGreaterThan(tokens.count, 20, "vocab rejected nearly every phoneme char")
        XCTAssertLessThanOrEqual(tokens.count, 510, "exceeds the model's max token window")

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        let session = try ORTSession(env: ortEnv, modelPath: modelPath, sessionOptions: options)

        let inputNames = (try? session.inputNames()) ?? []
        let outputNames = (try? session.outputNames()) ?? []
        print("KOKORO-SMALL-SPIKE inputs: \(inputNames) outputs: \(outputNames)")
        XCTAssertTrue(inputNames.contains("input_ids"), "expected input_ids, got \(inputNames)")
        XCTAssertTrue(inputNames.contains("style"), "expected style, got \(inputNames)")
        XCTAssertTrue(inputNames.contains("speed"), "expected speed, got \(inputNames)")
        let outputName = outputNames.contains("waveform") ? "waveform" : (outputNames.first ?? "waveform")

        let adjusted = min(max(tokens.count - 2, 0), rows - 1)
        let style = Array(voiceFlat[(adjusted * 256)..<((adjusted + 1) * 256)])

        let tokens64 = tokens.map(Int64.init)
        let tokensTensor = try ORTValue(
            tensorData: NSMutableData(bytes: tokens64, length: tokens64.count * MemoryLayout<Int64>.size),
            elementType: .int64,
            shape: [1, NSNumber(value: tokens.count)]
        )
        let styleTensor = try ORTValue(
            tensorData: NSMutableData(bytes: style, length: style.count * MemoryLayout<Float>.size),
            elementType: .float,
            shape: [1, NSNumber(value: 256)]
        )
        var speedValue: Float = 1.0
        let speedTensor = try ORTValue(
            tensorData: NSMutableData(bytes: &speedValue, length: MemoryLayout<Float>.size),
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
            outputNames: [outputName],
            runOptions: nil
        )
        let elapsed = Date().timeIntervalSince(started)

        let raw = try outputs[outputName]!.tensorData()
        let samples = (raw as Data).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        let seconds = Double(samples.count) / 24_000.0
        print("KOKORO-SMALL-SPIKE \(samples.count) samples = \(String(format: "%.2f", seconds))s audio in \(String(format: "%.2f", elapsed))s")
        XCTAssertGreaterThan(seconds, 1.0, "output too short to be real speech")
        let peak = samples.map { abs($0) }.max() ?? 0
        print("KOKORO-SMALL-SPIKE peak amplitude \(peak)")
        XCTAssertGreaterThan(peak, 0.01, "output is silence — the graph produced nothing")

        try WAVWriter.write(samples: samples, sampleRate: 24_000, to: URL(fileURLWithPath: outPath))
    }
}
