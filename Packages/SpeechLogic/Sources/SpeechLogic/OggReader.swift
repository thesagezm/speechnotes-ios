import Foundation

/// An Ogg page, and the Ogg container's structural read.
///
/// Apple's media stack has no Ogg demuxer on ANY platform — `AVPlayer`,
/// `AVAudioPlayer` and `AudioFileOpen` all fail on a `.opus` / `.ogg` / `.oga`
/// file whatever codec is inside (the audiobook player refused one and told
/// the user to convert it). The CODEC is supported; the CONTAINER is not. So
/// a container we cannot play is read here, and its packets handed to
/// `AVAudioConverter` as raw codec data.
///
/// Only the STRUCTURE is decoded: pages, their segment table, and the
/// packets the pages carry. The one identification header that matters is
/// `OpusHead`, read for pre-skip and channel count; `OpusTags` and the rest
/// are passed through untouched for whoever decodes them.
///
/// Foundation-only on purpose — no `Compression`, no AudioToolbox — so this
/// parser and its tests run in a plain SwiftPM package on any host, which is
/// the only way to test it from a machine that is not a phone.
public enum OggReader {

    /// One codec packet, with the sample position at which it ends.
    ///
    /// A packet in Ogg can span pages and a page can carry several packets
    /// (the segment table IS the length list), so segments are accumulated
    /// until a segment shorter than 255 bytes terminates one — 255 is the
    /// escape value that means "another segment follows".
    public struct Packet {
        /// Codec payload — what `AVAudioConverter` decodes.
        public let payload: Data
        /// Samples decoded so far at `StreamInfo.sampleRate`. For Opus this
        /// is the whole time axis: a chapter boundary is "start at the first
        /// packet whose granule reaches N".
        public let granule: UInt64
        /// Position in the stream, so a seek can name a packet.
        public let index: Int
    }

    /// What the stream says about itself before any packet is decoded.
    public struct StreamInfo: Equatable, Sendable {
        public enum Codec: Equatable, Sendable {
            case opus
            /// A valid Ogg stream carrying something else (Vorbis, FLAC,
            /// Speex). The packet stream is readable; the codec is not ours.
            case other(String)
        }
        public let codec: Codec
        /// Decoder output starts this many samples late. Left in, the first
        /// fraction of a second plays as a click.
        public let preSkip: Int
        /// Opus' granule rate. 48 000 for every stream in practice, but read
        /// rather than assumed.
        public let sampleRate: Int
        public let channels: Int
        /// The header's informational `input sample rate`, when the writer
        /// put a sane value there. Never used for timing.
        public let inputSampleRate: Int?
    }

    public enum OggError: LocalizedError, Equatable {
        case notOgg
        case truncated
        case malformed

        public var errorDescription: String? {
            switch self {
            case .notOgg: return "This file is not an Ogg stream (no OggS capture pattern)."
            case .truncated: return "This Ogg stream ends in the middle of a page or packet."
            case .malformed: return "This Ogg stream is malformed."
            }
        }
    }

    /// The whole stream, read once.
    ///
    /// Holds every packet's BYTES, so peak memory is the file's own size —
    /// the same trade the MP4 chapter reader makes, and the reason this runs
    /// off the main thread. What it buys is the chapter table (free: packet
    /// granules) and a seek that means a packet index.
    public struct Stream {
        public let info: StreamInfo
        public let packets: [Packet]

        /// The same packet list in the shared shape the engine-side decoder
        /// consumes — `OpusPacketStream` is what `OpusPacketDecoder` reads,
        /// so an Ogg stream and an Opus-in-MP4 track decode identically.
        public var packetStream: OpusPacketStream {
            OpusPacketStream(
                packets: packets.map { OpusPacketStream.Packet(payload: $0.payload, granule: $0.granule, index: $0.index) },
                headerPacket: packets.first.map { [UInt8]($0.payload) },
                sampleRate: info.sampleRate,
                channels: info.channels,
                preSkip: info.preSkip
            )
        }

        /// Samples at `info.sampleRate` at the end of the stream.
        public var totalSamples: UInt64 { packets.last?.granule ?? 0 }

        /// Length in seconds, pre-skip removed.
        public var duration: TimeInterval {
            guard info.sampleRate > 0 else { return 0 }
            let samples = max(0, Int64(clamping: totalSamples) - Int64(info.preSkip))
            return Double(samples) / Double(info.sampleRate)
        }

