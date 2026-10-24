import SwiftUI
import Combine
import SpeechLogic

// MARK: - Stats-tab card

/// The Stats tab's Pomodoro section — sits directly under Goals. Idle, it
/// reads like the goals empty state; running, it shows the phase ring, the
/// countdown, and the controls. Customization lives on a subpage
/// (PomodoroConfigView); this card is the always-visible viewer.
struct PomodoroCard: View {
    @ObservedObject private var store = PomodoroStore.shared
    @State private var showingConfig = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pomodoro")
                    .font(.headline)
                Spacer()
                Button {
                    Haptics.tap()
                    showingConfig = true
                } label: {
                    Image(systemName: "timer")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Capsule().fill(Color.blue))
                }
                .accessibilityLabel("Set up the pomodoro timer")
            }

            if let session = store.session, session.isRunning {
                PomodoroRunView(store: store, session: session)
            } else {
                PomodoroIdleView {
                    Haptics.tap()
                    showingConfig = true
                }
            }

            PomodoroTodayLine(record: store.todayRecord())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .sheet(isPresented: $showingConfig) {
            PomodoroConfigView()
        }
        .onAppear { store.tick() }
    }
}

/// The idle state — goals-empty-state flavored, with a "Set up" affordance.
private struct PomodoroIdleView: View {
    var onSetup: () -> Void

