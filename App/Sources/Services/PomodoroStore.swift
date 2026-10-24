import Foundation
import SwiftUI
import UserNotifications
import SpeechLogic

/// One day of folded focus time — the Pomodoro section's own "today" line.
/// Deliberately NOT a StatsStore entry: reading/listening charts split by
/// kind, and timer minutes are neither.
struct PomodoroDayRecord: Codable, Equatable {
    var dayKey: String
    var focusSeconds: Double
    var blocks: Int

    var focusMinutes: Int { Int((focusSeconds / 60).rounded()) }
}

/// The persisted Pomodoro state: last-used config, the running session (if
/// any), and the day-folded focus history. One small JSON file — the
/// reading-goals pattern.
private struct PomodoroStateFile: Codable {
    var version: Int = 1
    var config: PomodoroConfig
    var session: PomodoroSession?
    var history: [PomodoroDayRecord] = []
}

/// The gentle top-of-app bubble the Pomodoro section raises (user ask:
/// "not a punch in my face — gentle, pleasing, useful"). Pure data — the
/// overlay in PomodoroViews renders it; actions map back through the kind.
struct PomodoroBanner: Identifiable, Equatable {
    enum Kind: Equatable {
        case countdown        // ≤60 s left in a fixed phase
        case blockComplete    // focus block done, break starting
        case resumeFocus      // break over, ease back in
        case sessionComplete
        case claimAvailable   // flowmodoro pot crossed the claim threshold
        case breakClaimed     // flowmodoro break just claimed
    }

    let id = UUID()
    var kind: Kind
    var icon: String
    var tint: Color
    var title: String
    var subtitle: String?
    /// Optional primary action label ("Claim now"). The handler is looked
    /// up from the kind by the overlay — banners stay Equatable data.
    var actionTitle: String?
    /// nil = stays until dismissed (still gentle: small, top, tappable-away).
    var autoDismissAfter: TimeInterval?
}

/// Owns the Pomodoro timer end-to-end: the persisted session, the day log,
/// phase notifications, and the banner. A @MainActor singleton like
/// GoalStore — the stats card, the config sheet and the root banner overlay
/// must all see the same state.
///
/// Kill-safety: the session is a Codable value whose every boundary is a
/// wall-clock date, so it is persisted on each transition and reconciled
/// from `Date()` alone on relaunch — the same date-math contract the
/// background-persistence rounds use for playback.
@MainActor
final class PomodoroStore: ObservableObject {
    static let shared = PomodoroStore()

    @Published private(set) var config: PomodoroConfig
    @Published private(set) var session: PomodoroSession?
    @Published private(set) var history: [PomodoroDayRecord] = []

    // MARK: Banners

