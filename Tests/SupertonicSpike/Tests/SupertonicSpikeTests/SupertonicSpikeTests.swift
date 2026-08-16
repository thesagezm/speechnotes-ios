import XCTest
import OnnxRuntimeBindings
import SpeechLogic

/// CI spike: proves the Supertone/supertonic-3 ONNX contract on the macOS
/// runner before any device work (blueprint: Docs/SUPERTONIC-PORT.md).
/// Helper.swift — the vendored, unmodified upstream file — is copied into
/// this directory by the workflow step right before `swift test`, so the
/// spike always exercises the exact code the app ships.
///
/// Asserts: assets present, sessions + unicode indexer load, `call` produces
/// ≥1 s of non-silent audio at the config sample rate. Prints (non-gating):
/// sample rate, real-time factor, and RSS of the xctest process before
/// load / after load / after generation — the A14 memory-headroom signal.
final class SupertonicSpikeTests: XCTestCase {

    /// Resident set of *this* xctest process in MB via ps — the 4 ORT
    /// sessions live here, so their cost shows up in this number.
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

    func testGenerateSpeech() throws {
        let env = ProcessInfo.processInfo.environment
        let onnxDir = env["SUPERTONIC_DIR"] ?? NSHomeDirectory() + "/supertonic-spike/onnx"
        let stylesDir = env["SUPERTONIC_STYLES"] ?? NSHomeDirectory() + "/supertonic-spike/voice_styles"
        let outPath = env["SUPERTONIC_OUT"] ?? NSHomeDirectory() + "/supertonic-spike/sample.wav"

        let fm = FileManager.default
        for file in ["duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx",
                     "vocoder.onnx", "tts.json", "unicode_indexer.json"] {
            let path = onnxDir + "/" + file
            XCTAssertTrue(fm.fileExists(atPath: path), "missing \(path)")
        }
        let stylePath = stylesDir + "/M1.json"
        XCTAssertTrue(fm.fileExists(atPath: stylePath), "missing \(stylePath)")

        let rss0 = rssMB()
        print("SUPERTONIC-SPIKE rss before load: \(String(format: "%.0f", rss0)) MB")

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let tts = try loadTextToSpeech(onnxDir, false, ortEnv)
        print("SUPERTONIC-SPIKE sampleRate=\(tts.sampleRate)")
        XCTAssertGreaterThan(tts.sampleRate, 8_000, "implausible sample rate from tts.json")

        let style = try loadVoiceStyle([stylePath], verbose: true)

        let rss1 = rssMB()
        print("SUPERTONIC-SPIKE rss after load: \(String(format: "%.0f", rss1)) MB (+\(String(format: "%.0f", rss1 - rss0)))")

        // Upstream ExampleONNX default text — same reference sentence, so the
        // sample is comparable with upstream results.
        let text = "This morning, I took a walk in the park, and the sound of the birds and the breeze was so pleasant that I stopped for a long time just to listen."

        let started = Date()
        let result = try tts.call(text, "en", style, 8, speed: 1.05, silenceDuration: 0.3)
        let elapsed = Date().timeIntervalSince(started)

        let rss2 = rssMB()
        print("SUPERTONIC-SPIKE rss after generate: \(String(format: "%.0f", rss2)) MB (+\(String(format: "%.0f", rss2 - rss1)))")

        // call() returns the padded/predicted-length wav; trim to the
        // duration the duration-predictor actually asked for (same rule as
        // upstream's example writer).
        let actualLen = Int(Float(tts.sampleRate) * result.duration)
        let samples = Array(result.wav.prefix(max(actualLen, 1)))

        let duration = Double(samples.count) / Double(tts.sampleRate)
        var sumSquares: Double = 0
        for sample in samples { sumSquares += Double(sample) * Double(sample) }
        let rms = sqrt(sumSquares / Double(max(1, samples.count)))
        let rtf = elapsed / max(duration, 0.001)
        print("SUPERTONIC-SPIKE duration=\(String(format: "%.2f", duration))s rtf=\(String(format: "%.3f", rtf)) rms=\(String(format: "%.4f", rms)) wavRaw=\(result.wav.count) trimmed=\(samples.count)")

        XCTAssertGreaterThan(duration, 1.0, "expected at least 1s of audio")
        XCTAssertGreaterThan(rms, 0.005, "audio looks silent")

        try WAVWriter.write(samples: samples, sampleRate: tts.sampleRate, to: URL(fileURLWithPath: outPath))
        print("SUPERTONIC-SPIKE wrote \(outPath)")
    }
}