    var body: some View {
        Button(action: onSetup) {
            HStack(spacing: 12) {
                Text("⏱️")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No timer running")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Structured, Flowmodoro or classic — set it up and it counts down right here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.blue.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

/// The tiny "today" line under the section — proof the timer feeds something.
private struct PomodoroTodayLine: View {
    let record: PomodoroDayRecord

    var body: some View {
        if record.blocks > 0 || record.focusSeconds > 0 {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Today · \(record.blocks) block\(record.blocks == 1 ? "" : "s") · \(PomodoroFormat.minutes(record.focusSeconds)) focused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

// MARK: - Running state

private struct PomodoroRunView: View {
    @ObservedObject var store: PomodoroStore
    let session: PomodoroSession

    @State private var confirmingStop = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let tint = PomodoroPalette.tint(for: session.phase)

            VStack(spacing: 12) {
                ring(now: now, tint: tint)
                caption
                controls(now: now, tint: tint)
            }
        }
    }

    // MARK: Ring

    private func ring(now: Date, tint: Color) -> some View {
        let progress = session.isPaused ? min(session.phaseProgress(now: now), 1) : session.phaseProgress(now: now)
        let paused = session.isPaused

        return ZStack {
            Circle()
                .stroke(Color(.systemFill), lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.001, min(1, progress))))
                .stroke(
                    LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text(centerTime(now: now))
                    .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(paused ? Color.secondary : Color.primary)
                phasePill
            }
        }
        .frame(width: 116, height: 116)
    }

    /// Fixed phases count down; flowmodoro's open focus counts up (the pot).
    private func centerTime(now: Date) -> String {
        if session.config.mode == .flowmodoro, session.phase == .focus {
            return PomodoroFormat.countdown(session.flowAccruedFocus(now: now))
        }
        return PomodoroFormat.countdown(session.secondsRemaining(now: now) ?? 0)
    }

    private var phasePill: some View {
        Text(phaseLabel)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(PomodoroPalette.tint(for: session.phase).opacity(0.15)))
            .foregroundStyle(PomodoroPalette.tint(for: session.phase))
    }

    private var phaseLabel: String {
        if session.isPaused { return "Paused" }
        switch session.phase {
        case .prep:
            return "Preparing"
        case .focus:
            if session.config.mode == .flowmodoro { return "Focus" }
            if let n = stepNumber(.focus) { return "Focus \(n.n) of \(n.total)" }
            return "Focus"
        case .rest:
            if session.config.mode == .flowmodoro { return "Break" }
            if let n = stepNumber(.rest) { return "Break \(n.n) of \(n.total)" }
            return "Break"
        case .done:
            return "Done"
        }
    }

    /// Which focus block / break is live (structured & classic only —
    /// flowmodoro has no numbered schedule).
    private func stepNumber(_ phase: PomodoroPhase) -> (n: Int, total: Int)? {
        guard session.config.mode != .flowmodoro, !session.steps.isEmpty else { return nil }
        let total = session.steps.filter { $0.phase == phase }.count
        guard total > 0 else { return nil }
        let through = min(session.stepIndex, session.steps.count - 1)
        let n = (0...through).filter { session.steps[$0].phase == phase }.count
        return (max(1, n), total)
    }

    // MARK: Caption

    private var caption: some View {
        Group {
            if session.config.mode == .flowmodoro {
                Text("5 min of focus earns 1 min of break")
            } else if session.config.mode == .structured, let end = session.windowEnd {
                Text("Ends \(end.formatted(date: .omitted, time: .shortened)) · \(session.config.structuredBreakCount) breaks × \(session.config.structuredBreakSeconds / 60) min")
            } else {
                let focus = session.config.classicFocusMinutes.reduce(0, +)
                Text("\(session.config.classicFocusMinutes.count) blocks · \(session.config.classicBreakMinutes.count) breaks · \(PomodoroFormat.minutes(Double(focus * 60))) of focus")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(now: Date, tint: Color) -> some View {
        HStack(spacing: 10) {
            // Pause / resume — always available while running.
            Button {
                Haptics.tap()
                session.isPaused ? store.resume() : store.pause()
            } label: {
                Label(session.isPaused ? "Resume" : "Pause",
                      systemImage: session.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .tint(tint)

            // Flowmodoro claim — appears once the pot crosses 3 focus min.
            if session.config.mode == .flowmodoro && session.phase == .focus {
                Button {
                    Haptics.tap()
                    store.claimBreak()
                } label: {
                    Label("Claim break", systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .disabled(!session.flowCanClaim(now: now))
            }

            // Skip — never during the mandatory prep; flowmodoro only skips
            // a rest (its focus has no "next" without a claim).
            if canSkip {
                Button {
                    Haptics.tap()
                    store.skipPhase()
                } label: {
                    Label("Skip", systemImage: "forward.fill")
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                Haptics.press()
                confirmingStop = true
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
        }
        .font(.footnote.weight(.semibold))
        .confirmationDialog("End this pomodoro?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("End timer", role: .destructive) {
                Haptics.press()
                store.stop()
            }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Focus time so far stays in today's count.")
        }
    }

    private var canSkip: Bool {
        guard !session.isPaused, session.phase != .prep else { return false }
        if session.config.mode == .flowmodoro { return session.phase == .rest }
        return true
    }
}

// MARK: - Config subpage

/// The customization subpage. Everything the user asked to tune lives here:
/// mode, the mandatory 2–5 min prep, the structured window (duration or
/// finish time + break count/length), the flowmodoro rule (fixed), and
/// classic's per-block/per-break minute tuning.
struct PomodoroConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PomodoroStore.shared
    @State private var draft: PomodoroConfig

    init() {
        // The view is re-inited freely; State(initialValue:) only lands on
        // first insertion, so live edits survive re-renders.
        _draft = State(initialValue: PomodoroStore.shared.config)
    }

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            Form {
                modeSection
                prepSection
                modeSpecificSections
                startSection
            }
            .navigationTitle("New Pomodoro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Shared sections

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $draft.mode) {
                Text("Structured").tag(PomodoroMode.structured)
                Text("Flowmodoro").tag(PomodoroMode.flowmodoro)
                Text("Pomodoro").tag(PomodoroMode.classic)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(modeFooter)
        }
    }

    private var modeFooter: String {
        switch draft.mode {
        case .structured:
            return "One window — a time limit or a finish time — with breaks spread evenly through it."
        case .flowmodoro:
            return "Focus as long as you like. Every 5 focus minutes bank 1 break minute, claimable from 3 minutes."
        case .classic:
            return "Your own blocks and breaks, each with its own length — 25 then 30, 5 then 15, whatever fits."
        }
    }

    /// The mandatory prep — 2–5 minutes, every mode, not skippable.
    private var prepSection: some View {
        Section {
            Picker("Prepare first", selection: prepMinutes) {
                ForEach(2...5, id: \.self) { m in
                    Text("\(m) min").tag(m)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Preparation")
        } footer: {
            Text("Every timer opens with this short prepare window — settle in before focus starts.")
        }
    }

    private var prepMinutes: Binding<Int> {
        Binding(
            get: { max(2, min(5, Int(round(Double(draft.prepSeconds) / 60)))) },
            set: { draft.prepSeconds = $0 * 60 }
        )
    }

    @ViewBuilder
    private var modeSpecificSections: some View {
        switch draft.mode {
        case .structured: structuredSections
        case .flowmodoro: flowmodoroSections
        case .classic: classicSections
        }
    }

    // MARK: Structured

    @ViewBuilder
    private var structuredSections: some View {
        Section("Ends") {
            Picker("Set by", selection: $draft.structuredByDuration) {
                Text("Time limit").tag(true)
                Text("Finish time").tag(false)
            }
            .pickerStyle(.segmented)

            if draft.structuredByDuration {
                Stepper(value: durationMinutes, in: 10...720, step: 5) {
                    HStack {
                        Text("Time limit")
                        Spacer()
                        Text(durationText(draft.structuredDurationSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else {
                DatePicker("Finish at", selection: finishTimeBinding, displayedComponents: .hourAndMinute)
            }
        }

        Section {
            Stepper(value: $draft.structuredBreakCount, in: 0...12) {
                HStack {
                    Text("Breaks in between")
                    Spacer()
                    Text("\(draft.structuredBreakCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if draft.structuredBreakCount > 0 {
                Stepper(value: breakLengthMinutes, in: 1...30) {
                    HStack {
                        Text("Each break")
                        Spacer()
                        Text("\(draft.structuredBreakSeconds / 60) min")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Breaks")
        } footer: {
            Text(structuredFooter)
        }
    }

    private var structuredFooter: String {
        if let summary = structuredSummary { return summary }
        return "Not enough room for \(draft.structuredBreakCount) break\(draft.structuredBreakCount == 1 ? "" : "s") in this window — shorten them, drop some, or give the window more time."
    }

    /// The layout preview, or nil when the window can't hold the plan.
    private var structuredSummary: String? {
        guard let end = draft.structuredWindowEnd(after: Date(), calendar: calendar) else { return nil }
        let window = end.timeIntervalSinceNow
        guard let segment = draft.structuredSegmentSeconds(window: window) else { return nil }
        let endsText = draft.structuredByDuration
            ? "in \(durationText(draft.structuredDurationSeconds))"
            : "at \(end.formatted(date: .omitted, time: .shortened))"
        let segments = draft.structuredBreakCount + 1
        var parts = ["≈\(PomodoroFormat.minutes(Double(segment))) focus × \(segments)"]
        if draft.structuredBreakCount > 0 {
            parts.append("\(draft.structuredBreakSeconds / 60) min break × \(draft.structuredBreakCount)")
        }
        parts.append("\(draft.prepSeconds / 60) min prep")
        return parts.joined(separator: " + ") + ", \(endsText)."
    }

    private var durationMinutes: Binding<Int> {
        Binding(
            get: { max(10, draft.structuredDurationSeconds / 60) },
            set: { draft.structuredDurationSeconds = $0 * 60 }
        )
    }

    private var breakLengthMinutes: Binding<Int> {
        Binding(
            get: { max(1, draft.structuredBreakSeconds / 60) },
            set: { draft.structuredBreakSeconds = $0 * 60 }
        )
    }

    /// The stored hour/minute rendered as a concrete date for the picker —
    /// "17:00" stays "17:00" whether it resolves to today or tomorrow.
    private var finishTimeBinding: Binding<Date> {
        Binding(
            get: {
                calendar.date(bySettingHour: draft.structuredFinishHour,
                              minute: draft.structuredFinishMinute, second: 0, of: Date()) ?? Date()
            },
            set: {
                let comps = calendar.dateComponents([.hour, .minute], from: $0)
                draft.structuredFinishHour = comps.hour ?? 17
                draft.structuredFinishMinute = comps.minute ?? 0
            }
        )
    }

    // MARK: Flowmodoro

    /// The rule IS the mode — displayed, not tuned.
    private var flowmodoroSections: some View {
        Section("The rule") {
            flowRow(icon: "brain.head.profile", tint: .green,
                    title: "5 min of focus", subtitle: "earns 1 min of break")
            flowRow(icon: "cup.and.saucer", tint: .blue,
                    title: "Claim from 3 min", subtitle: "the pot shows up as a button — take it whenever")
            flowRow(icon: "repeat", tint: .orange,
                    title: "It keeps growing", subtitle: "20 focused minutes banks a 4-minute break")
        }
    }

    private func flowRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Classic

    @ViewBuilder
    private var classicSections: some View {
        Section {
            Stepper(value: focusBlockCount, in: 1...12) {
                HStack {
                    Text("Blocks")
                    Spacer()
                    Text("\(draft.classicFocusMinutes.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ForEach(draft.classicFocusMinutes.indices, id: \.self) { i in
                minutesRow("Block \(i + 1)", minutes: blockBinding(i), range: 1...180)
            }
        } header: {
            Text("Focus blocks")
        } footer: {
            Text("Each block keeps its own length.")
        }

        Section {
            Stepper(value: breakCount, in: 0...max(0, draft.classicFocusMinutes.count)) {
                HStack {
                    Text("Breaks")
                    Spacer()
                    Text("\(draft.classicBreakMinutes.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ForEach(draft.classicBreakMinutes.indices, id: \.self) { i in
                minutesRow("Break \(i + 1)", minutes: breakBinding(i), range: 1...60)
            }
        } header: {
            Text("Breaks")
        } footer: {
            Text("A break follows each block while there are breaks left — one after the final block is fine.")
        }
    }

    private var focusBlockCount: Binding<Int> {
        Binding(
            get: { draft.classicFocusMinutes.count },
            set: {
                while draft.classicFocusMinutes.count < $0 { draft.classicFocusMinutes.append(25) }
                while draft.classicFocusMinutes.count > $0 { draft.classicFocusMinutes.removeLast() }
                // Breaks can't outlive their blocks.
                while draft.classicBreakMinutes.count > $0 { draft.classicBreakMinutes.removeLast() }
            }
        )
    }

    private var breakCount: Binding<Int> {
        Binding(
            get: { draft.classicBreakMinutes.count },
            set: {
                while draft.classicBreakMinutes.count < $0 { draft.classicBreakMinutes.append(5) }
                while draft.classicBreakMinutes.count > $0 { draft.classicBreakMinutes.removeLast() }
            }
        )
    }

    private func blockBinding(_ i: Int) -> Binding<Int> {
        Binding(
            get: { draft.classicFocusMinutes.indices.contains(i) ? draft.classicFocusMinutes[i] : 25 },
            set: { if draft.classicFocusMinutes.indices.contains(i) { draft.classicFocusMinutes[i] = $0 } }
        )
    }

    private func breakBinding(_ i: Int) -> Binding<Int> {
        Binding(
            get: { draft.classicBreakMinutes.indices.contains(i) ? draft.classicBreakMinutes[i] : 5 },
            set: { if draft.classicBreakMinutes.indices.contains(i) { draft.classicBreakMinutes[i] = $0 } }
        )
    }

    private func minutesRow(_ title: String, minutes: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: minutes, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(minutes.wrappedValue) min")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Start

    private var startSection: some View {
        Section {
            Button {
                Haptics.success()
                store.start(draft)
                dismiss()
            } label: {
                Text("Start Timer")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(canStart ? Color.blue : Color.blue.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            if store.session?.isRunning == true {
                Text("Starting now replaces the timer that's running.")
            } else {
                Text(structuredSummary ?? "") // empty for non-structured modes
            }
        }
    }

    private var canStart: Bool {
        guard draft.mode != .flowmodoro else { return true }
        if draft.mode == .classic {
            return !draft.classicFocusMinutes.isEmpty
        }
        return structuredSummary != nil
    }

    private func durationText(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 && m > 0 { return "\(h) h \(m) min" }
        if h > 0 { return "\(h) h" }
        return "\(m) min"
    }
}

// MARK: - Gentle top banner (app-wide)

/// The root-window Pomodoro banner — a soft floating card under the status
/// bar, across every tab. Deliberately NOT an alert: thin material, a
/// hairline tint stroke, one soft spring, non-blocking, dismissible by tap.
/// This surface also owns the app-wide one-second tick (phase transitions
/// must surface from any tab) and the foreground reconcile after suspension.
struct PomodoroBannerModifier: ViewModifier {
    @ObservedObject private var store = PomodoroStore.shared
    @Environment(\.scenePhase) private var scenePhase
    // @State: the publisher is created once per lifetime, not per render.
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            if let banner = store.banner {
                PomodoroBannerCard(banner: banner)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: store.banner)
        .onReceive(ticker) { _ in store.tick() }
        .onChange(of: scenePhase) { phase in
            // Back from suspension: wall-clock reconcile surfaces whatever
            // happened while away (break over, session done).
            if phase == .active {
                store.tick()
            }
        }
    }
}

private struct PomodoroBannerCard: View {
    let banner: PomodoroBanner
    @ObservedObject private var store = PomodoroStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 34, height: 34)
                .background(banner.tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle = banner.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

            if let actionTitle = banner.actionTitle {
                Button {
                    Haptics.tap()
                    handleAction()
                } label: {
                    Text(actionTitle)
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered)
                .tint(banner.tint)
            }

            Button {
                Haptics.tap()
                store.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(banner.tint.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .onTapGesture { store.dismissBanner() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(banner.title). \(banner.subtitle ?? "")")
    }

    private func handleAction() {
        switch banner.kind {
        case .claimAvailable:
            store.claimBreak()
        default:
            store.dismissBanner()
        }
    }
}

extension View {
    /// Attach once at the app root — see PomodoroBannerModifier.
    func pomodoroBanner() -> some View {
        modifier(PomodoroBannerModifier())
    }
}
