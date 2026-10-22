import Foundation

/// The chunk-token SCHEDULE — the dial between "speech starts fast" and
/// "speech does not run dry".
///
/// The problem it solves, in one paragraph: time-to-first-audio is the
/// first chunk's RENDER time, and time-to-second-audio is the second
/// chunk's. If the second chunk takes longer to render than the first
/// takes to PLAY, there is audible silence between the two (TTS_BASELINE
/// §2 — the "first sentence stall"). The break-even opener is
/// `batchMaxChars · RTF`, so no single fixed `firstMaxChars` serves both a
/// fast engine and a slow one — and a slow engine drifts as it thermally
/// throttles.
///
/// So there is no single right size: there is a schedule.
///
/// * The opener starts at the smallest rung.
/// * When a session's second buffer arrives LATE (the audible gap), the
///   next session climbs one rung.
/// * When a session's second buffer arrives ON TIME, the schedule resets to
///   the smallest rung — the fast opener is what the user feels, and it is
///   re-tried as soon as the engine proves it can cover it.
///
/// A rung is only ever abandoned after it has actually FAILED to cover the
/// second buffer, never speculatively.
public enum ChunkSchedule {

    /// The ladder of first-chunk sizes, in UTF-16 characters. Ascending:
    /// each rung is a bigger opener than the last.
    ///
    /// The unit is CHARACTERS of source text, not tokens — the same unit
    /// `SentenceChunker`'s `firstMaxChars`/`batchMaxChars` take. The
    /// engine's own token ceiling (Kokoro's 510) is enforced separately by
    /// the engine; the ladder never asks for more than the engine's own
    /// batch cap, because a bigger opener would just be split by the
    /// chunker — two renders, not one fast one.
    public static let sizes: [Int] = [100, 125, 150, 175, 200]

    /// The size the schedule starts at.
    public static let first: Int = 100

    /// The size the schedule gives up at and stays on. The largest rung is
    /// the engine's own batch ceiling for Kokoro, so a session that reaches
    /// the top rung runs "no fast-start at all" — the honest answer for an
    /// engine too slow to benefit from one.
    public static let largest: Int = 200

    /// The state of one session's schedule. The engine owns one of these
    /// per core instance: it hands the current rung to the chunker, and
    /// when a session ends it tells the schedule whether the second buffer
    /// was late. The NEXT session then uses whatever the schedule decided.
    ///
    /// Main-thread confined — `speak()` reads `currentSize`, the core
    /// calls `record`/`nextSize` from its own (main-thread) pipeline.
    public final class State {
        /// The rung the next session should use.
        public private(set) var size: Int

        /// Whether the most recently RECORDED session had a late second
        /// buffer. nil = no session recorded yet.
        public private(set) var lastWasLate: Bool?

        public init(size: Int = ChunkSchedule.first) {
            self.size = size
        }

        /// The current rung, clamped into the ladder.
        public var currentSize: Int {
            min(max(size, ChunkSchedule.first), ChunkSchedule.largest)
        }

        /// Records the outcome of one session.
        ///
        /// - Parameter secondBufferWasLate: true when the second buffer
        ///   arrived after the first one had already finished playing —
        ///   the audible gap. nil (never reported) is treated the same as
        ///   false: a session that taught us nothing is not a failure.
        public func record(secondBufferWasLate: Bool) {
            lastWasLate = secondBufferWasLate
            if secondBufferWasLate {
                size = climb(from: currentSize)
            } else {
                size = ChunkSchedule.first
            }
        }

        /// The rung to use: the size the last record() settled on.
        public func nextSize() -> Int { currentSize }

        /// The next rung UP from `current`, or `current` at the top of
        /// the ladder.
        private func climb(from current: Int) -> Int {
            for candidate in ChunkSchedule.sizes where candidate > current {
                return candidate
            }
            return current
        }

        /// A one-line summary for the device log.
        public var summary: String {
            "chunk-schedule rung \(currentSize) chars" +
            (lastWasLate == true ? " (last second buffer LATE)" : "")
        }
    }

    /// The rung for a given engine's batch ceiling, so a small-ceiling
    /// engine is never asked for a chunk it cannot take: the chunker's
    /// `batchMaxChars` is a HARD cap, and an opener above it would be split
    /// (defeating the point of a fast opener).
    public static func clamped(to batchCeiling: Int, from size: Int) -> Int {
        let floor = ChunkSchedule.first
        let ceiling = max(floor, min(largest, batchCeiling))
        return min(max(size, floor), ceiling)
    }
}
