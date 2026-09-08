import Foundation

/// In-memory log ring buffer shown in the Logs tab — our only debugger on device.
final class LogStore: ObservableObject {
    static let shared = LogStore()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let date: String      // formatted at creation; persisted lines carry their own
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

    // A serial queue for ALL disk I/O — the engines log per chunk (~1-3 Hz
    // during playback) and the old per-line main-thread open/seek/write/close
    // was constant main-thread file churn. Batch lines, flush on a timer.
    private let ioQueue = DispatchQueue(label: "LogStore.io")
    private var buffer: [String] = []
    private var flushTimer: DispatchSourceTimer?
    private let flushInterval: TimeInterval = 1.0

    // MARK: Logging from any thread

    func info(_ message: String) { append("INFO", message) }
    func error(_ message: String) { append("ERROR", message) }

    private func append(_ level: String, _ message: String) {
        let dateStr = Self.formatter.string(from: Date())
        let entry = Entry(date: dateStr, level: level, message: message)
        let line = "\(dateStr) [\(level)] \(message)\n"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(line)
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        flushTimer = timer
    }

    // MARK: Persistence

    private func flush() {
        flushTimer = nil
        guard !buffer.isEmpty else { return }
        let lines = buffer
        buffer.removeAll()
        let data = Data(lines.joined().utf8)
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
        entries = lines.compactMap { line in
            let text = String(line)
            // Parse the persisted timestamp so loaded entries show the
            // LOGGED time, not the launch time (the old code used Date()
            // at struct creation and lost the original time).
            let level = text.contains("[ERROR]") ? "ERROR" : "INFO"
            // First 12 chars are "HH:mm:ss.SSS " — grab the timestamp.
            let dateStr = text.count >= 12 ? String(text.prefix(12)) : ""
            return Entry(date: dateStr, level: level, message: text)
        }
    }

    var exportText: String {
        entries
            .map { "\($0.date) [\($0.level)] \($0.message)" }
            .joined(separator: "\n")
    }
}

/// Global shorthand: `Log.shared.info("...")`
enum Log {
    static let shared = LogStore.shared
}
