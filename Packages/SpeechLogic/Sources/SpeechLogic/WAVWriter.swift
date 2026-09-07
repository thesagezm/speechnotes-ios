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
    static func quantize(_ sample: Float) -> Int16 {
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
    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    /// Appends a `UInt32` in little-endian byte order, one explicit byte at a
    /// time (never relies on host endianness).
    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

/// Streaming WAV writer: constant memory regardless of render length.
///
/// `renderWAV` used to accumulate every chunk's samples in one `[Float]` —
/// a 200k-character chapter ≈ 1.1 GB of samples, a guaranteed jetsam kill.
/// This writer emits the 44-byte RIFF header with placeholder sizes up
/// front, appends Int16 frames as chunks finish, and patches both size
/// fields on close. NOT thread-safe: one writer per export, used from the
/// engine's serial generate queue.
public final class StreamingWriter {

    private let fileHandle: FileHandle
    private let sampleRate: Int
    public private(set) var sampleCount = 0
    private var closed = false

    /// Creates (or truncates) the file at `url` and writes the canonical
    /// header with placeholder size fields.
    public init(url: URL, sampleRate: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
        self.sampleRate = sampleRate

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        WAVWriter.appendUInt32(0, to: &header)                     // RIFF size — patched at close
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        WAVWriter.appendUInt32(16, to: &header)
        WAVWriter.appendUInt16(1, to: &header)                     // PCM
        WAVWriter.appendUInt16(1, to: &header)                     // mono
        WAVWriter.appendUInt32(UInt32(sampleRate), to: &header)
        WAVWriter.appendUInt32(UInt32(sampleRate * 2), to: &header)
        WAVWriter.appendUInt16(2, to: &header)
        WAVWriter.appendUInt16(16, to: &header)
        header.append(contentsOf: Array("data".utf8))
        WAVWriter.appendUInt32(0, to: &header)                     // data size — patched at close
        try fileHandle.write(contentsOf: header)
    }

    /// Encodes and appends one batch of mono Float32 samples.
    public func append(_ samples: [Float]) throws {
        guard !closed else { throw WAVWriterError.alreadyClosed }
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            WAVWriter.appendUInt16(UInt16(bitPattern: WAVWriter.quantize(sample)), to: &bytes)
        }
        sampleCount += samples.count
        try fileHandle.write(contentsOf: bytes)
    }

    /// Patches the RIFF + data size fields and closes the file. Safe to
    /// call twice; a writer dropped without close() still finalizes.
    public func close() throws {
        guard !closed else { return }
        closed = true
        let dataByteCount = sampleCount * 2
        try fileHandle.seek(toOffset: 4)
        var riffSize = Data()
        WAVWriter.appendUInt32(UInt32(36 + dataByteCount), to: &riffSize)
        try fileHandle.write(contentsOf: riffSize)
        try fileHandle.seek(toOffset: 40)
        var dataSize = Data()
        WAVWriter.appendUInt32(UInt32(dataByteCount), to: &dataSize)
        try fileHandle.write(contentsOf: dataSize)
        try fileHandle.close()
    }

    deinit {
        if !closed { try? close() }
    }
}

/// Streaming-writer failures.
public enum WAVWriterError: Error, LocalizedError {
    case alreadyClosed

    public var errorDescription: String? {
        switch self {
        case .alreadyClosed: return "The streaming WAV writer was already closed."
        }
    }
}
}
