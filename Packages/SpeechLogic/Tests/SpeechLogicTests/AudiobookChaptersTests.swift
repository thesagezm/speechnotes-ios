import XCTest
@testable import SpeechLogic

final class AudiobookChaptersTests: XCTestCase {

    // MARK: - Builders (fixtures built in code, like the PDF ones)

    private func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(payload.count + 8) + Array(type.utf8) + payload
    }

    /// Standard Nero `chpl` payload: version(1) flags(3) count(4 BE), then
    /// per chapter: start(8, 100-NANOSECOND units) nameLen(1) name.
    /// (Round 5's fixture invented a different layout — reserved field +
    /// 1-byte count + hundredth-second starts — which is why the parser
    /// matched it and read NO real file. This builder now matches the spec
    /// VLC/mp4chaps/ffmpeg write.)
    private func chpl(_ entries: [(Int, String)]) -> [UInt8] {
        var payload: [UInt8] = [0, 0, 0, 0]      // version + flags
        payload += be32(entries.count)           // chapter count, 4 bytes
        for (start, title) in entries {
            // 100-ns units: seconds × 10_000_000.
            let raw = start * 10_000_000
            payload += [UInt8((raw >> 56) & 0xFF), UInt8((raw >> 48) & 0xFF),
                        UInt8((raw >> 40) & 0xFF), UInt8((raw >> 32) & 0xFF),
                        UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                        UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
            let bytes = Array(title.utf8)
            payload += [UInt8(bytes.count)] + bytes
        }
        return payload
    }

    /// An M4B-shaped file: ftyp, then moov, then mdat. Real encoders put
    /// `chpl` UNDER moov/udta — the round-6 root cause was a parser that
    /// only scanned moov's direct children. (The old fixture wrapped chpl
    /// directly in moov, hiding that bug.)
    private func m4b(chapters: [(Int, String)]) -> Data {
        let moov = box("moov", box("udta", box("chpl", chpl(chapters))))
        let ftyp = box("ftyp", Array("M4B ".utf8) + be32(0) + Array("M4B ".utf8))
        let mdat = box("mdat", [UInt8](repeating: 0, count: 32))
        return Data(ftyp + moov + mdat)
    }

    /// Same book with moov at the END (ffmpeg without +faststart) — the
    /// whole-container parse must still find it.
    private func m4bMoovAtEnd(chapters: [(Int, String)]) -> Data {
        let moov = box("moov", box("udta", box("chpl", chpl(chapters))))
        let ftyp = box("ftyp", Array("M4B ".utf8) + be32(0) + Array("M4B ".utf8))
        let mdat = box("mdat", [UInt8](repeating: 0, count: 4096))
        return Data(ftyp + mdat + moov)
    }

    private func id3Frame(_ id: String, _ payload: [UInt8], major: Int) -> [UInt8] {
        let size: [UInt8] = major == 4
            ? [UInt8((payload.count >> 21) & 0x7F), UInt8((payload.count >> 14) & 0x7F),
               UInt8((payload.count >> 7) & 0x7F), UInt8(payload.count & 0x7F)]
            : be32(payload.count)
        return Array(id.utf8) + size + [0, 0] + payload
    }
    private func mp3WithChapters(_ chapters: [(String, Int, Int, String)], major: Int) -> Data {
        var frames: [UInt8] = []
        for (elementId, start, end, title) in chapters {
            let titleFrame = id3Frame("TIT2", [3] + Array(title.utf8), major: major)
            var payload = Array(elementId.utf8) + [0]
            payload += be32(start) + be32(end) + be32(0) + be32(0)
            frames += Array("CHAP".utf8)
            let size: [UInt8] = major == 4
                ? [0, 0, 0, UInt8((payload.count + titleFrame.count) & 0x7F)]
                : be32(payload.count + titleFrame.count)
            frames += size + [0, 0] + payload + titleFrame
        }
        let tagSize = frames.count
        let header: [UInt8] = [
            0x49, 0x44, 0x33, UInt8(major), 0, 0,
            UInt8((tagSize >> 21) & 0x7F), UInt8((tagSize >> 14) & 0x7F),
            UInt8((tagSize >> 7) & 0x7F), UInt8(tagSize & 0x7F),
        ]
        return Data(header + frames + [UInt8](repeating: 0, count: 64))
    }

    // MARK: - MP4 / chpl

    func testChplChaptersAreRead() {
        // Starts are SECONDS (the fixture converts to 100-ns units, the
        // spec's on-disk unit).
        let data = m4b(chapters: [(0, "Opening"), (1234, "The Middle"), (2500, "The End")])
        let chapters = AudiobookChapters.chaptersFromMP4(data, totalSeconds: 3000)
        XCTAssertEqual(chapters.map(\.title), ["Opening", "The Middle", "The End"])
        XCTAssertEqual(chapters[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(chapters[1].startSeconds, 1234, accuracy: 0.001)
        XCTAssertEqual(chapters[2].startSeconds, 2500, accuracy: 0.001)
        // Missing ends are filled from the next start, and the last from the total.
        XCTAssertEqual(chapters[0].endSeconds, 1234, accuracy: 0.001)
        XCTAssertEqual(chapters[2].endSeconds, 3000, accuracy: 0.001)
    }

    func testMoovAtEndIsRead() {
        // ffmpeg without +faststart puts moov after mdat — the form VLC
        // reads and the old 8 MB head slice never saw.
        let data = m4bMoovAtEnd(chapters: [(0, "Prologue"), (600, "Epilogue")])
        let chapters = AudiobookChapters.chaptersFromMP4(data, totalSeconds: 1000)
        XCTAssertEqual(chapters.map(\.title), ["Prologue", "Epilogue"])
        XCTAssertEqual(chapters[1].startSeconds, 600, accuracy: 0.001)
    }

    /// ffmpeg movenc's chpl variant — the layout the USER'S own book uses
    /// (When Breath Becomes Air, MOODY release): 4 zero bytes where Nero
    /// puts the count, then the count as ONE byte at offset 8. The round-6
    /// parser read a 4-byte count and got 0 → "Full audiobook" forever.
    /// Byte layout mirrors the probed real file.
    func testFfmpegChplVariantIsRead() {
        var payload: [UInt8] = [1, 0, 0, 0]      // version 1 + flags
        payload += [0, 0, 0, 0]                  // ffmpeg's 4 zero bytes
        payload += [3]                           // count, ONE byte
        func entry(_ seconds: Int, _ title: String) -> [UInt8] {
            let raw = seconds * 10_000_000
            let start = [UInt8((raw >> 56) & 0xFF), UInt8((raw >> 48) & 0xFF),
                         UInt8((raw >> 40) & 0xFF), UInt8((raw >> 32) & 0xFF),
                         UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                         UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
            let bytes = Array(title.utf8)
            return start + [UInt8(bytes.count)] + bytes
        }
        payload += entry(0, "Opening Credits")
        payload += entry(27, "Events described are based on the author's")
        payload += entry(918, "Prologue")
        let moov = box("moov", box("udta", box("chpl", payload)))
        let data = Data(box("ftyp", Array("M4B ".utf8) + be32(0) + Array("M4B ".utf8)) + moov)
        let chapters = AudiobookChapters.chaptersFromMP4(data, totalSeconds: 19722.5)
        XCTAssertEqual(chapters.map(\.title), ["Opening Credits", "Events described are based on the author's", "Prologue"])
        XCTAssertEqual(chapters[1].startSeconds, 27, accuracy: 0.01)
        XCTAssertEqual(chapters[2].startSeconds, 918, accuracy: 0.01)
    }

    func testMillisecondChplFallsBackWhenSpecReadingOverflows() {
        // A writer that stored MILLISECONDS instead of 100-ns units: the
        // spec reading overflows the duration by ~10,000×, the ms reading
        // fits — the parser must pick ms.
        var payload: [UInt8] = [0, 0, 0, 0]
        payload += be32(2)
        for (ms, title) in [(0, "One"), (900_000, "Two")] {
            let raw = ms
            payload += [UInt8((raw >> 56) & 0xFF), UInt8((raw >> 48) & 0xFF),
                        UInt8((raw >> 40) & 0xFF), UInt8((raw >> 32) & 0xFF),
                        UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                        UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
            let bytes = Array(title.utf8)
            payload += [UInt8(bytes.count)] + bytes
        }
        let moov = box("moov", box("udta", box("chpl", payload)))
        let data = Data(box("ftyp", Array("M4B ".utf8) + be32(0) + Array("M4B ".utf8)) + moov)
        let chapters = AudiobookChapters.chaptersFromMP4(data, totalSeconds: 1000)
        XCTAssertEqual(chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(chapters[1].startSeconds, 900, accuracy: 0.001)
    }

    func testUntitledChaptersGetPositionalNames() {
        let data = m4b(chapters: [(0, ""), (100, ""), (200, "")])
        let chapters = AudiobookChapters.chaptersFromMP4(data, totalSeconds: 400)
        XCTAssertEqual(chapters.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 3"])
    }

    func testGarbageDataYieldsNoChapters() {
        let junk = Data([UInt8](repeating: 0x41, count: 512))
        XCTAssertTrue(AudiobookChapters.chaptersFromMP4(junk, totalSeconds: 10).isEmpty)
        XCTAssertTrue(AudiobookChapters.chaptersFromID3(junk).isEmpty)
    }

    func testTruncatedChplStopsInsteadOfCrashing() {
        var payload = chpl([(0, "One"), (100, "Two")])
        payload.removeLast(4) // chop the last title
        let data = Data(box("moov", box("chpl", payload)))
        let chapters = AudiobookChapters.chaptersFromMP4(data, totalSeconds: 200)
        // The first chapter survives; the truncated one is dropped, not
        // guessed at, and nothing crashes.
        XCTAssertEqual(chapters.map(\.title), ["One"])
    }

    // MARK: - ID3 CHAP

    func testID3ChapFramesAreRead() {
        let data = mp3WithChapters([
            ("ch1", 0, 6000, "First"),
            ("ch2", 6000, 12000, "Second"),
        ], major: 3)
        let chapters = AudiobookChapters.chaptersFromID3(data)
        XCTAssertEqual(chapters.map(\.title), ["First", "Second"])
        XCTAssertEqual(chapters[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(chapters[1].startSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(chapters[1].endSeconds, 12, accuracy: 0.001)
    }

    func testID3v24ChapFramesAreRead() {
        let data = mp3WithChapters([("ch1", 0, 1000, "Only")], major: 4)
        let chapters = AudiobookChapters.chaptersFromID3(data)
        XCTAssertEqual(chapters.map(\.title), ["Only"])
    }

    func testNonID3FileYieldsNoChapters() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A])
        XCTAssertTrue(AudiobookChapters.chaptersFromID3(data).isEmpty)
    }

    /// The extended-header flag makes the first four bytes after the tag
    /// header an extended header, not a frame. Both the v2.3 (plain 32-bit,
    /// inclusive) and v2.4 (sync-safe, exclusive) forms must be skipped, or
    /// the first real chapter is lost.
    func testExtendedHeaderIsSkipped() {
        for major in [3, 4] {
            var frames: [UInt8] = []
            for (elementId, start, end, title) in [("ch1", 0, 5000, "First")] {
                let titleFrame = id3Frame("TIT2", [3] + Array(title.utf8), major: major)
                var payload = Array(elementId.utf8) + [0]
                payload += be32(start) + be32(end) + be32(0) + be32(0)
                frames += Array("CHAP".utf8)
                let size: [UInt8] = major == 4
                    ? [0, 0, 0, UInt8((payload.count + titleFrame.count) & 0x7F)]
                    : be32(payload.count + titleFrame.count)
                frames += size + [0, 0] + payload + titleFrame
            }

            // v2.3: a plain 32-bit size that INCLUDES its own four bytes, so a
            // 6-byte extended header is a size of 6. v2.4: a sync-safe size
            // that EXCLUDES them, so a 4-byte extended header is a size of 0.
            let body: [UInt8] = major == 4
                ? [0, 0, 0, 0]        // sync-safe size 0, nothing else
                : be32(6) + [0, 0]   // plain size 6, body is exactly those bytes
            let extended = body + frames
            let tagSize = extended.count
            // Layout: "ID3" (0..2), major (3), revision (4), FLAGS (5),
            // sync-safe size (6..9). The extended-header flag lives in byte 5.
            let header: [UInt8] = [
                0x49, 0x44, 0x33, UInt8(major), 0, 0x40,
                UInt8((tagSize >> 21) & 0x7F), UInt8((tagSize >> 14) & 0x7F),
                UInt8((tagSize >> 7) & 0x7F), UInt8(tagSize & 0x7F),
            ]
            let data = Data(header + extended + [UInt8](repeating: 0, count: 64))
            let chapters = AudiobookChapters.chaptersFromID3(data)
            XCTAssertEqual(chapters.map(\.title), ["First"], "major v2.\(major) lost the first chapter")
        }
    }

    // MARK: - MP4 chapter TRACK (no chpl) — the form the first device v1.6
    // audiobook round turned up: m4b-tool/ffmpeg M4Bs carry chapters as a
    // text trak with a sample table, and the chpl-only parser read none.

    private func mvhd(timescale: Int) -> [UInt8] {
        var payload: [UInt8] = [0]                    // version 0
        payload += [0, 0, 0]                          // flags
        payload += be32(0) + be32(0)                  // created/modified
        payload += be32(timescale)                    // timescale
        payload += be32(timescale * 600)              // duration (10 min)
        return payload
    }

    /// A text chapter track: mdia{hdlr(text), mdhd, minf{stbl{stts, stsz,
    /// stsc, stco}}} — sample payload offsets are absolute file offsets.
    private func chapterTrak(
        timescale: Int,
        samples: [(offset: Int, delta: Int, size: Int, title: String)]
    ) -> [UInt8] {
        var sttsPayload: [UInt8] = [0, 0, 0, 0] + be32(samples.count)
        for sample in samples {
            sttsPayload += be32(1) + be32(sample.delta)
        }
        var stszPayload: [UInt8] = [0, 0, 0, 0] + be32(0) + be32(samples.count)
        for sample in samples {
            stszPayload += be32(sample.size)
        }
        // stsc: every chunk holds exactly 1 sample.
        let stscPayload: [UInt8] = [0, 0, 0, 0] + be32(1) + be32(1) + be32(1)
        var stcoPayload: [UInt8] = [0, 0, 0, 0] + be32(samples.count)
        for sample in samples {
            stcoPayload += be32(sample.offset)
        }
        let stbl = box("stbl",
            box("stts", sttsPayload)
                + box("stsz", stszPayload)
                + box("stsc", stscPayload)
                + box("stco", stcoPayload))
        var hdlrPayload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + Array("text".utf8)
        hdlrPayload += [UInt8](repeating: 0, count: 12)
        var mdhdPayload: [UInt8] = [0, 0, 0, 0]
        mdhdPayload += be32(0) + be32(0)
        mdhdPayload += be32(timescale)
        mdhdPayload += be32(samples.reduce(0) { $0 + $1.delta })
        let mdia = box("mdia",
            box("hdlr", hdlrPayload)
                + box("mdhd", mdhdPayload)
                + box("minf", stbl))
        return box("trak", mdia)
    }

    func testChapterTrackWithoutChplIsRead() {
        let timescale = 1000
        // Two tracks: the audio one (handler soun) and the chapter text
        // track. The parser must skip the audio track's stbl and read only
        // the text one.
        var sounHdlr: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + Array("soun".utf8)
        sounHdlr += [UInt8](repeating: 0, count: 12)
        let audioTrak = box("trak", box("mdia",
            box("hdlr", sounHdlr)
                + box("mdhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(timescale) + be32(600_000))
                + box("minf", box("stbl", box("stts", [0, 0, 0, 0] + be32(1) + be32(1024) + be32(600_000))))
        ))
        let ftyp = box("ftyp", Array("M4B ".utf8) + be32(0) + Array("M4B ".utf8))
        let mvhdBox = box("mvhd", mvhd(timescale: timescale))

        // Chapter sample payloads sit AFTER moov at absolute offsets, exactly
        // like a real M4B interleaves them. Build the trak twice: once with
        // placeholder offsets to learn moov's length, then for real.
        let placeholder = chapterTrak(timescale: timescale, samples: [
            (offset: 0, delta: 0, size: 0, title: ""),
            (offset: 0, delta: 30_000, size: 0, title: ""),
            (offset: 0, delta: 30_000, size: 0, title: ""),
        ])
        let provisionalMoov = box("moov", mvhdBox + audioTrak + placeholder)
        let payloadStart = ftyp.count + provisionalMoov.count

        let titles = ["The Beginning", "A Turn", "The End"]
        var samples: [(offset: Int, delta: Int, size: Int, title: String)] = []
        var payloads: [UInt8] = []
        var cursor = payloadStart
        for (index, title) in titles.enumerated() {
            let raw: [UInt8] = [UInt8((Array(title.utf8).count >> 8) & 0xFF),
                                UInt8(Array(title.utf8).count & 0xFF)] + Array(title.utf8)
            let padded = raw + [UInt8](repeating: 0, count: (4 - raw.count % 4) % 4)
            // stts delta = duration from THIS sample to the NEXT — the
            // first chapter's delta is the 30 s gap to chapter 2.
            samples.append((offset: cursor, delta: 30_000, size: padded.count, title: title))
            payloads += padded
            cursor += padded.count
        }

        let trak = chapterTrak(timescale: timescale, samples: samples)
        let moov = box("moov", mvhdBox + audioTrak + trak)
        let data = Data(ftyp + moov + payloads)

        let chapters = AudiobookChapters.chaptersFromMP4(data, totalSeconds: 90)
        XCTAssertEqual(chapters.map(\.title), ["The Beginning", "A Turn", "The End"])
        XCTAssertEqual(chapters[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(chapters[1].startSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(chapters[2].startSeconds, 60, accuracy: 0.001)
        // Ends filled from the next start; the last from the total.
        XCTAssertEqual(chapters[2].endSeconds, 90, accuracy: 0.001)
    }

    func testChapterTrackMissingTablesFallsBackCleanly() {
        // A trak with a text handler but no stbl must yield nothing, not crash.
        var hdlrPayload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + Array("text".utf8)
        hdlrPayload += [UInt8](repeating: 0, count: 12)
        let trak = box("trak", box("mdia", box("hdlr", hdlrPayload)))
        let moov = box("moov", box("mvhd", mvhd(timescale: 1000)) + trak)
        let data = Data(moov)
        XCTAssertTrue(AudiobookChapters.chaptersFromMP4(data, totalSeconds: 10).isEmpty)
    }
}
