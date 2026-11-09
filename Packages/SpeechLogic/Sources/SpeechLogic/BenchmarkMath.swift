import Foundation

/// Pure math for the in-app TTS benchmark harness (Phase 3 of the hybrid
/// CPU+ANE plan — see Docs/PHASE3-BENCHMARK-HARNESS.md). Lives here per the
/// repo's golden rule: pure logic in SpeechLogic with tests; the App target
/// keeps only the sampler/orchestrator around it.

/// One `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` reading, aggregated
/// across all cores. Ticks are arbitrary Mach units — only DIFFERENCES
/// between two snapshots mean anything.
public struct CPULoadSnapshot: Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public static let zero = CPULoadSnapshot(user: 0, system: 0, idle: 0, nice: 0)

    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }
}

public enum BenchmarkMath {
    /// Busy-CPU percentage between two snapshots, 0…100. `nil` when the
    /// window carries no ticks at all (first sample, or a suspended process
    /// that saw no scheduling) — callers must not record a fabricated 0 %.
    public static func cpuBusyPercent(
        previous: CPULoadSnapshot,
        current: CPULoadSnapshot
    ) -> Double? {
        let busy = current.busy >= previous.busy ? current.busy - previous.busy : 0
        let total = current.total >= previous.total ? current.total - previous.total : 0
        guard total > 0 else { return nil }
        return (Double(busy) / Double(total)) * 100.0
    }

    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Median with the even-count convention: mean of the two middle values.
    public static func median(_ values: [Double]) -> Double? {
        percentile(values, 0.5)
    }

    /// Linear-interpolated percentile, 0…1. Empty input → nil.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let clamped = min(max(p, 0), 1)
        let rank = clamped * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = rank - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// One CSV record from raw fields: commas between, each field escaped.
    /// No trailing newline — the writer joins records with "\n" itself.
    public static func csvRow(_ fields: [String]) -> String {
        fields.map(csvEscaped).joined(separator: ",")
    }

    /// RFC-4180 escaping: quote only when the field contains a comma, quote,
    /// CR or LF; double any embedded quote.
    public static func csvEscaped(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
