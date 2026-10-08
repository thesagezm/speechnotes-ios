import Foundation

/// Reads an Opus-in-MP4 track — the shape behind every ".opus audiobook"
/// that is not a raw Ogg stream.
///
/// The device log told this story twice before anyone believed it: the
/// import of `book.opus` reports duration, cover AND author (all read by
/// AVFoundation's MP4 parser), and then the book will not play, because
/// AVFoundation can parse the CONTAINER but has no Opus DECODER behind
/// AVPlayer. The fix is the same as for raw Ogg: read the packets
/// ourselves, hand them to Apple's Opus codec through `AVAudioConverter`.
///
/// What this walks: `moov → trak → mdia` for `mdhd` (timescale) and
/// `minf → stbl` for the four tables that define a track's samples —
/// `stsd` (the sample entry; here the `Opus` box, whose `dOps` child
/// carries channels and pre-skip), `stts` (per-sample durations), `stsc`
/// (samples per chunk), `stsz` (sample sizes) and `stco`/`co64` (chunk
/// offsets). `mdat` is never interpreted — samples are copied out as-is.
///
/// Foundation-only, like `OggReader`: testable on any host, no audio stack.
public enum Mp4OpusReader {

    public enum Mp4OpusError: LocalizedError, Equatable {
        case notMp4
        case noOpusTrack
        case malformed

        public var errorDescription: String? {
            switch self {
            case .notMp4: return "This file is not an MP4/M4A container (no moov box)."
            case .noOpusTrack: return "This MP4 file has no Opus audio track."
            case .malformed: return "This MP4 file's sample tables are malformed."
            }
        }
    }

