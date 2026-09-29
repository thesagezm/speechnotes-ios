import Foundation

/// What the tracked time was spent on: visually reading (the book readers)
/// or listening (audiobook files and TTS playback). One enum — the stats UI
/// splits every chart by it, which is the one angle a read-aloud app has
/// that other trackers don't.
public enum StatsKind: String, Codable, Sendable, CaseIterable {
    case reading
    case listening
}

/// One folded row: per LOCAL calendar day, per subject (book/note UUID), per
/// kind. Time folds up in place — a shelf of books over a year stays a few
/// thousand tiny rows, not a session log.
public struct StatsEntry: Codable, Equatable, Sendable {
    public var day: String
    public var kind: StatsKind
    public var subjectId: String
    public var seconds: Double

    public init(day: String, kind: StatsKind, subjectId: String, seconds: Double) {
        self.day = day
        self.kind = kind
        self.subjectId = subjectId
        self.seconds = seconds
    }
}

/// Per-day totals split by kind — the stats UI's day rows.
public struct StatsDayTotals: Codable, Equatable, Sendable {
    public var reading: Double
    public var listening: Double

    public var total: Double { reading + listening }

    public init(reading: Double = 0, listening: Double = 0) {
        self.reading = reading
        self.listening = listening
    }
}

/// The reading/listening time store. Codable JSON (the app's store pattern —
/// no CoreData), one file, whole-file atomic rewrites at record time. The
/// record cadence is one fold per ~30 s per surface, so the write load is
/// trivial; a killed app loses at most one fold.
///
/// Thread-safety: one NSLock around the array. record() lands from the main
/// thread (view recorders) and Combine subscriptions; queries land from the
/// UI. All paths are short.
///
/// Tests inject a `calendar` (UTC) and explicit dates — every date-taking
/// method defaults to Date() so production call sites stay clean.
public final class StatsStore {
    public static let shared = StatsStore()

    private var entries: [StatsEntry] = []
    private let lock = NSLock()
    private let fileURL: URL
    private let calendar: Calendar

    public init(fileURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = base.appendingPathComponent("Speechnotes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("stats.json")
        }
        load()
    }

    // MARK: - Day keys

    /// Local calendar day, "yyyy-MM-dd". Local, not UTC: the heatmap answers
    /// "when did I read", and that reads in the user's own days.
    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The day key `daysBack` local days before `endingAt` (0 = that day).
    public func dayKey(daysBack: Int, endingAt: Date = Date()) -> String {
        let date = calendar.date(byAdding: .day, value: -daysBack, to: endingAt) ?? endingAt
        return Self.dayKey(date, calendar: calendar)
    }

    // MARK: - Writing

    public func record(subjectId: String, kind: StatsKind, seconds: Double, at date: Date = Date()) {
        guard seconds > 0, !subjectId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let day = Self.dayKey(date, calendar: calendar)
        if let idx = entries.firstIndex(where: { $0.day == day && $0.kind == kind && $0.subjectId == subjectId }) {
            entries[idx].seconds += seconds
        } else {
            entries.append(StatsEntry(day: day, kind: kind, subjectId: subjectId, seconds: seconds))
        }
        saveLocked()
    }

    // MARK: - Queries (all totals in seconds)

    /// Totals per local day for the last `daysBack` days ending at
    /// `endingAt`. Days with no rows are simply absent.
    public func dayTotals(daysBack: Int, endingAt: Date = Date()) -> [String: StatsDayTotals] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = calendar.date(byAdding: .day, value: -daysBack, to: endingAt) ?? .distantPast
        var out: [String: StatsDayTotals] = [:]
        for e in entries {
            guard let dayDate = dateForKey(e.day), dayDate >= startOfDay(cutoff) else { continue }
            var totals = out[e.day] ?? StatsDayTotals()
            switch e.kind {
            case .reading: totals.reading += e.seconds
            case .listening: totals.listening += e.seconds
            }
            out[e.day] = totals
        }
        return out
    }

    public func totals(daysBack: Int, kind: StatsKind? = nil, endingAt: Date = Date()) -> Double {
        dayTotals(daysBack: daysBack, endingAt: endingAt).values.reduce(0) { acc, day in
            switch kind {
            case .reading: return acc + day.reading
            case .listening: return acc + day.listening
            case nil: return acc + day.total
            }
        }
    }

    public func todayTotals(kind: StatsKind? = nil, at date: Date = Date()) -> Double {
        totals(daysBack: 0, kind: kind, endingAt: date)
    }

    /// Seconds per subject within the window — the per-book/per-note cards.
    public func subjectTotals(daysBack: Int, kind: StatsKind? = nil, endingAt: Date = Date()) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = calendar.date(byAdding: .day, value: -daysBack, to: endingAt) ?? .distantPast
        var out: [String: Double] = [:]
        for e in entries {
            guard let dayDate = dateForKey(e.day), dayDate >= startOfDay(cutoff) else { continue }
            if let kind, e.kind != kind { continue }
            out[e.subjectId, default: 0] += e.seconds
        }
        return out
    }

    /// Consecutive local days (ending today, or yesterday when today hasn't
    /// earned its minute yet) with at least `minimumSeconds` of combined
    /// reading+listening time. Zero when neither day qualifies.
    public func streak(minimumSeconds: Double = 60, at date: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var perDay: [String: Double] = [:]
        for e in entries { perDay[e.day, default: 0] += e.seconds }
        func counts(_ daysBack: Int) -> Bool {
            let key = Self.dayKey(calendar.date(byAdding: .day, value: -daysBack, to: date) ?? date, calendar: calendar)
            return (perDay[key] ?? 0) >= minimumSeconds
        }
        var cursor = counts(0) ? 0 : (counts(1) ? 1 : -1)
        guard cursor >= 0 else { return 0 }
        var streak = 0
        while counts(cursor) {
            streak += 1
            cursor += 1
        }
        return streak
    }

    /// Number of distinct days with any recorded time — the "days read"
    /// headline counter.
    public func activeDays() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.map(\.day)).count
    }

    // MARK: - Plumbing

    private func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func dateForKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([StatsEntry].self, from: data)) ?? []
    }

    /// Caller holds the lock. Atomic whole-file write; zero rows are dropped
    /// so the file only ever shrinks when time is un-recorded (nothing
    /// subtracts today, but the guard keeps the invariant cheap).
    private func saveLocked() {
        entries.removeAll { $0.seconds <= 0.001 }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
