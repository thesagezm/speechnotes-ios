import Foundation
import AVFoundation
import SpeechLogic

/// Decodes Opus packets to PCM, one chunk at a time, through libopus.
///
/// State by design: audio has to be decoded in order, so seeking is "resume
/// from packet N" (the caller knows N from `OpusPacketStream.packetIndex`)
/// and the decoder is rebuilt for each rearm — which is also how Opus wants
/// it, since libopus state IS a running decode position.
///
/// Thread confinement: one decoder and one scratch buffer, neither
/// thread-safe. The owner (the feed queue in `OpusAudioBackend`) calls
/// `decodeChunk` from ONE queue.
public final class OpusPacketDecoder {

    public enum OpusDecoderError: LocalizedError, Sendable {
        case noHeader
        case noOutput
        case badFormat(channels: Int)

        public var errorDescription: String? {
            switch self {
            case .noHeader:
                return "This Opus stream has no readable header."
            case .noOutput:
                return "The Opus decoder returned no audio."
            case .badFormat(let channels):
                return "Cannot build a \(channels)-channel audio format on this device."
            }
        }
    }

    /// The decoder's output format: float32 at Opus' fixed 48 kHz with the
    /// stream's own channel count (6 for a 5.1 book). The engine's mixer
    /// narrows the layout to the device's.
    public let format: AVAudioFormat

    /// Samples still to drop from the head of the output (the pre-skip the
    /// decoder emits before real audio begins).
    private var pendingDrop: Int

    private let opus: OpusLib
    /// The STREAM's channel count — what libopus decodes into the scratch.
    private let channels: Int
    /// The OUTPUT's channel count — min(2, `channels`); see the format note
    /// in `init`. Multichannel streams are downmixed on the way out.
    private let outputChannels: Int
    private let packets: [OpusPacketStream.Packet]
    private var index: Int
    private var scratch: [Float]

    /// - Parameters:
    ///   - stream: the packet stream, with its header packet.
    ///   - startAtPacket: the first packet to decode — a seek.
    ///   - dropSamples: samples to discard from the front of the output: the
    ///     stream's pre-skip when decoding from its first audio packet, zero
    ///     for a mid-stream start (whose granule already places it on the
    ///     timeline).
    public init(
        stream: OpusPacketStream,
        startAtPacket: Int = 0,
        dropSamples: Int = 0
    ) throws {
        guard let headerPacket = stream.headerPacket else { throw OpusDecoderError.noHeader }
        let lib = try OpusLib(head: headerPacket)
        // The DECODE runs at the stream's channel count (libopus multistream
        // writes all of them), but the OUTPUT is downmixed to at most stereo:
        // the layout-less format initializer returns NIL on iOS for >2
        // channels, and AVAudioUnitTimePitch — the speed knob — accepts only
        // mono/stereo. Every 5.1 book used to die at the format build with
        // the misleading `noOutput` ("the decoder returned no audio" when
        // nothing had been decoded yet; the device log's instant
        // `decoder rearm failed — noOutput` right after `stream ready`).
        channels = lib.channels
        outputChannels = min(2, channels)
        guard let built = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(lib.sampleRate),
            channels: AVAudioChannelCount(outputChannels),
            interleaved: false
        ) else {
            throw OpusDecoderError.badFormat(channels: outputChannels)
        }
        format = built
        self.opus = lib
        self.packets = stream.packets
        // Never start on the headers (granule 0, an Ogg-only concept).
        let firstAudio = stream.packets.firstIndex { $0.granule > 0 } ?? stream.packets.count
        self.index = max(startAtPacket, firstAudio)
        self.pendingDrop = max(0, dropSamples)
        // One packet is at most 120 ms; two is a comfortable chunk.
        self.scratch = [Float](repeating: 0, count: 2 * 5760 * lib.channels)
    }

    /// Whether every packet has been decoded.
    public var isFinished: Bool { index >= packets.count }

    /// The packet about to be decoded — its granule is the position a caller
    /// publishes while this chunk plays.
    public var pendingGranule: UInt64? {
        packets.indices.contains(index) ? packets[index].granule : nil
    }

    /// Decodes up to `packetLimit` packets into one non-interleaved buffer.
    ///
    /// - Returns: the audio, or nil at the end of the stream.
    public func decodeChunk(packetLimit: Int = 64) throws -> AVAudioPCMBuffer? {
        var interleaved: [Float] = []
        interleaved.reserveCapacity(scratch.count)
        var produced = 0
        let limit = max(1, packetLimit)

        while produced < limit, index < packets.count {
            let packet = Array(packets[index].payload)
            index += 1
            let frames = OpusLib.frameCount(packet: packet)
            guard frames > 0, frames * channels <= scratch.count else { continue }
            for slot in scratch.indices { scratch[slot] = 0 }
            let count = opus.decode(packet: packet, into: &scratch)
            guard count > 0 else { continue }
            interleaved.append(contentsOf: scratch[0..<(count * channels)])
            produced += 1
        }

        guard !interleaved.isEmpty else { return nil }

        // Pre-skip: the decoder's warm-up, not the recording.
        var frames = interleaved.count / channels
        var start = 0
        if pendingDrop > 0 {
            let drop = min(pendingDrop, frames)
            start = drop * channels
            frames -= drop
            pendingDrop -= drop
        }
        guard frames > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw OpusDecoderError.noOutput
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let body = Array(interleaved[start..<(start + frames * channels)])
        body.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress,
                  let destinations = buffer.floatChannelData else { return }
            // libopus writes interleaved; the engine wants planar. When the
            // stream is multichannel, Lo/Ro-downmix to stereo on the way —
            // both centers onto both outputs at -3 dB, the surrounds at
            // -6 dB on their own side, LFE mixed in low (rumble a book does
            // not need). Channel indexes follow the Vorbis/Opus orders:
            // 3 = L C R, 5 = L C R Ls Rs, 6 = L C R Ls Rs LFE, 7 = … BC LFE,
            // 8 = … BL BR LFE — LFE is always LAST from 6 channels up, which
            // is why the index is derived rather than hard-coded.
            if outputChannels == channels {
                for channel in 0..<outputChannels {
                    let destination = destinations[channel]
                    for frame in 0..<frames {
                        destination[frame] = base[frame * channels + channel]
                    }
                }
                return
            }
            for frame in 0..<frames {
                let frameBase = frame * channels
                var left: Float
                var right: Float
                if channels == 4 {
                    // Vorbis quad: L R Ls Rs.
                    left = base[frameBase] + 0.5 * base[frameBase + 2]
                    right = base[frameBase + 1] + 0.5 * base[frameBase + 3]
                } else {
                    left = base[frameBase] + 0.707 * base[frameBase + 1]
                    right = base[frameBase + 2] + 0.707 * base[frameBase + 1]
                    if channels >= 5 {
                        left += 0.5 * base[frameBase + 3]
                        right += 0.5 * base[frameBase + 4]
                    }
                    if channels >= 6 {
                        let lfe = base[frameBase + channels - 1]
                        left += 0.25 * lfe
                        right += 0.25 * lfe
                    }
                }
                destinations[0][frame] = max(-1, min(1, left))
                if outputChannels == 2 {
                    destinations[1][frame] = max(-1, min(1, right))
                }
            }
        }
        return buffer
    }
}