    @Published private(set) var banner: PomodoroBanner?
    private var bannerDismissTask: Task<Void, Never>?
    /// "1 minute left" fires once per phase — keyed by step index + phase.
    private var countdownAnnouncedKey: String?
    /// Flowmodoro's claim hint fires once per focus stint — keyed by the
    /// stint's start date.
    private var claimAnnouncedForStint: Date?

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pomodoro-state.json")
    }

    private let calendar = Calendar.current

    init() {
        var loaded = PomodoroStateFile(config: PomodoroConfig(), session: nil, history: [])
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(PomodoroStateFile.self, from: data) {
            loaded = decoded
        }
        config = loaded.config
        history = loaded.history
        if var restored = loaded.session {
            // Reconcile: phases that elapsed while the app was dead fold
            // into history without toasts or haptics — the notification
            // (if authorized) already spoke for them. But the resume
            // moments still deserve the gentle banner: reopening the app
            // after a break ran out IS the "ease back in" moment.
            let events = restored.advanceIfDue(now: Date())
            let finished = restored.phase == .done
            fold(events)
            session = finished ? nil : restored
            if !events.isEmpty { persist() }
            if finished {
                showBanner(sessionCompleteBanner())
            } else if events.contains(where: { $0.completedPhase == .rest }) {
                showBanner(Self.resumeBanner(fromBreak: true))
            }
        }
    }

    // MARK: Starting / stopping

    /// Starts (or replaces) the running session with the given config. The
    /// config is saved as the default so the next editor open pre-fills it.
    func start(_ newConfig: PomodoroConfig, now: Date = Date()) {
        if var old = session {
            let event = old.stop(now: now)
            fold(event.map { [$0] } ?? [])
        }
        config = newConfig
        session = PomodoroSession(config: newConfig, start: now, calendar: calendar)
        countdownAnnouncedKey = nil
        claimAnnouncedForStint = nil
        persist()
        requestNotificationAuthorizationIfNeeded()
        schedulePhaseNotification()
        // Prep is short; the card picks the banner up on its next render —
        // but raise it here so the overlay shows it even off the Stats tab.
        if newConfig.prepSeconds > 0 {
            showBanner(PomodoroBanner(
                kind: .countdown,
                icon: "hand.wave",
                tint: PomodoroPalette.tint(for: .prep),
                title: "Warming up",
                subtitle: "\(max(1, Int(round(Double(newConfig.prepSeconds) / 60)))) min of prep, then focus begins",
                actionTitle: nil,
                autoDismissAfter: 8
            ))
        }
    }

    func stop(now: Date = Date()) {
        guard var s = session else { return }
        let event = s.stop(now: now)
        fold(event.map { [$0] } ?? [])
        session = nil
        dismissBanner()
        cancelPhaseNotification()
        persist()
    }

    func pause(now: Date = Date()) {
        guard var s = session else { return }
        if s.pause(now: now) {
            session = s
            cancelPhaseNotification()
            persist()
        }
    }

    func resume(now: Date = Date()) {
        guard var s = session else { return }
        if s.resume(now: now) {
            session = s
            schedulePhaseNotification()
            persist()
        }
    }

    /// Skip the current phase (structured keeps its absolute window; classic
    /// slides; flow skips a rest). The engine's advance after the skip emits
    /// the partial-focus event, so history stays honest.
    func skipPhase(now: Date = Date()) {
        guard var s = session else { return }
        guard s.skipPhase(now: now) else { return }
        advance(session: &s, now: now)
    }

    func claimBreak(now: Date = Date()) {
        guard var s = session else { return }
        let earned = s.flowEarnedBreak(now: now)
        guard s.claimBreak(now: now) else { return }
        session = s
        claimAnnouncedForStint = nil
        persist()
        schedulePhaseNotification()
        showBanner(PomodoroBanner(
            kind: .breakClaimed,
            icon: "cup.and.saucer",
            tint: PomodoroPalette.tint(for: .rest),
            title: PomodoroFormat.breakLength(earned),
            subtitle: "To yourself — the pot starts refilling after",
            actionTitle: nil,
            autoDismissAfter: 8
        ))
    }

    // MARK: Ticking

    /// The one-second heartbeat. Cheap when nothing is due (a guard and a
    /// date compare); does real work only on transitions, where it folds
    /// history, raises the gentle banner, and reschedules the notification.
    /// Driven by the root banner overlay's timer so phase changes are seen
    /// from any tab, not just Stats.
    func tick(now: Date = Date(), announce: Bool = true) {
        guard var s = session, s.isRunning, !s.isPaused else { return }
        advance(session: &s, now: now, announce: announce)
    }

    private func advance(session s: inout PomodoroSession, now: Date, announce: Bool = true) {
        let events = s.advanceIfDue(now: now)
        guard !events.isEmpty else {
            guard announce, s.isRunning else { return }
            announceCountdownIfNeeded(s, now: now)
            announceClaimIfNeeded(s, now: now)
            return
        }

        let finished = s.phase == .done
        fold(events)
        countdownAnnouncedKey = nil
        session = finished ? nil : s
        if finished {
            cancelPhaseNotification()
            if announce {
                showBanner(sessionCompleteBanner())
                Haptics.success()
                ToastCenter.shared.show("Pomodoro complete 🎉")
            }
        } else if announce {
            announceTransition(events)
        }
        schedulePhaseNotification()
        persist()
    }

    // MARK: Banners

    /// The phase that just began gets the gentle headline — "break's over"
    /// after a rest, a quiet "ready to focus" after prep.
    private func announceTransition(_ events: [PomodoroEvent]) {
        guard let s = session, s.isRunning else { return }
        switch s.phase {
        case .focus:
            let fromBreak = events.contains { $0.completedPhase == .rest }
            showBanner(Self.resumeBanner(fromBreak: fromBreak))
            Haptics.tap()
        case .rest:
            let restSeconds = s.secondsRemaining(now: Date()) ?? 0
            showBanner(PomodoroBanner(
                kind: .blockComplete,
                icon: "checkmark.circle",
                tint: PomodoroPalette.tint(for: .rest),
                title: "Nice work — block done",
                subtitle: "\(PomodoroFormat.breakLength(restSeconds)) starting now — stretch, sip, breathe",
                actionTitle: nil,
                autoDismissAfter: 8
            ))
            Haptics.success()
        case .prep, .done:
            break
        }
    }

    /// The "ease back in" card — shared by live transitions and the
    /// relaunch reconcile so the copy can't drift.
    private static func resumeBanner(fromBreak: Bool) -> PomodoroBanner {
        PomodoroBanner(
            kind: .resumeFocus,
            icon: fromBreak ? "book" : "brain.head.profile",
            tint: PomodoroPalette.tint(for: .focus),
            title: fromBreak ? "Break's over" : "Ready to focus",
            subtitle: fromBreak
                ? "Ease back into your reading — no rush"
                : "Your prep time is up — ease into the first block",
            actionTitle: nil,
            autoDismissAfter: fromBreak ? nil : 7
        )
    }

    /// The "last minutes" nudge — one per phase, at the 60-second mark.
    private func announceCountdownIfNeeded(_ s: PomodoroSession, now: Date) {
        guard let end = s.phaseEnd else { return } // open-ended flow focus never counts down
        let remaining = end.timeIntervalSince(now)
        guard remaining > 0, remaining <= 60 else { return }
        let key = "\(s.stepIndex)-\(s.phase)-\(Int(end.timeIntervalSince1970))"
        guard countdownAnnouncedKey != key else { return }
        countdownAnnouncedKey = key
        let subtitle: String
        switch s.phase {
        case .prep: subtitle = "Focus begins in under a minute"
        case .focus: subtitle = "Finish the thought — a break is close"
        case .rest: subtitle = "Ease back toward your reading when ready"
        case .done: return
        }
        showBanner(PomodoroBanner(
            kind: .countdown,
            icon: "hourglass",
            tint: PomodoroPalette.tint(for: s.phase),
            title: "About a minute left",
            subtitle: subtitle,
            actionTitle: nil,
            autoDismissAfter: 10
        ))
    }

    /// Flowmodoro: the pot crossed 3 focus minutes — offer the claim once
    /// per stint, softly, with the claim one tap away.
    private func announceClaimIfNeeded(_ s: PomodoroSession, now: Date) {
        guard s.config.mode == .flowmodoro, s.phase == .focus,
              let stint = s.flowStintStart, claimAnnouncedForStint != stint,
              s.flowCanClaim(now: now) else { return }
        claimAnnouncedForStint = stint
        showBanner(PomodoroBanner(
            kind: .claimAvailable,
            icon: "cup.and.saucer",
            tint: PomodoroPalette.tint(for: .rest),
            title: "\(PomodoroFormat.breakLength(s.flowEarnedBreak(now: now))) banked",
            subtitle: "Claim a break whenever you like — it keeps growing",
            actionTitle: "Claim now",
            autoDismissAfter: nil
        ))
    }

    private func sessionCompleteBanner() -> PomodoroBanner {
        let record = todayRecord()
        let blocks = record.blocks
        let minutes = PomodoroFormat.minutes(record.focusSeconds)
        return PomodoroBanner(
            kind: .sessionComplete,
            icon: "party.popper",
            tint: PomodoroPalette.tint(for: .focus),
            title: "Pomodoro complete",
            subtitle: blocks > 0
                ? "\(blocks) block\(blocks == 1 ? "" : "s") · \(minutes) focused — well done today"
                : "Well done today",
            actionTitle: nil,
            autoDismissAfter: 12
        )
    }

    func showBanner(_ banner: PomodoroBanner) {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        self.banner = banner
        if let after = banner.autoDismissAfter {
            bannerDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.dismissBanner()
            }
        }
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        banner = nil
    }

    // MARK: History

    private func fold(_ events: [PomodoroEvent]) {
        let focus = events.filter { $0.completedPhase == .focus && $0.seconds > 0.5 }
        guard !focus.isEmpty else { return }
        let key = StatsStore.dayKey(Date(), calendar: calendar)
        var record = history.first { $0.dayKey == key } ?? PomodoroDayRecord(dayKey: key, focusSeconds: 0, blocks: 0)
        for event in focus {
            record.focusSeconds += event.seconds
            record.blocks += 1
        }
        history.removeAll { $0.dayKey == key }
        history.insert(record, at: 0)
        if history.count > 90 {
            history = Array(history.prefix(90))
        }
    }

    func todayRecord(now: Date = Date()) -> PomodoroDayRecord {
        let key = StatsStore.dayKey(now, calendar: calendar)
        return history.first { $0.dayKey == key } ?? PomodoroDayRecord(dayKey: key, focusSeconds: 0, blocks: 0)
    }

    // MARK: Persistence

    private func persist() {
        let file = PomodoroStateFile(config: config, session: session, history: history)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Phase notifications

    /// One pending local notification for the next fixed phase end — the
    /// background half of the banner. Removed on pause/stop, rescheduled on
    /// every transition and resume.
    private func schedulePhaseNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        guard let s = session, s.isRunning, !s.isPaused,
              let end = s.phaseEnd, end.timeIntervalSinceNow > 1 else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default
        switch s.phase {
        case .prep:
            content.title = "Ready to focus"
            content.body = "Prep is done — ease into your first block."
        case .focus:
            let rest = s.nextRestSeconds()
            content.title = "Nice work — block done"
            content.body = rest > 0
                ? "A \(PomodoroFormat.breakLength(rest)) is waiting — stretch, sip, breathe."
                : "Time for a short breather."
        case .rest:
            content.title = "Break's over"
            content.body = "Ease back into your reading — no rush."
        case .done:
            return
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: end.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger))
    }

    private func cancelPhaseNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    private func requestNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private static let notificationID = "com.speechnotes.pomodoro.phase"
}

