import SwiftUI
import Charts
import SpeechLogic

/// The Stats tab — reading and listening time, Fitness-style: inset-grouped
/// cards on the grouped background, Swift Charts bars, an activity heatmap,
/// and per-book/per-note cards. iOS-native theming throughout (system
/// grouped backgrounds, SF Symbols, accent color) — deliberately not a
/// Material dashboard.
struct StatsTabView: View {
    @EnvironmentObject private var books: BooksStore
    @EnvironmentObject private var notes: NotesStore

    private enum RangeOption: String, CaseIterable, Identifiable {
        case week = "Week"
        case month = "Month"
        case year = "Year"
        var id: String { rawValue }
        var daysBack: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .year: return 365
            }
        }
    }

    @State private var range: RangeOption = .week
    @State private var todayTotal: Double = 0
    @State private var streak = 0
    @State private var rangeTotal: Double = 0
    @State private var weekSlices: [DaySlice] = []
    @State private var monthSlices: [DaySlice] = []
    @State private var yearSlices: [MonthSlice] = []
    @State private var subjects: [SubjectRow] = []
    @State private var hasAnyData = false
    /// Heatmap day totals, loaded once per reload — the grid has 126 cells
    /// and each reads it, so a per-cell store query would be 126 scans.
    @State private var heatmapData: [String: StatsDayTotals] = [:]

    // MARK: - Row models

    /// Long-format chart row: one day × kind. Zero-value days are included
    /// for the visible window so bars stay aligned.
    private struct DaySlice: Identifiable {
        let date: Date
        let minutes: Double
        let kind: StatsKind
        let dayKey: String
        var id: String { dayKey + "-" + kind.rawValue }
    }

    private struct MonthSlice: Identifiable {
        let date: Date
        let minutes: Double
        let kind: StatsKind
        var id: String { "\(Int(date.timeIntervalSince1970))-\(kind.rawValue)" }
    }

    private struct SubjectRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let seconds: Double
        /// 0...1 where the subject carries position data (books).
        let progress: Double?
        let book: Book?
    }

    private let calendar = Calendar.current
    /// One static formatter (DateFormatter construction is expensive and
    /// this view reloads on every tab visit).
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f
    }()

    var body: some View {
        NavigationStack {
            // Goals live at the top of this tab regardless of whether any
            // stats exist yet — a fresh install can still set a reading
            // goal before the charts have anything to chart.
            ScrollView {
                VStack(spacing: 14) {
                    GoalsCard()
                    if hasAnyData {
                        headerCards
                        Picker("Range", selection: $range) {
                            ForEach(RangeOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, -2)

                        activityCard
                        heatmapCard
                        subjectsCard
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 30))
                                .foregroundStyle(.secondary)
                            Text("No statistics yet")
                                .font(.headline)
                            Text("Time you spend reading books and listening shows up here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Statistics")
            .onAppear(perform: reload)
            .onChange(of: range) { _ in reload() }
            .refreshable { reload() }
        }
    }

    // MARK: - Dashboard

    private var headerCards: some View {
        HStack(spacing: 10) {
            headerCard(
                icon: "book.pages",
                tint: .blue,
                value: hms(todayTotal),
                label: "Today"
            )
            headerCard(
                icon: "flame.fill",
                tint: .orange,
                value: streak > 0 ? "\(streak) day\(streak == 1 ? "" : "s")" : "—",
                label: "Streak"
            )
            headerCard(
                icon: "clock.badge.checkmark",
                tint: .green,
                value: hms(rangeTotal),
                label: range.rawValue
            )
        }
    }

    private func headerCard(icon: String, tint: Color, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity")
                .font(.headline)
            activityChart
                .frame(height: range == .year ? 170 : 180)
            legend
        }
        .padding(14)
        .background(cardBackground)
    }

    /// The bars must wear the legend's colours, not Swift Charts' own
    /// categorical palette — otherwise "reading" is blue in the legend and
    /// orange in the graph, which is the mismatch the goals tab inherited.
    /// One definition (`ActivityKind.legendColor`) feeds both.
    private static let activityColors: [String: Color] = [
        ActivityKind.reading.label: ActivityKind.reading.legendColor,
        ActivityKind.listening.label: ActivityKind.listening.legendColor,
    ]

    @ViewBuilder
    private var activityChart: some View {
        switch range {
        case .week:
            Chart(weekSlices) { slice in
                BarMark(
                    x: .value("Day", slice.date, unit: .day),
                    y: .value("Minutes", slice.minutes)
                )
                .foregroundStyle(by: .value("Kind", slice.kind.label))
                .cornerRadius(2.5)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartLegend(.hidden)
        case .month:
            Chart(monthSlices) { slice in
                BarMark(
                    x: .value("Day", slice.date, unit: .day),
                    y: .value("Minutes", slice.minutes)
                )
                .foregroundStyle(by: .value("Kind", slice.kind.label))
                .cornerRadius(2)
            }
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: 60 * 60 * 24 * 10)
            .chartLegend(.hidden)
            .chartForegroundStyleScale(Self.activityColors)
        case .year:
            Chart(yearSlices) { slice in
                BarMark(
                    x: .value("Month", slice.date, unit: .month),
                    y: .value("Minutes", slice.minutes)
                )
                .foregroundStyle(by: .value("Kind", slice.kind.label))
                .cornerRadius(2.5)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                }
            }
            .chartLegend(.hidden)
            .chartForegroundStyleScale(Self.activityColors)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(StatsKind.allCases, id: \.rawValue) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(kind.legendColor)
                        .frame(width: 10, height: 10)
                    Text(kind.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// 18-week activity heatmap — the last column is the current week
    /// (Mon-first), future cells render as empty tracks.
    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 18 weeks")
                .font(.headline)
            heatmap
        }
        .padding(14)
        .background(cardBackground)
    }

    private var heatmap: some View {
        let weeks = heatmapWeeks
        return HStack(alignment: .top, spacing: 3) {
            ForEach(weeks.indices, id: \.self) { w in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        heatmapCell(weeks[w][d])
                    }
                }
            }
        }
    }

    private func heatmapCell(_ date: Date?) -> some View {
        let level = heatmapLevel(date)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(level.fill)
            .frame(width: 13, height: 13)
            .accessibilityLabel(date.map { "Reading on \(Self.dayFormatter.string(from: $0)): \(heatmapMinutes($0)) minutes" } ?? "No data")
    }

    // MARK: - Subjects

    private var subjectsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subjects")
                .font(.headline)
                .padding(.bottom, 6)
            if subjects.isEmpty {
                Text("Nothing in this range yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(subjects) { row in
                    subjectRow(row)
                    if row.id != subjects.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func subjectRow(_ row: SubjectRow) -> some View {
        HStack(spacing: 12) {
            if let book = row.book {
                BookCoverView(book: book, height: 46)
                    .frame(width: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "note.text")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 46)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress = row.progress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.systemFill))
                            Capsule().fill(Color.accentColor)
                                .frame(width: proxy.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 4)
                }
            }
            Spacer()
            Text(hms(row.seconds))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Data

    private func reload() {
        let store = StatsStore.shared
        todayTotal = store.todayTotals()
        streak = store.streak()
        rangeTotal = store.totals(daysBack: range.daysBack)
        hasAnyData = store.activeDays() > 0

        let days = store.dayTotals(daysBack: max(range.daysBack, 18 * 7))
        weekSlices = daySlices(count: 7, from: days)
        monthSlices = daySlices(count: 30, from: days)
        yearSlices = monthSlices(from: days)
        subjects = buildSubjects(store: store)
        heatmapData = days
    }

    private func daySlices(count: Int, from days: [String: StatsDayTotals]) -> [DaySlice] {
        let today = calendar.startOfDay(for: Date())
        var out: [DaySlice] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = StatsStore.dayKey(date, calendar: calendar)
            let totals = days[key] ?? StatsDayTotals()
            out.append(DaySlice(date: date, minutes: totals.reading / 60, kind: .reading, dayKey: key))
            out.append(DaySlice(date: date, minutes: totals.listening / 60, kind: .listening, dayKey: key))
        }
        return out
    }

    private func monthSlices(from days: [String: StatsDayTotals]) -> [MonthSlice] {
        var perMonth: [Date: (reading: Double, listening: Double)] = [:]
        for (key, totals) in days {
            guard let date = dateFromKey(key) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: date)
            let monthDate = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? date
            var acc = perMonth[monthDate] ?? (0, 0)
            acc.reading += totals.reading
            acc.listening += totals.listening
            perMonth[monthDate] = acc
        }
        var out: [MonthSlice] = []
        let now = Date()
        for offset in stride(from: 11, through: 0, by: -1) {
            guard let month = calendar.date(byAdding: .month, value: -offset, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: month)
            let monthDate = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? month
            let acc = perMonth[monthDate] ?? (0, 0)
            out.append(MonthSlice(date: monthDate, minutes: acc.reading / 60, kind: .reading))
            out.append(MonthSlice(date: monthDate, minutes: acc.listening / 60, kind: .listening))
        }
        return out
    }

    private func buildSubjects(store: StatsStore) -> [SubjectRow] {
        let totals = store.subjectTotals(daysBack: range.daysBack)
        return totals
            .sorted { $0.value > $1.value }
            .compactMap { id, seconds -> SubjectRow? in
                if let book = books.books.first(where: { $0.id.uuidString == id }) {
                    return SubjectRow(
                        id: id,
                        title: book.title,
                        subtitle: book.author ?? "Book",
                        seconds: seconds,
                        progress: bookProgress(book),
                        book: book
                    )
                }
                if let note = notes.allNotes.first(where: { $0.id.uuidString == id }) {
                    return SubjectRow(
                        id: id,
                        title: note.title,
                        subtitle: "Note",
                        seconds: seconds,
                        progress: nil,
                        book: nil
                    )
                }
                return nil // subject was deleted — time stays folded into totals
            }
            .prefix(8)
            .map { $0 }
    }

    private func bookProgress(_ book: Book) -> Double? {
        guard let position = book.position else { return nil }
        switch book.format {
        case .epub:
            guard let count = book.spineCount, count > 0 else { return nil }
            return (Double(position.chapterIndex) + position.chapterFraction) / Double(count)
        case .pdf:
            guard let count = book.pageCount, count > 0 else { return nil }
            return (Double(position.chapterIndex) + position.chapterFraction) / Double(count)
        case .audio:
            return nil
        }
    }

    // MARK: - Heatmap plumbing

    /// 18 columns of 7 days (Mon-first), oldest week first; cells beyond
    /// today are nil. The current week column is complete-but-future-padded
    /// so the grid stays rectangular.
    private var heatmapWeeks: [[Date?]] {
        let today = Date()
        let weekdayOffset = (calendar.component(.weekday, from: today) + 5) % 7 // Mon = 0
        let weekStart = calendar.date(byAdding: .day, value: -weekdayOffset, to: calendar.startOfDay(for: today))!
        var weeks: [[Date?]] = []
        for w in stride(from: 17, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -7 * w, to: weekStart) else { continue }
            var column: [Date?] = []
            for d in 0..<7 {
                if let day = calendar.date(byAdding: .day, value: d, to: start), day <= today {
                    column.append(day)
                } else {
                    column.append(nil)
                }
            }
            weeks.append(column)
        }
        return weeks
    }

    private var heatmapTotals: [String: StatsDayTotals] {
        heatmapData
    }

    private func heatmapLevel(_ date: Date?) -> HeatLevel {
        guard let date else { return .empty }
        let totals = heatmapTotals[StatsStore.dayKey(date, calendar: calendar)]
        let minutes = (totals?.total ?? 0) / 60
        switch minutes {
        case ..<1: return .empty
        case ..<15: return .light
        case ..<30: return .medium
        case ..<60: return .high
        default: return .full
        }
    }

    private func heatmapMinutes(_ date: Date) -> Int {
        let totals = heatmapTotals[StatsStore.dayKey(date, calendar: calendar)]
        return Int(((totals?.total ?? 0) / 60).rounded())
    }

    private enum HeatLevel {
        case empty, light, medium, high, full

        var fill: Color {
            switch self {
            case .empty: return Color(.systemFill).opacity(0.4)
            case .light: return Color.accentColor.opacity(0.25)
            case .medium: return Color.accentColor.opacity(0.45)
            case .high: return Color.accentColor.opacity(0.7)
            case .full: return Color.accentColor
            }
        }
    }

    // MARK: - Helpers

    private func dateFromKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Compact duration text — "2 h 14 m", "48 min", "30 s".
    private func hms(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(m) m" }
        if m > 0 { return "\(m) min" }
        return "\(total) s"
    }
}

private extension StatsKind {
    var label: String {
        switch self {
        case .reading: return "Reading"
        case .listening: return "Listening"
        }
    }

    var legendColor: Color {
        switch self {
        case .reading: return Color.accentColor
        case .listening: return Color.accentColor.opacity(0.45)
        }
    }
}
