//
//  RenderAheadBankTests.swift
//  SpeechLogic
//
//  Tests for the render-ahead bank policy (Batch B of the background-
//  persistence plan) — thermal sizing, the byte cap, the allow check and
//  the exhaustion classification.
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
        XCTAssertEqual(RenderAheadBankPolicy.fullQualityTotalStep, 8)
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

    // MARK: - Allow check (the check the producer actually paces on)

    /// Generate while the bank is below target.
    func testAllowsBelowTarget() {
        XCTAssertTrue(RenderAheadBankPolicy.allows(bankedSeconds: 0, targetSeconds: 30))
        XCTAssertTrue(RenderAheadBankPolicy.allows(bankedSeconds: 29.9, targetSeconds: 30))
    }

    /// At exactly the target the check returns false: the producer parks and
    /// the bank must drain below target before it generates again.
    func testHoldsAtExactlyTarget() {
        XCTAssertFalse(RenderAheadBankPolicy.allows(bankedSeconds: 30, targetSeconds: 30))
    }

    /// Pressure shrinks the target, so the same banked depth that passes at
    /// nominal must hold at critical.
    func testPressureShrinksAllowance() {
        let policy = RenderAheadBankPolicy()
        XCTAssertTrue(policy.allowsNext(
            bankedSeconds: 20, thermal: .nominal, sampleRate: 24_000))
        XCTAssertFalse(policy.allowsNext(
            bankedSeconds: 20, thermal: .critical, sampleRate: 24_000))
    }

    /// The allow check can NEVER deadlock, even when the target is smaller
    /// than one chunk's audio: an empty bank is always below any positive
    /// target, so the producer can always resume from a drained bank. This
    /// is the property the rejected estimate-including check lacked.
    func testEmptyBankAlwaysRefills() {
        let policy = RenderAheadBankPolicy()
        // Critical target 8 s vs a hypothetical 20 s chunk: 0 < 8 passes.
        XCTAssertTrue(policy.allowsNext(
            bankedSeconds: 0, thermal: .critical, sampleRate: 24_000))
    }

    // MARK: - Exhaustion classification

    func testIsExhaustedUsesHalfSecondThreshold() {
        XCTAssertTrue(RenderAheadBankPolicy.isExhausted(bankedSeconds: 0))
        XCTAssertTrue(RenderAheadBankPolicy.isExhausted(bankedSeconds: 0.4))
        XCTAssertFalse(RenderAheadBankPolicy.isExhausted(bankedSeconds: 0.5))
        XCTAssertFalse(RenderAheadBankPolicy.isExhausted(bankedSeconds: 5))
    }
}

private extension RenderAheadBankPolicy {
    /// Mirrors the core's call shape: effective target at the current
    /// thermal state, then the static allow check.
    func allowsNext(bankedSeconds: Double, thermal: ThermalPressure, sampleRate: Double) -> Bool {
        Self.allows(
            bankedSeconds: bankedSeconds,
            targetSeconds: effectiveTargetSeconds(thermal: thermal, sampleRate: sampleRate))
    }
}
