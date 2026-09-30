import Foundation
import SpeechLogic

enum BookFormat: String, Codable {
    case epub
    case pdf
    /// A finished audiobook file (M4B / M4A / MP4 with a chpl atom, or MP3 with
    /// ID3 CHAP frames). The audio already exists — Speechnotes plays it and
    /// keeps the chapter list for navigation and lock-screen controls, instead
    /// of synthesizing anything.
    case audio
}

/// Where the reader left off. EPUB: spine index + scroll fraction inside the
/// chapter; PDF: page index + fraction inside the page. One shape keeps the
/// manifest and the resume logic format-agnostic. `cfi` is EPUB-only and
/// survives font-size/rotation better than the index+fraction pair — when
/// set it wins on restore and the other fields are the fallback.
struct BookPosition: Codable, Equatable, Hashable {
    var chapterIndex: Int
    var chapterFraction: Double
    var cfi: String?
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
    /// Nesting level for the drop-down TOC tree (0 = top). Optional so
    /// manifests written before round 6 keep decoding.
    var depth: Int?
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
    /// audio: the chapters read out of the file's own metadata (chpl / ID3
    /// CHAP). One list, so the shelf, the player bar, lock screen and the
    /// mini-player all agree on the unit boundaries without re-parsing.
    var audioChapters: [AudioChapter]?
    /// audio: where the chapters came from — "chpl", "id3" or "single" when
    /// the file has no chapter metadata at all (one implicit chapter).
    var audioChapterSource: String?
    /// audio: total duration in seconds, read at import for the player bar
    /// and the lock-screen scrubber.
    var audioDuration: Double?
    var hasCover: Bool
    var toc: [BookTocEntry]?
    var position: BookPosition?
    /// Set at import when the book parsed badly (DRM/encryption, malformed
    /// container) — the shelf explains WHY instead of shelving a silent
    /// husk with no TOC and no TTS.
    var importError: String?
    /// Soft-delete stamp for the books recycle bin — nil while the book is
    /// on the shelf. Optional so manifests written before the bin existed
    /// keep decoding exactly as they did.
    var deletedAt: Date?

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
        audioChapters: [AudioChapter]? = nil,
        audioChapterSource: String? = nil,
        audioDuration: Double? = nil,
        hasCover: Bool = false,
        toc: [BookTocEntry]? = nil,
        position: BookPosition? = nil,
        importError: String? = nil,
        deletedAt: Date? = nil
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
        self.audioChapters = audioChapters
        self.audioChapterSource = audioChapterSource
        self.audioDuration = audioDuration
        self.hasCover = hasCover
        self.toc = toc
        self.position = position
        self.importError = importError
        self.deletedAt = deletedAt
    }

    /// True when the book sits in the recycle bin.
    var isDeleted: Bool { deletedAt != nil }

    /// How long a binned book stays on disk. Same window as notes.
    static let recycleRetentionDays = 30
}

extension Book {
    /// "Book Title — Chapter 3" style subtitle for the mini-player / list.
    var authorOrFormat: String {
        if let author, !author.isEmpty { return author }
        switch format {
        case .epub: return docKindLabel ?? "EPUB"
        case .pdf: return "PDF"
        case .audio: return "Audiobook"
        }
    }

    /// What kind of document a shelf item really is, from the ORIGINAL file
    /// extension (office formats normalize to EPUB at import, so the plain
    /// format read "EPUB" for a Word doc). nil for genuine EPUBs.
    var docKindLabel: String? {
        guard format == .epub else { return nil }
        switch (originalFileName as NSString).pathExtension.lowercased() {
        case "docx": return "Word"
        case "doc": return "Word 97"
        case "odt": return "ODT"
        case "pptx": return "Slides"
        case "odp": return "ODP"
        default: return nil
        }
    }
}