        /// Packet index closest to `seconds`, clamped — the resume point for
        /// a tap on the scrubber. Opus has no keyframes to seek to, so the
        /// decoder must start from a packet boundary and that boundary is
        /// what this names.
        public func packetIndex(at seconds: TimeInterval) -> Int {
            guard !packets.isEmpty else { return 0 }
            let target = UInt64(max(0, seconds) * Double(info.sampleRate)) + UInt64(info.preSkip)
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
        /// tags. `stepSeconds` of 3600 gives an hour per chapter, which is
        /// what the shelf's single-chapter fallback means by "one chapter".
        public func chapterBoundaries(stepSeconds: TimeInterval) -> [Double] {
            guard stepSeconds > 0, info.sampleRate > 0, !packets.isEmpty else { return [] }
            let step = UInt64(stepSeconds * Double(info.sampleRate))
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
            let samples = max(0, Int64(clamping: granule) - Int64(info.preSkip))
            return Double(samples) / Double(info.sampleRate)
        }
    }

    /// One chapter mark read from the stream's OpusTags comments
    /// (`CHAPTER001=Title` + `CHAPTER001url=timecode`).
    public struct OggChapter: Equatable, Sendable {
        public let title: String
        public let startSeconds: TimeInterval

        public init(title: String, startSeconds: TimeInterval) {
            self.title = title
            self.startSeconds = startSeconds
        }
    }

    /// What an audiobook's manifest needs, read from BOUNDED slices.
    ///
    /// The import path cannot read a whole book — a 664 MB Opus encode would
    /// be the device freeze this codebase keeps fixing — and it does not need
    /// to: Ogg's last page carries a granule equal to the TOTAL sample
    /// count, so an 8 MB head (the `OpusHead` header) plus an 8 MB tail (the
    /// final pages) give an exact duration. The head slice is scanned for the
    /// last page it fully contains; the tail is scanned for the last valid
    /// page anywhere in it, which is the stream's end.
    public struct Summary: Equatable, Sendable {
        public let sampleRate: Int
        public let channels: Int
        public let preSkip: Int
        public let totalSamples: UInt64
        public let variant: String
        /// Chapter marks from the OpusTags comments, when the muxer wrote
        /// them — empty means the stream has none and the caller falls back
        /// to uniform division.
        public let chapters: [OggChapter]

        public var duration: TimeInterval {
            guard sampleRate > 0 else { return 0 }
            let samples = max(0, Int64(clamping: totalSamples) - Int64(preSkip))
            return Double(samples) / Double(sampleRate)
        }
    }

    /// Duration and identification from a head and a tail slice of the file.
    /// Throws when the head carries no readable identification header.
    public static func summary(head: Data, tail: Data) throws -> Summary {
        var info: StreamInfo?
        var tagsChapters: [OggChapter] = []
        var lastGranule: UInt64 = 0
        var sawPage = false
        // Packets assemble ACROSS pages, exactly as `read` assembles them.
        // A book's OpusTags packet carries the muxer's whole comment block —
        // embedded art, lyrics, the chapter table — and regularly spans
        // dozens of pages (933 KB on a real Harry Potter 5.1ch encode). The
        // old per-page assembly dropped every packet that did not COMPLETE
        // on one page, so that file's chapters were silently lost to the
        // uniform-division fallback.
        var pending: [UInt8] = []
        /// A runaway "packet" (a corrupt segment table) is being discarded;
        /// keep discarding until a short segment ends it.
        var dropping = false
        var offset = head.startIndex
        while offset < head.endIndex {
            guard let page = Page(data: head, at: offset - head.startIndex) else { break }
            sawPage = true
            for segment in page.segments {
                guard segment.upperBound <= head.count else { break }
                if dropping {
                    if segment.count < 255 { dropping = false }
                    continue
                }
                pending.append(contentsOf: head[head.startIndex + segment.lowerBound..<(head.startIndex + segment.upperBound)])
                guard segment.count < 255 else {
                    if pending.count > Self.maxMetadataPacketBytes {
                        // Comment packets with art run to megabytes; audio
                        // packets never approach this. Past the cap the
                        // segment table is lying, not describing metadata.
                        pending.removeAll(keepingCapacity: true)
                        dropping = true
                    }
                    continue   // 255: the packet continues on this page or the next
                }
                let packet = Data(pending)
                pending.removeAll(keepingCapacity: true)
                // Latch on a packet that actually IS OpusHead, not merely on
                // the first completed one: on a multiplexed stream the second
                // logical stream's OpusHead is not packet 0, and latching
                // `info` on that one returned `.other` with no retry.
                if info == nil, packet.starts(with: Data(Self.opusHeadMagic)) {
                    info = streamInfo(firstPacket: packet)
                }
                if tagsChapters.isEmpty, packet.starts(with: tagsMagic) {
                    tagsChapters = chapters(fromTagsPacket: packet)
                }
            }
            if page.granule > 0 { lastGranule = page.granule }
            offset = page.end
        }
        // The tail holds the stream's last page — and its granule, the
        // authoritative sample count.
        var tailOffset = 0
        while let found = lastPageStart(in: tail, from: tailOffset) {
            guard let page = Page(data: tail, at: found) else { break }
            sawPage = true
            if page.granule > 0 { lastGranule = page.granule }
            tailOffset = found + 1
        }
        guard let info, sawPage else { throw OggError.notOgg }
        return Summary(
            sampleRate: info.sampleRate,
            channels: info.channels,
            preSkip: info.preSkip,
            totalSamples: lastGranule,
            variant: info.codec == .opus ? "opus" : "ogg",
            chapters: tagsChapters
        )
    }

/// Ceiling on one assembled packet during the bounded summary scan. A
    /// comment packet with embedded art is routinely megabytes — a
    /// METADATA_BLOCK_PICTURE is base64, so a 3 MB cover alone is ~4 MB of
    /// comment — plus lyrics and the chapter table, so this has to clear a
    /// large embedded cover with room to spare or the chapter comments go
    /// with it. Still a cap: past it the segment table is describing audio
    /// from a corrupt file, not metadata.
    private static let maxMetadataPacketBytes = 24 * 1024 * 1024

