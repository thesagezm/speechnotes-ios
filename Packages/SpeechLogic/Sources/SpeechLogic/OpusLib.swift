import Foundation
import COpus

/// The Opus decoder, through libopus — the reference implementation, and
/// the same one VLC links.
///
/// ## Why not the system
///
/// Every earlier attempt in this app went through `AVAudioConverter` over a
/// hand-built `kAudioFormatOpus` ASBD. That is not a public decoding path,
/// it never produced a decoded sample on device, and it cannot express a
/// multistream decode. libopus can, and does.
///
/// ## Why multistream, and why this is VLC's code
///
/// A stream with **channel mapping family 1** (any book with more than two
/// channels, which is every "5.1ch" encode) is a *multistream* stream: the
/// packet interleaves 3–4 coded streams plus coupling channels, and the
/// decoder must be told how many and how to map them. The single-stream
/// `opus_decoder` is the wrong tool and either errors or silently
/// downmixes. VLC gets this right and this file is transcribed from it,
/// deliberately:
///
///   * `modules/codec/opus_header.c` — `opus_header_parse`. OpusHead is
///     little-endian, and for family != 0 the packet carries the stream
///     count, coupling count and channel map right after the mapping
///     family byte. There is no table to look up.
///   * `modules/codec/opus.c` — `DecoderCreate` builds a
///     `opus_multistream_decoder` from those four numbers.
///   * `modules/codec/opus.c` — `DecodePacket` sizes the output buffer with
///     libopus' OWN helpers (`opus_packet_get_nb_frames` ×
///     `opus_packet_get_samples_per_frame`) and rejects anything outside
///     [2.5 ms, 120 ms]. Hand-rolling that from the TOC byte is what the
///     previous decoder did, and it is wrong for variable-frame packets.
///
/// VLC's channel-REORDER step for >2 channels is deliberately not copied:
/// it exists to match libopus' internal order to VLC's aout channel order,
/// and on iOS the mixer handles the layout.
public final class OpusLib {

    public enum OpusLibError: LocalizedError, Sendable {
        case badHeader
        case createFailed(Int32)
        case unsupportedMapping

        public var errorDescription: String? {
            switch self {
            case .badHeader: return "The Opus header is malformed."
            case .createFailed(let code): return "The Opus decoder could not start (error \(code))."
            case .unsupportedMapping:
                return "This Opus stream uses a channel mapping this device does not support."
            }
        }
    }

    /// The decoded header, in the shape `opus_header_parse` produces.
    public struct Header: Equatable, Sendable {
        public let channels: Int
        public let preSkip: Int
        public let inputSampleRate: Int
        public let gain: Int
        public let channelMapping: Int
        public let nbStreams: Int
        public let nbCoupled: Int
        public let streamMap: [UInt8]
    }

    public let channels: Int
    public let sampleRate = 48_000

    private let decoder: OpaquePointer
    private let map: [UInt8]

    /// - Parameter head: the book's `OpusHead` packet, verbatim.
    public init(head: [UInt8]) throws {
        guard let header = OpusLib.parseHeader(head) else { throw OpusLibError.badHeader }
        // VLC's own admissibility test, kept whole: >2 channels with family
        // 0 is meaningless, and families 2/3 (ambisonics, projection) are
        // not what an audiobook is.
        if (header.channels > 2 && header.channelMapping == 0)
            || header.channels > 8
            || header.channelMapping >= 2 {
            throw OpusLibError.unsupportedMapping
        }
        channels = header.channels
        map = header.streamMap
        var error: Int32 = 0
        let created: OpaquePointer? = map.withUnsafeBufferPointer { buffer in
            opus_multistream_decoder_create(
                48_000,
                Int32(header.channels),
                Int32(header.nbStreams),
                Int32(header.nbCoupled),
                buffer.baseAddress!,
                &error
            )
        }
        guard let created else { throw OpusLibError.createFailed(error) }
        decoder = created
    }

    deinit { opus_multistream_decoder_destroy(decoder) }

