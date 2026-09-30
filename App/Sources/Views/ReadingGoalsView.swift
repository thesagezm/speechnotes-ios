import SwiftUI

/// One reading goal: a book, a start date, and a finish-by deadline. The
/// progress is never stored — it is derived live from the book's own
/// position in the shelf (chapter/page/audio position), so a goal advances
/// exactly when the book does, in whichever reader the user last opened.
///
/// `bookTitle` is a snapshot so a goal whose book was deleted still renders
/// (with an honest "book removed" state) instead of vanishing.
struct ReadingGoal: Identifiable, Codable, Equatable {
    let id: UUID
    var bookID: UUID
    var bookTitle: String
    var createdAt: Date
    var startDate: Date
    var deadline: Date
    /// Set once the derived progress crosses the finish line.
    var completedAt: Date?

    init(book: Book, start: Date, deadline: Date) {
        self.id = UUID()
        self.bookID = book.id
        self.bookTitle = book.title
        self.createdAt = Date()
        self.startDate = start
        self.deadline = deadline
        self.completedAt = nil
    }
}

/// Persists goals as one small JSON file (the notes/manifests pattern — a
/// handful of goals never justify a database).
@MainActor
final class GoalStore: ObservableObject {
    /// One shared instance — goals are created from the Stats tab AND the
    /// shelf's long-press menu, and both must see the same list.
    static let shared = GoalStore()