    /// Hoisted out of the walk: an 8 MB head holds tens of thousands of packets,
    /// and building this `Data` per packet was an allocation per packet.
    private static let opusTagsMagic: [UInt8] = [0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73]
    private static let tagsMagic = Data(opusTagsMagic)
    private static let opusHeadMagic: [UInt8] = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]

    /// Chapter marks out of an OpusTags packet: magic(8), vendor length (4
    /// LE) + vendor, comment count (4 LE), then count × (length (4 LE) +
    /// UTF-8 comment).
    ///
    /// Chapter comments follow the Xiph chapter extension as ffmpeg and
    /// m4b-tool actually write it: `CHAPTER001=00:00:00.000` (the BARE key
    /// carries the TIMECODE) and `CHAPTER001NAME=Chapter 1` (the NAME suffix
    /// carries the title). `CHAPTER001URL=…` is a literal URL in the spec,
    /// but some writers put a timecode there instead — accepted as a
    /// fallback when it parses as one. Suffix matching is case-insensitive;
    /// anything unparseable is skipped, and a stream with no usable marks
    /// yields [] (the caller's uniform fallback takes over).
    static func chapters(fromTagsPacket packet: Data) -> [OggChapter] {
        let bytes = [UInt8](packet)
        guard bytes.count >= 8, Array(bytes.prefix(8)) == opusTagsMagic else { return [] }
        func le32(_ index: Int) -> Int {
            Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
                | (Int(bytes[index + 2]) << 16) | (Int(bytes[index + 3]) << 24)
        }
        var cursor = 8
        guard cursor + 4 <= bytes.count else { return [] }
        let vendorLength = le32(cursor)
        cursor += 4 + vendorLength
        guard vendorLength >= 0, cursor + 4 <= bytes.count else { return [] }
        let count = le32(cursor)
        cursor += 4
        guard count >= 0, count <= 100_000 else { return [] }
        var titles: [String: String] = [:]   // "001" → title
        var times: [String: String] = [:]    // "001" → bare-key timecode
        var urlTimes: [String: String] = [:] // "001" → url-field timecode
        for _ in 0..<count {
            guard cursor + 4 <= bytes.count else { break }
            let length = le32(cursor)
            cursor += 4
            guard length >= 0, cursor + length <= bytes.count else { break }
            let line = String(bytes: bytes[cursor..<(cursor + length)], encoding: .utf8) ?? ""
            cursor += length
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            // Vorbis comment field names are case-insensitive.
            let upperKey = key.uppercased()
            guard upperKey.hasPrefix("CHAPTER") else { continue }
            // The key shape is CHAPTER<number>[NAME|URL|TIME]; the digits are
            // the mark's identity and the role suffix says what the value
            // means.
            let suffix = upperKey.dropFirst("CHAPTER".count)
            let digits = suffix.prefix(while: \.isNumber)
            guard !digits.isEmpty else { continue }
            let number = String(digits)
            switch suffix.dropFirst(digits.count) {
            case "":
                times[number] = value          // bare key IS the timecode
            case "NAME":
                titles[number] = value
            case "URL", "TIME":
                // Spec-wise a URL is a link; some writers store the
                // timecode here — kept only when it parses as one.
                urlTimes[number] = value
            default:
                break
            }
        }
        guard !times.isEmpty || !urlTimes.isEmpty else { return [] }
        var out: [OggChapter] = []
        // The bare key wins; the url/time field is the fallback when the
        // bare value does not parse as a timecode (or is absent).
        for number in Array(Set(times.keys).union(urlTimes.keys)).sorted() {
            let candidates = [times[number], urlTimes[number]].compactMap { $0 }
            guard let raw = candidates.first(where: { Self.chapterTimecode($0) != nil }),
                  let seconds = Self.chapterTimecode(raw) else { continue }
            let title = titles[number] ?? "Chapter \(number)"
            out.append(OggChapter(title: title, startSeconds: seconds))
        }
        return out.sorted { $0.startSeconds < $1.startSeconds }
    }

