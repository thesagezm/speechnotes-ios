import XCTest
@testable import SpeechLogic

/// Mp4OpusReader against a structurally real MP4 built in-test.
///
/// No local muxer emits Opus-in-MP4 (ffmpeg's muxer gained the tag long
/// after its demuxer), so the fixture is assembled by hand: real ISO BMFF
/// boxes, real big-endian tables, the exact nesting `moov → trak → mdia →
/// minf → stbl` carries, plus the two traps real books bring — a chapter
/// text track beside the audio track, and a uniform-size `stsz`.
final class Mp4OpusReaderTests: XCTestCase {

    // MARK: - Mini MP4 builder

    private func box(_ type: String, _ payload: Data) -> Data {
        let size = payload.count + 8
        return Data([UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF),
                     UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
            + Data(type.utf8)
            + payload
    }

    private func u32(_ value: Int) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
              UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private func u16(_ value: Int) -> Data {
        Data([UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// One Opus audio track: stsd(Opus+dOps), stts, stsc, stsz, stco.
    /// The stco offsets are placeholders patched by `buildMp4`.
    private func opusTrak(
        packetSizes: [Int],
        samplesPerChunk: Int,
        preSkip: Int,
        channels: Int,
        timescale: Int = 48_000,
        uniformSize: Int? = nil
    ) -> Data {
        // Sample entry: 6 reserved + 2 data_ref_index, then the dOps box.
        var dOps = Data([0, UInt8(channels)])      // version, channels
        dOps.append(u16(preSkip))                   // pre-skip
        dOps.append(u32(48_000))                    // input sample rate
        dOps.append(u16(0))                         // gain
        dOps.append(Data([0]))                      // mapping family
        var stsd = u32(0) + u32(1)                  // version/flags, 1 entry
        stsd.append(box("Opus", Data(repeating: 0, count: 6) + u16(1) + box("dOps", dOps)))

        let stts = u32(0) + u32(1) + u32(packetSizes.count) + u32(960)
        let stsc = u32(0) + u32(1) + u32(1) + u32(samplesPerChunk) + u32(1)

        var stsz: Data
        if let uniformSize {
            stsz = u32(0) + u32(uniformSize) + u32(packetSizes.count)
        } else {
            var sizes = u32(0) + u32(0) + u32(packetSizes.count)
            for size in packetSizes { sizes.append(u32(size)) }
            stsz = sizes
        }

        let chunkCount = (packetSizes.count + samplesPerChunk - 1) / samplesPerChunk
        var stco = u32(0) + u32(chunkCount)
        for _ in 0..<chunkCount { stco.append(u32(0)) }

        var mdhd = Data([0, 0, 0, 0])               // v0, flags
        mdhd.append(u32(0) + u32(0))                // creation, modification
        mdhd.append(u32(timescale))
        mdhd.append(u32(0))                         // duration (unused here)
        mdhd.append(u16(0x55C4) + u16(0))           // language, pre_defined

        let mdia = box("mdia", box("mdhd", mdhd)
            + box("minf", box("stbl", box("stsd", stsd) + box("stts", stts)
                + box("stsc", stsc) + box("stsz", stsz) + box("stco", stco))))
        return box("trak", mdia)
    }

    /// A minimal text trak (the "chapter track" a muxer may attach): its
    /// tables (1 000 timescale, a `text` stsd) must never leak into the
    /// audio track's.
    private func textTrak() -> Data {
        var stsd = u32(0) + u32(1)
        stsd.append(box("text", Data(repeating: 0, count: 16)))
        let stts = u32(0) + u32(1) + u32(3) + u32(1_024)
        let stsc = u32(0) + u32(1) + u32(1) + u32(1) + u32(1)
        let stsz = u32(0) + u32(8) + u32(3)
        let stco = u32(0) + u32(1) + u32(64)
        let mdhd = Data([0, 0, 0, 0]) + u32(0) + u32(0) + u32(1_000) + u32(0) + u16(0) + u16(0)
        return box("trak", box("mdia", box("mdhd", mdhd)
            + box("minf", box("stbl", box("stsd", stsd) + box("stts", stts)
                + box("stsc", stsc) + box("stsz", stsz) + box("stco", stco)))))
    }

    /// ftyp + mdat(`packetCount` contiguous packets) + moov(traks), with
    /// each trak's stco patched to point at its chunks inside mdat. Chunks
    /// are `samplesPerChunk` consecutive packets, laid out back to back.
    private func buildMp4(
        traks: [Data],
        packetCount: Int,
        samplesPerChunk: Int,
        packetSize: Int
    ) -> Data {
        let packet = Data([0xFC, 0xFF, 0xFE])       // TOC 0xFC: CELT FB, 20 ms
        precondition(packetSize == packet.count, "the fixture's stsz says \(packetSize)")
        var body = Data()
        for _ in 0..<packetCount { body.append(packet) }

        // ftyp: a real box — [size][type][minorVersion][compatible brands].
        let ftypPayload = box("ftyp", u32(0x200) + Data("isomiso2mp41".utf8))

        // Chunks live in the mdat payload, which starts after ftyp + the
        // 8-byte mdat header.
        let mdatPayloadStart = ftypPayload.count + 8
        let chunkCount = (packetCount + samplesPerChunk - 1) / samplesPerChunk
        var chunkOffsets: [Int] = []
        for chunk in 0..<chunkCount {
            chunkOffsets.append(mdatPayloadStart + chunk * samplesPerChunk * packet.count)
        }

        let moovBody = traks.reduce(Data()) { $0 + patchStco($1, offsets: chunkOffsets) }
        let moov = box("moov", moovBody)
        return ftypPayload + box("mdat", body) + moov
    }

    /// Rewrites the placeholder offsets inside a trak's stco with the real
    /// chunk offsets.
    private func patchStco(_ trak: Data, offsets: [Int]) -> Data {
        var out = trak
        guard let stcoRange = out.range(of: Data("stco".utf8)) else { return out }
        var cursor = stcoRange.upperBound + 4       // version/flags
        let count = Int(out[cursor]) << 24 | Int(out[cursor + 1]) << 16
            | Int(out[cursor + 2]) << 8 | Int(out[cursor + 3])
        cursor += 4
        for index in 0..<min(count, offsets.count) {
            let value = offsets[index]
            out[cursor] = UInt8(value >> 24 & 0xFF)
            out[cursor + 1] = UInt8(value >> 16 & 0xFF)
            out[cursor + 2] = UInt8(value >> 8 & 0xFF)
            out[cursor + 3] = UInt8(value & 0xFF)
            cursor += 4
        }
        return out
    }

    private func standardOpusFixture(
        samplesPerChunk: Int = 2,
        uniformSize: Int? = nil,
        traks: ((Data) -> [Data])? = nil,
        timescale: Int = 48_000,
        preSkip: Int = 312
    ) throws -> OpusPacketStream {
        let audio = opusTrak(
            packetSizes: [3, 3, 3, 3],
            samplesPerChunk: samplesPerChunk,
            preSkip: preSkip,
            channels: 2,
            timescale: timescale,
            uniformSize: uniformSize
        )
        let data = buildMp4(
            traks: traks?(audio) ?? [audio],
            packetCount: 4,
            samplesPerChunk: samplesPerChunk,
            packetSize: 3
        )
        return try Mp4OpusReader.read(data)
    }

    // MARK: - The reads

    func testReadsPacketsGranulesAndDOps() throws {
        let stream = try standardOpusFixture()
        XCTAssertEqual(stream.packets.count, 4)
        XCTAssertEqual(stream.channels, 2)
        XCTAssertEqual(stream.preSkip, 312)
        XCTAssertEqual(stream.sampleRate, 48_000)
        // Two 960-sample samples per chunk, granulated in stts order.
        XCTAssertEqual(stream.packets.map { $0.granule }, [960, 1_920, 2_880, 3_840])
        // `payload` is optional since the lazy-stream shape arrived (eager
        // packets always carry it; lazy ones read through the mapped source).
        XCTAssertEqual(stream.packets[0].payload, Data([0xFC, 0xFF, 0xFE]))
        XCTAssertEqual(stream.duration, (3_840 - 312) / 48_000.0, accuracy: 1e-9)
    }

    func testPacketIndexSkipsPreSkipAndLandsOnPacketBoundaries() throws {
        let stream = try standardOpusFixture()
        // 0.02 s = 960 samples + pre-skip 312 → the packet ending at 1 920.
        XCTAssertEqual(stream.packetIndex(at: 0.02), 1)
        XCTAssertEqual(stream.packetIndex(at: 0), 0)
        XCTAssertEqual(stream.packetIndex(at: -5), 0)
        XCTAssertEqual(stream.packetIndex(at: 9_999), 3)
    }

    func testUniformStszReadsTheSameAsVariable() throws {
        let stream = try standardOpusFixture(samplesPerChunk: 4, uniformSize: 3)
        XCTAssertEqual(stream.packets.count, 4)
        XCTAssertEqual(stream.packets.map { $0.granule }, [960, 1_920, 2_880, 3_840])
    }

    func testTextChapterTrackDoesNotClobberTheAudioTrack() throws {
        // The text trak comes FIRST, the way chapter-attaching muxers lay
        // tracks out; its 1 000 timescale must not win.
        let stream = try standardOpusFixture { audio in [self.textTrak(), audio] }
        XCTAssertEqual(stream.packets.count, 4)
        XCTAssertEqual(stream.sampleRate, 48_000)
        XCTAssertEqual(stream.packets.map { $0.granule }, [960, 1_920, 2_880, 3_840])
    }

    func testNonZeroTimescaleIsNormalizedTo48k() throws {
        let stream = try standardOpusFixture(timescale: 24_000, preSkip: 0)
        // Granules written on a 24 kHz timescale double to 48 kHz.
        XCTAssertEqual(stream.packets.map { $0.granule }, [1_920, 3_840, 5_760, 7_680])
        XCTAssertEqual(stream.duration, 7_680 / 48_000.0, accuracy: 1e-9)
    }

    func testNonMp4BytesAreRejected() {
        XCTAssertThrowsError(try Mp4OpusReader.read(Data(repeating: 0x41, count: 512))) { error in
            XCTAssertEqual(error as? Mp4OpusReader.Mp4OpusError, .malformed)
        }
    }

    func testMp4WithoutOpusTrackIsRejected() throws {
        let data = buildMp4(traks: [textTrak()], packetCount: 4, samplesPerChunk: 1, packetSize: 3)
        XCTAssertThrowsError(try Mp4OpusReader.read(data)) { error in
            XCTAssertEqual(error as? Mp4OpusReader.Mp4OpusError, .noOpusTrack)
        }
    }

    func testTruncatedSampleTableIsRejected() throws {
        let audio = opusTrak(packetSizes: [3, 3, 3, 3], samplesPerChunk: 2, preSkip: 312, channels: 2)
        var data = buildMp4(traks: [audio], packetCount: 4, samplesPerChunk: 2, packetSize: 3)
        data = data.prefix(data.count - 40)         // cut into the moov tables
        XCTAssertThrowsError(try Mp4OpusReader.read(data))
    }
}
