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
/// How it works: a dedicated thread (never main) ticks at `interval` and
/// publishes a MainActor check each time. The check stamps the time it ran;
/// the next tick measures how long ago that stamp was. A gap larger than
/// `threshold` means the main actor did not run the check in time — the
/// thread was blocked. What it can then do is limited by definition (the
/// main thread is the only thing that can fix the UI), so this watchdog
/// does the three things that are actually safe and useful:
///
///   1. **Report** — one log line per incident, with the gap, so a device
///      log names the stall precisely instead of "froze".
///   2. **Shed work** — the shelf backfill is cancelled mid-flight (its
///      loop checks the token), which is the heaviest main-adjacent work in
///      the app and the one that was blocking it.
///   3. **Recover the surface** — nothing on main is touched, so no risk of
///      re-entering a wedged state; when the block lifts, the next tick
///      logs "cleared" and the shelf is refreshed once from scratch.
///
/// Deliberately NOT done: killing and relaunching the UI, or force-quitting
/// the process. Both are worse than the freeze — the user loses their
/// place and the app "crashes" from their side. The honest goal is that a
/// freeze now takes seconds to clear instead of a hard restart.
///
/// Threading: the ticker is a plain `Thread` subclassInstance; it must
/// never touch main state directly, only hop.
@MainActor
final class HangWatchdog {
    static let shared = HangWatchdog()

    /// Gap after which the main thread is declared blocked. Generous: PDF
    /// cover renders and shelf refreshes legitimately take ~1 s on device.
    private let threshold: TimeInterval = 4.0

    /// Main-actor stamp, updated by every check.
    private var lastCheckAt: ContinuousClock.Instant = .now
    private var blockedSince: ContinuousClock.Instant?
    private var worker: Thread?

    /// Set true while a main-thread block is being reported — cleared when
    /// the main actor runs again.
    private(set) var isBlocked: Bool = false

    /// Work the watchdog can cancel when it sees a block. The heavy,
    /// self-checking loops (BooksStore's backfill) register here.
    var onBlocked: (() -> Void)?

    private init() {}

    func start() {
        guard worker == nil else { return }
        let worker = MainThreadProbeThread(
            check: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastCheckAt = ContinuousClock.now
                    if self.isBlocked {
                        Log.shared.info("HangWatchdog: main thread responsive again after \(self.blockedDurationText())")
                        self.isBlocked = false
                        self.blockedSince = nil
                    }
                }
            },
            onBlocked: { [weak self] gap in
                Task { @MainActor in
                    guard let self, !self.isBlocked else { return }
                    self.isBlocked = true
                    self.blockedSince = ContinuousClock.now
                    Log.shared.error("HangWatchdog: main thread blocked ~\(String(format: "%.1f", gap))s — cancelling shelf work and reporting")
                    self.onBlocked?()
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

    private func blockedDurationText() -> String {
        guard let since = blockedSince else { return "?" }
        return String(format: "%.1fs", Self.seconds(from: since, to: ContinuousClock.now))
    }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let interval = a.duration(to: b)
        return Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// The worker: wakes every interval, hops to main with a check, and
/// measures the gap between the check running and the previous one. A gap
/// over the threshold is a blocked main thread.
private final class MainThreadProbeThread: Thread {
    /// Both are plain (non-isolated) closures that hop to main internally:
    /// a blocking main thread is precisely when the hop cannot run, so the
    /// worker must never call an isolated function synchronously.
    private let check: () -> Void
    private let onBlocked: (_ gapSeconds: Double) -> Void

    init(check: @escaping () -> Void, onBlocked: @escaping (_ gapSeconds: Double) -> Void) {
        self.check = check
        self.onBlocked = onBlocked
        super.init()
    }

    override func main() {
        var previousCheck: ContinuousClock.Instant? = nil
        while !isCancelled {
            let dispatchedAt = ContinuousClock.now
            check()
            // Sleep in small slices so cancellation is prompt — a blocked
            // main thread also blocks the run loop this thread would
            // otherwise wait on.
            var waited = 0.0
            while waited < 1.0, !isCancelled {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            if isCancelled { return }
            let now = ContinuousClock.now
            // Measure only the time from DISPATCHING the check to the next
            // dispatch — the worker's own sleep is not main-thread time, and
            // counting it reported every ordinary tick as a ~1 s block.
            //
            // The gap between `previousCheck` (when main actually RAN the
            // previous check) and `dispatchedAt` (when this one was queued) is
            // the real stall. Measuring around the sleep instead — the
            // original shape — is what produced the log's impossible
            // "main thread blocked ~4632.2s" lines: that figure is
            // wall-clock time between two ticks, so an app that was simply
            // suspended overnight (watchdog thread asleep with it) reported
            // the hours as one continuous block, and every 1 s tick looked
            // like a 1.4 s block. The stall the device report describes is
            // real, but these numbers were measuring something else entirely.
            if let previousCheck {
                let interval = previousCheck.duration(to: dispatchedAt)
                let gap = Double(interval.components.seconds)
                    + Double(interval.components.attoseconds) / 1_000_000_000_000_000_000
                // One tick of scheduler slack (1 s sleep + dispatch jitter)
                // is not a stall.
                if gap >= 2.5 {
                    self.onBlocked(gap)
                }
            }
            previousCheck = dispatchedAt
        }
    }
}
