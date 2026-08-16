import SwiftUI

struct NotesListView: View {
    @EnvironmentObject private var notes: NotesStore
    @State private var path: [UUID] = []
    @State private var showingImporter = false
    @State private var importErrorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if notes.notes.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "note.text",
                        description: Text("Tap + to write your first note and hear it read aloud.")
                    )
                } else {
                    List {
                        ForEach(notes.notes) { note in
                            NavigationLink(value: note.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.title)
                                        .font(.headline)
                                    Text("Edited \(note.updatedAt, style: .relative)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { notes.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("Speechnotes")
            .navigationDestination(for: UUID.self) { noteId in
                NoteEditorView(noteId: noteId)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import file")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let note = notes.createNote()
                        path.append(note.id)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: ImportService.acceptedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importFile(at: url) }
                case .failure(let error):
                    importErrorMessage = error.localizedDescription
                }
            }
            // Open-In files and speechnotes:// links (LiveContainer forwards
            // what it can; the Files picker above always works).
            .onOpenURL { url in
                handleOpenURL(url)
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { importErrorMessage != nil },
                    set: { if !$0 { importErrorMessage = nil } }
                )
            ) {
                Button("OK") { importErrorMessage = nil }
            } message: {
                Text(importErrorMessage ?? "")
            }
        }
    }

    // MARK: - Import

    private func importFile(at url: URL) {
        guard ImportService.canImport(url) else {
            importErrorMessage = "Unsupported file type: \(url.lastPathComponent)"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let imported = ImportService.importText(from: url)
            DispatchQueue.main.async {
                guard let imported else {
                    importErrorMessage = "Could not extract text from \(url.lastPathComponent)."
                    return
                }
                addNote(text: imported.text)
            }
        }
    }

    private func handleOpenURL(_ url: URL) {
        if url.isFileURL {
            importFile(at: url)
            return
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "speechnotes" else { return }
        guard let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.shared.error("NotesList: speechnotes:// URL without usable text")
            return
        }
        addNote(text: text)
    }

    /// Imported text lands verbatim; the note's title derives from its first
    /// line like every other note.
    private func addNote(text: String) {
        let note = notes.createNote()
        var updated = note
        updated.text = text
        notes.update(updated)
        path.append(note.id)
    }
}
