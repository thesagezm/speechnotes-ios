import Foundation
import SpeechLogic

enum BookFormat: String, Codable {
    case epub
    case pdf
}

/// Where the reader left off. EPUB: spine index + scroll fraction inside the
/// chapter; PDF: page index + fraction inside the page. One shape keeps the
/// manifest and the resume logic format-agnostic.
struct BookPosition: Codable, Equatable, Hashable {
    var chapterIndex: Int
    var chapterFraction: Double
}

/// One TOC row snapshotted at import time (epub: from EpubInfo's native
/// parse — the epub.js runtime TOC is the primary navigation, this is the
/// zero-webview fallback). PDF outlines are read live from PDFKit instead.
struct BookTocEntry: Codable, Equatable, Hashable {
    var label: String
    /// Zip entry path the entry points at (epub only).
    var href: String
    /// Index into the book's spine when it could be resolved.
    var spineIndex: Int?
}

/// The library's manifest record — ONE manifest.json per book directory.
/// Deliberately not notes.json: a shelf of 50 MB books must not share the
/// file the editor rewrites on every save flush.
struct Book: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var title: String
    var author: String?
    var format: BookFormat
    var originalFileName: String
    var addedAt: Date
    var lastOpenedAt: Date?
    /// epub: chapter (spine) count.
    var spineCount: Int?
    /// epub: the spine's zip entry paths in reading order — the TTS chapter
    /// text pipeline reads chapters straight from the archive with these, no
    /// webview needed. Books imported before v1.4.2-P3 lack it; the Books
    /// store backfills lazily.
    var spine: [String]?
    /// pdf: page count.
    var pageCount: Int?
    /// pdf: speech chapters, resolved once at import (or lazily backfilled):
    /// the PDF's own outline tree when it has one, else heading detection,
    /// else labeled page ranges (`pdfChapterSource` records which). The TTS
    /// chapter pipeline reads these exactly like an epub's spine.
    var pdfChapters: [PdfChapter]?
    var pdfChapterSource: String?
    var hasCover: Bool
    var toc: [BookTocEntry]?
    var position: BookPosition?
    /// Set at import when the book parsed badly (DRM/encryption, malformed
    /// container) — the shelf explains WHY instead of shelving a silent
    /// husk with no TOC and no TTS.
    var importError: String?

    init(
        id: UUID,
        title: String,
        author: String? = nil,
        format: BookFormat,
        originalFileName: String,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        spineCount: Int? = nil,
        spine: [String]? = nil,
        pageCount: Int? = nil,
        pdfChapters: [PdfChapter]? = nil,
        pdfChapterSource: String? = nil,
        hasCover: Bool = false,
        toc: [BookTocEntry]? = nil,
        position: BookPosition? = nil,
        importError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.originalFileName = originalFileName
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.spineCount = spineCount
        self.spine = spine
        self.pageCount = pageCount
        self.pdfChapters = pdfChapters
        self.pdfChapterSource = pdfChapterSource
        self.hasCover = hasCover
        self.toc = toc
        self.position = position
        self.importError = importError
    }
}

extension Book {
    /// "Book Title — Chapter 3" style subtitle for the mini-player / list.
    var authorOrFormat: String {
        if let author, !author.isEmpty { return author }
        return format == .epub ? "EPUB" : "PDF"
    }
}
