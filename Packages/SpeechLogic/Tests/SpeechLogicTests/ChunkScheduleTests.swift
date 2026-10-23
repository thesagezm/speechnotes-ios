import XCTest
@testable import SpeechLogic

/// The chunk-token schedule: the seconds-based target that trades a
/// slightly slower first buffer for a second buffer that arrives on time.
final class ChunkScheduleTests: XCTestCase {

    // MARK: - The starting point

    /// A fresh state starts at the initial target.
    func testFreshStateStartsAtInitialTarget() {
        let state = ChunkSchedule.State()
        XCTAssertEqual(state.currentTargetSeconds, ChunkSchedule.initialTargetSeconds)
        XCTAssertNil(state.lastWasLate)
        XCTAssertNil(state.lastSecondBufferSeconds)
        XCTAssertNil(state.measuredCharactersPerAudioSecond)
    }

    /// An out-of-range constructor value is clamped into the legal band.
    func testOutOfRangeTargetIsClamped() {
        XCTAssertEqual(ChunkSchedule.State(targetSeconds: 0.1).currentTargetSeconds, ChunkSchedule.minimumTargetSeconds)
        XCTAssertEqual(ChunkSchedule.State(targetSeconds: 9999).currentTargetSeconds, ChunkSchedule.maximumTargetSeconds)
    }

    // MARK: - Growing

    /// A late second buffer grows the target — and the new target must be
    /// ABOVE the wait that was not covered, or the next session is short
    /// for exactly the same reason.
    func testLateSessionGrowsAboveTheMeasuredWait() {
        let state = ChunkSchedule.State()
        state.record(
            secondBufferWasLate: true,
            chunk0AudioSeconds: 3.0,
            secondBufferSeconds: 8.5,
            rate: 1.0
        )
        XCTAssertEqual(state.lastWasLate, true)
        XCTAssertGreaterThan(state.currentTargetSeconds, 8.5)
        XCTAssertGreaterThanOrEqual(state.currentTargetSeconds, 8.5 * ChunkSchedule.growHeadroom)
    }

    /// Repeated failures keep growing, up to the ceiling — and the ceiling
    /// is the honest answer for an engine too slow for a fast-start.
    func testRepeatedFailuresGrowToTheCeilingAndStop() {
        let state = ChunkSchedule.State()
        for _ in 0..<10 {
            state.record(
                secondBufferWasLate: true,
                chunk0AudioSeconds: 2.0,
                secondBufferSeconds: 12.0,
                rate: 1.0
            )
        }
        XCTAssertEqual(state.currentTargetSeconds, ChunkSchedule.maximumTargetSeconds)
    }

    /// The growth is at least a doubling per failure: the gaps in the
    /// device log span 0.08 s to 25 s, and a schedule that grew by a
    /// fraction would need a dozen sessions to cross that.
    func testGrowthIsAtLeastADoubling() {
        let state = ChunkSchedule.State()
        let before = state.currentTargetSeconds
        state.record(
            secondBufferWasLate: true,
            chunk0AudioSeconds: 1.0,
            secondBufferSeconds: 1.0,
            rate: 1.0
        )
        XCTAssertGreaterThanOrEqual(state.currentTargetSeconds, before * 2)
    }

    // MARK: - Holding on success (the fix for the oscillating ladder)

    /// A covered session does NOT snap the target back to the bottom. This
    /// is the behaviour that kept the old ladder oscillating: one lucky
    /// session reset the opener to 100 chars and the next session was
    /// short again.
    func testCoveredSessionHoldsTheTarget() {
        let state = ChunkSchedule.State()
        state.record(
            secondBufferWasLate: true,
            chunk0AudioSeconds: 2.0,
            secondBufferSeconds: 6.0,
            rate: 1.0
        )
        let grown = state.currentTargetSeconds
        XCTAssertGreaterThan(grown, ChunkSchedule.initialTargetSeconds)

        // A tight cover (under the slack threshold) holds the target.
        state.record(
            secondBufferWasLate: false,
            chunk0AudioSeconds: grown,
            secondBufferSeconds: grown - 0.5,
            rate: 1.0
        )
        XCTAssertEqual(state.currentTargetSeconds, grown)
        XCTAssertEqual(state.lastWasLate, false)
    }

    /// A COMFORTABLE cover gives some of the target back — but never below
    /// the wait it has to cover, so the next session cannot be short.
    func testComfortableCoverShrinksButStaysAboveTheWait() {
        let state = ChunkSchedule.State(targetSeconds: 20.0)
        state.record(
            secondBufferWasLate: false,
            chunk0AudioSeconds: 20.0,
            secondBufferSeconds: 5.0,
            rate: 1.0
        )
        XCTAssertLessThan(state.currentTargetSeconds, 20.0)
        XCTAssertGreaterThanOrEqual(state.currentTargetSeconds, 5.0 + ChunkSchedule.shrinkSlackSeconds)
    }

