import Foundation
import AVFoundation
import SpeechLogic

/// Decodes the packets of an Opus stream, one chunk at a time.
///
/// The packets come from `OpusPacketStream` — the shared shape both
/// demuxers produce (`OggReader` for a raw Ogg stream, `Mp4OpusReader` for
/// an Opus-in-MP4 track). The decoder is Apple's — `AVAudioConverter` over
/// `kAudioFormatOpus`, the same Opus backend the system uses anywhere else —
/// so no vendored codec and no third-party dependency, which is also what
/// the LiveContainer rules require.
///
/// ## Why this shape
///
/// Audio has to be decoded in order, so this is a stateful, resummable
/// stream, not a `decode(index:)` lookup: seeking is "resume from packet N",
/// and the caller knows N from `OpusPacketStream.packetIndex`. Decoding is
/// deliberately chunked — one call decodes at most `packetLimit` packets —
/// because a ten-hour book is hundreds of MB of PCM and nothing wants that
/// materialize in one go.
///
/// Thread confinement: the decoder owns one `AVAudioConverter` and one
/// reusable `AVAudioCompressedBuffer`, neither of which is thread-safe. The
/// owner (the feed loop in `OpusAudioBackend`) must call `decodeChunk` from
/// ONE queue only.
public final class OpusPacketDecoder {

