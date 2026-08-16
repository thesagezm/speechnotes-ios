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
        save()
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