// MARK: - Small shared helpers

/// Phase colors shared by the card, the ring and the banner — one source so
/// "break is blue" everywhere.
enum PomodoroPalette {
    static func tint(for phase: PomodoroPhase) -> Color {
        switch phase {
        case .prep: return .orange
        case .focus: return .green
        case .rest: return .blue
        case .done: return .secondary
        }
    }
}

/// Human copy for durations that are often fractional ("36 s", "2.4 min").
enum PomodoroFormat {
    static func breakLength(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) s of break" }
        let minutes = seconds / 60
        if minutes >= 10 { return "\(Int(minutes.rounded())) min of break" }
        return String(format: "%.1f min of break", minutes)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) m" }
        return "\(minutes) min"
    }

    /// Countdown text; rounds up so the timer never shows 0:00 early.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

extension PomodoroSession {
    /// Break length that FOLLOWS the current focus phase, for copy —
    /// structured: the configured break; classic: the matching break entry;
    /// flow: the current pot.
    func nextRestSeconds() -> TimeInterval {
        guard config.mode != .flowmodoro, stepIndex + 1 < steps.count,
              steps[stepIndex + 1].phase == .rest,
              let restEnd = steps[stepIndex + 1].end else { return 0 }
        let focusEnd = phaseEnd ?? Date()
        return restEnd.timeIntervalSince(focusEnd)
    }
}
