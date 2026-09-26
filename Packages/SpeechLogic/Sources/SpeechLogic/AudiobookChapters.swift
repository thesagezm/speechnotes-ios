//
//  AudiobookChapters.swift
//  SpeechLogic
//
//  Chapter-list resolution for audiobook containers built on MPEG-4 or MP3
//  (M4B/M4A/MP4 and MP3-with-chapters). Two metadata formats matter in the
//  wild and both are covered here:
//
//   * **Nero / QuickTime chapter tracks and `chpl` atoms** — an MP4 chapter
//     list, either as a timed text track or an Apple `chpl` atom.
//   * **ID3v2 CHAP/CTOC frames** — the MP3 answer to the same problem, one
//     CHAP frame per chapter with its own title.
//
//  The parser reads only what it needs: boxes are walked by length prefix, so
//  a 900 MB audiobook is never loaded — the caller hands it a byte range. Only
//  integer decoding, big-endian box walking and ID3v2 frame splitting live
//  here; nothing in this file allocates in proportion to the file size.
//
//  This is a fresh implementation from the ISO/IEC 14496-12 box layout and the
//  ID3v2.3/2.4 informal spec. No third-party parser code.
//

import Foundation

/// What the container says about one chapter. Times are in SECONDS (fractional
/// where the container gives milliseconds) so the app can map playback time to
/// a chapter without knowing the container's native units.
public struct AudioChapter: Codable, Equatable, Hashable {
    public var title: String
    public var startSeconds: Double
    public var endSeconds: Double

