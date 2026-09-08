import Foundation

/// Owns the notebook list (Documents/notebooks.json). Notes reference a
/// notebook by id (`Note.notebookId`); deleting a notebook here does NOT
/// touch notes — the caller reassigns them via NotesStore so "Unfiled"
/// catches them. Joplin parity: notebooks are containers, notes live in
/// exactly one.
@MainActor
final class NotebooksStore: ObservableObject {
    static let shared = NotebooksStore()

    @Published private(set) var notebooks: [Notebook] = []

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notebooks.json")
    }

    init() {
        notebooks = Self.loadNotebooks()
    }

    /// Creates a notebook with a unique, non-empty name. Returns nil (and
    /// does nothing) when the name is blank or already taken.
    @discardableResult
    func create(name rawName: String) -> Notebook? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !notebooks.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        let notebook = Notebook(name: name)
        notebooks.append(notebook)
        notebooks.sort { $0.createdAt < $1.createdAt }
        save()
        return notebook
    }

    /// Renames in place; blank or conflicting names are ignored.
    func rename(_ notebook: Notebook, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let index = notebooks.firstIndex(where: { $0.id == notebook.id }) else { return }
        guard !notebooks.contains(where: {
            $0.id != notebook.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        notebooks[index].name = name
        save()
    }

    /// Removes the notebook. Notes that referenced it must be reassigned to
    /// nil (Unfiled) by the caller — see NotesStore.clearNotebook(_:).
    func delete(_ notebook: Notebook) {
        notebooks.removeAll { $0.id == notebook.id }
        save()
    }

    func name(for id: UUID?) -> String? {
        guard let id else { return nil }
        return notebooks.first(where: { $0.id == id })?.name
    }

    // MARK: - Persistence

    private static var backupFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notebooks.backup.json")
    }

    private static func loadNotebooks() -> [Notebook] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            return try JSONDecoder().decode([Notebook].self, from: try Data(contentsOf: fileURL))
        } catch {
            // A notebooks.json that fails to decode must never be silently
            // replaced by the next save — that turns one bad write into total
            // data loss (every notebook name gone, notes fall back to Unfiled).
            // Quarantine the bad file, recover from the rolling backup, carry on.
            Log.shared.error("Failed to load notebooks: \(error) — quarantining notebooks.json")
            let quarantine = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            if let backup = try? Data(contentsOf: backupFileURL),
               let recovered = try? JSONDecoder().decode([Notebook].self, from: backup),
               !recovered.isEmpty {
                Log.shared.error("NotebooksStore: recovered \(recovered.count) notebook(s) from notebooks.backup.json")
                return recovered
            }
            return []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(notebooks)
            try data.write(to: Self.fileURL, options: .atomic)
            // Mirror the rolling backup pattern from NotesStore — a backup
            // taken before each overwrite is the cheapest insurance against
            // a mid-write corruption.
            try? data.write(to: Self.backupFileURL, options: .atomic)
        } catch {
            Log.shared.error("Failed to save notebooks: \(error)")
        }
    }
}
