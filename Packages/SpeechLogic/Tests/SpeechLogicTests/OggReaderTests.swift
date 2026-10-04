import XCTest
@testable import SpeechLogic

/// OggReader against files produced by a real muxer, not hand-built bytes.
///
/// The fixtures are generated once (`Scripts/make-ogg-fixtures.sh`) so the
/// parser is tested against the page layouts ffmpeg/libopus actually emit:
/// packets spanning pages, and a Vorbis stream that is valid Ogg and NOT
/// Opus.
final class OggReaderTests: XCTestCase {

    /// The fixtures are package resources — in the test BUNDLE on Apple
    /// platforms, a plain directory under OGG_FIXTURES for the Linux
    /// scratch builds.
    private func load(_ name: String) throws -> Data {
        if let bundled = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Ogg") {
            return try Data(contentsOf: bundled)
        }
        if let dir = ProcessInfo.processInfo.environment["OGG_FIXTURES"] {
            return try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return try Data(contentsOf: URL(fileURLWithPath: name))
    }

    // MARK: - Opus

    func testReadsOpusIdentificationAndDuration() throws {
        let stream = try OggReader.read(try load("plain.opus"))
        XCTAssertEqual(stream.info.codec, .opus)
        XCTAssertEqual(stream.info.channels, 1)
        XCTAssertEqual(stream.info.sampleRate, 48_000)
        // 20 ms packets over 3 s of 440 Hz sine.
        XCTAssertEqual(stream.packets.count, 153, accuracy: 2)
        // ffprobe says 3.0065 s; pre-skip (312 samples ≈ 6.5 ms) is removed,
        // which is the number a player actually needs.
        XCTAssertEqual(stream.duration, 3.0065, accuracy: 0.02)
    }

    func testFirstPacketIsOpusHead() throws {
        let stream = try OggReader.read(try load("plain.opus"))
        let head = stream.packets[0].payload
        XCTAssertEqual(String(bytes: head.prefix(8), encoding: .isoLatin1), "OpusHead")
        XCTAssertEqual(head[8], 1, "OpusHead version must be 1")
    }

    func testSecondPacketIsOpusTags() throws {
        let stream = try OggReader.read(try load("tagged.opus"))
        // Header packets come before audio: OpusHead, then OpusTags, then
        // packets. Anything else means the segment walk is off by a page.
        let tags = String(bytes: stream.packets[1].payload.prefix(8), encoding: .isoLatin1)
        XCTAssertEqual(tags, "OpusTags")
    }

    func testLongFilePacketCountAndSeeksLand() throws {
        let stream = try OggReader.read(try load("long.opus"))
        XCTAssertEqual(stream.duration, 120.0065, accuracy: 0.05)
        XCTAssertGreaterThan(stream.packets.count, 5_900)

        // Every seek must land ON a packet (never past the end) and never
        // AFTER the time asked for: a resume that lands early costs a few ms,
        // one that lands late skips audio.
        for seconds in stride(from: 0.0, through: 119.0, by: 7.0) {
            let index = stream.packetIndex(at: seconds)
            XCTAssertLessThan(index, stream.packets.count)
            let landed = Double(Int64(stream.packets[index].granule) - Int64(stream.info.preSkip)) / 48_000
            XCTAssertLessThanOrEqual(landed, seconds + 0.03, "seek to \(seconds) landed late")
        }
        // Time ≤ 0 must land on the first AUDIO packet — packets 0 and 1 are
        // the OpusHead/OpusTags headers, and the decoder must never be fed
        // those. (The old expectation of 0 handed the headers to the decoder.)
        XCTAssertEqual(
            stream.packetIndex(at: -5),
            stream.packets.firstIndex { $0.granule > 0 }
        )
        XCTAssertEqual(stream.packetIndex(at: 9_999), stream.packets.count - 1)
    }

    func testChapterBoundariesAreUniqueAndInsideTheFile() throws {
        let stream = try OggReader.read(try load("long.opus"))
        // 0, 30, 60, 90 — and 120 is dropped because it is the end of the
        // file, not a chapter start. Boundaries sit on packet granules, and
        // granule→seconds removes pre-skip, so each lands a few ms before
        // the whole second — accuracy, not equality.
        let boundaries = stream.chapterBoundaries(stepSeconds: 30)
        XCTAssertEqual(boundaries.count, 4)
        for (index, boundary) in boundaries.enumerated() {
            XCTAssertEqual(boundary, Double(index) * 30, accuracy: 0.02)
        }
    }

    func testPacketGranuleStepsAre20ms() throws {
        // Opus granule steps 960 at 48 kHz for 20 ms frames. If the walk
        // invented or dropped a packet, the step would not be constant.
        let stream = try OggReader.read(try load("plain.opus"))
        let granules = stream.packets.map(\.granule)
        for index in 1..<granules.count {
            let step = granules[index] - granules[index - 1]
            XCTAssertLessThanOrEqual(step, 960, "packet \(index) advanced \(step) samples")
        }
    }

    // MARK: - Not Opus, but still Ogg

    func testVorbisStreamIsNotClaimedAsOpus() throws {
        // A .oga holding Vorbis: valid Ogg, and the app must say "not Opus"
        // rather than hand Vorbis packets to the Opus decoder.
        let stream = try OggReader.read(try load("realvorbis.oga"))
        guard case .other(let magic) = stream.info.codec else {
            return XCTFail("Vorbis stream claimed as Opus")
        }
        XCTAssertFalse(magic.isEmpty)
        XCTAssertFalse(stream.packets.isEmpty)
    }

