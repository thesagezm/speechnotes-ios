import Foundation

/// In-memory log ring buffer shown in the Logs tab — our only debugger on device.
final class LogStore: ObservableObject {
    static let shared = LogStore()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let date = Date()
        let level: String
        let message: String
    }

    init() {
        loadPersistedTail()
    }
    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 500

    /// Entries kept in the persistent on-disk log before roll-over.
    private static let persistedTailLimit = 300
    /// Roll the file once it grows past this.
    private static let persistedSizeLimit = 2_000_000

    /// Survives crashes (unlike the in-memory buffer) — this file is how we
    /// diagnose hard kills like the long-note jetsam/crash.
    private lazy var logFileURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speechnotes.log")
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: Logging from any thread

    func info(_ message: String) { append("INFO", message) }
    func error(_ message: String) { append("ERROR", message) }

    private func append(_ level: String, _ message: String) {
        let entry = Entry(level: level, message: message)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            self.persist(entry)
        }
    }

    // MARK: Persistence

    /// Appends one formatted line to the on-disk log, rolling the file when
    /// it outgrows the cap. Called on the main thread only.
    private func persist(_ entry: Entry) {
        let line = "\(Self.formatter.string(from: entry.date)) [\(entry.level)] \(entry.message)\n"
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logFileURL)
        }
        rollIfNeeded()
    }

    private func rollIfNeeded() {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int,
            size > Self.persistedSizeLimit
        else { return }
        guard let raw = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let tail = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(Self.persistedTailLimit)
            .joined(separator: "\n")
        try? Data((tail + "\n").utf8).write(to: logFileURL, options: .atomic)
    }

    /// Loads the tail of the persistent log so the Logs tab (and exports)
    /// show what happened before a crash or relaunch.
    private func loadPersistedTail() {
        guard let raw = try? String(contentsOf: logFileURL, encoding: .utf8), !raw.isEmpty else { return }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(Self.persistedTailLimit)
        entries = lines.map { line in
            let text = String(line)
            let level = text.contains("[ERROR]") ? "ERROR" : "INFO"
            return Entry(level: level, message: text)
        }
    }

    var exportText: String {
        entries
            .map { "\(Self.formatter.string(from: $0.date)) [\($0.level)] \($0.message)" }
            .joined(separator: "\n")
    }
}

/// Global shorthand: `Log.shared.info("...")`
enum Log {
    static let shared = LogStore.shared
}
