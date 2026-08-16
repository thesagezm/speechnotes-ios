import Foundation

/// Minimal WAV writer: mono float samples → 16-bit PCM .wav file.
enum WavWriter {
    static func writeMono16Bit(samples: [Float], sampleRate: Int, to url: URL) throws {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, Double(sample)))
            let value = Int16(clamped * Double(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }

        var header = Data()
        func append(_ string: String) { header.append(contentsOf: string.utf8) }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }

        append("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        appendUInt32(16)              // PCM chunk size
        appendUInt16(1)               // format = PCM
        appendUInt16(1)               // channels = mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate) * 2) // byte rate
        appendUInt16(2)               // block align
        appendUInt16(16)              // bits per sample
        append("data")
        appendUInt32(UInt32(pcm.count))

        try (header + pcm).write(to: url)
    }
}
