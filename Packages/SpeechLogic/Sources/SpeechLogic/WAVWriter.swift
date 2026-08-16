//
//  WAVWriter.swift
//  SpeechLogic
//
//  Encodes mono Float32 PCM buffers (Kokoro neural TTS output, 24 kHz) as
//  canonical 16-bit PCM WAV files. This is the export path for the Share
//  Sheet: rendered speech is packaged into a self-contained .wav that other
//  apps and the system Files app can open without any proprietary container.
//

import Foundation

/// Caseless namespace for writing canonical 16-bit PCM WAV files from mono
/// `Float32` sample buffers. Cannot be instantiated.
public enum WAVWriter {

    /// Byte length of the canonical RIFF/WAVE header this writer emits
    /// (12-byte RIFF descriptor + 24-byte "fmt " subchunk + 8-byte "data"
    /// subchunk header).
    private static let headerByteCount = 44

    // MARK: - Public API

    /// Builds a complete WAV file in memory.
    ///
    /// The result is a canonical 44-byte RIFF/WAVE header followed by the
    /// encoded samples:
    /// PCM audio format (1), mono (1 channel), 16 bits per sample, all
    /// multi-byte integer fields little-endian.
    ///
    /// Each sample is converted to `Int16` by multiplying by 32767 and
    /// clamping to the range `[-32768, 32767]`; `NaN` samples are encoded
    /// as silence (`0`).
    ///
    /// - Parameters:
    ///   - samples: Mono `Float32` samples, nominally in `[-1, 1]`. Values
    ///     outside that range are clamped rather than rejected.
    ///   - sampleRate: Sample rate in hertz (e.g. `24000` for Kokoro output).
    /// - Returns: A `Data` containing the complete WAV file.
    public static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let dataByteCount = samples.count * 2 // 16-bit mono: 2 bytes per sample

        var data = Data(capacity: headerByteCount + dataByteCount)

        // RIFF chunk descriptor.
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + dataByteCount), to: &data) // overall size minus 8
        data.append(contentsOf: Array("WAVE".utf8))

        // "fmt " subchunk: canonical 16-byte PCM format descriptor.
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16, to: &data)                      // fmt chunk size
        appendUInt16(1, to: &data)                       // audio format: PCM
        appendUInt16(1, to: &data)                       // num channels: mono
        appendUInt32(UInt32(sampleRate), to: &data)      // sample rate (Hz)
        appendUInt32(UInt32(sampleRate * 2), to: &data)  // byte rate = sampleRate * numChannels * bits/8
        appendUInt16(2, to: &data)                       // block align
        appendUInt16(16, to: &data)                      // bits per sample

        // "data" subchunk: the 16-bit little-endian samples.
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(dataByteCount), to: &data)   // data chunk size

        for sample in samples {
            appendUInt16(UInt16(bitPattern: quantize(sample)), to: &data)
        }

        return data
    }

    /// Encodes `samples` as a WAV file and writes it atomically to `url`.
    ///
    /// A convenience over `wavData(samples:sampleRate:)` for callers that
    /// want the bytes on disk directly (e.g. handing a temporary file URL to
    /// the Share Sheet). The write is atomic: readers never observe a
    /// partially written file.
    ///
    /// - Parameters:
    ///   - samples: Mono `Float32` samples, nominally in `[-1, 1]`.
    ///   - sampleRate: Sample rate in hertz (e.g. `24000` for Kokoro output).
    ///   - url: Destination file URL, overwritten if it already exists.
    /// - Throws: Any error from `Data.write(to:options:)`, e.g. an
    ///   unwritable directory.
    public static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        try wavData(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    // MARK: - Internals

    /// Converts one `Float` sample to `Int16` by multiplying by 32767 and
    /// clamping to `[-32768, 32767]`. `NaN` maps to `0` (silence), and
    /// infinities clamp to the matching full-scale value.
    private static func quantize(_ sample: Float) -> Int16 {
        if sample.isNaN {
            return 0
        }
        let scaled = sample * 32767.0
        if scaled >= 32767.0 {
            return Int16.max // 32767
        }
        if scaled <= -32768.0 {
            return Int16.min // -32768
        }
        return Int16(scaled)
    }

    /// Appends a `UInt16` in little-endian byte order, one explicit byte at a
    /// time (never relies on host endianness).
    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    /// Appends a `UInt32` in little-endian byte order, one explicit byte at a
    /// time (never relies on host endianness).
    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