    /// A cover with less than the required slack holds the target — a
    /// 10 ms near-miss must not shrink the opener.
    func testTightCoverDoesNotShrink() {
        let state = ChunkSchedule.State(targetSeconds: 20.0)
        state.record(
            secondBufferWasLate: false,
            chunk0AudioSeconds: 20.0,
            secondBufferSeconds: 19.5,
            rate: 1.0
        )
        XCTAssertEqual(state.currentTargetSeconds, 20.0)
    }

    /// The target never falls below the floor, however many comfortable
    /// covers arrive.
    func testTargetNeverFallsBelowTheFloor() {
        let state = ChunkSchedule.State(targetSeconds: 4.0)
        for _ in 0..<10 {
            state.record(
                secondBufferWasLate: false,
                chunk0AudioSeconds: 4.0,
                secondBufferSeconds: 0.2,
                rate: 1.0
            )
        }
        XCTAssertGreaterThanOrEqual(state.currentTargetSeconds, ChunkSchedule.minimumTargetSeconds)
    }

    // MARK: - The no-second-buffer case

    /// A session with no second buffer teaches NOTHING when the engine has
    /// no remembered wait — and the target HOLDS. The old ladder reset to
    /// the bottom here, which is how it kept ending up at the bottom.
    func testNoSecondBufferHoldsTheTargetWhenNothingIsKnown() {
        let state = ChunkSchedule.State()
        state.record(
            secondBufferWasLate: true,
            chunk0AudioSeconds: 2.0,
            secondBufferSeconds: 8.0,
            rate: 1.0
        )
        let grown = state.currentTargetSeconds

        state.record(
            secondBufferWasLate: nil,
            chunk0AudioSeconds: grown,
            secondBufferSeconds: nil,
            rate: 1.0
        )
        XCTAssertEqual(state.currentTargetSeconds, grown)
    }

    /// A session with no second buffer DOES teach something when the
    /// engine has a remembered wait and the opener was shorter than it:
    /// the opener was too small, so the target grows.
    func testNoSecondBufferGrowsWhenTheOpenerWasShorterThanTheKnownWait() {
        let state = ChunkSchedule.State()
        state.record(
            secondBufferWasLate: false,
            chunk0AudioSeconds: 8.0,
            secondBufferSeconds: 8.0,
            rate: 1.0
        )
        let before = state.currentTargetSeconds

        state.record(
            secondBufferWasLate: nil,
            chunk0AudioSeconds: 3.0,
            secondBufferSeconds: nil,
            rate: 1.0
        )
        XCTAssertGreaterThan(state.currentTargetSeconds, before)
        XCTAssertGreaterThanOrEqual(state.currentTargetSeconds, 8.0 * ChunkSchedule.growHeadroom)
    }

    // MARK: - Learning the engine's speaking rate

    /// The schedule MEASURES how many characters this engine speaks per
    /// second of audio instead of assuming — Supertonic and Kokoro differ
    /// by more than a factor of two on the device logs.
    func testSpeakingRateIsMeasuredFromTheOpener() {
        let state = ChunkSchedule.State()
        // 54 characters of audio took 7.64 s.
        state.record(
            secondBufferWasLate: false,
            chunk0AudioSeconds: 7.64,
            chunk0Characters: 54,
            secondBufferSeconds: 6.0,
            rate: 1.0
        )
        XCTAssertEqual(state.measuredCharactersPerAudioSecond ?? 0, 54.0 / 7.64, accuracy: 0.0001)
        XCTAssertEqual(state.measuredAtRate, 1.0)
    }

    /// A faster voice plays the same characters in LESS time, so the same
    /// audio target needs MORE characters.
    func testBudgetScalesWithTheSpeechRate() {
        let state = ChunkSchedule.State(targetSeconds: 6.0)
        state.record(
            secondBufferWasLate: false,
            chunk0AudioSeconds: 3.3,
            chunk0Characters: 54,
            secondBufferSeconds: 2.0,
            rate: 1.0
        )
        let atNormal = state.openerCharacterBudget(rate: 1.0, batchCeiling: 400)
        let atDouble = state.openerCharacterBudget(rate: 2.0, batchCeiling: 400)
        let atHalf = state.openerCharacterBudget(rate: 0.5, batchCeiling: 400)
        XCTAssertGreaterThan(atDouble, atNormal)
        XCTAssertLessThan(atHalf, atNormal)
        // Doubling the rate doubles the characters that fit in the same
        // audio target (within one character of rounding).
        XCTAssertEqual(Double(atDouble), Double(atNormal) * 2, accuracy: 2)
        XCTAssertEqual(Double(atHalf), Double(atNormal) / 2, accuracy: 2)
    }

