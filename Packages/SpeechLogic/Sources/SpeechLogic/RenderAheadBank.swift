//
//  RenderAheadBank.swift
//  SpeechLogic
//
//  Render-ahead bank policy for the streaming TTS engines (Batch B of the
//  background-persistence plan — Docs/PLAN-BACKGROUND-PERSISTENCE.md §6).
//

import Foundation

/// Thermal pressure, decoupled from `ProcessInfo.ThermalState` so this file
/// stays buildable and testable on every platform (the package's other
/// consumers pass `thermalState.rawValue` in). Case order and meaning match
/// the Foundation enum: 0 nominal, 1 fair, 2 serious, 3 critical.
public enum ThermalPressure: Equatable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    /// Maps a raw `ProcessInfo.ThermalState.rawValue`. Values are clamped,
    /// not trapping: an unknown future raw value degrades to the hottest
    /// known state (conservative — under-sizing the bank only makes the
    /// producer hold earlier, it never over-runs a hot device), and a
    /// negative one to the coolest.
    public init(thermalStateRawValue: Int) {
        switch thermalStateRawValue {
        case ..<1: self = .nominal
        case 1: self = .fair
        case 2: self = .serious
        default: self = .critical
        }
    }
}

/// The render-ahead bank: how many seconds of generated-but-unplayed audio
/// the streaming pipeline may hold ahead of the playhead, and how hard the
/// synthesizer may work to fill it.
///
/// Batch B replaces the old CHUNK-COUNT throttle (`generationAheadLimit`
/// chunks) with AUDIO SECONDS, because the device log shows why chunk count
/// is the wrong unit: chunk audio length varies ~40× between a short
/// sentence and a packed 200-char chunk, so "2 chunks ahead" is anywhere
/// from 2 s to 40 s of protection against the 8–35 s main-thread stalls the
/// same log records. Seconds measure the thing the listener actually hears
/// run out.
///
/// Sizing tracks THERMAL STATE, from the same device log: synthesis RTF
/// measured 0.48 at nominal/fair but 1.68 at critical — above 1.0 the model
/// cannot keep pace with real time, so under pressure the bank shrinks
/// (less CPU spent generating audio that would arrive too late anyway) and
/// Supertonic drops its flow-matching denoising steps from 8 to 4, roughly
/// halving per-chunk work to pull the RTF back under 1.0.
///
/// The bank is ALSO capped in BYTES (`byteCapBytes`), not only seconds: the
/// models themselves already hold hundreds of MB resident (Supertonic
/// ~399 MB, Kokoro fp32 326 MB), and an audio-seconds figure alone says
/// nothing about memory — at 24 kHz mono Float32 a second is only 96 KB, so
/// the byte cap binds far above the seconds targets and exists as the
/// jetsam guard for future retuning (a higher seconds target, a higher
/// sample rate). An uncapped bank that gets the process jetsammed in the
/// background is itself a background-persistence failure, which is why the
/// cap lives in the same policy as the targets.
///
/// Pure arithmetic — no clocks, no I/O, no logging — so the whole policy is
/// assertable in CI (the app target has no test target; this package is the
/// only one that does).
public struct RenderAheadBankPolicy: Equatable {

    /// Hard ceiling on the bank in PCM bytes. The seconds targets bind far
    /// below it at every sample rate the engines use (24 kHz → 96 KB/s, so
    /// the largest seconds target is ~2.9 MB); this is the guard against a
    /// future retune or an unexpected sample rate, sized to stay an order of
    /// magnitude under jetsam territory alongside ~400 MB of resident
    /// ONNX sessions.
    public var byteCapBytes: Int

    /// The default byte cap: 32 MB ≈ 349 s at 24 kHz mono Float32.
    public static let defaultByteCapBytes = 32 * 1024 * 1024

    public init(byteCapBytes: Int = RenderAheadBankPolicy.defaultByteCapBytes) {
        self.byteCapBytes = byteCapBytes
    }

    /// Bank target in audio seconds, by thermal state. Nominal and fair
    /// share the full target: the device log shows RTF stays comfortably
    /// under 1.0 through fair, and the bank's job there is to ride out the
    /// 8–35 s main-thread stalls. At serious and critical it shrinks toward
    /// the minimum useful buffer — generating further ahead of a machine
    /// that has already lost real-time burns CPU (heat) for audio that
    /// cannot cover a drain anyway.
    public func targetSeconds(for thermal: ThermalPressure) -> Double {
        switch thermal {
        case .nominal, .fair: return 30
        case .serious: return 15
        case .critical: return 8
        }
    }

