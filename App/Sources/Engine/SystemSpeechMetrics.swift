import Foundation

/// Apple system speech's chunk-boundary measurement — the Batch A2 slice.
///
/// `PlaybackMetrics` exists and is excellent, and it measures a machine this
/// engine does not have: per-chunk generation stamps around a producer loop,
/// a render-ahead bank, a player node, an RTF figure. `SystemEngine` hands an
/// utterance to `AVSpeechSynthesizer` and waits. Borrowing the ONNX metrics
/// here would mean inventing fields for measurements that cannot be taken.
///
/// So this measures the one thing the Apple path makes hard to see and the
/// other engines report for free: **the silence between `didFinish` on one
/// chunk and the first audio of the next.** That is the number Batch F's
/// decision rests on. Everything else here is that figure's context — a
/// boundary count and a session summary in the same log shape as the neural
/// engines', so one `metrics` filter covers every engine in a device log.
///
/// The instrumentation is deliberately three `ContinuousClock` stamps and a
/// dispatch hop the delegate callbacks were already making. It records; it
/// never gates, reorders or delays speech.
final class SystemSpeechMetrics {

    // MARK: - Session state (main thread only — every call site is)

    private var sessionActive = false
    private var sessionStart: ContinuousClock.Instant?
    private var chunkCount = 0
    private var boundaries = 0
    private var worstBoundary: Double = 0
    private var totalBoundary: Double = 0
    private var loggedBoundaries = 0

    /// A boundary wide enough to be worth its own log line. Matches the
    /// neural engines' GAP escalation threshold (`PlaybackMetrics.gapIsError`)
    /// so the same number reads as "interesting" across all three engines.
    private static let noticeThreshold: Double = 0.5

    /// How many boundaries between lines. At ~1 chunk/second a chapter is
    /// hundreds of boundaries; one line per 50 keeps the summary useful
    /// without evicting TTFA from the 500-entry ring (TTS_BASELINE §6).
    private static let boundaryLogInterval = 50

    // MARK: - Lifecycle

    /// Called from `speak(_:)`, after the chunker has run so `chunkCount` is
    /// real. Closes any session a second play tap left open — same contract
    /// as `PlaybackMetrics.beginSession`.
    func beginSession(chunkCount: Int, rate: Double) {
        if sessionActive { endSession(reason: "superseded") }
        sessionActive = true
        self.chunkCount = chunkCount
        boundaries = 0
        worstBoundary = 0
        totalBoundary = 0
        loggedBoundaries = 0
        sessionStart = ContinuousClock.now
        emit("session start — \(chunkCount) chunks, rate@start \(String(format: "%.2f", rate))")
    }

    /// One summary line, then the engine goes quiet. `reason` separates a
    /// natural finish from a user stop, and the summary is where the boundary
    /// figure is quotable without grepping the per-50 lines.
    func endSession(reason: String) {
        guard sessionActive, let start = sessionStart else { return }
        sessionActive = false
        let mean = boundaries > 0 ? totalBoundary / Double(boundaries) : 0
        let wall = seconds(from: start, to: ContinuousClock.now)
        emit("session \(reason) — \(chunkCount) chunks, boundaries \(boundaries)"
            + " (mean \(String(format: "%.3f", mean))s, worst \(String(format: "%.3f", worstBoundary))s),"
            + " wall \(String(format: "%.2f", wall))s")
    }

    // MARK: - Boundaries

    /// One inter-chunk boundary: from the previous chunk's `didFinish` (the
    /// stamp taken there, passed here) to this chunk's first audio.
    func recordBoundary(startedAt: ContinuousClock.Instant) {
        guard sessionActive else { return }
        let seconds = seconds(from: startedAt, to: ContinuousClock.now)

        boundaries += 1
        totalBoundary += seconds
        if seconds > worstBoundary { worstBoundary = seconds }

        if seconds >= Self.noticeThreshold {
            emit("GAP \(String(format: "%.3f", seconds))s of silence — between chunk \(boundaries)"
                + " and \(boundaries + 1)", isError: true)
        } else if boundaries - loggedBoundaries >= Self.boundaryLogInterval {
            loggedBoundaries = boundaries
            emit("boundaries \(boundaries)/\(chunkCount) — mean \(String(format: "%.3f", mean))s,"
                + " worst \(String(format: "%.3f", worstBoundary))s")
        }
    }

    // MARK: - Helpers

    private var mean: Double {
        boundaries > 0 ? totalBoundary / Double(boundaries) : 0
    }

    /// `ContinuousClock.Instant.duration(to:)` gives a `Duration`; the
    /// components form is the same conversion `PlaybackMetrics` uses, so both
    /// engines' figures come out on one scale.
    private func seconds(from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> Double {
        let interval = from.duration(to: to)
        return Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1_000_000_000_000_000_000
    }

    // MARK: - Log

    /// Every line carries the `metrics` tag the device protocol filters on,
    /// and the prefix the neural engines' lines carry — so a log grepped for
    /// one string covers all engines.
    ///
    /// `isError` is currently unused and that is a decision, not an
    /// oversight: Batch A2 measures and records. Whether a wide boundary
    /// should be an ERROR line is a question for Batch F, which is the batch
    /// that fixes it — an error line written before there is a fix is a log
    /// that cries wolf. The parameter is kept so the escalation is one call
    /// away when it is earned.
    private func emit(_ message: String, isError: Bool = false) {
        Log.shared.info("SystemEngine metrics \(message)")
    }
}