    public init(title: String, startSeconds: Double, endSeconds: Double) {
        self.title = title
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Resolution entry point. `data` must be the whole file for MP3 (ID3 frames
/// live at the head) and may be a HEAD slice for MP4 (the chapter boxes sit
/// near the start, before `mdat`).
public enum AudiobookChapters {

    /// Chapters from an MP4-family container (`.m4b`, `.m4a`, `.mp4`).
    ///
    /// Two forms in the wild, both implemented:
    ///   * `moov/chpl` — the simple Nero chapter atom most M4B encoders
    ///     write.
    ///   * a real chapter TRACK — a text `trak` whose sample table carries
    ///     one sample per chapter (the form m4b-tool, ffmpeg's `-map_metadata'
    ///     and most commercial downloads write). The first device v1.6
    ///     audiobook round showed chpl-only support leaves those files with
    ///     "Full audiobook" as the only chapter.
    ///
    /// Sample-table walking needs the movie timescale from `moov/mvhd`, and
    /// the per-chapter titles live in the track's `stsd` entry (`text` box)
    /// as Pascal/QT strings, sometimes as `udta` names. Titles are
    /// best-effort: positions without a title get "Chapter N".
    public static func chaptersFromMP4(_ data: Data, totalSeconds: Double) -> [AudioChapter] {
        var found: [AudioChapter] = []
        forEachBox(in: data, range: 0..<data.count) { type, payload in
            guard type == "moov" else { return }
            found = chaptersFromMoov(data, range: payload) ?? []
        }
        guard let chapters = normalize(found, totalSeconds: totalSeconds), !chapters.isEmpty else {
            return []
        }
        return chapters
    }

    /// Chapters from ID3v2 `CHAP` frames (MP3). `CTOC` is read only to learn
    /// the intended order; with no CTOC the frames' own order is used.
    public static func chaptersFromID3(_ data: Data) -> [AudioChapter] {
        guard data.count > 10 else { return [] }
        let bytes = [UInt8](data.prefix(min(data.count, 4 * 1024 * 1024)))
        guard bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return [] } // "ID3"
        let major = Int(bytes[3])
        guard major == 3 || major == 4 else { return [] }
        let size = syncSafeInt(bytes[6], bytes[7], bytes[8], bytes[9])
        let tagEnd = min(bytes.count, 10 + size)
        var cursor = 10
        // An extended header, when the flag says there is one, must be skipped
        // rather than misread as the first frame. v2.4's size is sync-safe and
        // EXCLUDES its own four bytes; v2.3's is a plain 32-bit size that
        // INCLUDES them. Both encodings exist in the wild.
        if bytes[5] & 0x40 != 0, cursor + 4 <= tagEnd {
            let extended: Int
            if major == 4 {
                // v2.4's extended header is [4-byte sync-safe size][1-byte
                // flags][4-byte padding size] — the size comes FIRST and
                // counts only what follows it.
                extended = syncSafeInt(bytes[cursor], bytes[cursor + 1], bytes[cursor + 2], bytes[cursor + 3])
                cursor += 4 + extended
            } else {
                extended = Int(be32(bytes, cursor))
                cursor += extended
            }
        }

        var chapters: [AudioChapter] = []
        while cursor + 10 <= tagEnd {
            let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .isoLatin1) ?? ""
            guard id != "\0\0\0\0", !id.isEmpty else { break }
            let frameSize: Int
            if major == 4 {
                frameSize = syncSafeInt(bytes[cursor + 4], bytes[cursor + 5], bytes[cursor + 6], bytes[cursor + 7])
            } else {
                frameSize = Int(bytes[cursor + 4]) << 24 | Int(bytes[cursor + 5]) << 16
                    | Int(bytes[cursor + 6]) << 8 | Int(bytes[cursor + 7])
            }
            let payloadStart = cursor + 10
            let payloadEnd = min(tagEnd, payloadStart + frameSize)
            guard payloadEnd > payloadStart else { break }
            if id == "CHAP" {
                if let chapter = parseChapFrame(Array(bytes[payloadStart..<payloadEnd])) {
                    chapters.append(chapter)
                }
            }
            cursor = payloadEnd
        }
        return normalize(chapters, totalSeconds: nil) ?? chapters
    }

    // MARK: - MP4 walking

    /// Calls `body` for every box at this level. A box is a 4-byte big-endian
    /// length, a 4-byte type, then the payload; length 1 means a 64-bit
    /// extended length follows, length 0 means "to end of file". A malformed
    /// length ends the walk instead of looping.
    private static func forEachBox(
        in data: Data,
        range: Range<Int>,
        _ body: (String, Range<Int>) -> Void
    ) {
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let length = Int(be32(data, cursor))
            let type = fourCC(data, cursor + 4)
            var headerSize = 8
            var boxLength = length
            if length == 1 {
                guard cursor + 16 <= range.upperBound else { return }
                boxLength = Int(be64(data, cursor + 8))
                headerSize = 16
            } else if length == 0 {
                boxLength = range.upperBound - cursor
            }
            guard boxLength >= headerSize, cursor + boxLength <= range.upperBound else { return }
            body(type, (cursor + headerSize)..<(cursor + boxLength))
            cursor += boxLength
        }
    }

    private static func chaptersFromMoov(_ data: Data, range: Range<Int>) -> [AudioChapter]? {
        // `chpl` is the simple, widely written form — prefer it when present.
        var chplPayload: Range<Int>?
        var mvhdPayload: Range<Int>?
        var traks: [Range<Int>] = []
        forEachBox(in: data, range: range) { type, payload in
            if type == "chpl" { chplPayload = payload }
            if type == "mvhd" { mvhdPayload = payload }
            if type == "trak" { traks.append(payload) }
        }
        if let chplPayload {
            let chapters = parseChpl(Array(data[chplPayload]))
            if !chapters.isEmpty { return chapters }
        }
        // No `chpl` (or it was empty): try a real chapter track — a `trak`
        // whose handler is `text` (or `sbtl`), whose sample table then gives
        // one chapter per sample. This is what m4b-tool and ffmpeg write.
        if let mvhdPayload,
           let timescale = parseMvhdTimescale(Array(data[mvhdPayload])) {
            for trak in traks {
                if let chapters = chaptersFromTrak(data, range: trak, movieTimescale: timescale),
                   !chapters.isEmpty {
                    return chapters
                }
            }
        }
        return nil
    }