    /// "00:12:34.500" | "12:34.5" | "754.5" → seconds. Nil when unparseable.
    static func chapterTimecode(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":")
        var seconds: Double = 0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// The last `OggS` capture pattern at or after `from` whose page header
    /// parses and fits — a random fourCC in the payload fails the fit test.
    private static func lastPageStart(in data: Data, from: Int) -> Int? {
        guard let marker = data.range(of: Data([0x4F, 0x67, 0x67, 0x53]), options: [], in: (data.startIndex + from)..<data.endIndex) else {
            return nil
        }
        return marker.lowerBound - data.startIndex
    }

    /// Reads `data` as an Ogg stream. Throws on anything that is not one.
    ///
    /// ## Granule positions
    ///
    /// Ogg stores ONE granule per page — the sample count at the end of the
    /// LAST packet that completed on it — not one per packet. A page holding
    /// 50 packets therefore keeps a number only for the 50th, and the other
    /// 49 have to be recovered. The stored values are authoritative, so every
    /// recovered position is a fraction of the span between the page BEFORE
    /// it and this one: exact at both ends, evenly spread between. That is
    /// what a chapter table and a resume point both need, and both of them
    /// land on a boundary rather than mid-page.
    public static func read(_ data: Data) throws -> Stream {
        var packets: [Packet] = []
        var info: StreamInfo?
        /// Bytes carried over from a page: the first packet of this page
        /// CONTINUES a packet that started on the previous one, and those
        /// segments belong to it rather than to a fresh packet.
        var pending: [UInt8] = []
        pending.reserveCapacity(8 * 1024)
        var previousGranule: UInt64 = 0
        var offset = data.startIndex
        let count = data.count
        var sawPage = false

        while offset < count {
            // Trailing zero padding after the last page is legal in some
            // muxers; stop rather than fail.
            guard let page = Page(data: data, at: offset) else {
                if sawPage, allZero(data, from: offset, to: count) { break }
                throw sawPage ? OggError.truncated : OggError.notOgg
            }
            sawPage = true
            // Zero-length segments are legal and carry no bytes, but the
            // segment table still has to be walked in full or the ranges
            // misalign.
            guard page.end <= count else { throw OggError.truncated }
            let span = page.granule > previousGranule ? page.granule - previousGranule : 0
            let packetsEndingHere = page.segments.filter { $0.count < 255 }.count

            var completed = 0
            for segment in page.segments {
                guard segment.upperBound <= count else { throw OggError.truncated }
                pending.append(contentsOf: data[data.startIndex + segment.lowerBound..<(data.startIndex + segment.upperBound)])
                guard segment.count < 255 else { continue }   // 255: packet continues
                completed += 1
                let payloadData = payloadData(pending)
                if info == nil { info = streamInfo(firstPacket: payloadData) }
                packets.append(Packet(
                    payload: payloadData,
                    granule: granuleFor(completedPacket: completed, packetsEndingHere: packetsEndingHere, page: page, previousGranule: previousGranule),
                    index: packets.count
                ))
                pending.removeAll(keepingCapacity: true)
            }
            _ = span
            previousGranule = page.granule
            offset = page.end
        }

        // A segment list that ends with 255s left a packet unterminated: the
        // file is short, and half a packet is worse than none.
        guard pending.isEmpty else { throw OggError.truncated }
        guard let info else { throw OggError.notOgg }
        return Stream(info: info, packets: packets)
    }