    // MARK: - Failures

    func testNonOggBytesAreRejected() {
        XCTAssertThrowsError(try OggReader.read(Data(repeating: 0x41, count: 512))) { error in
            XCTAssertEqual(error as? OggReader.OggError, .notOgg)
        }
    }

    func testFlacIsNotMistakenForOgg() {
        // "fLaC" — a real audio container that also turns up with an .oga
        // extension. The capture-pattern check is what keeps it out.
        let flac = Data([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22])
            + Data(repeating: 0, count: 256)
        XCTAssertThrowsError(try OggReader.read(flac)) { error in
            XCTAssertEqual(error as? OggReader.OggError, .notOgg)
        }
    }

    func testTruncatedStreamThrowsRatherThanReturningHalfTheBook() throws {
        let data = try load("plain.opus")
        XCTAssertThrowsError(try OggReader.read(data.prefix(data.count / 2)))
    }

    // MARK: - OpusTags chapter marks

    /// Builds one Ogg page by hand. The parser verifies the capture pattern
    /// and walks the segment table — CRC is not checked (it is not needed
    /// for structure), which is what makes a synthetic page possible.
    private func oggPage(segments: [Data], granule: UInt64 = 0, serial: UInt32 = 7, seq: UInt32) -> Data {
        var header = Data([0x4F, 0x67, 0x67, 0x53])   // "OggS"
        header.append(0)                              // version
        header.append(0)                              // header type flags
        var g = granule.littleEndian
        withUnsafeBytes(of: &g) { header.append(contentsOf: $0) }
        var s = serial.littleEndian
        withUnsafeBytes(of: &s) { header.append(contentsOf: $0) }
        var q = seq.littleEndian
        withUnsafeBytes(of: &q) { header.append(contentsOf: $0) }
        header.append(contentsOf: [0, 0, 0, 0])       // CRC — unchecked here
        header.append(UInt8(segments.count))
        for segment in segments { header.append(UInt8(segment.count)) }
        var page = header
        for segment in segments { page.append(segment) }
        return page
    }

    private func opusTagsPacket(comments: [String]) -> Data {
        var out = Data("OpusTags".utf8)
        var vendor = UInt32(0).littleEndian
        withUnsafeBytes(of: &vendor) { out.append(contentsOf: $0) }
        var count = UInt32(comments.count).littleEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        for comment in comments {
            var length = UInt32(comment.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(contentsOf: comment.utf8)
        }
        return out
    }

    private func opusHeadPacket(channels: UInt8 = 2) -> Data {
        var head = Data("OpusHead".utf8)
        head.append(1)          // version
        head.append(channels)
        var preSkip = UInt16(312).littleEndian
        withUnsafeBytes(of: &preSkip) { head.append(contentsOf: $0) }
        var rate = UInt32(48_000).littleEndian
        withUnsafeBytes(of: &rate) { head.append(contentsOf: $0) }
        head.append(contentsOf: [0, 0])   // gain
        head.append(0)                    // mapping family 0
        return head
    }

    /// A head slice carrying OpusHead and OpusTags on two pages, with
    /// CHAPTER marks, yields them from `summary` in timeline order.
    func testSummaryReadsChapterMarksFromOpusTags() throws {
        let head = oggPage(segments: [opusHeadPacket()], seq: 0)
            + oggPage(segments: [opusTagsPacket(comments: [
                "CHAPTER002=The Vanishing Glass",
                "CHAPTER002url=00:29:30.500",
                "CHAPTER001=The Boy Who Lived",
                "CHAPTER001url=00:00:00.000",
                "encoder=Lavf59.27.100",
            ])], seq: 1)
        // A one-page tail: the final granule sets the duration (100 s).
        let tail = oggPage(segments: [Data(repeating: 0xFC, count: 100)], granule: 4_800_000, seq: 2)

        let summary = try OggReader.summary(head: head, tail: tail)
        XCTAssertEqual(summary.chapters.count, 2)
        XCTAssertEqual(summary.chapters[0].title, "The Boy Who Lived")
        XCTAssertEqual(summary.chapters[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(summary.chapters[1].title, "The Vanishing Glass")
        XCTAssertEqual(summary.chapters[1].startSeconds, 29 * 60 + 30.5, accuracy: 0.001)
    }

    /// A stream without CHAPTER comments reports no chapters — the caller's
    /// uniform fallback must stay in the picture.
    func testTagsWithoutChapterCommentsYieldNoChapters() {
        let tags = opusTagsPacket(comments: ["encoder=Lavf59.27.100", "title=Something"])
        XCTAssertEqual(OggReader.chapters(fromTagsPacket: tags).count, 0)
    }

    func testChapterTimecodeForms() {
        XCTAssertEqual(OggReader.chapterTimecode("01:02:03.500")!, 3723.5, accuracy: 0.001)
        XCTAssertEqual(OggReader.chapterTimecode("12:34.5")!, 754.5, accuracy: 0.001)
        XCTAssertEqual(OggReader.chapterTimecode("754.5")!, 754.5, accuracy: 0.001)
        XCTAssertNil(OggReader.chapterTimecode("not a time"))
        XCTAssertNil(OggReader.chapterTimecode(""))
    }
}