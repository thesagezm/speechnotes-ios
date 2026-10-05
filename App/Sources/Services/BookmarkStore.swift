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

    /// The most recent bookmark of ANY kind saved within `maxAge` — the
    /// foreground-reconcile auto-resume candidate. Notes AND books now: a
    /// suspended background session loses its engines either way, and a
    /// book left mid-listen deserves the same "pick up where you were" a
    /// note gets. Returns the key so a stale entry (note deleted, book
    /// gone) can be dropped by the caller.
    func mostRecentBookmark(within maxAge: TimeInterval) -> (key: String, mark: SpeechPlayer.PlaybackBookmark)? {
        guard let key = recency.first(where: { bookmarks[$0] != nil }),
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
    private var lastPersist = Date.distantPast
    /// Serial: writes land in call order, so the last snapshot taken is the
    /// file's final state even when writes overlap.
    private let persistQueue = DispatchQueue(label: "BookmarkStore.persist")

    /// Throttle with a GUARANTEED trailing write (min interval 1 s). The old
    /// code was a re-arming 500 ms debounce: playback ticks fire every 0.3 s
    /// and each tick cancelled the pending write, so the file NEVER landed
    /// during continuous playback — exactly the jetsam-window loss the
    /// per-item store was supposed to prevent. Now: at most one write per
    /// second, and if writes keep coming a trailing one is always scheduled
    /// for the interval boundary instead of being deferred forever.
    private func schedulePersist() {
        let sinceLast = Date().timeIntervalSince(lastPersist)
        if sinceLast >= 1.0 {
            persistNow()
            return
        }
        guard persistTask == nil else { return } // trailing write already armed
        let wait = UInt64((1.0 - sinceLast) * 1_000_000_000)
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled else { return }
            self?.persistTask = nil
            self?.persistNow()
        }
    }

    /// Snapshot synchronously, write off-main. The encode captures the state
    /// AT THE CALL — that is the guarantee the scenePhase path relies on —
    /// and the file I/O runs on the serial persist queue. A few-KB write
    /// finishes inside the backgrounding grace window, and immediately while
    /// audio keeps the process alive. `lastPersist` is stamped before the
    /// write: a failing write must not turn the throttle into a hot loop.
    func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        lastPersist = Date()
        let snapshot: Data
        do {
            snapshot = try JSONEncoder().encode(bookmarks)
        } catch {
            Log.shared.error("BookmarkStore: encode failed: \(error)")
            return
        }
        let url = fileURL
        persistQueue.async {
            do {
                try snapshot.write(to: url, options: .atomic)
            } catch {
                // The queue closure must not capture the non-Sendable
                // LogStore — stringify here, log on the main actor.
                let message = "\(error)"
                Task { @MainActor in
                    Log.shared.error("BookmarkStore: persist failed: \(message)")
                }
            }
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
