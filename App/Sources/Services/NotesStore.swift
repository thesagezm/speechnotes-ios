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

    /// Binned notes, most recently deleted first.
    var deletedNotes: [Note] {
        allNotes
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

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
        var note = Note()
        note.notebookId = notebookId
        allNotes.insert(note, at: 0)
        save()
        return note
    }

    /// Pin / favorite toggles (v1.4 organization).
    func setPinned(_ pinned: Bool, noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }) else { return }
        allNotes[index].isPinned = pinned
        save()
    }

    func setFavorite(_ favorite: Bool, noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }) else { return }
        allNotes[index].isFavorite = favorite
        save()
    }

    /// Files a note into a notebook (nil = Unfiled).
    func move(noteId: UUID, to notebookId: UUID?) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }) else { return }
        guard allNotes[index].notebookId != notebookId else { return }
        allNotes[index].notebookId = notebookId
        allNotes[index].updatedAt = Date()
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
        rowMetadata.removeValue(forKey: noteId)
        // The editor path cleans images at delete-confirm time; the bin's
        // purge paths are the only other exits — clean here too or the
        // per-note image directory leaks forever.
        NoteImageStore.removeAllImages(for: noteId)
        NotificationCenter.default.post(name: .noteDeleted, object: noteId)
        save()
    }

    /// Really deletes every binned note. No undo.
    func emptyRecycleBin() {
        let purgedIds = allNotes.filter { $0.deletedAt != nil }.map(\.id)
        allNotes.removeAll { $0.deletedAt != nil }
        for id in purgedIds {
            rowMetadata.removeValue(forKey: id)
            NoteImageStore.removeAllImages(for: id)
        }
        save()
    }

    /// Drops binned notes older than the retention window. Called once from
    /// init — good enough, no timer.
    private func pruneExpiredDeleted() {
        let cutoff = Date().addingTimeInterval(-Double(Note.recycleRetentionDays) * 24 * 3600)
        let before = allNotes.count
        let expired = allNotes.filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        for note in expired { rowMetadata.removeValue(forKey: note.id) }
        allNotes.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
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
            let data = try JSONEncoder().encode(allNotes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.shared.error("Failed to save notes (flush): \(error)")
        }
    }

    private func save() {
        // Encoding is the expensive part (tens of ms on a big library) —
        // run it detached, then hop back to the main actor for the write so
        // successive saves stay ORDERED (two detached writers could finish
        // out of order and persist an older snapshot last).
        let snapshot = allNotes
        let url = fileURL
        let backupURL = backupFileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else {
                Log.shared.error("Failed to encode notes for save")
                return
            }
            await MainActor.run {
                do {
                    try data.write(to: url, options: .atomic)
                    self.savesSinceBackup += 1
                    if self.savesSinceBackup >= 10 {
                        self.savesSinceBackup = 0
                        try? data.write(to: backupURL, options: .atomic)
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
        do {
            allNotes = try JSONDecoder().decode([Note].self, from: try Data(contentsOf: fileURL))
        } catch {
            // A notes.json that fails to decode must never be silently
            // replaced by the next save — that turns one bad write into
            // total data loss. Quarantine the bad file, recover from the
            // rolling backup, and carry on from what survives.
            Log.shared.error("Failed to load notes: \(error) — quarantining notes.json")
            let quarantine = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            if let backup = try? Data(contentsOf: backupFileURL),
               let recovered = try? JSONDecoder().decode([Note].self, from: backup),
               !recovered.isEmpty {
                allNotes = recovered
                Log.shared.error("NotesStore: recovered \(recovered.count) note(s) from notes.backup.json")
            }
        }
    }
}

extension Notification.Name {
    /// Posted when a note is soft-deleted or purged (object = note UUID).
    /// SpeechPlayer stops playback if the deleted note is the live one.
    static let noteDeleted = Notification.Name("NotesStore.noteDeleted")
}
