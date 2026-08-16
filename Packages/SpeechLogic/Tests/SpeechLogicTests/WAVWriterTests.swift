//
//  WAVWriterTests.swift
//  SpeechLogicTests
//
//  XCTest coverage for WAVWriter: canonical 44-byte header layout,
//  Float → Int16 quantization round-trips, out-of-range clamping, NaN
//  handling, empty input, odd sample counts, and on-disk byte fidelity.
//

import XCTest
@testable import SpeechLogic

final class WAVWriterTests: XCTestCase {

    // MARK: - Fixtures

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WAVWriterTests-\(UUID().uuidString).wav")
    }

    override func tearDown() {
        if let fileURL = fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        super.tearDown()
    }

    // MARK: - Header correctness

    func testHeaderFields() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let data = WAVWriter.wavData(samples: samples, sampleRate: 24000)

        // Total size: 44-byte canonical header + 2 bytes per sample.
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(data.count, 54)

        XCTAssertEqual(magic(data, at: 0), "RIFF")
        XCTAssertEqual(u32(data, at: 4), 46)      // RIFF chunk size: 36 + dataSize
        XCTAssertEqual(magic(data, at: 8), "WAVE")
        XCTAssertEqual(magic(data, at: 12), "fmt ")
        XCTAssertEqual(u32(data, at: 16), 16)     // fmt chunk size
        XCTAssertEqual(u16(data, at: 20), 1)      // audio format: PCM
        XCTAssertEqual(u16(data, at: 22), 1)      // num channels: mono
        XCTAssertEqual(u32(data, at: 24), 24000)  // sample rate
        XCTAssertEqual(u32(data, at: 28), 48000)  // byte rate: sampleRate * 2
        XCTAssertEqual(u16(data, at: 32), 2)      // block align
        XCTAssertEqual(u16(data, at: 34), 16)     // bits per sample
        XCTAssertEqual(magic(data, at: 36), "data")
        XCTAssertEqual(u32(data, at: 40), 10)     // dataSize: 5 samples * 2 bytes
    }

    // MARK: - Sample round-trip

    func testSampleRoundTrip() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let data = WAVWriter.wavData(samples: samples, sampleRate: 24000)

        XCTAssertEqual(int16Sample(data, at: 0), 0)

        // 0.5 * 32767 = 16383.5; truncation encodes 16383, rounding 16384.
        // Accept either (tolerance ±1).
        let positiveHalf = int16Sample(data, at: 1)
        XCTAssertTrue(positiveHalf == 16383 || positiveHalf == 16384,
                      "expected 16383 or 16384, got \(positiveHalf)")

        let negativeHalf = int16Sample(data, at: 2)
        XCTAssertTrue(negativeHalf == -16383 || negativeHalf == -16384,
                      "expected -16383 or -16384, got \(negativeHalf)")

        XCTAssertEqual(int16Sample(data, at: 3), 32767)

        // -1.0 * 32767 = -32767 exactly; implementations that scale by 32768
        // instead produce the full-scale negative -32768. Accept either
        // (tolerance ±1).
        let negativeFullScale = int16Sample(data, at: 4)
        XCTAssertTrue(negativeFullScale == -32767 || negativeFullScale == -32768,
                      "expected -32767 or -32768, got \(negativeFullScale)")
    }

    // MARK: - Clamping

    func testClampingOutOfRangeSamples() {
        let data = WAVWriter.wavData(samples: [2.0, -2.0, 10.0, -10.0], sampleRate: 24000)

        XCTAssertEqual(int16Sample(data, at: 0), 32767)
        XCTAssertEqual(int16Sample(data, at: 1), -32768)
        XCTAssertEqual(int16Sample(data, at: 2), 32767)
        XCTAssertEqual(int16Sample(data, at: 3), -32768)
    }

    // MARK: - NaN handling

    func testNaNSampleEncodesAsSilence() {
        let data = WAVWriter.wavData(samples: [.nan, 0.25, .nan], sampleRate: 24000)

        XCTAssertEqual(int16Sample(data, at: 0), 0)
        XCTAssertEqual(int16Sample(data, at: 2), 0)

        // Sanity: neighboring, valid samples are unaffected by the NaNs.
        XCTAssertGreaterThan(int16Sample(data, at: 1), 0)
    }

    // MARK: - Empty input

    func testEmptySamplesProduceBareHeader() {
        let data = WAVWriter.wavData(samples: [], sampleRate: 24000)

        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(magic(data, at: 0), "RIFF")
        XCTAssertEqual(u32(data, at: 4), 36)  // 36 + 0 data bytes
        XCTAssertEqual(magic(data, at: 8), "WAVE")
        XCTAssertEqual(magic(data, at: 36), "data")
        XCTAssertEqual(u32(data, at: 40), 0)
    }

    // MARK: - File writing

    func testWriteCreatesFileWithIdenticalBytes() throws {
        let samples: [Float] = [0.25, -0.75, 0.9, -0.1, 0]
        let expected = WAVWriter.wavData(samples: samples, sampleRate: 24000)

        try WAVWriter.write(samples: samples, sampleRate: 24000, to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let readBack = try Data(contentsOf: fileURL)
        XCTAssertEqual(readBack, expected)
        XCTAssertEqual(readBack.count, 44 + samples.count * 2)
        XCTAssertEqual(magic(readBack, at: 0), "RIFF")
    }

    // MARK: - Non-multiple-of-word sizes

    func testOddSampleCountYieldsEvenDataSize() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        let data = WAVWriter.wavData(samples: samples, sampleRate: 22050)

        XCTAssertEqual(u32(data, at: 40), 14)   // dataSize: 7 samples * 2 bytes (always even)
        XCTAssertEqual(u32(data, at: 4), 50)    // RIFF chunk size: 36 + 14
        XCTAssertEqual(data.count, 58)          // 44-byte header + 14 data bytes

        // A non-default sample rate flows through correctly.
        XCTAssertEqual(u32(data, at: 24), 22050)
        XCTAssertEqual(u32(data, at: 28), 44100)
    }

    // MARK: - Little-endian decoding helpers

    /// Reads the 4-byte ASCII magic string at `offset`.
    private func magic(_ data: Data, at offset: Int) -> String {
        String(bytes: Array(data.subdata(in: offset..<(offset + 4))), encoding: .ascii) ?? "<invalid>"
    }

    /// Reads the little-endian `UInt16` at `offset`.
    private func u16(_ data: Data, at offset: Int) -> UInt16 {
        let b = Array(data.subdata(in: offset..<(offset + 2)))
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    /// Reads the little-endian `UInt32` at `offset`.
    private func u32(_ data: Data, at offset: Int) -> UInt32 {
        let b = Array(data.subdata(in: offset..<(offset + 4)))
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    /// Decodes the `Int16` PCM sample at `index` (0-based) of the data chunk.
    private func int16Sample(_ data: Data, at index: Int) -> Int16 {
        Int16(bitPattern: u16(data, at: 44 + index * 2))
    }
}