    @Published private(set) var goals: [ReadingGoal] = []

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("reading-goals.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([ReadingGoal].self, from: data) {
            goals = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func add(book: Book, start: Date, deadline: Date) {
        goals.insert(ReadingGoal(book: book, start: start, deadline: deadline), at: 0)
        persist()
    }

    func remove(_ goal: ReadingGoal) {
        goals.removeAll { $0.id == goal.id }
        persist()
    }

    /// Marks goals complete once their book's live progress crosses the
    /// line — called on every dashboard reload.
    func refreshCompletion(progressOf: (ReadingGoal) -> Double?) {
        var changed = false
        for index in goals.indices {
            guard goals[index].completedAt == nil,
                  let fraction = progressOf(goals[index]), fraction >= 0.999 else { continue }
            goals[index].completedAt = Date()
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

// MARK: - Derived progress

/// Everything the goal card/detail render, computed from the book's live
/// shelf state. All date math is calendar-day based (a deadline is a date,
/// not an instant).
struct GoalProgress {
    var fraction: Double?
    /// "Chapter 12 of 30" / "Page 130 of 267" / "5h 12m of 9h 30m".
    var unitLabel: String?
    var bookExists: Bool

    var daysLeft: Int
    /// Linear expectation between start and deadline, clamped to 0…1.
    var expectedFraction: Double

    enum Status {
        case done, onTrack, ahead, behind, overdue, noBook
    }

    var status: Status {
        guard let fraction else { return bookExists ? .onTrack : .noBook }
        if fraction >= 0.999 { return .done }
        if daysLeft <= 0 { return .overdue }
        if fraction >= expectedFraction + 0.1 { return .ahead }
        if fraction >= expectedFraction - 0.05 { return .onTrack }
        return .behind
    }
}

enum GoalMath {
    /// The book's completion fraction from its own position data.
    static func fraction(of book: Book) -> Double? {
        guard let position = book.position else { return nil }
        switch book.format {
        case .epub:
            guard let count = book.spineCount, count > 0 else { return nil }
            return min(1, max(0, (Double(position.chapterIndex) + position.chapterFraction) / Double(count)))
        case .pdf:
            guard let count = book.pageCount, count > 0 else { return nil }
            return min(1, max(0, (Double(position.chapterIndex) + position.chapterFraction) / Double(count)))
        case .audio:
            // Elapsed file seconds via the chapter table's starts — the
            // same arithmetic the audio reader's counter uses.
            guard let duration = book.audioDuration, duration > 0,
                  let chapters = book.audioChapters,
                  chapters.indices.contains(position.chapterIndex) else { return nil }
            let chapter = chapters[position.chapterIndex]
            let span = max(1, chapter.endSeconds - chapter.startSeconds)
            let elapsed = chapter.startSeconds + position.chapterFraction * span
            return min(1, max(0, elapsed / duration))
        }
    }

    /// Where in the book the position sits, in the format's own unit.
    static func unitLabel(for book: Book) -> String? {
        guard let position = book.position else { return nil }
        switch book.format {
        case .epub:
            guard let count = book.spineCount, count > 0 else { return nil }
            return "Chapter \(min(position.chapterIndex + 1, count)) of \(count)"
        case .pdf:
            guard let count = book.pageCount, count > 0 else { return nil }
            return "Page \(min(position.chapterIndex + 1, count)) of \(count)"
        case .audio:
            guard let duration = book.audioDuration, duration > 0,
                  let chapters = book.audioChapters,
                  chapters.indices.contains(position.chapterIndex) else { return nil }
            let chapter = chapters[position.chapterIndex]
            let span = max(1, chapter.endSeconds - chapter.startSeconds)
            return "\(clock(chapter.startSeconds + position.chapterFraction * span)) of \(clock(duration))"
        }
    }

    static func progress(for goal: ReadingGoal, book: Book?, calendar: Calendar) -> GoalProgress {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.startOfDay(for: goal.startDate)
        let deadline = calendar.startOfDay(for: goal.deadline)
        let totalDays = max(1, calendar.dateComponents([.day], from: start, to: deadline).day ?? 1)
        let elapsedDays = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        let expected = min(1, max(0, Double(elapsedDays) / Double(totalDays)))
        let daysLeft = max(0, calendar.dateComponents([.day], from: today, to: deadline).day ?? 0)
        return GoalProgress(
            fraction: book.flatMap(fraction(of:)),
            unitLabel: book.flatMap(unitLabel(for:)),
            bookExists: book != nil,
            daysLeft: daysLeft,
            expectedFraction: expected
        )
    }

    /// H:MM for the audio goal readout.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

// MARK: - Goals card (dashboard)

/// The dashboard's Goals section — Duolingo-flavored on purpose: saturated
/// per-goal gradients, a thick rounded progress bar, status pills, and a
/// celebratory state when the finish line is crossed.
struct GoalsCard: View {
    @EnvironmentObject private var books: BooksStore
    @ObservedObject private var goalStore = GoalStore.shared
    @State private var showingEditor = false
    @State private var selectedGoal: ReadingGoal?

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Goals")
                    .font(.headline)
                Spacer()
                Button {
                    Haptics.tap()
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Capsule().fill(Color.green))
                }
                .accessibilityLabel("Add goal")
            }

            if goalStore.goals.isEmpty {
                emptyState
            } else {
                ForEach(goalStore.goals) { goal in
                    Button {
                        Haptics.tap()
                        selectedGoal = goal
                    } label: {
                        GoalRow(goal: goal, book: book(for: goal))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .sheet(isPresented: $showingEditor) {
            GoalEditorView { book, start, deadline in
                goalStore.add(book: book, start: start, deadline: deadline)
            }
        }
        .sheet(item: $selectedGoal) { goal in
            GoalDetailView(
                goal: goal,
                book: book(for: goal),
                onDelete: {
                    goalStore.remove(goal)
                    selectedGoal = nil
                }
            )
        }
        .onAppear { refreshCompletion() }
        .onChange(of: books.books) { _ in refreshCompletion() }
    }

    private func book(for goal: ReadingGoal) -> Book? {
        books.books.first { $0.id == goal.bookID }
    }

    private func refreshCompletion() {
        goalStore.refreshCompletion { goal in
            book(for: goal).flatMap(GoalMath.fraction(of:))
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Text("🎯")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set your first goal")
                    .font(.subheadline.weight(.semibold))
                Text("Pick a book, choose a finish date, and watch the bar fill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
    }
}

/// One goal card. The palette cycles per goal so several goals read as
/// distinct streaks rather than a wall of identical rows.
struct GoalRow: View {
    let goal: ReadingGoal
    let book: Book?

    var body: some View {
        let progress = GoalMath.progress(for: goal, book: book, calendar: .current)
        let palette = Self.palette(for: goal.id)

        return HStack(spacing: 12) {
            if let book {
                BookCoverView(book: book, height: 56)
                    .frame(width: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 56)
                    .background(Color(.systemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(goal.bookTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.systemFill))
                        if let fraction = progress.fraction {
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [palette.0, palette.1],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: max(8, proxy.size.width * min(max(fraction, 0), 1)))
                        }
                    }
                }
                .frame(height: 10)

                HStack(spacing: 8) {
                    Text(statusText(progress))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusColor(progress).opacity(0.18)))
                        .foregroundStyle(statusColor(progress))
                    if let unit = progress.unitLabel {
                        Text(unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text("\(Int(((progress.fraction ?? 0) * 100).rounded()))%")
                    .font(.subheadline.weight(.heavy).monospacedDigit())
                    .foregroundStyle(progress.fraction == nil ? Color.secondary : palette.1)
                Text(progress.daysLeft <= 0 ? "now" : "\(progress.daysLeft)d left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.0.opacity(0.08))
        )
    }

    private func statusText(_ progress: GoalProgress) -> String {
        switch progress.status {
        case .done: return "🎉 Done"
        case .ahead: return "🔥 Ahead"
        case .onTrack: return "On track"
        case .behind: return "Behind"
        case .overdue: return "Overdue"
        case .noBook: return "Book removed"
        }
    }

    private func statusColor(_ progress: GoalProgress) -> Color {
        switch progress.status {
        case .done: return .yellow
        case .ahead: return .green
        case .onTrack: return .teal
        case .behind: return .orange
        case .overdue: return .red
        case .noBook: return .secondary
        }
    }

    /// Stable per-goal gradient — folded from the UUID's own bytes, NOT
    /// hashValue (which is randomized per process and would reshuffle the
    /// colors on every launch).
    static func palette(for id: UUID) -> (Color, Color) {
        let palettes: [(Color, Color)] = [
            (Color(red: 0.31, green: 0.76, blue: 0.37), Color(red: 0.13, green: 0.60, blue: 0.55)),
            (Color(red: 0.98, green: 0.62, blue: 0.16), Color(red: 0.93, green: 0.36, blue: 0.21)),
            (Color(red: 0.55, green: 0.44, blue: 0.90), Color(red: 0.83, green: 0.35, blue: 0.63)),
            (Color(red: 0.23, green: 0.55, blue: 0.94), Color(red: 0.15, green: 0.68, blue: 0.84)),
        ]
        let first = id.uuid.0 &+ id.uuid.15
        return palettes[Int(first) % palettes.count]
    }
}

// MARK: - Editor

/// Create-goal flow: pick a book, set the start and the finish-by dates.
struct GoalEditorView: View {
    @EnvironmentObject private var books: BooksStore
    @Environment(\.dismiss) private var dismiss

    var onCreate: (Book, Date, Date) -> Void
    /// Set when the editor opens from a book's long-press menu — the book
    /// is pre-chosen and the picker section hides.
    var presetBook: Book? = nil

    @State private var selectedBook: Book?
    @State private var startDate = Date()
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var bookSearch = ""

    private let calendar = Calendar.current

    private var candidateBooks: [Book] {
        let query = bookSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = query.isEmpty
            ? books.books
            : books.books.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return source.filter { $0.importError == nil }
    }

    private var datesValid: Bool {
        calendar.startOfDay(for: deadline) > calendar.startOfDay(for: startDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                if presetBook == nil {
                Section("Book") {
                    if candidateBooks.isEmpty {
                        Text(books.books.isEmpty
                             ? "Import a book first — the shelf is empty."
                             : "No books match \"\(bookSearch)\".")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidateBooks) { book in
                            Button {
                                Haptics.tap()
                                selectedBook = book
                            } label: {
                                HStack(spacing: 12) {
                                    BookCoverView(book: book, height: 44)
                                        .frame(width: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    Text(book.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if selectedBook?.id == book.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.green)
                                    }
                                }
                            }
                        }
                    }
                }
                }

                Section {
                    DatePicker(
                        "Start reading",
                        selection: $startDate,
                        in: calendar.startOfDay(for: Date())...,
                        displayedComponents: .date
                    )
                    DatePicker(
                        "Finish by",
                        selection: $deadline,
                        in: calendar.startOfDay(for: startDate).addingTimeInterval(86_400)...,
                        displayedComponents: .date
                    )
                } header: {
                    Text("Schedule")
                } footer: {
                    if !datesValid {
                        Text("The finish date must be after the start date.")
                    }
                }

                Section {
                    Button {
                        Haptics.success()
                        if let book = selectedBook {
                            onCreate(book, startDate, deadline)
                            dismiss()
                        }
                    } label: {
                        Text("Create Goal")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selectedBook != nil && datesValid ? Color.green : Color.green.opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedBook == nil || !datesValid)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("New Reading Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { if selectedBook == nil { selectedBook = presetBook } }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Detail

/// One goal, blown up: gradient progress ring, schedule facts, and the
/// honest pace verdict (linear expectation between the two dates).
struct GoalDetailView: View {
    let goal: ReadingGoal
    let book: Book?
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let progress = GoalMath.progress(for: goal, book: book, calendar: .current)
                let palette = GoalRow.palette(for: goal.id)

                VStack(spacing: 20) {
                    // Progress ring
                    ZStack {
                        Circle()
                            .stroke(Color(.systemFill), lineWidth: 12)
                        if let fraction = progress.fraction {
                            Circle()
                                .trim(from: 0, to: max(0.001, min(1, fraction)))
                                .stroke(
                                    LinearGradient(
                                        colors: [palette.0, palette.1],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                        }
                        VStack(spacing: 2) {
                            Text("\(Int(((progress.fraction ?? 0) * 100).rounded()))%")
                                .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                            Text(statusText(progress))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(statusColor(progress))
                        }
                    }
                    .frame(width: 150, height: 150)
                    .padding(.top, 10)

                    Text(goal.bookTitle)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)

                    if let unit = progress.unitLabel {
                        Text(unit)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        factRow(icon: "calendar.badge.clock", label: "Started", value: shortDate(goal.startDate))
                        Divider()
                        factRow(icon: "flag.checkered", label: "Finish by", value: shortDate(goal.deadline))
                        Divider()
                        factRow(
                            icon: "hourglass",
                            label: "Time left",
                            value: progress.daysLeft <= 0 ? "Deadline reached" : "\(progress.daysLeft) day\(progress.daysLeft == 1 ? "" : "s")"
                        )
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )

                    Text(paceMessage(progress))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)

                    Button(role: .destructive) {
                        Haptics.press()
                        onDelete()
                    } label: {
                        Label("Delete goal", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func factRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func paceMessage(_ progress: GoalProgress) -> String {
        switch progress.status {
        case .done:
            return "Goal complete — enjoy the finish line 🎉"
        case .noBook:
            return "The book this goal pointed at is no longer on the shelf."
        case .overdue:
            return "The deadline passed at \(Int(((progress.fraction ?? 0) * 100).rounded()))% — extend it by deleting and recreating the goal."
        case .behind:
            return String(format: "Behind pace: %.0f%% expected by today. A little every day closes the gap.", progress.expectedFraction * 100)
        case .ahead:
            return "Ahead of pace — keep it up! 🔥"
        case .onTrack:
            return String(format: "On pace: %.0f%% expected by today, right where you are.", progress.expectedFraction * 100)
        }
    }

    private func statusText(_ progress: GoalProgress) -> String {
        switch progress.status {
        case .done: return "Done"
        case .ahead: return "Ahead"
        case .onTrack: return "On track"
        case .behind: return "Behind"
        case .overdue: return "Overdue"
        case .noBook: return "No book"
        }
    }

    private func statusColor(_ progress: GoalProgress) -> Color {
        switch progress.status {
        case .done: return .yellow
        case .ahead: return .green
        case .onTrack: return .teal
        case .behind: return .orange
        case .overdue: return .red
        case .noBook: return .secondary
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
