import Foundation
import CryptoKit

/// Disk-backed cache for images the markdown preview downloads from the
/// internet (`https://…` targets typed or pasted into note bodies).
///
/// Until now those bytes lived only in the in-memory NSCache and vanished on
/// relaunch; this store persists them under `Caches/remote-images/` so the
/// Storage tab can enumerate them as a browsable gallery and the preview can
/// re-render without a re-fetch. A `<hash>.url` sidecar keeps the source URL
/// (the filename is a hash of it, which can't be reversed).
///
/// Lives in Caches/, so iOS may purge it under disk pressure — a purged image
/// simply re-downloads the next time its note renders. Static-function style
/// mirrors NoteImageStore.
enum RemoteImageStore {
    struct Entry: Identifiable {
        /// Source URL (recovered from the sidecar; falls back to the file path).
        let url: URL
        /// Cached bytes on disk.
        let fileURL: URL
        let bytes: Int64
        var id: String { url.absoluteString }
    }

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-images", isDirectory: true)
    }

    // MARK: - Paths

    /// Deterministic cache path for a remote URL: `<sha256(url)>.<ext>`.
    static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).\(sanitisedExtension(from: url))")
    }

    private static func sanitisedExtension(from url: URL) -> String {
        let raw = url.pathExtension.lowercased()
        let allowed: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"]
        return allowed.contains(raw) ? raw : "img"
    }

    private static func sidecarURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("url")
    }

    // MARK: - Read / write

    /// Cached bytes for a remote URL, or nil when not cached yet.
    static func loadData(for url: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    /// Persists downloaded bytes (and the source-URL sidecar) for next launch.
    static func store(_ data: Data, for url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = fileURL(for: url)
        try? data.write(to: target, options: .atomic)
        try? Data(url.absoluteString.utf8).write(to: sidecarURL(for: target), options: .atomic)
    }

    // MARK: - Enumeration (Storage gallery)

    /// Every cached remote image: source URL, disk path, size. Image bytes
    /// only — `.url` sidecars are excluded from counts and footprints.
    static func allEntries() -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }
        return files.compactMap { file -> Entry? in
            guard file.pathExtension.lowercased() != "url" else { return nil }
            let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let source = (try? String(contentsOf: sidecarURL(for: file), encoding: .utf8))
                .flatMap(URL.init(string:))
            return Entry(url: source ?? file, fileURL: file, bytes: bytes)
        }
        .sorted { $0.url.absoluteString < $1.url.absoluteString }
    }

    static func totalFootprint() -> Int64 {
        allEntries().reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Deletion

    static func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
        try? FileManager.default.removeItem(at: sidecarURL(for: entry.fileURL))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
