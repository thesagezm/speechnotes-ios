import Foundation

/// The packet stream both Opus demuxers feed to the decoder.
///
/// `OggReader` walks the Ogg container and `Mp4OpusReader` walks an MP4
/// sample table (`Opus-in-MP4` — the shape every "audiobook.opus" from a
/// downloader actually has: AVFoundation parses that container fine, reads
/// its cover and tags, and then cannot DECODE the track, because Apple
/// ships no Opus decoder behind AVPlayer). Both produce the same thing: an
/// ordered list of codec packets, each with the sample position at which it
/// ends, at Opus' fixed 48 kHz output rate.
///
/// Foundation-only, like the readers — this is what the engine-side decoder
/// consumes, and it has to be testable where no audio stack exists.
public struct OpusPacketStream: Sendable {

    /// One codec packet, with the sample position at which it ends.
    public struct Packet: Sendable {
        /// Codec payload — what `AVAudioConverter` decodes.
        public let payload: Data
        /// Samples (at `sampleRate`) decoded up to the END of this packet.
        public let granule: UInt64
        /// Position in the stream, so a seek can name a packet.
        public let index: Int

        public init(payload: Data, granule: UInt64, index: Int) {
            self.payload = payload
            self.granule = granule
            self.index = index
        }
    }

    public let packets: [Packet]
    /// Opus' granule rate — 48 000 for every stream in practice; readers
    /// normalize to it.
    public let sampleRate: Int
    public let channels: Int
    /// Decoder output starts this many samples late. Left in, the first
    /// fraction of a second plays as a click.
    public let preSkip: Int

    public init(packets: [Packet], sampleRate: Int, channels: Int, preSkip: Int) {
        self.packets = packets
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.channels = max(1, channels)
        self.preSkip = max(0, preSkip)
    }

    /// Samples at `sampleRate` at the end of the stream.
    public var totalSamples: UInt64 { packets.last?.granule ?? 0 }

    /// Length in seconds, pre-skip removed.
    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        let samples = max(0, Int64(clamping: totalSamples) - Int64(preSkip))
        return Double(samples) / Double(sampleRate)
    }

    /// Packet index closest to `seconds`, clamped — the resume point for a
    /// tap on the scrubber. Opus has no keyframes to seek to, so the decoder
    /// starts from a packet boundary and this names it. Header packets
    /// (granule 0, an Ogg-only concept) are never returned — the decoder
    /// must not be fed them.
    public func packetIndex(at seconds: TimeInterval) -> Int {
        guard !packets.isEmpty else { return 0 }
        let target = UInt64(max(0, seconds) * Double(sampleRate)) + UInt64(preSkip)
        var low = 0
        var high = packets.count - 1
        while low < high {
            let mid = (low + high) / 2
            if packets[mid].granule < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Uniform chapter boundaries, for a file with no chapter metadata —
    /// the "Full audiobook" case every other format gets from its own tags.
    public func chapterBoundaries(stepSeconds: TimeInterval) -> [Double] {
        guard stepSeconds > 0, sampleRate > 0, !packets.isEmpty else { return [] }
        let step = UInt64(stepSeconds * Double(sampleRate))
        guard step > 0 else { return [] }
        var out: [Double] = [0]
        var next = step
        for packet in packets {
            guard packet.granule >= next else { continue }
            out.append(granuleSeconds(packet.granule))
            // A long packet can cover several steps; never hand back two
            // chapters that begin at the same instant.
            while next <= packet.granule { next += step }
        }
        if let last = out.last, last >= duration - 1 { out.removeLast() }
        return out
    }

    private func granuleSeconds(_ granule: UInt64) -> Double {
        let samples = max(0, Int64(clamping: granule) - Int64(preSkip))
        return Double(samples) / Double(sampleRate)
    }
}