    /// Before any measurement, the fallback conversion is used — and it
    /// still respects the engine's ceiling.
    func testBudgetBeforeAnyMeasurementUsesTheFallback() {
        let state = ChunkSchedule.State(targetSeconds: 6.0)
        let budget = state.openerCharacterBudget(rate: 1.0, batchCeiling: 400)
        XCTAssertEqual(
            budget,
            Int((6.0 * ChunkSchedule.defaultCharactersPerAudioSecond).rounded(.up))
        )
        XCTAssertEqual(state.openerCharacterBudget(rate: 1.0, batchCeiling: 10), 10)
    }

    /// An engine's own fallback figure is used until it has measured its
    /// own — Supertonic and Kokoro speak at very different rates.
    func testPerEngineFallbackIsUsedBeforeAnyMeasurement() {
        let kokoro = ChunkSchedule.State(
            targetSeconds: ChunkSchedule.initialTargetSeconds,
            fallbackCharactersPerAudioSecond: ChunkSchedule.kokoroCharactersPerAudioSecond
        )
        let supertonic = ChunkSchedule.State(
            targetSeconds: ChunkSchedule.supertonicTargetSeconds,
            fallbackCharactersPerAudioSecond: ChunkSchedule.supertonicCharactersPerAudioSecond
        )
        XCTAssertEqual(kokoro.fallbackCharactersPerAudioSecond, 16.0)
        XCTAssertEqual(supertonic.fallbackCharactersPerAudioSecond, 10.0)
        XCTAssertGreaterThan(
            kokoro.openerCharacterBudget(rate: 1.0, batchCeiling: 400),
            supertonic.openerCharacterBudget(rate: 1.0, batchCeiling: 400)
        )
    }

    // MARK: - The character budget

    /// The budget is the target converted to characters at the live rate.
    func testBudgetFollowsTargetAndRate() {
        // 6 s at 15 chars/s = 90 chars.
        XCTAssertEqual(
            ChunkSchedule.openerCharacterBudget(targetSeconds: 6.0, rate: 1.0, batchCeiling: 400),
            90
        )
        // A faster voice needs more characters for the same audio.
        XCTAssertEqual(
            ChunkSchedule.openerCharacterBudget(targetSeconds: 6.0, rate: 2.0, batchCeiling: 400),
            180
        )
        // A slower voice needs fewer.
        XCTAssertEqual(
            ChunkSchedule.openerCharacterBudget(targetSeconds: 6.0, rate: 0.5, batchCeiling: 400),
            45
        )
    }

    /// The engine's own ceiling is a HARD cap: an opener above it would be
    /// split by the chunker, which is two renders, not one fast one.
    func testBudgetIsClampedToTheEngineCeiling() {
        // Supertonic's 200 ceiling.
        XCTAssertEqual(
            ChunkSchedule.openerCharacterBudget(targetSeconds: 6.0, rate: 1.0, batchCeiling: 200),
            90
        )
        // A 30 s target at 15 chars/s is 450 chars — pinned to Kokoro's 160.
        XCTAssertEqual(
            ChunkSchedule.openerCharacterBudget(targetSeconds: 30.0, rate: 1.0, batchCeiling: 160),
            160
        )
    }

    /// A zero or negative rate must not divide the budget by zero.
    func testBudgetHandlesANonPositiveRate() {
        XCTAssertEqual(
            ChunkSchedule.openerCharacterBudget(targetSeconds: 6.0, rate: 0, batchCeiling: 400),
            90
        )
        XCTAssertEqual(
            ChunkSchedule.openerCharacterBudget(targetSeconds: 6.0, rate: -1, batchCeiling: 400),
            90
        )
    }

    // MARK: - Log line

    func testSummaryMentionsTheTargetAndTheVerdict() {
        let state = ChunkSchedule.State()
        XCTAssertTrue(state.summary.contains("8.00"))
        state.record(
            secondBufferWasLate: true,
            chunk0AudioSeconds: 2.0,
            secondBufferSeconds: 8.0,
            rate: 1.0
        )
        XCTAssertTrue(state.summary.contains("LATE"))
        XCTAssertFalse(state.summary.contains("8.00"))
    }
}
