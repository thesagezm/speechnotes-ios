import Foundation

// MARK: - Modes

/// The three timer shapes the Stats tab's Pomodoro section offers.
///
/// - `structured`: one fixed window ("3 hours from now" or "finish by 17:00")
///   with N evenly-spaced breaks carved out of it. The window is absolute —
///   pauses shift it, but skips do not pull the finish earlier.
/// - `flowmodoro`: open-ended focus; every 5 focus minutes bank 1 break
///   minute, claimable from 3 focus minutes.
/// - `classic`: hand-tuned focus blocks and breaks, each with its own length
///   (block 1 = 25 min, block 2 = 30 min; break 1 = 5 min, break 2 = 15 min).
public enum PomodoroMode: String, Codable, Sendable, CaseIterable {
    case structured
    case flowmodoro
    case classic
}

// MARK: - Phases

/// One segment of a running timer. `rest` (decoded/encoded as "rest") is the
/// break phase — spelled around the Swift keyword.
public enum PomodoroPhase: String, Codable, Sendable {
    case prep
    case focus
    case rest
    case done
}

// MARK: - Config

/// A full description of a timer run. The running session snapshots its
/// config at start, so editing preferences never bends a live timer.
public struct PomodoroConfig: Codable, Equatable, Sendable {
    public var mode: PomodoroMode

    /// Mandatory preparation window before the first focus phase, seconds.
    /// Clamped 120...300 (2–5 min) by the editor; every mode runs it, and it
    /// is not skippable.
    public var prepSeconds: Int

    // Structured
    /// true → the window is a duration from start; false → a wall-clock
    /// finish time (hour/minute below, next occurrence).
    public var structuredByDuration: Bool
    public var structuredDurationSeconds: Int
    public var structuredFinishHour: Int
    public var structuredFinishMinute: Int
    public var structuredBreakCount: Int
    public var structuredBreakSeconds: Int

    // Classic — per-block/per-break minutes, adjustable individually.
    /// Focus block lengths in minutes; the count of blocks IS the array count.
    public var classicFocusMinutes: [Int]
    /// Break lengths in minutes; a break follows each block while the array
    /// has entries (breaks.count <= blocks keeps them strictly in between).
    public var classicBreakMinutes: [Int]

    public init(
        mode: PomodoroMode,
        prepSeconds: Int = 180,
        structuredByDuration: Bool = true,
        structuredDurationSeconds: Int = 3 * 3600,
        structuredFinishHour: Int = 17,
        structuredFinishMinute: Int = 0,
        structuredBreakCount: Int = 3,
        structuredBreakSeconds: Int = 5 * 60,
        classicFocusMinutes: [Int] = [25, 25, 25, 25],
        classicBreakMinutes: [Int] = [5, 5, 5]
    ) {
        self.mode = mode
        self.prepSeconds = prepSeconds
        self.structuredByDuration = structuredByDuration
        self.structuredDurationSeconds = structuredDurationSeconds
        self.structuredFinishHour = structuredFinishHour
        self.structuredFinishMinute = structuredFinishMinute
        self.structuredBreakCount = structuredBreakCount
        self.structuredBreakSeconds = structuredBreakSeconds
        self.classicFocusMinutes = classicFocusMinutes
        self.classicBreakMinutes = classicBreakMinutes
    }

    /// The absolute end of a structured window that starts at `start` —
    /// either start + duration, or the next occurrence of the finish
    /// wall-clock time (today if still ahead, otherwise tomorrow).
    public func structuredWindowEnd(after start: Date, calendar: Calendar) -> Date? {
        if structuredByDuration {
            return start.addingTimeInterval(TimeInterval(structuredDurationSeconds))
        }
        var comps = DateComponents()
        comps.hour = structuredFinishHour
        comps.minute = structuredFinishMinute
        return calendar.nextDate(after: start, matching: comps, matchingPolicy: .nextTime)
    }