    /// Reads `data` as an MP4/M4A container and extracts its Opus track.
    /// Throws when the container has no readable Opus track — the caller is
    /// expected to fall back to `AVPlayer`, which handles everything else.
    public static func read(_ data: Data) throws -> OpusPacketStream {
        var sawMoov = false
        var timescale = 48_000
        var opusEntry: Range<Int>?
        var stts: [(count: Int, delta: Int)] = []
        var stsc: [(firstChunk: Int, samplesPerChunk: Int)] = []
        var sampleSizes: [Int] = []
        var chunkOffsets: [Int] = []

        // Walk semantics: a visitor returns TRUE to keep walking its level,
        // FALSE to stop. The per-track state (timescale, tables) is written
        // by each `trak`; the walk keeps its state only from traks that
        // carry an Opus sample entry, so a video or chapter text track can
        // never clobber the audio track's tables.
        try walkBoxes(data: data, range: 0..<data.count) { type, body in
            guard type == "moov" else { return true }
            sawMoov = true
            try walkBoxes(data: data, range: body) { type, body in
                guard type == "trak" else { return true }

                // Per-trak locals: a trak only contributes when it turns out
                // to be the Opus one.
                var trakTimescale = 48_000
                var trakOpusEntry: Range<Int>?
                var trakStts: [(count: Int, delta: Int)] = []
                var trakStsc: [(firstChunk: Int, samplesPerChunk: Int)] = []
                var trakSampleSizes: [Int] = []
                var trakChunkOffsets: [Int] = []

                try walkBoxes(data: data, range: body) { type, body in
                    guard type == "mdia" else { return true }
                    try walkBoxes(data: data, range: body) { type, body in
                        switch type {
                        case "mdhd":
                            trakTimescale = parseMdhd(data: data, range: body) ?? trakTimescale
                            return true
                        case "minf":
                            try walkBoxes(data: data, range: body) { type, body in
                                guard type == "stbl" else { return true }
                                try walkBoxes(data: data, range: body) { type, body in
                                    switch type {
                                    case "stsd":
                                        trakOpusEntry = findOpusEntry(data: data, range: body)
                                    case "stts":
                                        trakStts = parseStts(data: data, range: body)
                                    case "stsc":
                                        trakStsc = parseStsc(data: data, range: body)
                                    case "stsz":
                                        trakSampleSizes = parseStsz(data: data, range: body)
                                    case "stco":
                                        trakChunkOffsets = parseStco32(data: data, range: body)
                                    case "co64":
                                        trakChunkOffsets = parseStco64(data: data, range: body)
                                    default:
                                        break
                                    }
                                    return true
                                }
                                return true
                            }
                            return true
                        default:
                            return true
                        }
                    }
                    return true
                }

                // A complete Opus track ends the hunt. Anything else is
                // dropped on the floor — the next trak starts clean.
                if trakOpusEntry != nil, !trakStts.isEmpty, !trakStsc.isEmpty,
                   !trakSampleSizes.isEmpty, !trakChunkOffsets.isEmpty {
                    timescale = trakTimescale
                    opusEntry = trakOpusEntry
                    stts = trakStts
                    stsc = trakStsc
                    sampleSizes = trakSampleSizes
                    chunkOffsets = trakChunkOffsets
                    return false
                }
                return true
            }
            // One moov is all a book gets; stop the top-level walk.
            return false
        }

        guard sawMoov else { throw Mp4OpusError.notMp4 }
        guard let entry = opusEntry else { throw Mp4OpusError.noOpusTrack }
        guard !stts.isEmpty, !stsc.isEmpty, !sampleSizes.isEmpty, !chunkOffsets.isEmpty else {
            throw Mp4OpusError.malformed
        }
        let dOps = readDOps(data: data, entry: entry)

        // Samples live in chunks; `stsc` maps chunk number → samples-per-
        // chunk with last-entry-wins semantics. The duration of sample N is
        // its `stts` delta; the granule is the cumulative sum through it.
        var packets: [OpusPacketStream.Packet] = []
        packets.reserveCapacity(sampleSizes.count)
        var sampleIndex = 0
        var granule: UInt64 = 0
        var sttsCursor = 0
        var sttsRemaining = stts[0].count

        for (chunkNumber, offset) in chunkOffsets.enumerated() where sampleIndex < sampleSizes.count {
            let perChunk = samplesPerChunk(chunkNumber: chunkNumber + 1, stsc: stsc) ?? 1
            var cursor = offset
            for _ in 0..<perChunk where sampleIndex < sampleSizes.count {
                let size = sampleSizes[sampleIndex]
                guard cursor >= 0, cursor + size <= data.count, sttsRemaining > 0 else {
                    throw Mp4OpusError.malformed
                }
                granule += UInt64(stts[sttsCursor].delta)
                sttsRemaining -= 1
                if sttsRemaining == 0, sttsCursor < stts.count - 1 {
                    sttsCursor += 1
                    sttsRemaining = stts[sttsCursor].count
                }
                packets.append(OpusPacketStream.Packet(
                    payload: data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + cursor + size)),
                    granule: granule,
                    index: sampleIndex
                ))
                cursor += size
                sampleIndex += 1
            }
        }
        guard !packets.isEmpty else { throw Mp4OpusError.malformed }

        // The spec fixes an Opus track's media timescale at 48 000, but not
        // every muxer read that memo — normalize so granules always mean
        // "samples at 48 kHz" to the decoder.
        if timescale > 0, timescale != 48_000 {
            let scale = Double(48_000) / Double(timescale)
            packets = packets.map { packet in
                // MP4 reads are always EAGER — the payload exists; the
                // optional is the lazy-stream shape's addition.
                OpusPacketStream.Packet(
                    payload: packet.payload ?? Data(),
                    granule: UInt64((Double(packet.granule) * scale).rounded()),
                    index: packet.index
                )
            }
        }

        // MP4 carries channels + pre-skip in `dOps` rather than an OpusHead
        // packet. Build the equivalent head so the decoder has ONE input
        // shape — but only for the mappings `dOps` can actually express
        // (family 0 is mono/stereo). Opus-in-MP4 above two channels has no
        // stream map anywhere in the container, so it is refused with a
        // reason rather than decoded wrong.
        var syntheticHead: [UInt8]? = nil
        if dOps.channels <= 2 {
            var head: [UInt8] = Array("OpusHead".utf8)
            head += [0, UInt8(dOps.channels)]
            head += [UInt8(dOps.preSkip & 0xFF), UInt8((dOps.preSkip >> 8) & 0xFF)]
            head += [0x80, 0xBB, 0x00, 0x00]           // 48000, LE
            head += [0, 0]                              // gain 0
            head += [0]                                 // mapping family 0
            syntheticHead = head
        }
        return OpusPacketStream(
            packets: packets,
            headerPacket: syntheticHead,
            sampleRate: 48_000,
            channels: dOps.channels,
            preSkip: dOps.preSkip
        )
    }

    // MARK: - Box walk

    /// Walks the child boxes of the range, calling `visit` per box with its
    /// type and BODY range. `visit` returns TRUE to keep walking, FALSE to
    /// stop this level.
    private static func walkBoxes(
        data: Data,
        range: Range<Int>,
        _ visit: (String, Range<Int>) throws -> Bool
    ) throws {
        var offset = range.lowerBound
        let end = range.upperBound
        while offset + 8 <= end {
            let size = Int(be32(data, offset))
            let type = fourCC(data, offset + 4)
            if size == 1 {
                // 64-bit size: [largesize: u64] follows the type.
                guard offset + 16 <= end else { throw Mp4OpusError.malformed }
                let large = Int(clamping: be64(data, offset + 8))
                guard large >= 16, offset + large <= end else { throw Mp4OpusError.malformed }
                guard try visit(type, (offset + 16)..<(offset + large)) else { return }
                offset += large
            } else if size == 0 {
                // Extends to the end of the enclosing box.
                _ = try visit(type, (offset + 8)..<end)
                return
            } else {
                guard size >= 8, offset + size <= end else { throw Mp4OpusError.malformed }
                guard try visit(type, (offset + 8)..<(offset + size)) else { return }
                offset += size
            }
        }
    }

    // MARK: - The tables

    /// The `Opus` sample entry inside `stsd` — the byte range of the whole
    /// entry box — or nil when this track is not Opus.
    private static func findOpusEntry(data: Data, range: Range<Int>) -> Range<Int>? {
        // stsd: version/flags(4) entryCount(4) entries...
        let base = range.lowerBound
        guard range.count >= 8 else { return nil }
        let entryCount = Int(be32(data, base + 4))
        var cursor = base + 8
        let end = range.upperBound
        for _ in 0..<entryCount {
            guard cursor + 8 <= end else { return nil }
            let size = Int(be32(data, cursor))
            guard size >= 8, cursor + size <= end else { return nil }
            if fourCC(data, cursor + 4) == "Opus" {
                return cursor..<(cursor + size)
            }
            cursor += size
        }
        return nil
    }

    /// `dOps` (OpusSampleEntry): version(1) channels(1) preSkip(2 BE)
    /// inputSampleRate(4 BE) gain(2) mapping(1) [stream/coupled/map...].
    private static func readDOps(data: Data, entry: Range<Int>) -> (channels: Int, preSkip: Int) {
        // An audio sample entry is 8 (box header) + 6 (reserved) + 2
        // (data_ref_index) = 16 bytes before its child boxes start.
        var cursor = entry.lowerBound + 16
        let end = entry.upperBound
        while cursor + 8 <= end {
            let size = Int(be32(data, cursor))
            guard size >= 12, cursor + size <= end else { break }
            if fourCC(data, cursor + 4) == "dOps" {
                let body = cursor + 8
                guard body + 4 <= end else { break }
                let channels = Int(data[body + 1])
                let preSkip = Int(be16(data, body + 2))
                return (max(1, channels), preSkip)
            }
            cursor += size
        }
        // No dOps: the entry is not spec-conformant. One channel and no
        // pre-skip is the least-wrong guess — the decoder still runs, the
        // first 6 ms may click.
        return (1, 0)
    }

    /// Media timescale from `mdhd` (v0 or v1 — the timescale sits after the
    /// version-dependent creation/modification fields).
    private static func parseMdhd(data: Data, range: Range<Int>) -> Int? {
        let base = range.lowerBound
        guard range.count >= 8 else { return nil }
        let version = data[base] >> 4
        if version == 1 {
            guard range.count >= 24 else { return nil }
            return Int(be32(data, base + 4 + 16))
        }
        guard range.count >= 16 else { return nil }
        return Int(be32(data, base + 4 + 8))
    }

    private static func parseStts(data: Data, range: Range<Int>) -> [(count: Int, delta: Int)] {
        let base = range.lowerBound + 4  // version/flags
        guard base + 4 <= range.upperBound else { return [] }
        let count = Int(be32(data, base))
        var cursor = base + 4
        var out: [(count: Int, delta: Int)] = []
        for _ in 0..<count where cursor + 8 <= range.upperBound {
            out.append((Int(be32(data, cursor)), Int(be32(data, cursor + 4))))
            cursor += 8
        }
        return out
    }

    private static func parseStsc(data: Data, range: Range<Int>) -> [(firstChunk: Int, samplesPerChunk: Int)] {
        let base = range.lowerBound + 4
        guard base + 4 <= range.upperBound else { return [] }
        let count = Int(be32(data, base))
        var cursor = base + 4
        var out: [(firstChunk: Int, samplesPerChunk: Int)] = []
        for _ in 0..<count where cursor + 12 <= range.upperBound {
            out.append((Int(be32(data, cursor)), Int(be32(data, cursor + 4))))
            cursor += 12
        }
        return out
    }

    private static func parseStsz(data: Data, range: Range<Int>) -> [Int] {
        let base = range.lowerBound + 4
        guard base + 8 <= range.upperBound else { return [] }
        let uniform = Int(be32(data, base))
        let count = Int(be32(data, base + 4))
        if uniform != 0 {
            return Array(repeating: uniform, count: count)
        }
        var cursor = base + 8
        var out: [Int] = []
        out.reserveCapacity(count)
        for _ in 0..<count where cursor + 4 <= range.upperBound {
            out.append(Int(be32(data, cursor)))
            cursor += 4
        }
        return out
    }

    private static func parseStco32(data: Data, range: Range<Int>) -> [Int] {
        let base = range.lowerBound + 4
        guard base + 4 <= range.upperBound else { return [] }
        let count = Int(be32(data, base))
        var cursor = base + 4
        var out: [Int] = []
        out.reserveCapacity(count)
        for _ in 0..<count where cursor + 4 <= range.upperBound {
            out.append(Int(be32(data, cursor)))
            cursor += 4
        }
        return out
    }

    private static func parseStco64(data: Data, range: Range<Int>) -> [Int] {
        let base = range.lowerBound + 4
        guard base + 4 <= range.upperBound else { return [] }
        let count = Int(be32(data, base))
        var cursor = base + 4
        var out: [Int] = []
        out.reserveCapacity(count)
        for _ in 0..<count where cursor + 8 <= range.upperBound {
            out.append(Int(clamping: be64(data, cursor)))
            cursor += 8
        }
        return out
    }

    /// Samples per chunk for `chunkNumber` (1-based): the LAST stsc entry
    /// whose first-chunk number does not exceed it.
    private static func samplesPerChunk(chunkNumber: Int, stsc: [(firstChunk: Int, samplesPerChunk: Int)]) -> Int? {
        var result: Int?
        for entry in stsc where entry.firstChunk <= chunkNumber {
            result = entry.samplesPerChunk
        }
        return result
    }

    // MARK: - Byte helpers (big-endian, ISO BMFF)

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func be16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0..<8 {
            value = (value << 8) | UInt64(data[data.startIndex + offset + byte])
        }
        return value
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String {
        let base = data.startIndex + offset
        return String(bytes: data[base..<(base + 4)], encoding: .isoLatin1) ?? "????"
    }
}
