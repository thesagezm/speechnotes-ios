import Foundation
import CryptoKit
import SpeechLogic

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

    // MARK: - Note index (which note references which cached image)
    //
    // The cache is keyed by URL hash — it says nothing about ownership. The
    // index (index.json, note UUID → URL strings) is what lets Storage delete
    // ONE note's cached images, and what lets the recycle bin's purge take
    // a note's web images with it (user request: images a note downloaded
    // should not outlive the note in the bin). URLs still referenced by
    // another note are kept.

    private static let lock = NSLock()

    private static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    private static func loadIndex() -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: indexURL),
              let raw = try? JSONDecoder().decode([String: Set<String>].self, from: data) else { return [:] }
        return raw
    }

    private static func saveIndex(_ index: [String: Set<String>]) {
        try? fmCreateDirectory()
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static func fmCreateDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Records that `noteId`'s markdown references `urls`. Called from the
    /// preview's cache refresh (off-main). Merge semantics; writes only on
    /// change.
    static func record(urls: [URL], noteId: UUID) {
        guard !urls.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var index = loadIndex()
        let key = noteId.uuidString
        let set = Set(urls.map(\.absoluteString))
        if (index[key] ?? []).isSuperset(of: set) { return }
        index[key, default: []].formUnion(set)
        saveIndex(index)
    }

    /// Notes with recorded images → their URL strings. Stale entries (notes
    /// already purged before the index existed) are filtered by the caller.
    static func indexedNotes() -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return loadIndex()
    }

    /// Deletes every cached web image ONLY this note references, drops the
    /// note's index entry, and returns the bytes freed. Shared URLs (another
    /// note references them too) survive, as does their index record.
    @discardableResult
    static func removeImages(for noteId: UUID) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var index = loadIndex()
        guard let strings = index.removeValue(forKey: noteId.uuidString) else { return 0 }
        var referencedElsewhere: Set<String> = []
        for (_, urls) in index { referencedElsewhere.formUnion(urls) }
        var freed: Int64 = 0
        for string in strings where !referencedElsewhere.contains(string) {
            guard let url = URL(string: string) else { continue }
            let file = fileURL(for: url)
            let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            freed += bytes
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: sidecarURL(for: file))
        }
        saveIndex(index)
        return freed
    }

    /// Every remote (web) image URL a markdown body references — the same
    /// extraction the preview uses, so the index and the prefetch see exactly
    /// what will render. Local `speechnotes://` targets are excluded.
    static func remoteImageURLs(in markdown: String) -> [URL] {
        var out: [URL] = []
        func collect(_ target: String) {
            guard NoteImageStore.parseLocalTarget(target) == nil,
                  let url = URL(string: target),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            out.append(url)
        }
        for block in MarkdownText.blocks(markdown) {
            switch block {
            case .image(_, let url):
                collect(url)
            case .paragraph(let text):
                for run in MarkdownText.inlineRuns(text) {
                    if case .image(_, let url) = run { collect(url) }
                }
            default: break
            }
        }
        return out
    }

    /// Downloads and stores `urls` without decoding (the Automatic caching
    /// mode's open-a-note prefetch). Already-cached URLs are skipped.
    static func prefetch(_ urls: [URL]) {
        for url in urls {
            guard loadData(for: url) == nil else { continue }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            var fetched: Data?
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: url) { d, _, _ in
                fetched = d
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 15)
            task.cancel()
            if let d = fetched, !d.isEmpty {
                store(d, for: url)
            }
        }
    }
}
