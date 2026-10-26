import XCTest
@testable import SpeechLogic

/// The Pomodoro engine's date math. Everything runs on a UTC calendar so
/// finish-time windows are deterministic; `t0` is a fixed instant and every
/// assertion names its offset from it.
final class PomodoroEngineTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// 2026-03-10 14:00:00 UTC.
    private var t0: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 14))!
    }

    private func date(hour: Int, minute: Int = 0, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    private func seconds(_ n: Double) -> Date { t0.addingTimeInterval(n) }

    /// `secondsRemaining` is optional (open-ended flow focus / done return
    /// nil); tests expect a real number, so nil degrades to -1 and fails
    /// the assertion loudly instead of the type checker.
    private func secs(_ remaining: TimeInterval?) -> TimeInterval { remaining ?? -1 }

    // MARK: Classic

    /// Blocks [25, 30] + breaks [5, 15] (breaks == blocks → trailing break)
    /// + 2 min prep. The whole run walks through every phase in order and
    /// each event carries the configured duration.
    func testClassicFullRun() {
        var config = PomodoroConfig(mode: .classic, prepSeconds: 120)
        config.classicFocusMinutes = [25, 30]
        config.classicBreakMinutes = [5, 15]
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        XCTAssertEqual(session.phase, .prep)
        XCTAssertEqual(session.secondsRemaining(now: t0), 120)

        // Prep ends → first focus block.
        var events = session.advanceIfDue(now: seconds(120))
        XCTAssertEqual(session.phase, .focus)
        XCTAssertEqual(events.map(\.completedPhase), [.prep])

        // Mid first block, nothing due.
        XCTAssertTrue(session.advanceIfDue(now: seconds(600)).isEmpty)
        XCTAssertEqual(secs(session.secondsRemaining(now: seconds(600))), 1500 - 480, accuracy: 0.001)

        // First block completes at 120 + 1500.
        events = session.advanceIfDue(now: seconds(1620))
        XCTAssertEqual(events.map(\.completedPhase), [.focus])
        XCTAssertEqual(events.first?.seconds ?? 0, 1500, accuracy: 0.001)
        XCTAssertEqual(session.phase, .rest)
        XCTAssertEqual(secs(session.secondsRemaining(now: seconds(1620))), 300, accuracy: 0.001)

        // Break then second (longer) block.
        events = session.advanceIfDue(now: seconds(1920))
        XCTAssertEqual(events.map(\.completedPhase), [.rest])
        XCTAssertEqual(secs(session.secondsRemaining(now: seconds(1920))), 1800, accuracy: 0.001)

        events = session.advanceIfDue(now: seconds(1920 + 1800))
        XCTAssertEqual(events.map(\.completedPhase), [.focus])
        XCTAssertEqual(events.first?.seconds ?? 0, 1800, accuracy: 0.001)
        XCTAssertEqual(session.phase, .rest)
        XCTAssertEqual(secs(session.secondsRemaining(now: seconds(3720))), 900, accuracy: 0.001)

        // Trailing break runs out → done.
        events = session.advanceIfDue(now: seconds(4620))
        XCTAssertEqual(events.map(\.completedPhase), [.rest])
        XCTAssertEqual(session.phase, .done)
        XCTAssertNil(session.phaseEnd)
        XCTAssertTrue(session.advanceIfDue(now: seconds(99999)).isEmpty)
    }

    /// Fewer breaks than blocks → no break after the final block.
    func testClassicFewerBreaksThanBlocks() {
        var config = PomodoroConfig(mode: .classic, prepSeconds: 0)
        config.classicFocusMinutes = [25, 25]
        config.classicBreakMinutes = [5]
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        XCTAssertEqual(session.steps.map(\.phase), [.focus, .rest, .focus])
        session.advanceIfDue(now: seconds(1500))
        session.advanceIfDue(now: seconds(1800))
        let events = session.advanceIfDue(now: seconds(3300))
        XCTAssertEqual(events.map(\.completedPhase), [.focus])
        XCTAssertEqual(session.phase, .done)
    }

    /// A relaunch after the app was gone for hours reconciles every elapsed
    /// phase in one call and lands in the step that contains "now".
    func testClassicReconcileAfterLongGap() {
        var config = PomodoroConfig(mode: .classic, prepSeconds: 120)
        config.classicFocusMinutes = [25]
        config.classicBreakMinutes = [5]
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        // Gone for 40 minutes: prep (2) + focus (25) + break (5) all elapsed,
        // now 8 minutes into nothing — the timeline is exhausted.
        let events = session.advanceIfDue(now: seconds(40 * 60))
        XCTAssertEqual(events.map(\.completedPhase), [.prep, .focus, .rest])
        XCTAssertEqual(events[1].seconds, 1500, accuracy: 0.001)
        XCTAssertEqual(session.phase, .done)
    }

    // MARK: Structured

    /// 3 h window, 2 min prep, 3 breaks × 5 min → four equal focus segments
    /// of (10800 − 120 − 900) / 4 = 2445 s, and the final focus ends exactly
    /// at the window end.
    func testStructuredDurationTimeline() {
        var config = PomodoroConfig(mode: .structured, prepSeconds: 120)
        config.structuredByDuration = true
        config.structuredDurationSeconds = 3 * 3600
        config.structuredBreakCount = 3
        config.structuredBreakSeconds = 300
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        XCTAssertEqual(session.steps.map(\.phase), [.prep, .focus, .rest, .focus, .rest, .focus, .rest, .focus])
        XCTAssertEqual(session.windowEnd, t0.addingTimeInterval(10800))
        XCTAssertEqual(session.steps.last?.end, t0.addingTimeInterval(10800))

        // Walk the whole window; the focus events must sum to the focus pool.
        let events = session.advanceIfDue(now: t0.addingTimeInterval(10800))
        XCTAssertEqual(events.map(\.completedPhase),
                       [.prep, .focus, .rest, .focus, .rest, .focus, .rest, .focus])
        let focusSeconds = events.filter { $0.completedPhase == .focus }.map(\.seconds).reduce(0, +)
        XCTAssertEqual(focusSeconds, 9780, accuracy: 0.001)
        XCTAssertEqual(events.map(\.seconds).reduce(0, +), 10800, accuracy: 0.001)
        XCTAssertEqual(session.phase, .done)
    }

    /// Finish-time mode resolves to the next occurrence of the wall-clock
    /// time: same day when still ahead, tomorrow when already past.
    func testStructuredFinishTimeWindow() {
        var config = PomodoroConfig(mode: .structured, prepSeconds: 120)
        config.structuredByDuration = false
        config.structuredFinishHour = 17

        // Started 14:00, finish 17:00 → same-day window of 3 h.
        var end = config.structuredWindowEnd(after: date(hour: 14), calendar: calendar)
        XCTAssertEqual(end, date(hour: 17))
        // Started 18:00 → tomorrow 17:00.
        end = config.structuredWindowEnd(after: date(hour: 18), calendar: calendar)
        XCTAssertEqual(end, date(hour: 17, day: 11))
    }

    /// A window too small for prep + breaks + a minute of focus per segment
    /// builds no timeline beyond prep and refuses to segment.
    func testStructuredTooSmallWindow() {
        var config = PomodoroConfig(mode: .structured, prepSeconds: 300)
        config.structuredByDuration = true
        config.structuredDurationSeconds = 1200
        config.structuredBreakCount = 5
        config.structuredBreakSeconds = 600
        XCTAssertNil(config.structuredSegmentSeconds(window: 1200))
        let session = PomodoroSession(config: config, start: t0, calendar: calendar)
        XCTAssertEqual(session.steps.map(\.phase), [.prep])
    }

    /// Skipping a structured phase ends it now but leaves the later
    /// boundaries absolute — the finish time does not move.
    func testStructuredSkipKeepsWindow() {
        var config = PomodoroConfig(mode: .structured, prepSeconds: 0)
        config.structuredBreakCount = 1
        config.structuredBreakSeconds = 300
        config.structuredDurationSeconds = 3600
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)
        // segment = (3600 − 300) / 2 = 1650

        XCTAssertTrue(session.skipPhase(now: seconds(600)))
        let events = session.advanceIfDue(now: seconds(600))
        XCTAssertEqual(events.map(\.completedPhase), [.focus])
        XCTAssertEqual(events.first?.seconds ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(session.phase, .rest)
        // The break still ends on the original grid (t0 + 1950)…
        XCTAssertEqual(session.phaseEnd, t0.addingTimeInterval(1950))
        // …and the final focus still ends exactly at the window end.
        XCTAssertEqual(session.steps.last?.end, t0.addingTimeInterval(3600))
    }

    // MARK: Pause / resume

    func testPauseSlidesCurrentAndFutureBoundaries() {
        var config = PomodoroConfig(mode: .classic, prepSeconds: 0)
        config.classicFocusMinutes = [25]
        config.classicBreakMinutes = [5]
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        // Ten minutes into the block, pause for five.
        XCTAssertTrue(session.pause(now: seconds(600)))
        XCTAssertTrue(session.isPaused)
        XCTAssertFalse(session.pause(now: seconds(610))) // double pause is a no-op
        XCTAssertEqual(secs(session.secondsRemaining(now: seconds(3600))), 900, accuracy: 0.001) // frozen

        XCTAssertTrue(session.resume(now: seconds(900)))
        XCTAssertEqual(secs(session.secondsRemaining(now: seconds(900))), 900, accuracy: 0.001)
        // The following break slides by the paused span too.
        XCTAssertEqual(session.steps[1].end, t0.addingTimeInterval(1800 + 300))
    }

    // MARK: Flowmodoro

    func testFlowmodoroAccrualAndClaim() {
        var config = PomodoroConfig(mode: .flowmodoro, prepSeconds: 120)
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        // Prep → open-ended focus.
        var events = session.advanceIfDue(now: seconds(120))
        XCTAssertEqual(events.map(\.completedPhase), [.prep])
        XCTAssertEqual(session.phase, .focus)
        XCTAssertNil(session.phaseEnd)

        // Below the claim threshold: the pot is earned but not claimable.
        // The gate is on the POT — 3 break minutes = 15 focus minutes — so
        // 3 focus minutes (a 36-second pot) is earned but far from claimable.
        XCTAssertFalse(session.flowCanClaim(now: seconds(120 + 180)))
        XCTAssertEqual(session.flowEarnedBreak(now: seconds(120 + 180)), 36, accuracy: 0.001)
        XCTAssertFalse(session.flowCanClaim(now: seconds(120 + 899)))
        XCTAssertTrue(session.flowCanClaim(now: seconds(120 + 900)))
        XCTAssertEqual(session.flowEarnedBreak(now: seconds(120 + 900)), 180, accuracy: 0.001)

        // Fifteen focus minutes → a 3-minute pot; claiming banks it and restarts focus.
        events = session.advanceIfDue(now: seconds(120 + 900))
        XCTAssertTrue(events.isEmpty) // focus never "completes" on its own
        XCTAssertTrue(session.claimBreak(now: seconds(120 + 900)))
        XCTAssertEqual(session.phase, .rest)
        XCTAssertEqual(secs(session.secondsRemaining(now: seconds(120 + 900))), 180, accuracy: 0.001)
        XCTAssertEqual(session.flowAccruedFocus(now: seconds(120 + 900)), 0, accuracy: 0.001)
        XCTAssertEqual(session.flowBreaksClaimed, 1)

        // Rest runs out → focus restarts from zero.
        events = session.advanceIfDue(now: seconds(120 + 1080))
        XCTAssertEqual(events.map(\.completedPhase), [.rest])
        XCTAssertEqual(events.first?.seconds ?? 0, 180, accuracy: 0.001)
        XCTAssertEqual(session.phase, .focus)
        XCTAssertEqual(session.flowEarnedBreak(now: seconds(120 + 1080)), 0, accuracy: 0.001)
    }

    func testFlowmodoroPauseStopsAccrual() {
        var config = PomodoroConfig(mode: .flowmodoro, prepSeconds: 0)
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        // 4 minutes of focus, then a 3-minute pause: the pot freezes at 4 min.
        session.pause(now: seconds(240))
        XCTAssertEqual(session.flowAccruedFocus(now: seconds(420)), 240, accuracy: 0.001)
        session.resume(now: seconds(420))
        XCTAssertEqual(session.flowAccruedFocus(now: seconds(420)), 240, accuracy: 0.001)
        XCTAssertEqual(session.flowAccruedFocus(now: seconds(480)), 300, accuracy: 0.001)

        // A paused focus cannot be claimed even once the pot is full:
        // accrue to exactly 15 focus minutes ACROSS the earlier pause
        // (240 s + 660 s of live focus), freeze, then try to claim
        // mid-pause — false however long the pause runs.
        session.pause(now: seconds(1080))
        XCTAssertEqual(session.flowAccruedFocus(now: seconds(1200)), 900, accuracy: 0.001)
        XCTAssertEqual(session.flowEarnedBreak(now: seconds(1200)), 180, accuracy: 0.001)
        XCTAssertFalse(session.claimBreak(now: seconds(1200)))
        // Resuming unlocks it: the pot is exactly at the threshold and the
        // claim lands there.
        session.resume(now: seconds(1200))
        XCTAssertTrue(session.flowCanClaim(now: seconds(1200)))
        XCTAssertTrue(session.claimBreak(now: seconds(1200)))
        XCTAssertEqual(secs(session.secondsRemaining(now: seconds(1200))), 180, accuracy: 0.001)
    }

    func testFlowmodoroSkipRest() {
        var config = PomodoroConfig(mode: .flowmodoro, prepSeconds: 0)
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        session.advanceIfDue(now: seconds(900))
        XCTAssertTrue(session.claimBreak(now: seconds(900))) // 3 min rest
        XCTAssertTrue(session.skipPhase(now: seconds(930))) // 30 s into the rest
        XCTAssertEqual(session.phase, .focus)
        XCTAssertEqual(session.flowAccruedFocus(now: seconds(930)), 0, accuracy: 0.001)
        // Focus in structured/classic has no "next" to skip to in flow mode.
        XCTAssertFalse(session.skipPhase(now: seconds(960)))
    }

    // MARK: Skip

    /// Skipping a classic phase slides the rest of the schedule earlier.
    func testClassicSkipSlidesSchedule() {
        var config = PomodoroConfig(mode: .classic, prepSeconds: 0)
        config.classicFocusMinutes = [25, 25]
        config.classicBreakMinutes = [5, 5]
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        // Skip 15 minutes into the first block → every later boundary pulls
        // forward by the reclaimed 10 minutes.
        XCTAssertTrue(session.skipPhase(now: seconds(900)))
        let events = session.advanceIfDue(now: seconds(900))
        XCTAssertEqual(events.map(\.completedPhase), [.focus])
        XCTAssertEqual(events.first?.seconds ?? 0, 900, accuracy: 0.001)
        XCTAssertEqual(session.phase, .rest)
        XCTAssertEqual(session.phaseEnd, t0.addingTimeInterval(1200)) // was 1800
        XCTAssertEqual(session.steps[2].end, t0.addingTimeInterval(2700)) // was 3300
        XCTAssertEqual(session.steps[3].end, t0.addingTimeInterval(3000)) // was 3600
    }

    // MARK: Stop

    func testStopMidFocusReportsPartial() {
        var config = PomodoroConfig(mode: .classic, prepSeconds: 0)
        config.classicFocusMinutes = [25]
        config.classicBreakMinutes = []
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        let event = session.stop(now: seconds(600))
        XCTAssertEqual(event?.completedPhase, .focus)
        XCTAssertEqual(event?.seconds ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(session.phase, .done)
        XCTAssertNil(session.stop(now: seconds(700))) // already done
    }

    func testStopMidPrep() {
        var config = PomodoroConfig(mode: .classic, prepSeconds: 120)
        config.classicFocusMinutes = [25]
        config.classicBreakMinutes = []
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)
        let event = session.stop(now: seconds(60))
        XCTAssertEqual(event?.completedPhase, .prep)
        XCTAssertEqual(event?.seconds ?? 0, 60, accuracy: 0.001)
    }

    func testStopFlowFocusCountsAccrued() {
        var config = PomodoroConfig(mode: .flowmodoro, prepSeconds: 0)
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)
        let event = session.stop(now: seconds(360)) // 6 min of focus in flight
        XCTAssertEqual(event?.completedPhase, .focus)
        XCTAssertEqual(event?.seconds ?? 0, 360, accuracy: 0.001)
    }

    // MARK: Progress + persistence

    func testPhaseProgressBounds() {
        var config = PomodoroConfig(mode: .classic, prepSeconds: 120)
        config.classicFocusMinutes = [25]
        config.classicBreakMinutes = []
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)

        XCTAssertEqual(session.phaseProgress(now: t0), 0, accuracy: 0.001)
        XCTAssertEqual(session.phaseProgress(now: seconds(60)), 0.5, accuracy: 0.001)
        session.advanceIfDue(now: seconds(120))
        XCTAssertEqual(session.phaseProgress(now: seconds(870)), 0.5, accuracy: 0.001) // 750 of 1500 s
        XCTAssertEqual(session.phaseProgress(now: seconds(120 + 1500)), 1, accuracy: 0.001)
    }

    func testFlowProgressCyclesPerEarnedMinute() {
        var config = PomodoroConfig(mode: .flowmodoro, prepSeconds: 0)
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)
        session.advanceIfDue(now: t0)
        // Halfway through the first 5-minute earning unit.
        XCTAssertEqual(session.phaseProgress(now: seconds(150)), 0.5, accuracy: 0.001)
        // Into the second unit: 6 min accrued → 1/5 of the lap.
        XCTAssertEqual(session.phaseProgress(now: seconds(360)), 0.2, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        var config = PomodoroConfig(mode: .structured, prepSeconds: 150)
        config.structuredByDuration = false
        config.structuredFinishHour = 17
        config.structuredBreakCount = 2
        var session = PomodoroSession(config: config, start: t0, calendar: calendar)
        session.pause(now: seconds(30))
        session.resume(now: seconds(90))
        session.advanceIfDue(now: seconds(600))

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PomodoroSession.self, from: data)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.config, config)

        let configData = try JSONEncoder().encode(config)
        let decodedConfig = try JSONDecoder().decode(PomodoroConfig.self, from: configData)
        XCTAssertEqual(decodedConfig, config)
    }

    /// A session JSON written before an app update must decode rather than
    /// wipe the running timer — every field is optional in the reader.
    func testDecodeToleratesMissingOptionalFields() throws {
        var session = PomodoroSession(config: PomodoroConfig(mode: .flowmodoro), start: t0, calendar: calendar)
        session.advanceIfDue(now: seconds(200))
        let data = try JSONEncoder().encode(session)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var stripped = object
        stripped.removeValue(forKey: "flowBreaksClaimed")
        stripped.removeValue(forKey: "windowEnd")
        let repaired = try JSONSerialization.data(withJSONObject: stripped)
        let decoded = try JSONDecoder().decode(PomodoroSession.self, from: repaired)
        XCTAssertEqual(decoded.flowBreaksClaimed, 0)
        XCTAssertNil(decoded.windowEnd)
    }
}
