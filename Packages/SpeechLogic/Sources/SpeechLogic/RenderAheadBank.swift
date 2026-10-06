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
/// The allow check is deliberately just `banked < target` — NOT
/// `banked + estimatedNextChunk ≤ target`. A target can drop below one
/// chunk's audio length (critical's 8 s vs a ~20 s chunk), and an
/// estimate-including check never passes then: the producer wedges forever
/// with a starving bank. The shipped check overshoots the target by at most
/// one chunk — bounded, and unable to deadlock.
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

    /// Supertonic's full-quality flow-matching step count — the upstream
    /// ExampleONNX default. Used verbatim at nominal/fair and on offline
    /// exports (where RTF > 1 costs nothing, so the pressure shed never
    /// applies).
    public static let fullQualityTotalStep = 8

    public init(byteCapBytes: Int = RenderAheadBankPolicy.defaultByteCapBytes) {
        self.byteCapBytes = byteCapBytes
    }

    /// Bank target in audio seconds, by thermal state. Nominal and fair
    /// share the full target: the device log shows RTF stays comfortably
    /// under 1.0 through fair, and the bank's job there is to ride out the
    /// 8–35 s main-thread stalls. At serious and critical it shrinks toward
    /// the minimum useful buffer — generating further ahead of a machine
    /// that has already lost real time burns CPU (heat) for audio that
    /// cannot cover a drain anyway.
    public func targetSeconds(for thermal: ThermalPressure) -> Double {
        switch thermal {
        case .nominal, .fair: return 30
        case .serious: return 15
        case .critical: return 8
        }
    }

    /// Supertonic's flow-matching denoising step count, by thermal state.
    /// Audio DURATION is set by the duration predictor and does not depend
    /// on the step count — only synthesis time (and quality margin) does —
    /// so fewer steps means faster chunks and NOTHING else in the pacing
    /// arithmetic. Kokoro has no step parameter and ignores this.
    ///
    /// **The 2026-10-06 device verdict: shedding at `serious` overshot.**
    /// Continuous generation heats the phone, so real sessions sit at
    /// `serious` for their whole length — the 8/8/4/4 ladder rendered ~90%
    /// of a 17-minute book at 4 steps: audible artifacts, pitch drifting
    /// between chunks, unnatural breaks (the user's quality report, which
    /// outranks speed). The same device ran 8-step chunks at RTF 0.42–0.49 —
    /// full quality keeps ahead of playback ~2:1. The shed is now an
    /// EMERGENCY gear only: 4 steps at critical thermal, where the Batch A
    /// log measured RTF 1.68 at 8 steps and speech would stall outright.
    public func totalStep(for thermal: ThermalPressure) -> Int {
        switch thermal {
        case .nominal, .fair, .serious: return Self.fullQualityTotalStep
        case .critical: return 4
        }
    }

    /// How far the producer may pre-render under thermal pressure, as a
    /// multiplier on the state's seconds target (Batch C2).
    ///
    /// Kokoro has no compute dial — no step parameter, and shrinking chunks
    /// does not lower a transformer's RTF, which is roughly constant in
    /// chunk size. What smaller banks DO buy is GRANULARITY: at a 15 s bank
    /// a thermal transition costs at most 15 s of margin swing instead of
    /// 30 s, so the drain that follows recovers in smaller steps. That is a
    /// real property, and it is not throughput.
    ///
    /// The values are multipliers so the byte-cap and seconds-target
    /// arithmetic in `effectiveTargetSeconds` keeps working unchanged.
    public func pressureFactor(for thermal: ThermalPressure) -> Double {
        switch thermal {
        case .nominal, .fair: return 1.0
        case .serious: return 0.5
        case .critical: return 0.25
        }
    }

    /// The seconds target under thermal pressure, after the byte cap.
    /// `effectiveTargetSeconds` plus the pressure factor, in one call.
    public func pressuredTargetSeconds(thermal: ThermalPressure, sampleRate: Double) -> Double {
        effectiveTargetSeconds(thermal: thermal, sampleRate: sampleRate) * pressureFactor(for: thermal)
    }

    /// Bytes of mono Float32 PCM per second of audio at `sampleRate`.
    public static func bytesPerSecond(sampleRate: Double) -> Double {
        sampleRate * 4
    }

    /// The target that actually gates the producer: the thermal seconds
    /// target, CAPPED by the byte cap expressed in seconds. Non-positive
    /// sample rates fall back to treating the seconds target as binding
    /// (a zero sample rate cannot be converted to bytes; refusing to
    /// generate at all would be a worse failure than an unguarded bank).
    public func effectiveTargetSeconds(thermal: ThermalPressure, sampleRate: Double) -> Double {
        let secondsTarget = targetSeconds(for: thermal)
        guard sampleRate > 0 else { return secondsTarget }
        let bytesTarget = Double(byteCapBytes) / Self.bytesPerSecond(sampleRate: sampleRate)
        return min(secondsTarget, bytesTarget)
    }

    /// Whether the producer may synthesize the next chunk. At `banked ==
    /// target` the producer HOLDS (this returns false): the bank must DRAIN
    /// below target before more work is admitted, so a producer parked at
    /// exactly the full mark cannot generate back-to-back.
    public static func allows(bankedSeconds: Double, targetSeconds: Double) -> Bool {
        bankedSeconds < targetSeconds
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
