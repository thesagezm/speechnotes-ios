import XCTest
@testable import SpeechLogic

/// The Opus decode path, against a REAL book when one is available.
///
/// Set `OPUS_BOOK` to a path and the test decodes actual packets from it;
/// without it the test is a no-op, so CI stays hermetic while the developer
/// can prove the pipeline end to end off-device.
///
/// This is the check that three previous rounds of "Opus not playing" never
/// had: the app read its packets, handed them to a system converter, and
/// never looked at whether a single sample came back. The sample content
/// check is the whole point.
final class OpusDecodeRealBookTests: XCTestCase {

    func testDecodesRealOpusBookToNonSilentPCM() throws {
        guard let path = ProcessInfo.processInfo.environment["OPUS_BOOK"],
              FileManager.default.fileExists(atPath: path) else {
            return   // hermetic on CI
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        // The head slice is enough: a page-boundary cut of the first 8 MB
        // carries the header and thousands of audio packets. OggReader
        // refuses a truncated stream (correctly), so the cut has to land on
        // a page boundary — hence the walk below.
        let limit = min(8 * 1024 * 1024, data.count)
        let bytes = [UInt8](data.prefix(limit))
        var offset = 0
        var lastGood = 0
        while offset + 27 <= bytes.count {
            let segmentCount = Int(bytes[offset + 26])
            guard offset + 27 + segmentCount <= bytes.count else { break }
            var cursor = offset + 27 + segmentCount
            var whole = true
            for index in 0..<segmentCount {
                let length = Int(bytes[offset + 27 + index])
                if cursor + length > bytes.count { whole = false; break }
                cursor += length
            }
            if !whole { break }
            offset = cursor
            lastGood = offset
        }
        XCTAssertGreaterThan(lastGood, 0, "no complete Ogg page in the head")

        let stream = try OggReader.read(Data(bytes[0..<lastGood])).packetStream
        XCTAssertEqual(stream.sampleRate, 48_000)
        guard let headerPacket = stream.headerPacket else {
            return XCTFail("the stream carried no OpusHead")
        }

        // The header parse is where a multistream book is won or lost: the
        // stream count, coupling count and channel map live in the tail of
        // OpusHead and there is no way to infer them.
        let header = try XCTUnwrap(OpusLib.parseHeader(headerPacket))
        XCTAssertEqual(header.channels, stream.channels)
        if header.channels > 2 {
            XCTAssertGreaterThan(header.channelMapping, 0,
                                 "more than two channels with family 0 is meaningless")
            XCTAssertGreaterThan(header.nbStreams, 1, "a multistream book needs >1 stream")
        }

        let opus = try OpusLib(head: headerPacket)
        var frames = 0
        var peak: Float = 0
        for packetMeta in stream.packets.prefix(40) {
            // Eager or lazy: `payload(of:)` is the one access path.
            guard let packetData = stream.payload(of: packetMeta) else { continue }
            let bytes = [UInt8](packetData)
            let expected = OpusLib.frameCount(packet: bytes)
            guard expected > 0 else { continue }
            var pcm = [Float](repeating: 0, count: expected * opus.channels)
            let decoded = opus.decode(packet: bytes, into: &pcm)
            guard decoded > 0 else { continue }
            frames += decoded
            for sample in pcm { peak = max(peak, abs(sample)) }
        }

        // The assertions that matter: frames came back AT ALL, and they are
        // not silence. Everything before this point could pass with a
        // decoder that was never actually exercised.
        XCTAssertGreaterThan(frames, 0, "libopus produced no frames")
        XCTAssertGreaterThan(peak, 0.001, "decoded audio is silent")
    }

    /// The header parse itself, against bytes we control: OpusHead is
    /// little-endian, and family-1 books carry the stream/coupling counts
    /// and the channel map in the packet tail.
    func testHeaderParseMatchesRFC7845() throws {
        var head: [UInt8] = Array("OpusHead".utf8)
        head += [0, 6]                                   // version, 6 channels
        head += [0x38, 0x01]                             // pre-skip 312 (LE)
        head += [0x80, 0xBB, 0x00, 0x00]                 // input rate 48000 (LE)
        head += [0, 0]                                   // gain 0
        head += [1]                                      // mapping family 1
        head += [4, 2]                                   // 4 streams, 2 coupled
        head += [0, 4, 1, 2, 3, 5]                       // channel map

        let header = try XCTUnwrap(OpusLib.parseHeader(head))
        XCTAssertEqual(header.channels, 6)
        XCTAssertEqual(header.preSkip, 312, "OpusHead is little-endian (RFC 7845 5.1)")
        XCTAssertEqual(header.inputSampleRate, 48_000)
        XCTAssertEqual(header.channelMapping, 1)
        XCTAssertEqual(header.nbStreams, 4)
        XCTAssertEqual(header.nbCoupled, 2)
        XCTAssertEqual(header.streamMap, [0, 4, 1, 2, 3, 5])
    }

    /// A big-endian read of the same bytes is the mistake this file was
    /// written after: 14337 instead of 312, i.e. 300 ms of decoder warm-up
    /// left in the first second of every book.
    func testPreSkipIsNotReadBigEndian() throws {
        var head: [UInt8] = Array("OpusHead".utf8)
        head += [0, 1]
        head += [0x38, 0x01]
        head += [0x80, 0xBB, 0x00, 0x00]
        head += [0, 0]
        head += [0]
        let header = try XCTUnwrap(OpusLib.parseHeader(head))
        XCTAssertEqual(header.preSkip, 312)
        XCTAssertNotEqual(header.preSkip, 0x3801)
    }

    func testHeaderRejectsGarbage() {
        XCTAssertNil(OpusLib.parseHeader(Array("NotOpus!!".utf8)))
        XCTAssertNil(OpusLib.parseHeader([1, 2, 3]))
        // family 0 with more than two channels is not a real stream.
        var head: [UInt8] = Array("OpusHead".utf8)
        head += [0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertNil(OpusLib.parseHeader(head))
    }
}