    public enum OpusDecoderError: LocalizedError, Sendable {
        case unavailable
        case noOutput

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This device cannot decode Opus."
            case .noOutput:
                return "The Opus decoder returned no audio."
            }
        }
    }

    /// The decoder's output format: float32 at Opus' own rate (always
    /// 48 kHz) with the stream's own channel count. The engine plays this
    /// format directly — the mixer node does any downmix.
    public let format: AVAudioFormat

    /// Samples still to be dropped from the head of the output (Opus'
    /// pre-skip — the decoder warming up, not the recording).
    private var pendingDrop: Int

    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioCompressedBuffer
    private var packets: [OpusPacketStream.Packet]
    private var index: Int

    /// - Parameters:
    ///   - stream: the packet stream to decode, in packet order.
    ///   - startAtPacket: the first packet to decode — a seek. Header
    ///     packets (granule 0, an Ogg-only concept) are skipped
    ///     automatically; the decoder must never be fed them.
    ///   - dropSamples: samples at the FRONT of the output to discard — the
    ///     stream's pre-skip when decoding starts at the stream's first
    ///     audio packet. A mid-stream seek needs no drop: the packet's own
    ///     granule already places its output on the timeline.
    public init(
        stream: OpusPacketStream,
        startAtPacket: Int = 0,
        dropSamples: Int = 0
    ) throws {
        let channels = max(1, stream.channels)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(stream.sampleRate), channels: UInt32(channels)) else {
            throw OpusDecoderError.unavailable
        }
        // The compressed source format, built by hand: `AVAudioFormat(settings:)`
        // is geared to linear PCM, and Opus' ASBD is variable-rate — zero
        // bytes-per-packet/frame, a nominal 20 ms frame, no flags.
        var opusASBD = AudioStreamBasicDescription(
            mSampleRate: Double(stream.sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let opusFormat = AVAudioFormat(streamDescription: &opusASBD) else {
            throw OpusDecoderError.unavailable
        }
        guard let converter = AVAudioConverter(from: opusFormat, to: format) else {
            throw OpusDecoderError.unavailable
        }
        // Prime method: the decoder trims pre-skip itself (the `dropSamples`
        // counter below) — the converter must not ALSO trim, or the start of
        // the book loses real audio.
        converter.primeMethod = .none

        let maxPacketSize = max(1, stream.packets.map { $0.payload.count }.max() ?? 1_275)
        guard let inputBuffer = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: maxPacketSize
        ) else {
            throw OpusDecoderError.unavailable
        }

        self.format = format
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.packets = stream.packets
        // Never start on the headers: packetIndex(at:) already skips them,
        // but a caller passing 0 by hand would otherwise feed OpusHead bytes
        // to the decoder as if they were audio.
        let firstAudio = stream.packets.firstIndex { $0.granule > 0 } ?? stream.packets.count
        self.index = max(startAtPacket, firstAudio)
        self.pendingDrop = max(0, dropSamples)
    }

    /// Whether every packet has been fed to the converter.
    public var isFinished: Bool { index >= packets.count }

    /// The packet about to be decoded, if any — its granule is the position
    /// a caller publishes while this chunk plays.
    public var pendingGranule: UInt64? {
        packets.indices.contains(index) ? packets[index].granule : nil
    }

    /// Decodes at most `packetLimit` packets into one buffer.
    ///
    /// - Returns: the decoded audio, or nil when the stream is exhausted.
    ///   Fewer than the full limit can come back when the converter decides
    ///   it has enough; that is fine — the caller just calls again.
    public func decodeChunk(packetLimit: Int = 64) throws -> AVAudioPCMBuffer? {
        guard !isFinished else { return nil }
        // 2880 frames is one 60 ms Opus packet — the largest there is — so
        // 2880 × limit covers the worst case for every packet in the chunk.
        let capacity = AVAudioFrameCount(2_880 * max(1, packetLimit))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw OpusDecoderError.unavailable
        }
        output.frameLength = 0

        var fed = 0
        let limit = max(1, packetLimit)
        let status = converter.convert(to: output, error: nil, withInputFrom: { _, inputStatus in
            if self.index >= self.packets.count {
                inputStatus.pointee = .endOfStream
                return nil
            }
            if fed >= limit {
                // Out of budget for this chunk — the caller comes back for
                // the rest. (Not .endOfStream: packets remain.)
                inputStatus.pointee = .noDataNow
                return nil
            }
            let packet = self.packets[self.index]
            self.index += 1
            fed += 1
            self.stage(packet: packet)
            inputStatus.pointee = .haveData
            return self.inputBuffer
        })

        switch status {
        case .error:
            throw OpusDecoderError.noOutput
        case .endOfStream, .haveData, .inputRanDry:
            break
        @unknown default:
            break
        }

        guard output.frameLength > 0 else {
            // Ran dry with nothing produced while packets remain would be a
            // wedged decoder — say so rather than silently skip audio.
            if !isFinished, fed < limit {
                throw OpusDecoderError.noOutput
            }
            return nil
        }

        // Pre-skip: the first `pendingDrop` frames of output are the decoder
        // priming, not the recording. Trimmed in place, per channel.
        if pendingDrop > 0 {
            let channels = Int(format.channelCount)
            let drop = min(pendingDrop, Int(output.frameLength))
            if let channelData = output.floatChannelData {
                for channel in 0..<channels {
                    let source = channelData[channel]
                    let remaining = Int(output.frameLength) - drop
                    if remaining > 0 {
                        memmove(source, source + drop, remaining * MemoryLayout<Float>.size)
                    }
                }
            }
            output.frameLength -= AVAudioFrameCount(drop)
            pendingDrop -= drop
        }

        guard output.frameLength > 0 else { return nil }
        return output
    }

    /// Copies one packet into the reusable compressed buffer and stamps its
    /// packet description. The description's frame count comes from the
    /// packet's own TOC byte (RFC 6716 §3.1) — the ASBD's nominal 960 is
    /// what variable packets fall back to, not what they are.
    private func stage(packet: OggReader.Packet) {
        let bytes = packet.payload
        let count = min(bytes.count, inputBuffer.byteLength)
        bytes.copyBytes(to: inputBuffer.data.assumingMemoryBound(to: UInt8.self), count: count)
        inputBuffer.byteLength = UInt32(count)
        inputBuffer.packetCount = 1
        if let descriptions = inputBuffer.packetDescriptions {
            descriptions[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: UInt32(Self.framesInPacket(opusPacket: bytes)),
                mDataByteSize: count
            )
        }
    }

    /// Frames of PCM one Opus packet decodes to, from its TOC byte: bits 5–7
    /// select the mode/rate config (which fixes the frame duration), bits
    /// 0–1 the frame packing (1 frame, 2 equal, 2 unequal, or N signaled by
    /// a frame-count byte). A malformed TOC degrades to the 20 ms nominal —
    /// the decoder still reads the real one; this only sizes the description.
    static func framesInPacket(opusPacket payload: Data) -> Int {
        guard let toc = payload.first else { return 960 }
        let config = Int(toc >> 3)
        let framesPerFrameMs: Double
        switch config {
        case 0...11: framesPerFrameMs = [10, 20, 40, 60][config % 4]     // SILK: NB/MB/WB
        case 12...15: framesPerFrameMs = config % 2 == 0 ? 10 : 20       // Hybrid: SWB/FS
        default: framesPerFrameMs = [2.5, 5, 10, 20][config % 4]         // CELT: NB/WB/SWB/FS
        }
        let framesPerFrame = Int(framesPerFrameMs / 1000 * 48_000)
        let frameCount: Int
        switch toc & 0x03 {
        case 0: frameCount = 1
        case 1, 2: frameCount = 2
        default:
            // Code 3: an arbitrary count in a second byte, ((b >> 3) + 1).
            if payload.count >= 2 {
                frameCount = Int(payload[payload.startIndex + 1] >> 3) + 1
            } else {
                frameCount = 1
            }
        }
        return max(1, framesPerFrame * frameCount)
    }
}