    /// Focus seconds per structured segment for a window of `window` seconds,
    /// or nil when the window cannot hold prep + the breaks + at least one
    /// focus minute per segment. Residual seconds land in the final segment
    /// (the timeline builder ends it exactly at the window end).
    public func structuredSegmentSeconds(window: TimeInterval) -> Int? {
        let fixed = prepSeconds + structuredBreakCount * structuredBreakSeconds
        let segments = structuredBreakCount + 1
        let focus = Int(window) - fixed
        guard focus >= segments * 60 else { return nil }
        return focus / segments
    }
}

// MARK: - Timeline steps

/// A scheduled step. `end` is absolute for structured AND classic (classic's
/// chained durations are resolved to dates at start, and pauses slide every
/// not-yet-reached end) — nil only for the open-ended flowmodoro focus,
/// which lives outside the timeline entirely.
public struct PomodoroStep: Codable, Equatable, Sendable {
    public var phase: PomodoroPhase
    public var end: Date?

    public init(phase: PomodoroPhase, end: Date?) {
        self.phase = phase
        self.end = end
    }
}

// MARK: - Events

/// One phase that just completed, surfaced so the store can fold focus
/// seconds into history and fire toasts/haptics.
public struct PomodoroEvent: Equatable, Sendable {
    public var completedPhase: PomodoroPhase
    /// How long the completed phase ran, seconds. Focus events feed the
    /// day log; partial focus (stop/skip mid-block) is included.
    public var seconds: TimeInterval

    public init(completedPhase: PomodoroPhase, seconds: TimeInterval) {
        self.completedPhase = completedPhase
        self.seconds = seconds
    }
}

// MARK: - Session

/// The live timer, as a plain Codable value. All time math is anchored to
/// wall-clock dates, never to tick counts, so the session survives the app
/// being backgrounded, suspended or killed: on relaunch the store feeds the
/// current date to `advanceIfDue` and every phase that elapsed while away is
/// reconciled (and logged) from the timeline alone.
public struct PomodoroSession: Codable, Equatable, Sendable {
    public var config: PomodoroConfig
    public var startedAt: Date

    /// Current phase; `.done` once the timeline (or a stop) has run out.
    public var phase: PomodoroPhase
    /// Start of the current phase (nil when done).
    public var phaseStart: Date?
    /// End of the current phase — nil for the open-ended flowmodoro focus
    /// and for `.done`.
    public var phaseEnd: Date?

    /// Structured/classic: the absolute timeline, with `stepIndex` pointing
    /// at the current step (steps[stepIndex].end == phaseEnd while one is
    /// active). Flowmodoro keeps this empty.
    public var steps: [PomodoroStep]
    public var stepIndex: Int

    /// Non-nil while paused: the instant the freeze began. Every boundary
    /// slides by the paused span on resume.
    public var pausedAt: Date?
    /// Structured only: the absolute window end (shifts with pauses; display
    /// uses it, the math uses the step ends).
    public var windowEnd: Date?

    // Flowmodoro bookkeeping.
    /// Focus seconds banked toward the next break, EXCLUDING the live stint.
    public var flowBanked: TimeInterval
    /// When the current focus stint began (nil while resting/paused).
    public var flowStintStart: Date?
    public var flowBreaksClaimed: Int

    // MARK: Flowmodoro constants (the rule is the mode — not configurable)

    /// Focus seconds that earn one break minute.
    public static let flowUnitFocus: TimeInterval = 300
    /// Focus seconds before a break may be claimed at all.
    public static let flowClaimThreshold: TimeInterval = 180

    // MARK: Start

