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

    private func chpl(_ entries: [(Int, String)]) -> [UInt8] {
        var payload: [UInt8] = [0, 0, 0, 0]      // version + flags
        payload += [0, 0, 0, 0]                  // reserved
        payload += [UInt8(entries.count)]        // chapter count
        for (start, title) in entries {
            payload += [UInt8((start >> 56) & 0xFF), UInt8((start >> 48) & 0xFF),
                        UInt8((start >> 40) & 0xFF), UInt8((start >> 32) & 0xFF),
                        UInt8((start >> 24) & 0xFF), UInt8((start >> 16) & 0xFF),
                        UInt8((start >> 8) & 0xFF), UInt8(start & 0xFF)]
            let bytes = Array(title.utf8)
            payload += [UInt8(bytes.count)] + bytes
        }
        return payload
    }

    /// An M4B-shaped file: ftyp, then moov, then mdat. `chpl` is a BOX inside
    /// moov — [4-byte size][4-byte type][payload] — which is what real
    /// encoders write; wrapping the raw chpl payload directly in moov is not a
    /// valid file and no parser could read it.
    private func m4b(chapters: [(Int, String)]) -> Data {
        let moov = box("moov", box("chpl", chpl(chapters)))
        let ftyp = box("ftyp", Array("M4B ".utf8) + be32(0) + Array("M4B ".utf8))
        let mdat = box("mdat", [UInt8](repeating: 0, count: 32))
        return Data(ftyp + moov + mdat)
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
        // Starts are in hundredths of a second.
        let data = m4b(chapters: [(0, "Opening"), (1234, "The Middle"), (2500, "The End")])
        let chapters = AudiobookChapters.chaptersFromMP4(data, totalSeconds: 3000)
        XCTAssertEqual(chapters.map(\.title), ["Opening", "The Middle", "The End"])
        XCTAssertEqual(chapters[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(chapters[1].startSeconds, 12.34, accuracy: 0.001)
        XCTAssertEqual(chapters[2].startSeconds, 25.0, accuracy: 0.001)
        // Missing ends are filled from the next start, and the last from the total.
        XCTAssertEqual(chapters[0].endSeconds, 12.34, accuracy: 0.001)
        XCTAssertEqual(chapters[2].endSeconds, 3000, accuracy: 0.001)
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
}