    /// Granule of the `completedPacket`th packet that finished on this page,
    /// 1-based. Both ends are anchored to values Ogg actually stores and the
    /// positions between are evenly spread — see the note on `read`.
    private static func granuleFor(
        completedPacket: Int,
        packetsEndingHere: Int,
        page: Page,
        previousGranule: UInt64
    ) -> UInt64 {
        guard packetsEndingHere > 0 else { return page.granule }
        // A page that merely carries the tail of a continued packet, or a
        // header page, stores no advance. Both are correct at the page's own
        // value, not a fallback.
        guard page.granule > previousGranule else { return page.granule }
        return previousGranule
            + (page.granule - previousGranule) * UInt64(completedPacket) / UInt64(packetsEndingHere)
    }

    /// The bytes of the packet that ENDS at `endingAt` in `page`: the carry-
    /// over from the previous page, plus every segment of this page up to and
    /// including `endingAt`.
    private static func payloadData(_ bytes: [UInt8]) -> Data { Data(bytes) }

    private static func allZero(_ data: Data, from: Int, to: Int) -> Bool {
        for index in from..<to where data[data.startIndex + index] != 0 { return false }
        return true
    }

    // MARK: - Identification header

    /// `OpusHead`, 19 bytes: magic(8) version(1) channels(1) preSkip(2 LE)
    /// inputRate(4 LE) gain(2 LE) mapping(1). It is the ONLY header that has
    /// to be understood to decode — everything else is codec payload.
    private static func streamInfo(firstPacket packet: Data) -> StreamInfo {
        let bytes = [UInt8](packet.prefix(19))
        let magic = bytes.prefix(8)
        guard magic.count == 8,
              magic.elementsEqual([0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]) else {
            return StreamInfo(
                codec: .other(String(bytes: magic, encoding: .isoLatin1) ?? "?"),
                preSkip: 0,
                sampleRate: 48_000,
                channels: 2,
                inputSampleRate: nil
            )
        }
        // OpusHead's multi-byte fields are LITTLE-endian (RFC 7845 §5.1) —
        // the same order the Ogg page headers use. (A big-endian read of
        // the fixtures' `38 01` yields 14337 where ffprobe reports
        // initial_padding=312, which is how that was pinned down.)
        func le16(_ index: Int) -> Int { Int(bytes[index]) | (Int(bytes[index + 1]) << 8) }
        func le32(_ index: Int) -> Int {
            Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
                | (Int(bytes[index + 2]) << 16) | (Int(bytes[index + 3]) << 24)
        }
        let channels = Int(bytes[9])
        // The header's `input sample rate` is INFORMATIONAL: it is whatever
        // rate the encoder was fed (commonly 44100), while the granule axis
        // every position in this app counts is Opus' fixed 48 kHz output.
        // Reporting the input rate made durations and seek targets wrong on
        // any 44.1 kHz encode, so it is kept only as metadata and the
        // timeline rate is always 48 kHz.
        let inputRate = le32(12)
        return StreamInfo(
            codec: .opus,
            preSkip: le16(10),
            sampleRate: 48_000,
            channels: channels > 0 ? channels : 2,
            inputSampleRate: inputRate > 0 ? inputRate : nil
        )
    }

    // MARK: - Page

    /// One Ogg page: the byte range of each of its segments, and where the
    /// next page starts.
    struct Page {
        static let headerLength = 27

        let granule: UInt64
        let segments: [Range<Int>]
        /// Offset of the next page — the body follows the segment table, so
        /// this is where the walk resumes.
        let end: Int

        init?(data: Data, at offset: Int) {
            let header = Self.headerLength
            guard offset >= 0, offset + header <= data.count else { return nil }
            let base = data.startIndex + offset
            let bytes = [UInt8](data[base..<(base + header)])
            // "OggS" — the one thing every Ogg page starts with, and the
            // difference between an Ogg file and a FLAC that happens to end
            // in .oga.
            guard bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 else { return nil }
            func le64(_ index: Int) -> UInt64 {
                var value: UInt64 = 0
                for shift in stride(from: 0, to: 64, by: 8) {
                    value |= UInt64(bytes[index + shift / 8]) << UInt64(shift)
                }
                return value
            }
            granule = le64(6)
            let segmentCount = Int(bytes[26])
            let tableStart = offset + header
            guard tableStart + segmentCount <= data.count else { return nil }
            let table = data[data.startIndex + tableStart..<(data.startIndex + tableStart + segmentCount)]
            var ranges: [Range<Int>] = []
            ranges.reserveCapacity(segmentCount)
            var cursor = tableStart + segmentCount
            for length in table {
                ranges.append(cursor..<(cursor + Int(length)))
                cursor += Int(length)
            }
            segments = ranges
            end = cursor
        }
    }
}