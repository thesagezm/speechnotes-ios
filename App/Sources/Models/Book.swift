import Foundation

enum BookFormat: String, Codable {
    case epub
    case pdf
}

/// Where the reader left off. EPUB: spine index + scroll fraction inside the
/// chapter; PDF: page index + fraction inside the page. One shape keeps the
/// manifest and the resume logic format-agnostic.
struct BookPosition: Codable, Equatable {
    var chapterIndex: Int
    var chapterFraction: Double
}

/// One TOC row snapshotted at import time (epub: from EpubInfo's native
/// parse — the epub.js runtime TOC is the primary navigation, this is the
/// zero-webview fallback). PDF outlines are read live from PDFKit instead.
struct BookTocEntry: Codable, Equatable {
    var label: String
    /// Zip entry path the entry points at (epub only).
    var href: String
    /// Index into the book's spine when it could be resolved.
    var spineIndex: Int?
}

/// The library's manifest record — ONE manifest.json per book directory.
/// Deliberately not notes.json: a shelf of 50 MB books must not share the
/// file the editor rewrites on every save flush.
struct Book: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var author: String?
    var format: BookFormat
    var originalFileName: String
    var addedAt: Date
    var lastOpenedAt: Date?
    /// epub: chapter (spine) count.
    var spineCount: Int?
    /// pdf: page count.
    var pageCount: Int?
    var hasCover: Bool
    var toc: [BookTocEntry]?
    var position: BookPosition?

    init(
        id: UUID,
        title: String,
        author: String? = nil,
        format: BookFormat,
        originalFileName: String,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        spineCount: Int? = nil,
        pageCount: Int? = nil,
        hasCover: Bool = false,
        toc: [BookTocEntry]? = nil,
        position: BookPosition? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.originalFileName = originalFileName
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.spineCount = spineCount
        self.pageCount = pageCount
        self.hasCover = hasCover
        self.toc = toc
        self.position = position
    }
}

extension Book {
    /// "Book Title — Chapter 3" style subtitle for the mini-player / list.
    var authorOrFormat: String {
        if let author, !author.isEmpty { return author }
        return format == .epub ? "EPUB" : "PDF"
    }
}
