import XCTest
import KokoroSwift
import MLX
import MLXUtilsLibrary
import Metal

/// Phase 2 spike: proves the full Kokoro pipeline (model + voices + G2P + MLX)
/// runs on Apple silicon and produces audible speech. Runs on CI (macOS),
/// writes sample.wav next to the model files so CI can upload it as an artifact.
final class KokoroSpikeTests: XCTestCase {
    private var modelDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("kokoro-spike")
    }

    func testGenerateSpeech() throws {
        // Environment diagnostics — lets a failure in the log explain itself.
        let device = MTLCreateSystemDefaultDevice()
        print("KOKORO-SPIKE metal-device=\(device?.name ?? "NONE")")
        for name in ["kokoro-v1_0.safetensors", "voices.npz"] {
            let url = modelDir.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            print("KOKORO-SPIKE file=\(name) size=\(size)")
        }

        let modelPath = modelDir.appendingPathComponent("kokoro-v1_0.safetensors")
        let voicesURL = modelDir.appendingPathComponent("voices.npz")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: modelPath.path),
            "missing model file: \(modelPath.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: voicesURL.path),
            "missing voices file: \(voicesURL.path)"
        )

        let voices = try XCTUnwrap(NpyzReader.read(fileFromPath: voicesURL), "voices.npz failed to parse")
        XCTAssertGreaterThan(voices.count, 10, "expected a voice bank, got \(voices.count) entries")
        print("KOKORO-SPIKE voices available: \(voices.keys.sorted().joined(separator: ", "))")

        // Eric is the user's pick; fall back to whatever the bank contains.
        let voiceKey = voices.keys.first { $0.hasPrefix("am_eric") }
            ?? voices.keys.sorted().first
        let voice = try XCTUnwrap(voices[voiceKey!], "voice \(voiceKey!) missing")

        let tts = KokoroTTS(modelPath: modelPath)
        let text = "Hello! This is Speechnotes iOS, speaking with Kokoro, entirely on device."

        let started = Date()
        let (audio, _) = try tts.generateAudio(voice: voice, language: .enUS, text: text)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(audio.count, 1000, "generated audio is suspiciously short")
        let peak = audio.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.05, "generated audio is silent")

        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        let duration = Double(audio.count) / sampleRate
        let rtf = elapsed / duration
        print("KOKORO-SPIKE voice=\(voiceKey!) samples=\(audio.count) rate=\(Int(sampleRate)) "
              + "audioSeconds=\(String(format: "%.2f", duration)) "
              + "generateSeconds=\(String(format: "%.2f", elapsed)) "
              + "realTimeFactor=\(String(format: "%.2f", rtf))")

        let wavURL = modelDir.appendingPathComponent("sample.wav")
        try WavWriter.writeMono16Bit(samples: audio, sampleRate: Int(sampleRate), to: wavURL)
        print("KOKORO-SPIKE wrote \(wavURL.path)")

        XCTAssertLessThan(rtf, 10.0, "generation unexpectedly slow (rtf \(rtf))")
    }
}
