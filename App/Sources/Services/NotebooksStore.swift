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
        notebooks = Self.sorted(Self.loadNotebooks())
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
        // A NEW notebook goes to the END of the user's order, not between
        // older unmigrated entries — reordering must never shuffle a library
        // that never asked for it. Placing a new notebook needs a full
        // re-stamp anyway, so do it once: the newly created notebook gets the
        // highest position and everything already placed keeps theirs.
        let highest = (notebooks.compactMap(\.order).max() ?? -1) + 1
        var notebook = Notebook(name: name, order: highest > 0 ? highest : nil)
        notebooks.append(notebook)
        applyOrder()
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

    // MARK: - Order

    /// The displayed order: explicitly-placed notebooks first (by `order`),
    /// then the ones never moved (by `createdAt`). A library that never
    /// reordered keeps the exact list it had, because every entry still has
    /// `order == nil` and falls through to the date sort.
    static func sorted(_ notebooks: [Notebook]) -> [Notebook] {
        notebooks.sorted { lhs, rhs in
            switch (lhs.order, rhs.order) {
            case let (left?, right?):
                return left == right
                    ? lhs.createdAt < rhs.createdAt
                    : left < right
            case (nil, nil):
                return lhs.createdAt < rhs.createdAt
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            }
        }
    }

    /// Re-sorts the published list in place. Called after every mutation so
    /// the array the views bind to is ALWAYS in display order — no view
    /// sorts, no two screens disagreeing on where a notebook sits.
    private func applyOrder() {
        let ordered = Self.sorted(notebooks)
        if ordered != notebooks {
            notebooks = ordered
        }
    }

    /// Moves the notebook at `offset` to `destination` (the indices SwiftUI's
    /// `onMove` hands over, expressed in the CURRENT display order) and
    /// stamps the whole list so the position survives a relaunch. A
    /// contiguous stamp keeps two notebooks from ever sharing an `order`
    /// value, which would leave the next move ambiguous.
    func move(fromOffsets offsets: IndexSet, toDestination destination: Int) {
        var list = Self.sorted(notebooks)
        list.move(fromOffsets: offsets, toDestination: destination)
        for index in list.indices {
            list[index].order = index
        }
        notebooks = list
        applyOrder()
        save()
    }

    /// Current display order, for a view that needs the index of a notebook
    /// it is holding (drag handles, context menus).
    func index(of notebook: Notebook) -> Int? {
        notebooks.firstIndex(where: { $0.id == notebook.id })
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

    private var saveTask: Task<Void, Never>?

    /// Debounced save — matches NotesStore's 1 s coalesce. Row renames and
    /// deletes used to encode + write the whole JSON synchronously per
    /// action; the manager screen fires one call per keystroke during a
    /// rename, and a rename/deleted flurry now lands one write when typing
    /// settles. Same backup-touch behavior as before, just not per keystroke.
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    /// Synchronous save, kept for the moments a pending write must not be
    /// lost (the app is about to background). Hooked up the same way
    /// NotesStore's flushNow is — call sites that need it are added there,
    /// alongside the notes flush.
    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    private func saveNow() {
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
