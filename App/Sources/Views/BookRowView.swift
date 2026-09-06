import SwiftUI

/// One library row: cover thumbnail + title + metadata line. Takes the value
/// + precomputed metadata so it renders without touching the disk (the same
/// pattern NoteRowView uses).
struct BookRowView: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            BookCoverView(book: book, height: 62)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var metaLine: String {
        var parts = [book.authorOrFormat]
        switch book.format {
        case .epub:
            if let chapters = book.spineCount {
                parts.append("\(chapters) chapter\(chapters == 1 ? "" : "s")")
            }
        case .pdf:
            // Chapters appear once resolution lands (import or backfill) —
            // until then the honest page count is the fallback.
            if let chapters = book.pdfChapters, !chapters.isEmpty {
                parts.append("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")")
            } else if let pages = book.pageCount {
                parts.append("\(pages) pages")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Book cover thumbnail. Falls back to a format glyph when the book has no
/// cover (or PDFs, whose first page could be rendered later). Loads +
/// decodes once per cell off-main via `.task` — never inline in body.
struct BookCoverView: View {
    let book: Book
    /// Height drives the layout; width follows the ~2:3 book aspect.
    var height: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                    Image(systemName: book.format == .epub ? "book.closed" : "doc.richtext")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: height * 0.7, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.primary.opacity(0.08))
        )
        .task(id: book.id) {
            guard image == nil else { return }
            let url = BooksStore.coverFileURL(book)
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage(data: data)
            }.value
        }
    }
}
