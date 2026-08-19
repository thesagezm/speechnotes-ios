import Foundation

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
    func createNote() -> Note {
        let note = Note()
        allNotes.insert(note, at: 0)
        save()
        return note
    }

    func update(_ note: Note) {
        guard let index = allNotes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.updatedAt = Date()
        allNotes[index] = updated
        scheduleSave()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            guard index < allNotes.count else { continue }
            softDelete(noteId: allNotes[index].id)
        }
        save()
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
    }

    /// Moves a binned note back into the active list, timestamps preserved.
    func recover(noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }),
              allNotes[index].deletedAt != nil else { return }
        allNotes[index].deletedAt = nil
        allNotes[index].updatedAt = Date()
        save()
    }

    /// Really deletes one binned note. No undo.
    func purge(noteId: UUID) {
        allNotes.removeAll { $0.id == noteId }
        save()
    }

    /// Really deletes every binned note. No undo.
    func emptyRecycleBin() {
        allNotes.removeAll { $0.deletedAt != nil }
        save()
    }

    /// Drops binned notes older than the retention window. Called once from
    /// init — good enough, no timer.
    private func pruneExpiredDeleted() {
        let cutoff = Date().addingTimeInterval(-Double(Note.recycleRetentionDays) * 24 * 3600)
        let before = allNotes.count
        allNotes.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
        if allNotes.count != before { save() }
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

    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(allNotes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.shared.error("Failed to save notes: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            allNotes = try JSONDecoder().decode([Note].self, from: try Data(contentsOf: fileURL))
        } catch {
            Log.shared.error("Failed to load notes: \(error)")
        }
    }
}
