import SwiftUI

struct NotesListView: View {
    @EnvironmentObject private var notes: NotesStore
    @State private var path: [UUID] = []

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
                        let note = notes.createNote()
                        path.append(note.id)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}
