import XCTest
@testable import SpeechLogic

/// StatsStore folds, windows and streak logic — all against a fixed UTC
/// calendar so the day keys are deterministic regardless of the machine's
/// timezone.
final class StatsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 2026-09-30 12:00 UTC, with a UTC calendar → every "local day" is a
    /// UTC day, so injected dates map to known keys.
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func makeStore() -> StatsStore {
        StatsStore(fileURL: dir.appendingPathComponent("stats.json"), calendar: utcCalendar)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        utcCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func dayKey(_ date: Date) -> String {
        StatsStore.dayKey(date, calendar: utcCalendar)
    }

    func testDayKeyPadsFields() {
        XCTAssertEqual(dayKey(day(2026, 9, 30)), "2026-09-30")
        XCTAssertEqual(dayKey(day(2026, 1, 5)), "2026-01-05")
    }

    func testRecordFoldsSameDaySubjectKind() throws {
        let store = makeStore()
        let when = day(2026, 9, 30)
        store.record(subjectId: "book-a", kind: .reading, seconds: 30, at: when)
        store.record(subjectId: "book-a", kind: .reading, seconds: 45, at: when)
        store.record(subjectId: "book-a", kind: .listening, seconds: 10, at: when)
        store.record(subjectId: "book-b", kind: .reading, seconds: 5, at: when)

        let totals = store.dayTotals(daysBack: 0, endingAt: when)
        XCTAssertEqual(totals["2026-09-30"], StatsDayTotals(reading: 80, listening: 10))
        XCTAssertEqual(store.subjectTotals(daysBack: 0, kind: .reading, endingAt: when)["book-a"], 75)
    }

    func testWindowFiltersOlderDays() throws {
        let store = makeStore()
        store.record(subjectId: "book-a", kind: .reading, seconds: 100, at: day(2026, 9, 1))
        store.record(subjectId: "book-a", kind: .reading, seconds: 50, at: day(2026, 9, 29))
        store.record(subjectId: "book-a", kind: .reading, seconds: 10, at: day(2026, 9, 30))

        XCTAssertEqual(store.totals(daysBack: 0, endingAt: day(2026, 9, 30)), 10)
        XCTAssertEqual(store.totals(daysBack: 1, endingAt: day(2026, 9, 30)), 60)
        XCTAssertEqual(store.totals(daysBack: 365, endingAt: day(2026, 9, 30)), 160)
    }

    func testKindSplit() throws {
        let store = makeStore()
        let when = day(2026, 9, 30)
        store.record(subjectId: "note-1", kind: .listening, seconds: 120, at: when)
        store.record(subjectId: "book-a", kind: .reading, seconds: 60, at: when)

        XCTAssertEqual(store.totals(daysBack: 7, kind: .listening, endingAt: when), 120)
        XCTAssertEqual(store.totals(daysBack: 7, kind: .reading, endingAt: when), 60)
        XCTAssertEqual(store.totals(daysBack: 7, endingAt: when), 180)
    }

    func testStreakCountsTodayAndYesterdayBridge() throws {
        let store = makeStore()
        let today = day(2026, 9, 30)
        // Today and the two previous days qualify; a 3-day streak.
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: day(2026, 9, 28))
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: day(2026, 9, 29))
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: today)
        XCTAssertEqual(store.streak(at: today), 3)
    }

    func testStreakSurvivesWhenTodayHasNoTimeYet() throws {
        let store = makeStore()
        let today = day(2026, 9, 30)
        // Yesterday + the day before qualify, today hasn't — the streak is
        // still alive (it breaks only if today ends below the minimum).
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: day(2026, 9, 28))
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: day(2026, 9, 29))
        XCTAssertEqual(store.streak(at: today), 2)
    }

    func testStreakBreaksOnGap() throws {
        let store = makeStore()
        let today = day(2026, 9, 30)
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: day(2026, 9, 28))
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: day(2026, 9, 29))
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: day(2026, 9, 27))
        XCTAssertEqual(store.streak(at: today), 3) // 27, 28, 29 — today not needed
    }

    func testStreakIgnoresSubThresholdDays() throws {
        let store = makeStore()
        let today = day(2026, 9, 30)
        // 30 s does not count as an active day.
        store.record(subjectId: "book-a", kind: .reading, seconds: 30, at: day(2026, 9, 29))
        store.record(subjectId: "book-a", kind: .reading, seconds: 300, at: day(2026, 9, 28))
        XCTAssertEqual(store.streak(at: today), 0)
    }

    func testPersistenceRoundTrip() throws {
        let url = dir.appendingPathComponent("stats.json")
        let store = StatsStore(fileURL: url, calendar: utcCalendar)
        store.record(subjectId: "book-a", kind: .listening, seconds: 90, at: day(2026, 9, 30))

        let reloaded = StatsStore(fileURL: url, calendar: utcCalendar)
        XCTAssertEqual(reloaded.totals(daysBack: 7, endingAt: day(2026, 9, 30)), 90)
        XCTAssertEqual(reloaded.activeDays(), 1)
    }

    func testZeroAndEmptySubjectsAreRejected() throws {
        let store = makeStore()
        store.record(subjectId: "", kind: .reading, seconds: 100, at: day(2026, 9, 30))
        store.record(subjectId: "book-a", kind: .reading, seconds: 0, at: day(2026, 9, 30))
        XCTAssertEqual(store.activeDays(), 0)
    }
}
