import Foundation

/// Holds all notes in memory and persists them as one JSON file in Documents.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("notes.json")
    }

    init() {
        load()
        Log.shared.info("NotesStore ready with \(notes.count) note(s)")
    }

    @discardableResult
    func createNote() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        save()
        return note
    }

    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.updatedAt = Date()
        notes[index] = updated
        scheduleSave()
    }

    func delete(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
        save()
    }

    /// Deletes by identity — used by the editor's delete button, where we
    /// don't have list offsets.
    func delete(noteId: UUID) {
        notes.removeAll { $0.id == noteId }
        save()
    }

    // MARK: - Persistence

    /// Typing fires update() on every keystroke; encoding the whole store to
    /// JSON synchronously each keypress made the editor laggy on device.
    /// Disk writes are coalesced: one save, a second after the last change.
    private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Persists immediately, cancelling any pending coalesced save. Call when
    /// leaving the editor or entering the background — anything that could
    /// kill the process within the debounce window.
    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.shared.error("Failed to save notes: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            notes = try JSONDecoder().decode([Note].self, from: try Data(contentsOf: fileURL))
        } catch {
            Log.shared.error("Failed to load notes: \(error)")
        }
    }
}
