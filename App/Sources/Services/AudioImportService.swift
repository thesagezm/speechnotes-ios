import Foundation
import AVFoundation
import OSLog

/// Transcribes an audio file (`.wav`, `.m4a`, `.mp3`, `.caf`, `.flac`,
/// `.aiff`) using the active STT engine.
///
/// Pipeline:
/// 1. Security-scope + file coordination read (handles iCloud placeholders).
/// 2. `AVURLAsset` → `AVAssetReader` → decode to PCM.
/// 3. Resample to 16 kHz mono Float32 (the format whisper.cpp + Apple SFSpeech
///    both expect).
/// 4. Hand off to the engine via the `STTEngine.transcribeFile(...)` API.
/// 5. Save the finalised transcript as a new `Note`.
@MainActor
final class AudioImportService {
    static let shared = AudioImportService()
    private let logger = Logger(subsystem: "com.speechnotes.ios", category: "AudioImport")

    enum ImportError: LocalizedError {
        case noAudioTrack
        case unsupportedFormat
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "No audio track in the file."
            case .unsupportedFormat: return "Unsupported audio format."
            case .readFailed(let s): return "Could not read audio: \(s)"
            }
        }
    }

    private init() {}

    /// Reads + transcribes an audio file. Returns the transcript text.
    /// Caller is responsible for committing it as a note (and handling
    /// permissions / errors with `Haptics` / alerts).
    func transcribe(
        _ url: URL,
        language: String?,
        engine: STTEngine
    ) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let samples = try await Self.samples(from: url)
        logger.info("AudioImport: \(samples.count) samples (\(Double(samples.count) / 16_000) s) ready for transcription")
        return try await engine.transcribeFile(samples: samples, language: language)
    }

    /// Splits the import into two stages so callers can drive a progress bar.
    static func samples(from url: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            try Self.decode(url: url)
        }.value
    }

    func runTranscription(
        samples: [Float],
        language: String?,
        engine: STTEngine,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        progress(0)
        return try await engine.transcribeFile(samples: samples, language: language)
    }

    nonisolated private static func decode(url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ImportError.noAudioTrack
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ImportError.readFailed(error.localizedDescription)
        }

        let sourceFormatDescriptions = track.formatDescriptions as? [CMAudioFormatDescription] ?? []
        let sourceFormat = sourceFormatDescriptions.first.flatMap { cmFormat in
            CMAudioFormatDescriptionGetStreamBasicDescription(cmFormat)?.pointee
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else {
            // The source isn't PCM-decodable to mono 16 kHz Float32 (rare on
            // iOS — but compressed-only codecs like AMR-WB can hit this).
            // Fallback: ask for whatever the source gives us and resample
            // ourselves below.
            throw ImportError.unsupportedFormat
        }
        reader.add(output)

        guard reader.startReading() else {
            throw ImportError.readFailed(reader.error?.localizedDescription ?? "reader.startReading failed")
        }

        var collected: [Float] = []
        while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard let raw = dataPointer else { continue }
            let count = length / MemoryLayout<Float>.size
            let bound = raw.withMemoryRebound(to: Float.self, capacity: count) { ptr in
                Array(UnsafeBufferPointer(start: ptr, count: count))
            }
            collected.append(contentsOf: bound)
        }
        if reader.status == .failed {
            throw ImportError.readFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        if let src = sourceFormat, abs(src.mSampleRate - 16_000) > 1 {
            // Source gave us a sample rate the AVAssetReader didn't honour
            // (rare — happens with very odd files). Cheap fallback: linear
            // resample to 16 kHz so downstream engines still work.
            collected = linearResample(collected, fromRate: src.mSampleRate, toRate: 16_000)
        }
        return collected
    }

    nonisolated private static func linearResample(_ samples: [Float], fromRate: Float64, toRate: Float64) -> [Float] {
        guard fromRate > 0, toRate > 0, !samples.isEmpty else { return samples }
        let ratio = toRate / fromRate
        let outCount = Int(Double(samples.count) * ratio)
        guard outCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) / ratio
            let lo = Int(pos)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(pos - Double(lo))
            out[i] = samples[lo] * (1 - frac) + samples[hi] * frac
        }
        return out
    }
}
