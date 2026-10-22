import Foundation
import SpeechLogic

/// Holds all notes in memory and persists them as one JSON file in Documents.
/// Deleted notes are kept (flagged `deletedAt`) for Note.recycleRetentionDays
/// so the user can recover them from the Recently Deleted screen.
@MainActor
final class NotesStore: ObservableObject {
    /// Everything, including notes sitting in the recycle bin.
    @Published private(set) var allNotes: [Note] = []

    /// Active notes only — what the whole UI reads as `notes.notes`.
    var notes: [Note] { allNotes.filter { $0.deletedAt == nil } }

    /// Monotonic counter, bumped on every mutation of `allNotes`. Lets views
    /// memoize derived lists (filter + sort + section) against the store's
    /// identity WITHOUT re-deriving on unrelated publishes: a view observing
    /// `SpeechPlayer` (a root environment object) re-evaluates its body ~3×/s
    /// during playback, and the list used to re-filter + re-sort the whole
    /// library on every one of those invocations — the stutter users felt
    /// while listening. Keying on this version makes a player tick a no-op.
    private(set) var version: Int = 0

    private func bumpVersion() { version += 1 }

    /// Binned notes, most recently deleted first.
    var deletedNotes: [Note] {
        allNotes
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// True while the store holds notes it CANNOT read — an encrypted
    /// notes.json with no unlocked key. The list screens show the unlock
    /// prompt instead of an empty library (an empty library is a lie; the
    /// notes are there, just sealed).
    @Published private(set) var isLocked: Bool = false

    /// The shape of the last file image read/written. Lets the settings
    /// screen say what the file on disk actually is, without stat-ing it.
    @Published private(set) var fileIsSealed: Bool = false

    /// Cached per-note list-row metadata (derived title, ~120-char preview,
    /// word count, listen estimate). All of it is derived from `text` —
    /// recomputing it inline on every list re-render (including per
    /// progress-tick during speech) was measurable with long notes, and
    /// Note.title itself runs a sentence scan. Computed once per text
    /// change, invalidated by the mutations below.
    struct RowMetadata {
        let title: String
        let preview: String
        let wordCount: Int
        let listenMinutes: Int?
    }

    private var rowMetadata: [UUID: RowMetadata] = [:]
    /// Save counter for the rolling backup rotation.
    private var savesSinceBackup = 0

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("notes.json")
    }

    init() {
        load()
        pruneExpiredDeleted()
        Log.shared.info("NotesStore ready with \(notes.count) note(s), \(deletedNotes.count) in recycle bin")
    }

    @discardableResult
    func createNote(notebookId: UUID? = nil) -> Note {
        createNote(id: UUID(), notebookId: notebookId)
    }

    /// Fixed identity — the JEX import keeps exported UUIDs so a re-export
    /// of the same library maps cleanly; clashing ids are resolved by the
    /// CALLER before this runs (a fresh UUID is minted there).
    @discardableResult
    func createNote(id: UUID, notebookId: UUID? = nil) -> Note {
        var note = Note()
        note.id = id
        note.notebookId = notebookId
        allNotes.insert(note, at: 0)
        bumpVersion()  // list views memoize on `version`
        save()
        return note
    }

