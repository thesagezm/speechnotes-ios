//
//  RenderAheadBankTests.swift
//  SpeechLogic
//
//  Tests for the render-ahead bank policy (Batch B of the background-
//  persistence plan) — thermal sizing, the byte cap, the allow check and
//  the char→seconds estimator.
//

import XCTest
@testable import SpeechLogic

final class RenderAheadBankTests: XCTestCase {

    // MARK: - ThermalPressure mapping

    func testThermalPressureMapsRawValues() {
        XCTAssertEqual(ThermalPressure(thermalStateRawValue: 0), .nominal)
        XCTAssertEqual(ThermalPressure(thermalStateRawValue: 1), .fair)
        XCTAssertEqual(ThermalPressure(thermalStateRawValue: 2), .serious)
        XCTAssertEqual(ThermalPressure(thermalStateRawValue: 3), .critical)
    }

    /// Unknown raw values clamp to the nearest known state rather than
    /// trapping — a future OS reporting 4 must degrade to the hottest known
    /// state, not crash a background session.
    func testThermalPressureClampsOutOfRangeRawValues() {
        XCTAssertEqual(ThermalPressure(thermalStateRawValue: 4), .critical)
        XCTAssertEqual(ThermalPressure(thermalStateRawValue: 100), .critical)
        XCTAssertEqual(ThermalPressure(thermalStateRawValue: -1), .nominal)
    }

    // MARK: - Thermal sizing

    /// Nominal and fair share the full 30 s target: RTF stays under 1.0
    /// through fair, and the bank's job there is covering the 8–35 s
    /// main-thread stalls the device log records.
    func testTargetSecondsByThermal() {
        let policy = RenderAheadBankPolicy()
        XCTAssertEqual(policy.targetSeconds(for: .nominal), 30)
        XCTAssertEqual(policy.targetSeconds(for: .fair), 30)
        XCTAssertEqual(policy.targetSeconds(for: .serious), 15)
        XCTAssertEqual(policy.targetSeconds(for: .critical), 8)
    }

    /// Supertonic's denoising steps drop 8→4 only under real pressure.
    func testTotalStepByThermal() {
        let policy = RenderAheadBankPolicy()
        XCTAssertEqual(policy.totalStep(for: .nominal), 8)
        XCTAssertEqual(policy.totalStep(for: .fair), 8)
        XCTAssertEqual(policy.totalStep(for: .serious), 4)
        XCTAssertEqual(policy.totalStep(for: .critical), 4)
    }

    // MARK: - Byte cap

    func testBytesPerSecondIsMonoFloat32() {
        XCTAssertEqual(RenderAheadBankPolicy.bytesPerSecond(sampleRate: 24_000), 96_000)
        XCTAssertEqual(RenderAheadBankPolicy.bytesPerSecond(sampleRate: 44_100), 176_400)
    }

    /// At the engines' 24 kHz the seconds target binds and the default byte
    /// cap never does (32 MB ≈ 349 s ≫ 30 s) — the cap is the jetsam guard,
    /// not the everyday limiter.
    func testEffectiveTargetAt24kHzIsSecondsBound() {
        let policy = RenderAheadBankPolicy()
        XCTAssertEqual(
            policy.effectiveTargetSeconds(thermal: .nominal, sampleRate: 24_000),
            30, accuracy: 1e-9)
        XCTAssertEqual(
            policy.effectiveTargetSeconds(thermal: .critical, sampleRate: 24_000),
            8, accuracy: 1e-9)
    }

    /// A small byte cap must bind BELOW the seconds target — the cap exists
    /// precisely so memory, not seconds, has the final word.
    func testSmallByteCapBindsBelowSecondsTarget() {
        // 1 MB at 24 kHz = 1_048_576 / 96_000 ≈ 10.92 s.
        let policy = RenderAheadBankPolicy(byteCapBytes: 1_048_576)
        let effective = policy.effectiveTargetSeconds(thermal: .nominal, sampleRate: 24_000)
        XCTAssertEqual(effective, 1_048_576.0 / 96_000.0, accuracy: 1e-9)
        XCTAssertLessThan(effective, policy.targetSeconds(for: .nominal))
    }

