import Foundation

/// Per-item playback bookmarks, persisted as Documents/bookmarks.json.
///
/// The old single-slot bookmark (one UserDefaults blob) meant starting book
/// B destroyed note A's resume position. Here every note (key
/// `note:<uuid>`) and every book chapter (key `book:<uuid>:<chapter>`) owns
/// its slot, capped at `maxEntries` most-recently-used.
@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var bookmarks: [String: SpeechPlayer.PlaybackBookmark] = [:]
    /// Keys touched this session, most recent first — drives LRU eviction.
    private var recency: [String] = []

    private static let maxEntries = 100
    private static let legacyKey = "playbackBookmark"

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bookmarks.json")
    }

    private init() {
        load()
        migrateLegacySlot()
    }

    static func noteKey(_ id: UUID) -> String { "note:\(id.uuidString)" }
    static func bookKey(_ id: String, chapter: Int) -> String { "book:\(id):\(chapter)" }

    func get(_ key: String) -> SpeechPlayer.PlaybackBookmark? {
        guard let mark = bookmarks[key] else { return nil }
        touch(key)
        return mark
    }

    func set(_ key: String, _ mark: SpeechPlayer.PlaybackBookmark) {
        bookmarks[key] = mark
        touch(key)
        schedulePersist()
    }

    func remove(_ key: String) {
        guard bookmarks[key] != nil else { return }
        bookmarks[key] = nil
        recency.removeAll { $0 == key }
        schedulePersist()
    }

    /// Marks the slot stale without dropping other items (a note's text
    /// changed, so its bookmark can no longer match).
    func removeAll(forNote id: UUID) {
        remove(Self.noteKey(id))
    }

    /// The most recent note-keyed bookmark if it was saved within `maxAge`
    /// seconds — the single auto-resume candidate for the app returning to
    /// the foreground. Book bookmarks are never candidates here (they resume
    /// from the reader's play button).
    func mostRecentNoteBookmark(within maxAge: TimeInterval) -> (key: String, mark: SpeechPlayer.PlaybackBookmark)? {
        guard let key = recency.first(where: { $0.hasPrefix("note:") }),
              let mark = bookmarks[key],
              mark.savedAt >= Date().addingTimeInterval(-maxAge) else { return nil }
        return (key, mark)
    }

    // MARK: - Private

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.insert(key, at: 0)
        while recency.count > Self.maxEntries {
            let evicted = recency.removeLast()
            bookmarks[evicted] = nil
        }
    }

    private var persistTask: Task<Void, Never>?

    /// Coalesces bursts (the bookmark timestamp updates on playback ticks
    /// through SpeechPlayer's throttled persist path).
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Synchronous write — also the scenePhase path via persistNow().
    func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        do {
            let data = try JSONEncoder().encode(bookmarks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.shared.error("BookmarkStore: persist failed: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            bookmarks = try JSONDecoder().decode([String: SpeechPlayer.PlaybackBookmark].self, from: try Data(contentsOf: fileURL))
            recency = bookmarks.keys.sorted { (bookmarks[$0]?.savedAt ?? .distantPast) > (bookmarks[$1]?.savedAt ?? .distantPast) }
        } catch {
            Log.shared.error("BookmarkStore: load failed: \(error)")
            let quarantine = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
        }
    }

    /// One-time migration of the pre-v1.5 single-slot bookmark.
    private func migrateLegacySlot() {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyKey) else { return }
        defer { UserDefaults.standard.removeObject(forKey: Self.legacyKey) }
        guard bookmarks.isEmpty,
              let mark = try? JSONDecoder().decode(SpeechPlayer.PlaybackBookmark.self, from: data) else { return }
        let key: String
        if let bookId = mark.bookId, let chapter = mark.chapterIndex {
            key = Self.bookKey(bookId, chapter: chapter)
        } else if let noteId = mark.noteId {
            key = Self.noteKey(noteId)
        } else {
            return
        }
        bookmarks[key] = mark
        touch(key)
        persistNow()
        Log.shared.info("BookmarkStore: migrated the legacy single-slot bookmark")
    }
}