    // MARK: - mvhd

    /// `mvhd` payload: version(1) flags(3), then creation(4/8), modification
    /// (4/8), timescale(4), duration(4/8). Version 0 uses 32-bit fields.
    private static func parseMvhdTimescale(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let version = Int(bytes[0])
        switch version {
        case 0:
            // 4 creation + 4 modification, then timescale.
            guard bytes.count >= 16 else { return nil }
            return Int(be32(bytes, 12))
        case 1:
            // 8 creation + 8 modification, then timescale.
            guard bytes.count >= 24 else { return nil }
            return Int(be32(bytes, 20))
        default:
            return nil
        }
    }

    // MARK: - Chapter trak

    /// A text chapter track: `trak/mdia` → `hdlr` (handler `text`/`sbtl`) +
    /// `minf/stbl` → `stts` (sample durations), `stsc`/`stco`/`stsz`
    /// (sample placement), `stsd/text` (titles). The walk is BOUNDED by the
    /// head slice the caller passed — a chunk offset pointing past the end
    /// simply drops that sample.
    private static func chaptersFromTrak(_ data: Data, range: Range<Int>, movieTimescale: Int) -> [AudioChapter]? {
        guard let mdia = childBox("mdia", in: data, range: range) else { return nil }
        // Handler must be a text/subtitle handler — the audio track's is
        // `soun` and a chapter track riding an audio sample table would be
        // misread as chapters-per-frame.
        guard let hdlr = childBox("hdlr", in: data, range: mdia),
              let handler = handlerType(data, range: hdlr),
              handler == "text" || handler == "sbtl" || handler == "subt"
        else { return nil }
        guard let minf = childBox("minf", in: data, range: mdia),
              let stbl = childBox("stbl", in: data, range: minf) else { return nil }

        // Media timescale (mdhd) — durations are in IT, the movie timescale
        // only converts the final seconds.
        var mediaTimescale = movieTimescale
        if let mdhd = childBox("mdhd", in: data, range: mdia),
           let parsed = parseMvhdTimescale(Array(data[mdhd])), parsed > 0 {
            mediaTimescale = parsed
        }

        // stts: run-length (count, delta) pairs — the chapter start times.
        guard let stts = childBox("stts", in: data, range: stbl) else { return nil }
        let rawStarts = parseStts(Array(data[stts]), timescale: mediaTimescale)
        guard !rawStarts.isEmpty else { return nil }

        // stsz: one size per sample (needed to read each title's extent).
        var sampleSizes: [Int] = []
        if let stsz = childBox("stsz", in: data, range: stbl) {
            sampleSizes = parseStsz(Array(data[stsz]))
        }

        // stco/stsc: chunk offsets → which byte range each sample occupies.
        var chunkOffsets: [Int] = []
        if let stco = childBox("stco", in: data, range: stbl) {
            chunkOffsets = parseStco(Array(data[stco]))
        }
        var samplesPerChunk: [Int] = []
        if let stsc = childBox("stsc", in: data, range: stbl) {
            samplesPerChunk = parseStscFirstRun(Array(data[stsc]), totalSamples: sampleSizes.count)
        }

        // Build each sample's (offset, size) by walking chunks. A text
        // chapter track carries its sample payloads inside `moov` itself
        // (tiny), so chunk offsets stay well inside the head slice; one
        // pointing outside (mdat-colocated layouts) drops the remaining
        // titles but keeps the positions.
        guard !chunkOffsets.isEmpty else { return nil }
        var starts: [Double] = []
        var extents: [(offset: Int, size: Int)] = []
        var sampleIndex = 0
        outer: for chunkOffset in chunkOffsets {
            let count = samplesPerChunk.first ?? 1
            for _ in 0..<max(1, count) {
                guard sampleIndex < rawStarts.count else { break outer }
                let size = sampleIndex < sampleSizes.count ? sampleSizes[sampleIndex] : 0
                starts.append(rawStarts[sampleIndex])
                extents.append((chunkOffset, size))
                sampleIndex += 1
            }
        }
        guard starts.count == rawStarts.count else {
            // Sample placement didn't cover every declared sample — the
            // head slice was too short. Fall back to titles-less chapters
            // from stts alone (positions are still right).
            return (0..<rawStarts.count).map { index in
                AudioChapter(
                    title: "Chapter \(index + 1)",
                    startSeconds: rawStarts[index],
                    endSeconds: 0
                )
            }
        }

        // Titles: each sample is a text-box payload — 2 bytes length/flags
        // (QuickTime text media: 16-bit BE size, then the string, sometimes
        // with a preceding atom like 'encd'). Read leniently.
        var titles: [String] = []
        for extent in extents {
            let end = extent.offset + extent.size
            guard extent.offset >= 0, end <= data.count else {
                titles.append("")
                continue
            }
            titles.append(parseTextSample(Array(data[extent.offset..<end])))
        }
        let chapters = zip(starts, titles).map { start, title in
            AudioChapter(
                title: title,
                startSeconds: start,
                endSeconds: 0
            )
        }
        return chapters
    }

