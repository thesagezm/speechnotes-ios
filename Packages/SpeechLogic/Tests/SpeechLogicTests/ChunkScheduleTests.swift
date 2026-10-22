import XCTest
@testable import SpeechLogic

/// The chunk-token schedule: the 100→125→150→175→200 ladder that trades a
/// slightly slower first buffer for a second buffer that arrives on time.
final class ChunkScheduleTests: XCTestCase {

    // MARK: - The ladder

    /// The ladder is exactly the requested schedule, ascending.
    func testLadderShape() {
        XCTAssertEqual(ChunkSchedule.sizes, [100, 125, 150, 175, 200])
        XCTAssertEqual(ChunkSchedule.first, 100)
        XCTAssertEqual(ChunkSchedule.largest, 200)
    }

    /// A fresh state starts at the smallest rung.
    func testFreshStateStartsAtFirst() {
        let state = ChunkSchedule.State()
        XCTAssertEqual(state.currentSize, 100)
        XCTAssertEqual(state.nextSize(), 100)
        XCTAssertNil(state.lastWasLate)
    }

    // MARK: - Climbing

    /// One late second buffer climbs exactly one rung.
    func testLateSessionClimbsOneRung() {
        let state = ChunkSchedule.State()
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 125)
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 150)
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 175)
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 200)
    }

    /// The ladder stops at 200 — there is no rung above it, and staying
    /// there is the honest answer for an engine too slow for a fast-start.
    func testTopRungStaysPut() {
        let state = ChunkSchedule.State(size: 200)
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 200)
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 200)
    }

    // MARK: - Resetting

    /// An on-time second buffer drops back to the smallest rung: the fast
    /// opener is what the user feels, and it is re-tried the moment the
    /// engine proves it can cover it. The schedule is a dial, not a ratchet.
    func testOnTimeSessionResetsToFast() {
        let state = ChunkSchedule.State()
        state.record(secondBufferWasLate: true)
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 150)
        state.record(secondBufferWasLate: false)
        XCTAssertEqual(state.currentSize, 100)
    }

    /// A success after a climb resets too — the ladder re-probes the fast
    /// rung every session rather than trusting a stale failure.
    func testResetAfterEachSuccess() {
        let state = ChunkSchedule.State()
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 125)
        state.record(secondBufferWasLate: false)
        XCTAssertEqual(state.currentSize, 100)
        // The rung is probed again — a second late session climbs from the
        // bottom again, not from where the first failure left off.
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.currentSize, 125)
    }

    // MARK: - Reporting

    /// The outcome is readable, so a log line can say what it decided.
    func testLastOutcomeIsRecorded() {
        let state = ChunkSchedule.State()
        state.record(secondBufferWasLate: true)
        XCTAssertEqual(state.lastWasLate, true)
        state.record(secondBufferWasLate: false)
        XCTAssertEqual(state.lastWasLate, false)
    }

    // MARK: - Clamping to an engine's ceiling

    /// A schedule rung is never handed to an engine whose batch ceiling is
    /// smaller: the chunker would split it, which is two renders, not one
    /// fast one.
    func testClampedToBatchCeiling() {
        // Kokoro's 160 ceiling: rungs above it are pinned to 160.
        XCTAssertEqual(ChunkSchedule.clamped(to: 160, from: 100), 100)
        XCTAssertEqual(ChunkSchedule.clamped(to: 160, from: 150), 150)
        XCTAssertEqual(ChunkSchedule.clamped(to: 160, from: 175), 160)
        XCTAssertEqual(ChunkSchedule.clamped(to: 160, from: 200), 160)
        // A ceiling at or above the ladder leaves every rung legal.
        XCTAssertEqual(ChunkSchedule.clamped(to: 200, from: 175), 175)
        XCTAssertEqual(ChunkSchedule.clamped(to: 400, from: 200), 200)
    }

    /// An out-of-range constructor value is clamped into the ladder.
    func testOutOfRangeSizeIsClamped() {
        XCTAssertEqual(ChunkSchedule.State(size: 10).currentSize, 100)
        XCTAssertEqual(ChunkSchedule.State(size: 9999).currentSize, 200)
    }

    // MARK: - Log line

    func testSummaryMentionsTheRung() {
        let state = ChunkSchedule.State()
        XCTAssertTrue(state.summary.contains("100"))
        state.record(secondBufferWasLate: true)
        XCTAssertTrue(state.summary.contains("125"))
        XCTAssertTrue(state.summary.contains("LATE"))
    }
}