    public init(config: PomodoroConfig, start: Date, calendar: Calendar) {
        self.config = config
        self.startedAt = start
        self.phase = .prep
        self.phaseStart = start
        self.phaseEnd = start.addingTimeInterval(TimeInterval(config.prepSeconds))
        self.steps = []
        self.stepIndex = 0
        self.pausedAt = nil
        self.windowEnd = nil
        self.flowBanked = 0
        self.flowStintStart = nil
        self.flowBreaksClaimed = 0

        if config.mode == .flowmodoro {
            // Open-ended focus after prep — nothing to schedule.
            if config.prepSeconds <= 0 { startFlowFocus(at: start) }
            return
        }

        if config.prepSeconds <= 0 { phaseEnd = start }
        steps = Self.buildTimeline(config: config, start: start, calendar: calendar)
        windowEnd = config.mode == .structured
            ? config.structuredWindowEnd(after: start, calendar: calendar)
            : nil
        syncCurrentStep(fallbackNow: start)
    }

    /// The full structured/classic timeline: prep, then focus blocks with
    /// breaks interleaved. Structured ends exactly at the window end; classic
    /// runs purely off the configured lengths.
    public static func buildTimeline(config: PomodoroConfig, start: Date, calendar: Calendar) -> [PomodoroStep] {
        var steps: [PomodoroStep] = []
        var t = start
        if config.prepSeconds > 0 {
            t = start.addingTimeInterval(TimeInterval(config.prepSeconds))
            steps.append(PomodoroStep(phase: .prep, end: t))
        }
        switch config.mode {
        case .flowmodoro:
            return steps
        case .classic:
            for (i, minutes) in config.classicFocusMinutes.enumerated() {
                t = t.addingTimeInterval(TimeInterval(minutes * 60))
                steps.append(PomodoroStep(phase: .focus, end: t))
                if i < config.classicBreakMinutes.count {
                    t = t.addingTimeInterval(TimeInterval(config.classicBreakMinutes[i] * 60))
                    steps.append(PomodoroStep(phase: .rest, end: t))
                }
            }
        case .structured:
            guard let windowEnd = config.structuredWindowEnd(after: start, calendar: calendar),
                  let segment = config.structuredSegmentSeconds(window: windowEnd.timeIntervalSince(start))
            else { return steps } // invalid window — the editor blocks starting it
            for _ in 0..<config.structuredBreakCount {
                t = t.addingTimeInterval(TimeInterval(segment))
                steps.append(PomodoroStep(phase: .focus, end: t))
                t = t.addingTimeInterval(TimeInterval(config.structuredBreakSeconds))
                steps.append(PomodoroStep(phase: .rest, end: t))
            }
            steps.append(PomodoroStep(phase: .focus, end: windowEnd))
        }
        return steps
    }

    // MARK: Reading state

    public var isPaused: Bool { pausedAt != nil }
    public var isRunning: Bool { phase != .done }