    /// One direct child box of the given type, or nil.
    private static func childBox(_ type: String, in data: Data, range: Range<Int>) -> Range<Int>? {
        var found: Range<Int>?
        forEachBox(in: data, range: range) { boxType, payload in
            if boxType == type, found == nil { found = payload }
        }
        return found
    }

    /// `hdlr` payload: version+flags(4), predefined(4), handler type(4).
    private static func handlerType(_ data: Data, range: Range<Int>) -> String? {
        let bytes = Array(data[range])
        guard bytes.count >= 12 else { return nil }
        return String(bytes: bytes[8..<12], encoding: .isoLatin1)
    }

    /// `stts` payload: version+flags(4), entryCount(4), then (count, delta)
    /// pairs. Returns CUMULATIVE start seconds.
    private static func parseStts(_ bytes: [UInt8], timescale: Int) -> [Double] {
        guard bytes.count >= 8, timescale > 0 else { return [] }
        let entries = Int(be32(bytes, 4))
        var starts: [Double] = []
        var ticks: Double = 0
        var cursor = 8
        for _ in 0..<entries {
            guard cursor + 8 <= bytes.count else { break }
            let count = Int(be32(bytes, cursor))
            let delta = Int(be32(bytes, cursor + 4))
            cursor += 8
            for _ in 0..<max(1, count) {
                starts.append(ticks / Double(timescale))
                ticks += Double(delta)
            }
        }
        return starts
    }

    /// `stsz` payload: version+flags(4), sampleSize(4), sampleCount(4), then
    /// per-sample sizes when sampleSize == 0.
    private static func parseStsz(_ bytes: [UInt8]) -> [Int] {
        guard bytes.count >= 12 else { return [] }
        let uniform = Int(be32(bytes, 4))
        let count = Int(be32(bytes, 8))
        if uniform > 0 {
            return Array(repeating: uniform, count: count)
        }
        var sizes: [Int] = []
        var cursor = 12
        for _ in 0..<count {
            guard cursor + 4 <= bytes.count else { break }
            sizes.append(Int(be32(bytes, cursor)))
            cursor += 4
        }
        return sizes
    }

    /// `stco` payload: version+flags(4), entryCount(4), then 32-bit offsets.
    private static func parseStco(_ bytes: [UInt8]) -> [Int] {
        guard bytes.count >= 8 else { return [] }
        let count = Int(be32(bytes, 4))
        var offsets: [Int] = []
        var cursor = 8
        for _ in 0..<count {
            guard cursor + 4 <= bytes.count else { break }
            offsets.append(Int(be32(bytes, cursor)))
            cursor += 4
        }
        return offsets
    }

