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
/// ## Two payload shapes (2026-10-08, the 1.7 GB book)
///
/// Eager streams hold every packet's bytes — fine for a 40 MB book, fatal
/// for the 11-hour full-cast one: `Data(contentsOf:)` + the walk's own
/// `[UInt8]` copies put ~3× the file in memory and iOS killed the process
/// (`NSPOSIXErrorDomain Code=12, cannot allocate memory`). Lazy streams
/// keep only granules and byte RANGES (~40 bytes per packet resident) and
/// read each payload on demand from a MAPPED file — the OS pages payload
/// bytes in and out, so peak memory is one chunk, whatever the book weighs.
/// The decoder reads packets strictly in order, which is exactly the access
/// pattern a mapped file likes.
///
/// Foundation-only, like the readers — this is what the engine-side decoder
/// consumes, and it has to be testable where no audio stack exists.
public struct OpusPacketStream: Sendable {

    /// One codec packet, with the sample position at which it ends.
    public struct Packet: Sendable {
        /// Codec payload — what the decoder decodes. nil for a LAZY packet:
        /// `OpusPacketStream.payload(of:)` supplies it on demand.
        public let payload: Data?
        /// For lazy packets: the payload's byte range in the source file.
        public let range: Range<Int>?
        /// Samples (at `sampleRate`) decoded up to the END of this packet.
        public let granule: UInt64
        /// Position in the stream, so a seek can name a packet.
        public let index: Int

        /// Eager packet — the shape every pre-1.7.4 caller built.
        public init(payload: Data, granule: UInt64, index: Int) {
            self.payload = payload
            self.range = nil
            self.granule = granule
            self.index = index
        }

        /// Lazy packet — payload read on demand from `source` via `range`.
        public init(range: Range<Int>, granule: UInt64, index: Int) {
            self.payload = nil
            self.range = range
            self.granule = granule
            self.index = index
        }
    }

    public let packets: [Packet]
    /// The book's `OpusHead` packet, when the container carries one (Ogg
    /// always does, as the stream's first packet). `OpusLib` needs it for
    /// the channel-mapping family, the stream count and the channel map —
    /// without them a 5.1 stream cannot be decoded at all. Nil only where
    /// the container supplied the equivalent facts out of band (MP4's
    /// `dOps`), and then a synthetic head is built by the reader.
    public let headerPacket: [UInt8]?
    /// Opus' granule rate — 48 000 for every stream in practice; readers
    /// normalize to it.
    public let sampleRate: Int
    public let channels: Int
    /// Decoder output starts this many samples late. Left in, the first
    /// fraction of a second plays as a click.
    public let preSkip: Int
    /// LAZY ONLY: a memory-mapped view of the source file the lazy packets
    /// read their payloads from. Eager streams hold nil.
    ///
    /// `Data(contentsOf:options: .mappedIfSafe)` does not read the file —
    /// it maps it; the pages come in on touch and the evictor drops them
    /// under pressure. A file the OS will not map (moved, partially evicted
    /// provider storage) makes `payload(of:)` return nil and the feed dies
    /// the ordinary decode-failure way, which is survivable.
    private let mappedSource: Data?

    /// Eager stream — payloads resident.
    public init(
        packets: [Packet],
        headerPacket: [UInt8]? = nil,
        sampleRate: Int,
        channels: Int,
        preSkip: Int
    ) {
        self.packets = packets
        self.headerPacket = headerPacket
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.channels = max(1, channels)
        self.preSkip = max(0, preSkip)
        self.mappedSource = nil
    }

    /// Lazy stream — a header + packet byte RANGES over a mapped file.
    public init(
        packets: [Packet],
        headerPacket: [UInt8]? = nil,
        sampleRate: Int,
        channels: Int,
        preSkip: Int,
        mappedSource: Data
    ) {
        self.packets = packets
        self.headerPacket = headerPacket
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.channels = max(1, channels)
        self.preSkip = max(0, preSkip)
        self.mappedSource = mappedSource
    }

    /// The payload of one packet, eager or lazy. nil only for a lazy packet
    /// whose source stopped being readable (moved file, evicted provider
    /// storage).
    public func payload(of packet: Packet) -> Data? {
        if let payload = packet.payload { return payload }
        guard let source = mappedSource, let range = packet.range else { return nil }
        guard range.upperBound <= source.count else { return nil }
        let base = source.startIndex + range.lowerBound
        return source[base..<(source.startIndex + range.upperBound)]
    }

    /// True when the stream reads payloads from the mapped file rather than
    /// holding them — the property a loader uses to pick its read path.
    public var isLazy: Bool { mappedSource != nil }

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
    /// the "Full audiobook" case every other format gets from its own
    /// tags.
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
