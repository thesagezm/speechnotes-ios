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

    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 500

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