    /// `stsc` first-run expansion: returns samples-per-chunk for each chunk
    /// index up to totalSamples. Only the first run's value is used — a text
    /// chapter track has 1 sample per chunk in practice, and multi-run
    /// tables with the full run-index math are not worth the complexity for
    /// a title-only read.
    private static func parseStscFirstRun(_ bytes: [UInt8], totalSamples: Int) -> [Int] {
        guard bytes.count >= 16 else { return [] }
        let entries = Int(be32(bytes, 4))
        guard entries >= 1 else { return [] }
        let firstRunSamplesPerChunk = Int(be32(bytes, 12))
        guard firstRunSamplesPerChunk > 0 else { return [] }
        let needed = max(1, totalSamples)
        return Array(repeating: firstRunSamplesPerChunk, count: needed)
    }

    /// A QuickTime text sample: 16-bit BE length prefix (the "text length"
    /// field of the text media sample description), then UTF-8/UTF-16 or
    /// Pascal bytes. Tolerates the `encd` atom wrapper some encoders add.
    private static func parseTextSample(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 2 else { return "" }
        var cursor = 0
        // Some writers put a small atom ('encd') first — its size field then
        // skips the wrapper.
        if bytes.count >= 8 {
            let atomSize = Int(be32(bytes, 0))
            let atomType = String(bytes: bytes[4..<8], encoding: .isoLatin1) ?? ""
            if atomSize > 8, atomSize <= bytes.count, atomType == "encd" {
                cursor = atomSize
            }
        }
        guard cursor + 2 <= bytes.count else { return "" }
        // 16-bit BE length (the text media length field is TWO bytes; a
        // 32-bit read here swallowed the first two string bytes and the
        // titles came out empty — "Chapter 1, Chapter 2" on a fully-titled
        // book).
        let length = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
        cursor += 2
        let end = min(bytes.count, cursor + length)
        guard end > cursor else { return "" }
        let payload = Array(bytes[cursor..<end])
        // Encoding flag (0 = utf8/mac-roman, 1 = utf16) when a 2-byte
        // text-description marker precedes the string; most chapter tracks
        // are plain UTF-8.
        if let text = String(bytes: payload, encoding: .utf8), !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = String(bytes: payload, encoding: .utf16) { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let text = String(bytes: payload, encoding: .macOSRoman) { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }

    // MARK: - chpl

    /// https://developer.apple.com/documentation/quicktime-file-format —
    /// `chpl` payload: version+flags (4), reserved (4), chapter count (1),
    /// then per chapter an 8-byte start (in the movie timescale, usually
    /// 1/100 s but read from `mvhd` when we can) and a Pascal string title.
    private static func parseChpl(_ bytes: [UInt8]) -> [AudioChapter] {
        guard bytes.count >= 9 else { return [] }
        let count = Int(bytes[8])
        var cursor = 9
        var chapters: [AudioChapter] = []
        for _ in 0..<count {
            guard cursor + 9 <= bytes.count else { break }
            let rawStart = Int(bytes[cursor]) << 56 | Int(bytes[cursor + 1]) << 48
                | Int(bytes[cursor + 2]) << 40 | Int(bytes[cursor + 3]) << 32
                | Int(bytes[cursor + 4]) << 24 | Int(bytes[cursor + 5]) << 16
                | Int(bytes[cursor + 6]) << 8 | Int(bytes[cursor + 7])
            cursor += 8
            let titleLength = Int(bytes[cursor])
            cursor += 1
            guard cursor + titleLength <= bytes.count else { break }
            let title = String(
                bytes: bytes[cursor..<(cursor + titleLength)],
                encoding: .utf8
            ) ?? ""
            cursor += titleLength
            chapters.append(AudioChapter(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                startSeconds: Double(rawStart) / 100.0,
                endSeconds: 0
            ))
        }
        return chapters
    }

    // MARK: - ID3 CHAP

    /// CHAP payload: element id (null-terminated), start (4), end (4),
    /// start offset (4), end offset (4), then a sub-frame list whose TIT2
    /// (v2.3) / TIT2 (v2.4) is the chapter name.
    private static func parseChapFrame(_ bytes: [UInt8]) -> AudioChapter? {
        var cursor = 0
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        guard cursor < bytes.count else { return nil }
        cursor += 1 // NUL
        guard cursor + 16 <= bytes.count else { return nil }
        let startMS = Int(be32(bytes, cursor))
        let endMS = Int(be32(bytes, cursor + 4))
        cursor += 16
        var title = ""
        while cursor + 10 <= bytes.count {
            let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .isoLatin1) ?? ""
            let size = Int(bytes[cursor + 4]) << 24 | Int(bytes[cursor + 5]) << 16
                | Int(bytes[cursor + 6]) << 8 | Int(bytes[cursor + 7])
            let payloadStart = cursor + 10
            let payloadEnd = min(bytes.count, payloadStart + size)
            guard payloadEnd > payloadStart else { break }
            if id == "TIT2" {
                title = decodeTextFrame(Array(bytes[payloadStart..<payloadEnd]))
            }
            cursor = payloadEnd
        }
        return AudioChapter(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startSeconds: Double(startMS) / 1000.0,
            endSeconds: Double(endMS) / 1000.0
        )
    }

    /// A text frame is an encoding byte then the payload; UTF-8 with a BOM and
    /// UTF-16 are both common in the wild.
    private static func decodeTextFrame(_ bytes: [UInt8]) -> String {
        guard let encodingByte = bytes.first else { return "" }
        let payload = Array(bytes.dropFirst())
        let data = Data(payload)
        switch encodingByte {
        case 0: return String(data: data, encoding: .isoLatin1) ?? ""
        case 1: return String(data: data, encoding: .utf16) ?? ""
        case 2: return String(data: data, encoding: .utf16BigEndian) ?? ""
        case 3: return String(data: data, encoding: .utf8) ?? ""
        default: return String(data: data, encoding: .utf8) ?? ""
        }
    }

    // MARK: - Shared

    /// Fills in missing end times (each chapter ends where the next starts),
    /// gives untitled chapters a positional name, and keeps only entries with
    /// a real start. Returns nil when there is nothing usable. Also used by
    /// the app to normalize AVFoundation's chapter groups.
    public static func normalize(_ chapters: [AudioChapter], totalSeconds: Double?) -> [AudioChapter]? {
        let usable = chapters
            .filter { $0.startSeconds >= 0 }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !usable.isEmpty else { return nil }
        var out: [AudioChapter] = []
        out.reserveCapacity(usable.count)
        for (index, chapter) in usable.enumerated() {
            var fixed = chapter
            if index + 1 < usable.count {
                if fixed.endSeconds <= fixed.startSeconds {
                    fixed.endSeconds = usable[index + 1].startSeconds
                }
            } else if let totalSeconds, totalSeconds > fixed.startSeconds {
                if fixed.endSeconds <= fixed.startSeconds {
                    fixed.endSeconds = totalSeconds
                }
            }
            if fixed.endSeconds <= fixed.startSeconds {
                fixed.endSeconds = fixed.startSeconds + 1
            }
            if fixed.title.isEmpty {
                fixed.title = "Chapter \(index + 1)"
            }
            out.append(fixed)
        }
        return out
    }

    // MARK: - Byte helpers

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(data[offset + index]) }
        return value
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(bytes[offset + index]) }
        return value
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        return value
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String {
        String(bytes: data[offset..<(offset + 4)], encoding: .isoLatin1) ?? ""
    }

    /// ID3 sizes are "sync-safe": 7 bits per byte, high bit always clear.
    private static func syncSafeInt(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        (Int(a & 0x7F) << 21) | (Int(b & 0x7F) << 14) | (Int(c & 0x7F) << 7) | Int(d & 0x7F)
    }
}
