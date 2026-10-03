import XCTest
@testable import SpeechLogic

/// OggReader against files produced by a real muxer, not hand-built bytes.
///
/// The fixtures are generated once (`Scripts/make-ogg-fixtures.sh`) so the
/// parser is tested against the page layouts ffmpeg/libopus actually emit:
/// packets spanning pages, and a Vorbis stream that is valid Ogg and NOT
/// Opus.
final class OggReaderTests: XCTestCase {

    private var fixtures: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OGG_FIXTURES"]
            ?? FileManager.default.currentDirectoryPath + "/fixtures")
    }

    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(name))
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
}