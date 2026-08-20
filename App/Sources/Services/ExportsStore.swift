import Foundation
import AVFoundation

struct ExportedAudio: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let sizeBytes: Int64
    let createdAt: Date
    var duration: TimeInterval?

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Scans Documents/Exports (written by the engines' renderWAV) and provides
/// delete/clear + storage-size helpers for the Storage tab.
@MainActor
final class ExportsStore: ObservableObject {
    @Published private(set) var exports: [ExportedAudio] = []

    static var exportsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports")
    }

    init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.exportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        var items: [ExportedAudio] = []
        for url in files where url.pathExtension.lowercased() == "wav" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            items.append(ExportedAudio(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                sizeBytes: Int64(values?.fileSize ?? 0),
                createdAt: values?.contentModificationDate ?? .distantPast,
                duration: nil
            ))
        }
        exports = items.sorted { $0.createdAt > $1.createdAt }
        loadDurations()
    }

    /// Opening each file for its duration is cheap but not free — off-main,
    /// patch back in.
    private func loadDurations() {
        let snapshot = exports
        Task.detached(priority: .utility) { [weak self] in
            var durations: [URL: TimeInterval] = [:]
            for item in snapshot {
                if let player = try? AVAudioPlayer(contentsOf: item.url) {
                    durations[item.url] = player.duration
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.exports = self.exports.map {
                    var copy = $0
                    copy.duration = durations[$0.url]
                    return copy
                }
            }
        }
    }

    func delete(_ item: ExportedAudio) {
        try? FileManager.default.removeItem(at: item.url)
        exports.removeAll { $0.url == item.url }
    }

    /// Returns bytes freed (for the log).
    @discardableResult
    func deleteAll() -> Int64 {
        let freed = totalBytes
        try? FileManager.default.removeItem(at: Self.exportsDirectory)
        exports = []
        return freed
    }

    var totalBytes: Int64 {
        exports.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Storage helpers (shared with Settings → Storage)

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Removes *.part / *.resumeData / *.resumeSource leftovers anywhere
    /// under Documents plus tmp contents. Returns bytes freed.
    nonisolated static func clearTemporaryFiles() -> Int64 {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var targets: [URL] = []
        if let dirs = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for dir in dirs {
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                targets += files.filter {
                    ["part", "resumeData", "resumeSource"].contains($0.pathExtension)
                }
            }
        }
        let tmp = fm.temporaryDirectory
        if let files = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            targets += files.map { tmp.appendingPathComponent($0.lastPathComponent) }
        }
        var freed: Int64 = 0
        for url in targets {
            freed += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? fm.removeItem(at: url)
        }
        return freed
    }
}