    /// A non-positive sample rate cannot be converted to bytes; the seconds
    /// target stands rather than the bank refusing to ever fill.
    func testNonPositiveSampleRateFallsBackToSecondsTarget() {
        let policy = RenderAheadBankPolicy(byteCapBytes: 1)
        XCTAssertEqual(policy.effectiveTargetSeconds(thermal: .nominal, sampleRate: 0), 30)
        XCTAssertEqual(policy.effectiveTargetSeconds(thermal: .nominal, sampleRate: -24_000), 30)
    }

    // MARK: - Allow check

    func testAllowsChunkWithinTarget() {
        let policy = RenderAheadBankPolicy()
        // 25 s banked + a 5 s estimate = exactly the 30 s nominal target.
        XCTAssertTrue(policy.allowsNextChunk(
            bankedSeconds: 25, nextChunkEstimateSeconds: 5, thermal: .nominal, sampleRate: 24_000))
        XCTAssertFalse(policy.allowsNextChunk(
            bankedSeconds: 25.1, nextChunkEstimateSeconds: 5, thermal: .nominal, sampleRate: 24_000))
    }

    /// Pressure shrinks the target, so the same banked depth that passes at
    /// nominal must hold at critical.
    func testPressureShrinksAllowance() {
        let policy = RenderAheadBankPolicy()
        XCTAssertTrue(policy.allowsNextChunk(
            bankedSeconds: 20, nextChunkEstimateSeconds: 5, thermal: .nominal, sampleRate: 24_000))
        XCTAssertFalse(policy.allowsNextChunk(
            bankedSeconds: 20, nextChunkEstimateSeconds: 5, thermal: .critical, sampleRate: 24_000))
    }

    /// A negative estimate (a defensive caller) can only make the bank more
    /// permissive than reality, never NaN the comparison — clamp it to zero.
    func testNegativeEstimateIsClamped() {
        let policy = RenderAheadBankPolicy()
        XCTAssertTrue(policy.allowsNextChunk(
            bankedSeconds: 30, nextChunkEstimateSeconds: -5, thermal: .nominal, sampleRate: 24_000))
        XCTAssertFalse(policy.allowsNextChunk(
            bankedSeconds: 30.1, nextChunkEstimateSeconds: -5, thermal: .nominal, sampleRate: 24_000))
    }

    // MARK: - Exhaustion classification

    func testIsExhaustedUsesHalfSecondThreshold() {
        XCTAssertTrue(RenderAheadBankPolicy.isExhausted(bankedSeconds: 0))
        XCTAssertTrue(RenderAheadBankPolicy.isExhausted(bankedSeconds: 0.4))
        XCTAssertFalse(RenderAheadBankPolicy.isExhausted(bankedSeconds: 0.5))
        XCTAssertFalse(RenderAheadBankPolicy.isExhausted(bankedSeconds: 5))
    }

    // MARK: - CharAudioEstimator

    /// With no measurements the seed rate applies: 0.1 s per UTF-16 char.
    func testEstimatorSeedRate() {
        let estimator = CharAudioEstimator()
        XCTAssertEqual(estimator.estimateSeconds(chars: 200), 20, accuracy: 1e-9)
        XCTAssertEqual(estimator.estimateSeconds(chars: 60), 6, accuracy: 1e-9)
        XCTAssertEqual(estimator.estimateSeconds(chars: 0), 0)
    }

    /// Measurements dilute the seed toward the measured rate: after recording
    /// 200 chars of real audio at 0.05 s/char, a 200-char estimate lands
    /// midway (0.075 s/char), and more of the same converges further.
    func testEstimatorConvergesTowardMeasuredRate() {
        var estimator = CharAudioEstimator()
        estimator.record(chars: 200, audioSeconds: 10)
        XCTAssertEqual(estimator.estimateSeconds(chars: 200), 15, accuracy: 1e-9)
        estimator.record(chars: 200, audioSeconds: 10)
        XCTAssertEqual(estimator.estimateSeconds(chars: 200), 40.0 / 3.0, accuracy: 1e-9)
    }

    /// Chunks that produced no audio are real measurements (they get skipped
    /// upstream) and may pull the estimate down — but a bogus negative one
    /// must not.
    func testEstimatorClampsNegativeSecondsAndIgnoresZeroChars() {
        var estimator = CharAudioEstimator()
        estimator.record(chars: 0, audioSeconds: 10)
        XCTAssertEqual(estimator.estimateSeconds(chars: 200), 20, accuracy: 1e-9)
        estimator.record(chars: 200, audioSeconds: -5)
        XCTAssertEqual(estimator.estimateSeconds(chars: 200), 10, accuracy: 1e-9)
    }
}
