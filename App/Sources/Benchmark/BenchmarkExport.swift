import Foundation
import SpeechLogic

/// Writes the benchmark's two artifacts into Documents/Exports/Benchmarks/:
/// a per-chunk CSV and a metadata+summary JSON. Both carry the full
/// provenance block, so a file shared out of the app six months later is
/// still attributable to a device, a build, a corpus and a config.
enum BenchmarkExport {
    static let csvHeader = [
        "chunk", "loop", "wall_s", "chars", "tokens", "steps",
        "gen_s", "audio_s", "rtf", "footprint_mb", "available_mb", "cpu_pct", "thermal",
    ]

    static func write(rows: [BenchmarkSession.ChunkRow], summary: BenchmarkSession.Summary) throws
        -> BenchmarkSession.ExportResult
    {
        let directory = documentsBenchmarkDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Self.fileStamp()
        let csvURL = directory.appendingPathComponent("bench-\(stamp)-\(summary.engineTier).csv")
        let jsonURL = directory.appendingPathComponent("bench-\(stamp)-\(summary.engineTier).json")

        let csv = try csvText(rows: rows, summary: summary)
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let json = try jsonText(rows: rows, summary: summary)
        try json.write(to: jsonURL, atomically: true, encoding: .utf8)

        return BenchmarkSession.ExportResult(csvURL: csvURL, jsonURL: jsonURL, summary: summary)
    }

    static func documentsBenchmarkDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Exports/Benchmarks", isDirectory: true)
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    // MARK: - CSV

    static func csvText(rows: [BenchmarkSession.ChunkRow], summary: BenchmarkSession.Summary) throws -> String {
        var lines: [String] = []
        lines.append(BenchmarkMath.csvRow(["# bench csv v1"]))
        lines.append(BenchmarkMath.csvRow([
            "# app", summary.appVersion, summary.appBuild,
            "device", summary.deviceModel, "ios", summary.osVersion,
            "ort", summary.ortVersion,
            "engine", summary.engineTier,
            "threads", summary.intraOpThreads.map(String.init) ?? "default",
            "corpus", summary.corpusId, summary.corpusSha256,
        ]))
        lines.append(BenchmarkMath.csvRow(csvHeader))
        for row in rows {
            lines.append(BenchmarkMath.csvRow([
                String(row.chunk),
                String(row.loop),
                String(format: "%.3f", row.wallSeconds),
                String(row.chars),
                row.tokenCount.map(String.init) ?? "",
                row.steps.map(String.init) ?? "",
                String(format: "%.3f", row.genSeconds),
                String(format: "%.3f", row.audioSeconds),
                String(format: "%.4f", row.rtf),
                row.footprintMB.map { String(format: "%.1f", $0) } ?? "",
                row.availableMB.map { String(format: "%.1f", $0) } ?? "",
                row.cpuPercent.map { String(format: "%.1f", $0) } ?? "",
                row.thermal,
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    struct JSONDocument: Codable {
        let summary: BenchmarkSession.Summary
        let rows: [BenchmarkSession.ChunkRow]
    }

    static func jsonText(rows: [BenchmarkSession.ChunkRow], summary: BenchmarkSession.Summary) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(JSONDocument(summary: summary, rows: rows))
        return String(decoding: data, as: UTF8.self)
    }
}