    /// Decodes leniently: a state file written by an older build (missing
    /// newer fields) restores rather than wipes a running timer. Only a
    /// corrupt config/startedAt is fatal — without those the session is
    /// meaningless anyway.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decode(PomodoroConfig.self, forKey: .config)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        phase = try c.decodeIfPresent(PomodoroPhase.self, forKey: .phase) ?? .done
        phaseStart = try c.decodeIfPresent(Date.self, forKey: .phaseStart)
        phaseEnd = try c.decodeIfPresent(Date.self, forKey: .phaseEnd)
        steps = try c.decodeIfPresent([PomodoroStep].self, forKey: .steps) ?? []
        stepIndex = try c.decodeIfPresent(Int.self, forKey: .stepIndex) ?? 0
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        windowEnd = try c.decodeIfPresent(Date.self, forKey: .windowEnd)
        flowBanked = try c.decodeIfPresent(TimeInterval.self, forKey: .flowBanked) ?? 0
        flowStintStart = try c.decodeIfPresent(Date.self, forKey: .flowStintStart)
        flowBreaksClaimed = try c.decodeIfPresent(Int.self, forKey: .flowBreaksClaimed) ?? 0
    }

    /// The instant time is measured against: a paused session is frozen at
    /// the moment it paused, whatever the clock says now.
    private func anchor(_ now: Date) -> Date { pausedAt ?? now }

    /// Seconds left in the current phase at `now` — nil for the open-ended
    /// flowmodoro focus and when done. Countdowns round up.
    public func secondsRemaining(now: Date) -> TimeInterval? {
        guard let end = phaseEnd else { return nil }
        return max(0, end.timeIntervalSince(anchor(now)))
    }

    /// 0...1 fill for the ring. Fixed-length phases fill by elapsed share;
    /// the open-ended flowmodoro focus fills cyclically toward the next
    /// earned break minute (300 s per lap).
    public func phaseProgress(now: Date) -> Double {
        switch (phaseStart, phaseEnd) {
        case let (start?, end?):
            let total = end.timeIntervalSince(start)
            guard total > 0 else { return 1 }
            let elapsed = min(total, max(0, anchor(now).timeIntervalSince(start)))
            return elapsed / total
        case (_?, nil):
            let unit = Self.flowUnitFocus
            let accrued = flowAccruedFocus(now: now)
            guard unit > 0 else { return 0 }
            return accrued.truncatingRemainder(dividingBy: unit) / unit
        default:
            return 0
        }
    }

    /// Flowmodoro: focus seconds banked toward the next break, including the
    /// live stint (frozen while paused).
    public func flowAccruedFocus(now: Date) -> TimeInterval {
        var accrued = flowBanked
        if phase == .focus, let stint = flowStintStart {
            accrued += max(0, anchor(now).timeIntervalSince(stint))
        }
        return max(0, accrued)
    }

    /// Break seconds currently earned: 1 minute per 5 focus minutes.
    public func flowEarnedBreak(now: Date) -> TimeInterval {
        flowAccruedFocus(now: now) / (Self.flowUnitFocus / 60)
    }

    public func flowCanClaim(now: Date) -> Bool {
        config.mode == .flowmodoro && phase == .focus && pausedAt == nil
            && flowAccruedFocus(now: now) >= Self.flowClaimThreshold
    }

    // MARK: Transitions

    /// Completes every phase whose end has passed by `now` and lands in the
    /// step that contains it — one call reconciles both a normal tick and a
    /// relaunch after the app was gone for hours. Returns the completed
    /// phases in order (durations included) for logging.
    @discardableResult
    public mutating func advanceIfDue(now: Date) -> [PomodoroEvent] {
        guard pausedAt == nil, phase != .done else { return [] }

        if config.mode == .flowmodoro {
            guard let end = phaseEnd, now >= end else { return [] }
            switch phase {
            case .prep:
                let seconds = end.timeIntervalSince(phaseStart ?? end)
                startFlowFocus(at: end)
                return [PomodoroEvent(completedPhase: .prep, seconds: seconds)]
            case .rest:
                let seconds = end.timeIntervalSince(phaseStart ?? end)
                startFlowFocus(at: end)
                return [PomodoroEvent(completedPhase: .rest, seconds: seconds)]
            default:
                return [] // open-ended focus has no end to pass
            }
        }

        var events: [PomodoroEvent] = []
        while stepIndex < steps.count, let end = steps[stepIndex].end, now >= end {
            let start = stepIndex == 0 ? startedAt : (steps[stepIndex - 1].end ?? startedAt)
            events.append(PomodoroEvent(completedPhase: steps[stepIndex].phase, seconds: end.timeIntervalSince(start)))
            stepIndex += 1
        }
        syncCurrentStep(fallbackNow: now)
        return events
    }

    /// Points phase/phaseEnd at steps[stepIndex]; done when the timeline is
    /// exhausted. (Flowmodoro never has steps — untouched.)
    private mutating func syncCurrentStep(fallbackNow: Date) {
        guard stepIndex < steps.count else {
            phase = .done
            phaseStart = nil
            phaseEnd = nil
            return
        }
        phase = steps[stepIndex].phase
        phaseEnd = steps[stepIndex].end
        phaseStart = stepIndex == 0 ? startedAt : (steps[stepIndex - 1].end ?? fallbackNow)
    }

    /// Flowmodoro: turn accrued focus into a break now. The break lasts the
    /// whole pot (1 min per 5 focus min) and the accumulator resets — focus
    /// starts from zero after it.
    @discardableResult
    public mutating func claimBreak(now: Date) -> Bool {
        guard config.mode == .flowmodoro, phase == .focus, pausedAt == nil,
              flowAccruedFocus(now: now) >= Self.flowClaimThreshold else { return false }
        let rest = flowEarnedBreak(now: now)
        flowBanked = 0
        flowStintStart = nil
        flowBreaksClaimed += 1
        phase = .rest
        phaseStart = now
        phaseEnd = now.addingTimeInterval(rest)
        return true
    }

    /// End the current phase immediately.
    ///
    /// - structured: the window is absolute, so later boundaries stay put —
    ///   only the skipped phase ends early.
    /// - classic: the schedule slides — everything after the skipped phase
    ///   pulls forward by the reclaimed time.
    /// - flowmodoro: only a rest can be skipped (focus has no "next" without
    ///   a claim); focus resumes immediately.
    @discardableResult
    public mutating func skipPhase(now: Date) -> Bool {
        guard phase != .done, pausedAt == nil, now < (phaseEnd ?? .distantFuture) else { return false }
        switch config.mode {
        case .flowmodoro:
            guard phase == .rest else { return false }
            startFlowFocus(at: now)
            return true
        case .structured:
            guard stepIndex < steps.count else { return false }
            steps[stepIndex].end = now
            return true
        case .classic:
            guard stepIndex < steps.count, let end = steps[stepIndex].end else { return false }
            let delta = end.timeIntervalSince(now)
            steps[stepIndex].end = now
            if stepIndex + 1 < steps.count {
                for i in (stepIndex + 1)..<steps.count { steps[i].end?.addTimeInterval(-delta) }
            }
            return true
        }
    }

    /// Freeze the clock. Flow focus banks the live stint first so accrual
    /// stops exactly at the pause.
    @discardableResult
    public mutating func pause(now: Date) -> Bool {
        guard phase != .done, pausedAt == nil else { return false }
        if config.mode == .flowmodoro, phase == .focus, let stint = flowStintStart {
            flowBanked += max(0, now.timeIntervalSince(stint))
            flowStintStart = nil
        }
        pausedAt = now
        return true
    }

    /// Slide every pending boundary by the paused span and unfreeze.
    @discardableResult
    public mutating func resume(now: Date) -> Bool {
        guard let paused = pausedAt else { return false }
        let delta = max(0, now.timeIntervalSince(paused))
        pausedAt = nil
        guard delta > 0 else { return true }
        phaseEnd?.addTimeInterval(delta)
        windowEnd?.addTimeInterval(delta)
        for i in stepIndex..<steps.count { steps[i].end?.addTimeInterval(delta) }
        if config.mode == .flowmodoro, phase == .focus {
            flowStintStart = now
        }
        return true
    }

    /// End the timer now. The phase in flight is reported with its partial
    /// duration so the store can fold focus seconds into the day log before
    /// dropping the session.
    @discardableResult
    public mutating func stop(now: Date) -> PomodoroEvent? {
        guard phase != .done else { return nil }
        let stoppedPhase = phase
        var seconds: TimeInterval = 0
        if config.mode == .flowmodoro && phase == .focus {
            seconds = flowAccruedFocus(now: now)
        } else if let start = phaseStart {
            let end = min(phaseEnd ?? now, anchor(now))
            seconds = max(0, end.timeIntervalSince(start))
        }
        phase = .done
        phaseStart = nil
        phaseEnd = nil
        pausedAt = nil
        return PomodoroEvent(completedPhase: stoppedPhase, seconds: seconds)
    }

    private mutating func startFlowFocus(at date: Date) {
        phase = .focus
        phaseStart = date
        phaseEnd = nil
        flowStintStart = date
    }
}
