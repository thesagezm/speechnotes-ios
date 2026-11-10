import SwiftUI

/// One row in the notes list. Takes `let note: Note` (a value, not a store
/// reference) so SwiftUI's diffing skips it when unrelated @Published
/// properties change (e.g. player.progress ticks during speech). The derived
/// metadata (title/preview/word count) is precomputed by NotesStore and
/// passed in — no per-render text scanning or sentence parsing.
struct NoteRowView: View {
    let note: Note
    let meta: NotesStore.RowMetadata
    /// E-Ink mode: the pin and star keep their glyphs but lose their hues —
    /// solid ink reads as "flagged" without a color to dither.
    @Environment(\.isEInk) private var isEInk

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meta.title)
                .font(.headline)
            if !meta.preview.isEmpty {
                Text(meta.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(isEInk ? Color.black : Color.orange)
                }
                if note.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(isEInk ? Color.black : Color.yellow)
                }
                Text(note.updatedAt, format: .relative(presentation: .named))
                Text("·").foregroundStyle(.tertiary)
                Text("\(meta.wordCount) words")
                if let minutes = meta.listenMinutes {
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