    /// Pin / favorite toggles (v1.4 organization).
    func setPinned(_ pinned: Bool, noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }) else { return }
        allNotes[index].isPinned = pinned
        bumpVersion()  // pin chips + section move need a fresh list
        rowMetadata.removeValue(forKey: noteId)
        save()
    }

    func setFavorite(_ favorite: Bool, noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }) else { return }
        allNotes[index].isFavorite = favorite
        rowMetadata.removeValue(forKey: noteId)
        save()
    }

    /// Files a note into a notebook (nil = Unfiled).
    func move(noteId: UUID, to notebookId: UUID?) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }) else { return }
        guard allNotes[index].notebookId != notebookId else { return }
        allNotes[index].notebookId = notebookId
        allNotes[index].updatedAt = Date()
        rowMetadata.removeValue(forKey: noteId)
        save()
    }

    /// After a notebook is deleted: its notes fall back to Unfiled.
    func clearNotebook(_ notebookId: UUID) {
        var changed = false
        for index in allNotes.indices where allNotes[index].notebookId == notebookId {
            allNotes[index].notebookId = nil
            changed = true
        }
        if changed { save() }
    }

    /// Active notes in a notebook scope (nil id = Unfiled).
    func notes(inNotebook notebookId: UUID?) -> [Note] {
        notes.filter { $0.notebookId == notebookId }
    }

    func update(_ note: Note) {
        guard let index = allNotes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.updatedAt = Date()
        allNotes[index] = updated
        bumpVersion()  // list views memoize on `version`
        rowMetadata.removeValue(forKey: note.id)
        scheduleSave()
    }

    /// Soft-deletes by identity — the editor's delete button and the list's
    /// swipe action both land here. The note moves to Recently Deleted.
    func delete(noteId: UUID) {
        softDelete(noteId: noteId)
        save()
    }

    private func softDelete(noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }) else { return }
        guard allNotes[index].deletedAt == nil else { return }
        allNotes[index].deletedAt = Date()
        // If that note is the one speaking, playback must not outlive it —
        // SpeechPlayer observes and stops.
        NotificationCenter.default.post(name: .noteDeleted, object: noteId)
    }

    /// Moves a binned note back into the active list, timestamps preserved.
    func recover(noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }),
              allNotes[index].deletedAt != nil else { return }
        allNotes[index].deletedAt = nil
        allNotes[index].updatedAt = Date()
        rowMetadata.removeValue(forKey: noteId)
        save()
    }

    /// Really deletes one binned note. No undo.
    func purge(noteId: UUID) {
        allNotes.removeAll { $0.id == noteId }
        bumpVersion()  // list views memoize on `version`
        rowMetadata.removeValue(forKey: noteId)
        // The bin's purge paths are where a note's images die: attached
        // images (per-note directory) AND the web images its markdown
        // downloaded, when no other note references them (round 5: the
        // editor's soft delete no longer removes anything — a note sitting
        // in the recycle bin keeps its images, so Recover restores it whole).
        NoteImageStore.removeAllImages(for: noteId)
        let id = noteId
        Task.detached(priority: .utility) {
            RemoteImageStore.removeImages(for: id)
        }
        NotificationCenter.default.post(name: .noteDeleted, object: noteId)
        save()
    }

    /// Really deletes every binned note. No undo.
    func emptyRecycleBin() {
        let purgedIds = allNotes.filter { $0.deletedAt != nil }.map(\.id)
        allNotes.removeAll { $0.deletedAt != nil }
        bumpVersion()  // list views memoize on `version`
        for id in purgedIds {
            rowMetadata.removeValue(forKey: id)
            NoteImageStore.removeAllImages(for: id)
            Task.detached(priority: .utility) {
                RemoteImageStore.removeImages(for: id)
            }
        }
        save()
    }

    /// Drops binned notes older than the retention window. Called once from
    /// init — good enough, no timer.
    private func pruneExpiredDeleted() {
        let cutoff = Date().addingTimeInterval(-Double(Note.recycleRetentionDays) * 24 * 3600)
        let before = allNotes.count
        let expired = allNotes.filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        for note in expired {
            rowMetadata.removeValue(forKey: note.id)
            NoteImageStore.removeAllImages(for: note.id)
            let id = note.id
            Task.detached(priority: .utility) {
                RemoteImageStore.removeImages(for: id)
            }
        }
        allNotes.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
        bumpVersion()  // list views memoize on `version`
        if allNotes.count != before { save() }
    }

    // MARK: - Row metadata cache

    /// First ~120 characters of the body (everything after the title line),
    /// whitespace-normalized. The scan is capped: rows re-render on every
    /// player publish, and whole-text walks were measurable with long notes.
    func metadata(for note: Note) -> RowMetadata {
        if let cached = rowMetadata[note.id] { return cached }
        let source = note.text.count > 800 ? String(note.text.prefix(800)) : note.text
        let body = source
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let meta = RowMetadata(
            title: note.title,
            preview: String(body.prefix(120)),
            wordCount: note.wordCount,
            listenMinutes: note.estimatedListenMinutes
        )
        rowMetadata[note.id] = meta
        return meta
    }

    // MARK: - Persistence

    private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Synchronous save for the moments a pending write must not be lost
    /// (scenePhase backgrounding, editor exit) — the process may be frozen
    /// right after this returns, so no detached task can be trusted with
    /// it. Every other save goes through the detached path in save().
    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            let sealed = try NotesFileSealer.seal(allNotes, key: EncryptionVault.shared.keyMaterial)
            fileIsSealed = sealed.isSealed
            try sealed.encoded.write(to: fileURL, options: .atomic)
        } catch {
            Log.shared.error("Failed to save notes (flush): \(error)")
        }
    }

    private func save() {
        // Encoding is the expensive part (tens of ms on a big library) —
        // run it detached, then hop back to the main actor for the write so
        // successive saves stay ORDERED (two detached writers could finish
        // out of order and persist an older snapshot last).
        //
        // The SEALING rides in the same detached block: with encryption on,
        // it is an AES-GCM pass over the whole library, and doing it here
        // would put it back on the main thread. The key material is a
        // value, so it crosses the boundary safely.
        let snapshot = allNotes
        let url = fileURL
        let backupURL = backupFileURL
        let key = EncryptionVault.shared.keyMaterial
        Task.detached(priority: .utility) {
            let sealed: JoplinNotesFile
            do {
                sealed = try NotesFileSealer.seal(snapshot, key: key)
            } catch {
                // Sealing failed (the vault locked between the edit and the
                // write, say). Fall back to plain rather than dropping the
                // edit: a lost note is worse than a momentarily-unencrypted
                // one, and the next successful save re-seals.
                Log.shared.error("Failed to seal notes for save: \(error) — writing plaintext")
                guard let plain = try? JSONEncoder().encode(snapshot) else {
                    Log.shared.error("Failed to encode notes for save")
                    return
                }
                sealed = JoplinNotesFile.plain(plain)
            }
            await MainActor.run {
                do {
                    try sealed.encoded.write(to: url, options: .atomic)
                    self.fileIsSealed = sealed.isSealed
                    self.savesSinceBackup += 1
                    if self.savesSinceBackup >= 10 {
                        self.savesSinceBackup = 0
                        try? sealed.encoded.write(to: backupURL, options: .atomic)
                    }
                } catch {
                    Log.shared.error("Failed to save notes: \(error)")
                }
            }
        }
    }

    /// Rolling backup refreshed every 10th save — the fallback load()
    /// recovers from when notes.json itself fails to decode.
    private var backupFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notes.backup.json")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Log.shared.error("Failed to read notes.json: \(error)")
            return
        }
        let file = JoplinNotesFile.read(data)
        fileIsSealed = file.isSealed
        let key = EncryptionVault.shared.keyMaterial
        guard case .sealed = file, key == nil else {
            // Plain file, or a sealed file we can open right now.
            do {
                allNotes = try NotesFileSealer.notes(from: file, key: key)
                isLocked = false
                bumpVersion()  // list views memoize on `version`
            } catch {
                Log.shared.error("Failed to load notes: \(error) — quarantining notes.json")
                quarantineAndRecover()
            }
            return
        }
        // Sealed file, no key: the library is intact but unreadable until
        // the passphrase arrives. Loading nothing here is correct — the
        // unlock path re-reads from disk.
        isLocked = true
        Log.shared.error("NotesStore: notes.json is encrypted and the vault is locked")
    }

    /// Re-reads the notes file after an unlock. Returns the note count that
    /// came back, or nil when the file could not be opened with the new key
    /// (wrong passphrase, corrupt file) — the caller then leaves the store
    /// empty rather than half-loaded.
    @discardableResult
    func reloadAfterUnlock() -> Int? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            isLocked = false
            return allNotes.count
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let file = JoplinNotesFile.read(data)
        do {
            let notes = try NotesFileSealer.notes(from: file, key: EncryptionVault.shared.keyMaterial)
            allNotes = notes
            isLocked = false
            fileIsSealed = file.isSealed
            bumpVersion()  // list views memoize on `version`
            rowMetadata.removeAll()
            pruneExpiredDeleted()
            Log.shared.info("NotesStore unlocked: \(notes.count) note(s)")
            return notes.count
        } catch {
            Log.shared.error("NotesStore unlock failed: \(error)")
            return nil
        }
    }

    /// Rewrites the whole file with the vault's CURRENT state: reads the
    /// notes on disk (with whatever key opens them), writes them back in
    /// the new shape. Used when encryption is turned on (plain → sealed)
    /// and when it is turned off (sealed → plain). Returns the note count
    /// now on disk.
    ///
    /// `forcePlain` is the turn-off path: the notes are written back
    /// unencrypted while the real key is still in memory. The caller
    /// deletes the key only after this returns — a failure here must leave
    /// the sealed file and its key untouched, never the other way round.
    @discardableResult
    func resealWithCurrentVault(forcePlain: Bool = false) throws -> Int {
        let file: JoplinNotesFile
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            file = JoplinNotesFile.read(data)
        } else {
            file = .plain(Data())
        }
        let notes: [Note]
        do {
            notes = try NotesFileSealer.notes(from: file, key: EncryptionVault.shared.keyMaterial)
        } catch {
            // The file we just read must not be stranded: if the current
            // vault cannot open it, leave it exactly as it is.
            Log.shared.error("resealWithCurrentVault: cannot read current file: \(error)")
            throw error
        }
        let written: JoplinNotesFile
        if forcePlain {
            written = try NotesFileSealer.seal(notes, key: nil)
        } else {
            written = try NotesFileSealer.seal(notes, key: EncryptionVault.shared.keyMaterial)
        }
        do {
            try written.encoded.write(to: fileURL, options: .atomic)
            fileIsSealed = written.isSealed
            allNotes = notes
            isLocked = false
            bumpVersion()  // list views memoize on `version`
            rowMetadata.removeAll()
            return notes.count
        } catch {
            Log.shared.error("resealWithCurrentVault: write failed: \(error)")
            throw error
        }
    }

    /// Wrong passphrase consequences, kept apart from a corrupt-file
    /// recovery path: a corrupt plaintext under a valid key means the
    /// quarantine is safe; a wrong key means leave the sealed file alone
    /// and wait for the right passphrase.
    private func quarantineAndRecover() {
        let file = JoplinNotesFile.read((try? Data(contentsOf: fileURL)) ?? Data())
        guard !file.isSealed else {
            // A sealed file that will not open is a key problem, not a
            // corruption problem — never quarantine an encrypted file.
            isLocked = true
            return
        }
        let quarantine = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: fileURL, to: quarantine)
        if let backup = try? Data(contentsOf: backupFileURL),
           let recovered = try? JSONDecoder().decode([Note].self, from: backup),
           !recovered.isEmpty {
            allNotes = recovered
            bumpVersion()  // list views memoize on `version`
            Log.shared.error("NotesStore: recovered \(recovered.count) note(s) from notes.backup.json")
        }
    }
}

extension Notification.Name {
    /// Posted when a note is soft-deleted or purged (object = note UUID).
    /// SpeechPlayer stops playback if the deleted note is the live one.
    static let noteDeleted = Notification.Name("NotesStore.noteDeleted")

    /// Posted by the HangWatchdog when it sees the main thread blocked.
    /// The shelf backfill listens: a blocked main thread plus a heavy
    /// background pass is the freeze, so the pass is cancelled instead of
    /// continuing to compete for I/O. See HangWatchdog for the full story.
    static let hangWatchdogFired = Notification.Name("HangWatchdog.fired")
}
