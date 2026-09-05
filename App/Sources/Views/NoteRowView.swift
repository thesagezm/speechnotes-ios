import SwiftUI

/// One row in the notes list. Takes `let note: Note` (a value, not a store
/// reference) so SwiftUI's diffing skips it when unrelated @Published
/// properties change (e.g. player.progress ticks during speech). The preview
/// string is precomputed by NotesStore and passed in — no per-render text
/// scanning.
struct NoteRowView: View {
    let note: Note
    let preview: String

    var body: some View {
        let _ = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("launch-diagnostics.log")
            .appendLine("NoteRowView body: \(note.id)")
        return VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(.headline)
            if !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                Text("·").foregroundStyle(.tertiary)
                Text("\(note.wordCount) words")
                if let minutes = note.estimatedListenMinutes {
                    Text("·").foregroundStyle(.tertiary)
                    Text("~\(minutes) min listen")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