    /// Frames one packet decodes to, and how many float samples that is
    /// (interleaved). -1 when the packet is not decodable.
    ///
    /// VLC's `DecodePacket`, in its first half.
    public static func frameCount(packet: [UInt8]) -> Int {
        var spp = opus_packet_get_nb_frames(packet, Int32(packet.count))
        if spp > 0 { spp *= Int32(opus_packet_get_samples_per_frame(packet, 48_000)) }
        // VLC: `if (spp<120 || spp>120*48) return NULL;` — 2.5 ms … 120 ms.
        guard spp >= 120, spp <= 120 * 48 else { return -1 }
        return Int(spp)
    }

    /// Decodes one packet into interleaved floats. Returns the frame count,
    /// or -1 on a decode error.
    ///
    /// `output` must hold at least `frameCount(packet:) * channels` floats.
    public func decode(packet: [UInt8], into output: inout [Float]) -> Int {
        let spp = OpusLib.frameCount(packet: packet)
        guard spp > 0, output.count >= spp * channels else { return -1 }
        return packet.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { pcm in
                Int(opus_multistream_decode_float(
                    decoder,
                    input.baseAddress,
                    Int32(packet.count),
                    pcm.baseAddress!,
                    Int32(spp),
                    0
                ))
            }
        }
    }

    /// `opus_header_parse`, transcribed from VLC's
    /// `modules/codec/opus_header.c`.
    ///
    /// OpusHead, RFC 7845 §5.1, all multi-byte fields little-endian:
    /// `"OpusHead"`, version, channels, pre-skip, input sample rate,
    /// output gain, channel mapping family — and, when the family is not
    /// zero, the stream count, the coupled-stream count and the channel
    /// map, all read straight out of the packet.
    public static func parseHeader(_ packet: [UInt8]) -> Header? {
        guard packet.count >= 19,
              String(bytes: packet[0..<8], encoding: .isoLatin1) == "OpusHead"
        else { return nil }
        var cursor = 8
        let version = Int(packet[cursor]); cursor += 1
        guard version & 0xF0 == 0 else { return nil }
        let channels = Int(packet[cursor]); cursor += 1
        guard channels > 0 else { return nil }
        let preSkip = Int(packet[cursor]) | (Int(packet[cursor + 1]) << 8)
        cursor += 2
        let raw = UInt32(packet[cursor])
            | (UInt32(packet[cursor + 1]) << 8)
            | (UInt32(packet[cursor + 2]) << 16)
            | (UInt32(packet[cursor + 3]) << 24)
        let inputRate = Int(truncatingIfNeeded: raw)
        cursor += 4
        let rawGain = UInt16(packet[cursor]) | (UInt16(packet[cursor + 1]) << 8)
        let gain = Int(Int16(bitPattern: rawGain))
        cursor += 2
        let mapping = Int(packet[cursor]); cursor += 1

        var nbStreams = 0
        var nbCoupled = 0
        var streamMap = [UInt8](repeating: 0, count: 255)
        if mapping == 0 {
            guard channels <= 2 else { return nil }
            nbStreams = 1
            nbCoupled = channels > 1 ? 1 : 0
            streamMap[0] = 0
            streamMap[1] = 1
        } else if mapping < 4 {
            guard cursor < packet.count else { return nil }
            nbStreams = Int(packet[cursor]); cursor += 1
            guard nbStreams >= 1, cursor < packet.count else { return nil }
            nbCoupled = Int(packet[cursor]); cursor += 1
            guard nbCoupled <= nbStreams, cursor + channels <= packet.count else { return nil }
            for index in 0..<channels { streamMap[index] = packet[cursor + index] }
        } else {
            return nil
        }
        return Header(
            channels: channels,
            preSkip: preSkip,
            inputSampleRate: inputRate,
            gain: gain,
            channelMapping: mapping,
            nbStreams: nbStreams,
            nbCoupled: nbCoupled,
            streamMap: Array(streamMap.prefix(channels))
        )
    }
}