    /// Supertonic's flow-matching denoising step count, by thermal state.
    /// The upstream default is 8; under pressure 4. Audio DURATION is set by
    /// the duration predictor and does not depend on the step count — only
    /// synthesis time (and quality margin) does — so halving steps halves
    /// the model's work per chunk without touching pacing arithmetic.
    /// Kokoro has no step parameter and ignores this.
    public func totalStep(for thermal: ThermalPressure) -> Int {
        switch thermal {
        case .nominal, .fair: return 8
        case .serious, .critical: return 4
        }
    }

    /// Bytes of mono Float32 PCM per second of audio at `sampleRate`.
    public static func bytesPerSecond(sampleRate: Double) -> Double {
        sampleRate * 4
    }

    /// The target that actually gates the producer: the thermal seconds
    /// target, floored by the byte cap expressed in seconds. Non-positive
    /// sample rates fall back to treating the seconds target as binding
    /// (a zero sample rate cannot be converted to bytes; refusing to
    /// generate at all would be a worse failure than an unguarded bank).
    public func effectiveTargetSeconds(thermal: ThermalPressure, sampleRate: Double) -> Double {
        let secondsTarget = targetSeconds(for: thermal)
        guard sampleRate > 0 else { return secondsTarget }
        let bytesTarget = Double(byteCapBytes) / Self.bytesPerSecond(sampleRate: sampleRate)
        return min(secondsTarget, bytesTarget)
    }

    /// Whether the producer may synthesize the next chunk. The estimate is
    /// the next chunk's PREDICTED audio length (the real length is unknown
    /// until synthesis), so the bank can overshoot the target by at most one
    /// chunk — the estimator's error, not a leak.
    public func allowsNextChunk(
        bankedSeconds: Double,
        nextChunkEstimateSeconds: Double,
        thermal: ThermalPressure,
        sampleRate: Double
    ) -> Bool {
        let clampedEstimate = max(0, nextChunkEstimateSeconds)
        return bankedSeconds + clampedEstimate <= effectiveTargetSeconds(thermal: thermal, sampleRate: sampleRate)
    }

    /// Bank depth below which a node drain counts as `bank exhausted`
    /// (synthesis-bound silence) rather than an ordinary GAP (the
    /// main-thread-stall case, where the bank holds audio that scheduling
    /// could not reach). Half a second: enough to absorb the tracker's
    /// 0.3 s heartbeat quantisation, small enough that a genuinely empty
    /// bank never reads as covered.
    public static let exhaustionThresholdSeconds: Double = 0.5

    public static func isExhausted(bankedSeconds: Double) -> Bool {
        bankedSeconds < exhaustionThresholdSeconds
    }
}

/// Estimates the audio seconds a chunk of N UTF-16 characters will produce,
/// from the session's own measurements.
///
/// The producer needs the next chunk's length BEFORE synthesizing it, and
/// the duration predictor's answer only exists after synthesis — so the
/// bank's allow check runs on an estimate. This one is a smoothed
/// seconds-per-char: `estimate = chars × (seedSeconds + measuredSeconds) /
/// (seedChars + measuredChars)`, i.e. the seed behaves like 200 characters
/// of prior measurement and real chunks dilute it within a chunk or two.
///
/// The 0.1 s/char seed is the sanity anchor, not a claim: ~10 chars/s is
/// ordinary speech at rate 1.0, and the estimator's job is only to be within
/// a chunk-length of the truth so the bank overshoots by at most one chunk.
/// The caller normalizes for the speed slider (records divide out the speed
/// they were measured at; estimates divide by the current speed) because a
/// 2× rate change moves seconds-per-char 2× while this type should stay a
/// pure char→seconds map.
public struct CharAudioEstimator {
    public static let seedChars: Double = 200
    public static let seedSecondsPerChar: Double = 0.1

    private var measuredChars: Double = 0
    private var measuredSeconds: Double = 0

    public init() {}

    /// Records one measured chunk. Non-positive char counts are ignored
    /// (they cannot move a per-char rate); negative seconds are clamped —
    /// a zero-length audio return is a real measurement (the chunk will be
    /// skipped upstream) and is allowed to pull the estimate down.
    public mutating func record(chars: Int, audioSeconds: Double) {
        let c = Double(chars)
        guard c > 0 else { return }
        measuredChars += c
        measuredSeconds += max(0, audioSeconds)
    }

    /// Estimated audio seconds for a chunk of `chars` UTF-16 characters.
    public func estimateSeconds(chars: Int) -> Double {
        let c = Double(chars)
        guard c > 0 else { return 0 }
        let rate = (Self.seedChars * Self.seedSecondsPerChar + measuredSeconds)
            / (Self.seedChars + measuredChars)
        return c * rate
    }
}
