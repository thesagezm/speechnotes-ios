import Foundation

/// One background watchdog that notices when the MAIN THREAD is blocked and
/// turns a hard freeze into a controlled one.
///
/// Why this exists: the device reports showed a "terminal" freeze — open an
/// audiobook, open a big PDF, and the app stopped responding until it was
/// hard-restarted. The blocking work was found and removed (bounded shelf
/// backfill, bounded audiobook parse), but the failure mode was made worse
/// by the app having no way to notice it was stuck: a blocked main thread
/// keeps the UI frozen, the watchdog timers that would have reported the
/// stall are themselves on that same thread, so nothing observes the hang
/// and nothing recovers.
///
/// How it works: a dedicated thread (never main) dispatches a check onto the
/// main actor every second. Each check measures the gap since the PREVIOUS
/// check actually ran on main — that gap is the real stall, measured exactly
/// where the truth is (a check that ran on main cannot have waited through
/// the block, and one that waited long did). A gap over `threshold` is one
/// incident:
///
///   1. **Report** — one log line naming the gap, so a device log says
///      "main thread blocked ~12.4s" instead of "froze".
///   2. **Shed work** — `onBlocked` fires (the shelf backfill, the heaviest
///      main-adjacent work in the app, listens and cancels; it retries on
///      the next shelf open).
///   3. **Clear** — the next check ~1 s later sees a normal gap and logs
///      that the thread is responsive again.
///
/// Suspension is NOT a stall. While the app is backgrounded the whole
/// process — probe thread included — is frozen; the first check after
/// resume then measures the entire backgrounded wall-clock as one gap.
/// That is exactly what the device log's impossible "~4632s / ~4716s
/// blocked" lines were: two long suspensions, not two freezes — and every
/// one of them fired `onBlocked`, cancelling the shelf backfill each time
/// ("repeated shelf-backfill cancels"). So the app arms the watchdog only
/// while foregrounded (`setActive` from the scene-phase handler) and every
/// re-arm stamps a fresh baseline, which keeps a suspension out of every
/// measurement by construction.
///
/// Deliberately NOT done: killing and relaunching the UI, or force-quitting
/// the process. Both are worse than the freeze — the user loses their
/// place and the app "crashes" from their side. The honest goal is that a
/// freeze now takes seconds to clear instead of a hard restart.
///
/// Threading: the ticker is a plain `Thread` subclass; it must never touch
/// main state directly, only hop. All bookkeeping (gap math, incident
/// flags) lives on the main actor inside the dispatched check.
@MainActor
final class HangWatchdog {
    static let shared = HangWatchdog()

    /// Gap after which the main thread is declared blocked. Generous: PDF
    /// cover renders and shelf refreshes legitimately take ~1 s on device.
    private let threshold: TimeInterval = 4.0

    /// When the previous check RAN on main — the measurement anchor.
    private var lastCheckAt: ContinuousClock.Instant = .now
    private var isBlocked = false
    private var worker: Thread?

    /// Work the watchdog can cancel when it sees a block. The heavy,
    /// self-checking loops (BooksStore's backfill) register here.
    var onBlocked: (() -> Void)?

    private init() {}

    func start() {
        guard worker == nil else { return }
        // Fresh baseline on every (re)arm: the gap across the foreground
        // pause must never enter a measurement.
        lastCheckAt = .now
        isBlocked = false
        let worker = MainThreadProbeThread(check: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let now = ContinuousClock.now
                let gap = Self.seconds(from: self.lastCheckAt, to: now)
                self.lastCheckAt = now
                if gap >= self.threshold {
                    guard !self.isBlocked else { return }
                    self.isBlocked = true
                    Log.shared.error("HangWatchdog: main thread blocked ~\(String(format: "%.1f", gap))s — cancelling shelf work and reporting")
                    self.onBlocked?()
                } else if self.isBlocked {
                    self.isBlocked = false
                    Log.shared.info("HangWatchdog: main thread responsive again")
                }
            }
        })
        worker.name = "com.speechnotes.hang-watchdog"
        worker.start()
        self.worker = worker
        Log.shared.info("HangWatchdog: armed (\(Int(threshold))s threshold)")
    }

    func stop() {
        worker?.cancel()
        worker = nil
    }

    /// Scene-phase hook: foregrounded arms the probe (with a fresh
    /// baseline), backgrounded disarms it — a suspended process cannot
    /// observe anything, and measuring across the suspension is precisely
    /// the bug that logged hours-long "blocks" and cancelled the shelf
    /// backfill on every resume.
    func setActive(_ active: Bool) {
        if active { start() } else { stop() }
    }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let interval = a.duration(to: b)
        return Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// The worker: wakes every second and dispatches a check onto the main
/// actor. It measures nothing — the check itself measures, on main, the gap
/// to the previous check that ran there. (Earlier drafts measured on this
/// thread, either around the sleep — reporting every ordinary tick as a
/// ~1.4 s block — or dispatch-to-dispatch, which stays ~1 s even while main
/// is wedged and so could never detect a real stall.)
private final class MainThreadProbeThread: Thread {
    /// A plain (non-isolated) closure that hops to main internally: a
    /// blocking main thread is precisely when the hop cannot run, so the
    /// worker must never call an isolated function synchronously.
    private let check: () -> Void

    init(check: @escaping () -> Void) {
        self.check = check
        super.init()
    }

    override func main() {
        while !isCancelled {
            check()
            // Sleep in small slices so cancellation is prompt.
            var waited = 0.0
            while waited < 1.0, !isCancelled {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
        }
    }
}
