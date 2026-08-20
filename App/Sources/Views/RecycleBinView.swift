import SwiftUI

/// Recently Deleted: binned notes with recover / delete-permanently /
/// empty-all. Pushed onto the notes list's navigation stack.
struct RecycleBinView: View {
    @EnvironmentObject private var notes: NotesStore
    @State private var showingEmptyConfirm = false

    var body: some View {
        Group {
            if notes.deletedNotes.isEmpty {
                ContentUnavailableView(
                    "Recycle bin is empty",
                    systemImage: "trash.slash",
                    description: Text("Deleted notes stay here for \(Note.recycleRetentionDays) days before they're removed for good.")
                )
            } else {
                binList
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !notes.deletedNotes.isEmpty {
                    Button("Empty", role: .destructive) { showingEmptyConfirm = true }
                }
            }
        }
        .confirmationDialog(
            "Permanently delete all \(notes.deletedNotes.count) notes?",
            isPresented: $showingEmptyConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                notes.emptyRecycleBin()
                Haptics.press()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var binList: some View {
        List {
            ForEach(notes.deletedNotes) { note in
                binRow(note)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            notes.recover(noteId: note.id)
                            Haptics.success()
                        } label: {
                            Label("Recover", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            notes.purge(noteId: note.id)
                        } label: {
                            Label("Delete Now", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func binRow(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(.headline)
            Text(note.text.split(whereSeparator: \.isNewline).dropFirst()
                .joined(separator: " ").prefix(90))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let deletedAt = note.deletedAt {
                Text("Deleted \(deletedAt, format: .relative(presentation: .named)) · \(note.recycleDaysRemaining ?? 0) days left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
