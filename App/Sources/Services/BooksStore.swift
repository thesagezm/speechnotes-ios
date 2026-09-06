import Foundation
import UIKit
import PDFKit
import SpeechLogic

/// The Books library. Each book is a self-contained directory under
/// Documents/Books/<uuid>/ holding the original file, a manifest.json, a
/// cover image and (from the TTS phase on) cached per-chapter speech text.
///
/// Storage model matters here: one manifest PER BOOK, never one big file —
/// the notes store rewrites its whole JSON on every save flush, which is
/// fine for notes and would be wasteful next to 50 MB books. Scanning the
/// shelf means decoding a handful of tiny manifests.
@MainActor
final class BooksStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var isImporting = false
    @Published var importError: String?

    // MARK: - Locations
    // All static helpers are `nonisolated` so the detached manifest builder
    // can use them off the main actor.

    nonisolated static var booksDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
    }

    nonisolated static func bookDirectory(_ id: UUID) -> URL {
        booksDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated static func originalFileURL(_ book: Book) -> URL {
        bookDirectory(book.id).appendingPathComponent("original.\(book.format.rawValue)")
    }

    nonisolated static func coverFileURL(_ book: Book) -> URL {
        bookDirectory(book.id).appendingPathComponent("cover.jpg")
    }

    /// Cached speech text for one chapter (written by the TTS phase; the
    /// reader path never has to re-extract a chapter it already spoke).
    nonisolated static func speechTextURL(_ book: Book, chapterIndex: Int) -> URL {
        bookDirectory(book.id)
            .appendingPathComponent("text", isDirectory: true)
            .appendingPathComponent(String(format: "%04d.txt", chapterIndex))
    }

    nonisolated static func manifestURL(_ id: UUID) -> URL {
        bookDirectory(id).appendingPathComponent("manifest.json")
    }

    /// For the Settings → Storage usage breakdown.
    nonisolated static func directorySize() -> Int64 {
        ExportsStore.directorySize(booksDirectory)
    }

    // MARK: - Shelf

    /// Called on tab open — never at launch (LiveContainer launch hygiene:
    /// no file I/O inside the first render).
    func refresh() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: Self.booksDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return }
        var shelf: [Book] = []
        for dir in dirs {
            let manifest = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let book = try? JSONDecoder().decode(Book.self, from: data) else { continue }
            shelf.append(book)
        }
        books = shelf.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
        backfillMissingPDFCovers()
    }

    /// PDFs imported before covers existed (or whose render failed at import)
    /// get their page-1 cover generated lazily here — one detached render per
    /// book, then the manifest updates and the shelf refreshes to show them.
    /// One-shot per session: a book that keeps failing must not loop.
    private var didBackfillPDFCovers = false

    private func backfillMissingPDFCovers() {
        guard !didBackfillPDFCovers else { return }
        let pending = books.filter { $0.format == .pdf && !$0.hasCover }
        guard !pending.isEmpty else { return }
        didBackfillPDFCovers = true
        Task.detached(priority: .utility) { [weak self] in
            for var book in pending {
                let dir = BooksStore.bookDirectory(book.id)
                guard let document = PDFDocument(url: dir.appendingPathComponent("original.pdf")),
                      document.pageCount > 0,
                      let page = document.page(at: 0),
                      let data = Self.renderPDFCover(page: page) else { continue }
                try? data.write(to: dir.appendingPathComponent("cover.jpg"), options: .atomic)
                book.hasCover = true
                if let manifest = try? JSONEncoder().encode(book) {
                    try? manifest.write(to: BooksStore.manifestURL(book.id), options: .atomic)
                }
            }
            await MainActor.run { [weak self] in
                self?.refresh()
            }
        }
    }

    // MARK: - Import

    /// Imports one book from a URL the caller already holds security scope
    /// for (the fileImporter pattern used across the app). The copy is
    /// synchronous and fast (one sequential file); the metadata parse and
    /// cover extraction run detached so a slow/corrupt file can never block
    /// the UI. Metadata failure downgrades to a filename-titled book — a
    /// book that parses badly is still a book.
    func importBook(from sourceURL: URL) async {
        isImporting = true
        defer { isImporting = false }

        let ext = sourceURL.pathExtension.lowercased()
        let format: BookFormat
        switch ext {
        case "epub": format = .epub
        case "pdf": format = .pdf
        default:
            importError = "Unsupported book format: .\(ext)"
            return
        }

        let id = UUID()
        let dir = Self.bookDirectory(id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent("original.\(format.rawValue)")
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            importError = "Could not copy \"\(sourceURL.lastPathComponent)\": \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: dir)
            return
        }

        let fileName = sourceURL.lastPathComponent
        let parsed = await Task.detached(priority: .userInitiated) { () -> Book in
            Self.buildManifest(id: id, format: format, originalFileName: fileName, directory: dir)
        }.value

        do {
            let data = try JSONEncoder().encode(parsed)
            try data.write(to: Self.manifestURL(id), options: .atomic)
        } catch {
            importError = "Could not save book metadata: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: dir)
            return
        }
        refresh()
    }

    /// Runs off-main. Reads only a few zip entries (epub) or the lazy
    /// PDFDocument attributes — never the whole book into memory.
    nonisolated private static func buildManifest(id: UUID, format: BookFormat, originalFileName: String, directory: URL) -> Book {
        let fallbackTitle = (originalFileName as NSString)
            .deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
        var book = Book(
            id: id,
            title: fallbackTitle,
            format: format,
            originalFileName: originalFileName
        )

        switch format {
        case .epub:
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("original.epub"), options: .mappedIfSafe),
                  let info = try? EpubParser.parse(archive: data) else {
                return book
            }
            book.title = info.title?.isEmpty == false ? info.title! : fallbackTitle
            book.author = info.creator?.isEmpty == false ? info.creator : nil
            book.spineCount = info.spine.isEmpty ? nil : info.spine.count
            if let coverPath = info.coverPath,
               let coverData = try? ZipReader.readEntry(coverPath, in: data),
               !coverData.isEmpty {
                try? coverData.write(to: directory.appendingPathComponent("cover.jpg"), options: .atomic)
                book.hasCover = true
            }
            // Snapshot the TOC with spine indices so the reader can navigate
            // without a webview. Anchors whose href missed the spine are kept
            // but unlinked.
            if !info.toc.isEmpty {
                let indexByHref = Dictionary(info.spine.enumerated().map { ($1, $0) },
                                             uniquingKeysWith: { first, _ in first })
                book.toc = info.toc.map { entry in
                    BookTocEntry(label: entry.label, href: entry.href, spineIndex: indexByHref[entry.href])
                }
            }
        case .pdf:
            // The copy is local, so PDFDocument(url:) stays lazy — no whole
            // PDF load just to read the title (ImportService's whole-doc
            // string extraction is the pattern we are deliberately avoiding).
            if let document = PDFDocument(url: directory.appendingPathComponent("original.pdf")) {
                book.pageCount = document.pageCount > 0 ? document.pageCount : nil
                // documentAttributes bridges as [AnyHashable: Any] — key it
                // with the full PDFDocumentAttribute spelling.
                let attrs = document.documentAttributes
                if let title = attrs?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { book.title = title }
                if let author = attrs?[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty { book.author = author }
                // Cover = page 1 rendered to a JPEG (epubs carry their real
                // cover; without this PDFs show a generic glyph on the shelf).
                if let page = document.page(at: 0) {
                    if let data = Self.renderPDFCover(page: page) {
                        try? data.write(to: directory.appendingPathComponent("cover.jpg"), options: .atomic)
                        book.hasCover = true
                    }
                }
            }
        }
        return book
    }

    /// Renders one PDF page as a shelf-cover JPEG. Width-fixed (600 pt),
    /// height follows the page's own aspect ratio.
    nonisolated private static func renderPDFCover(page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .cropBox)
        let width: CGFloat = 600
        let height = bounds.height > 0 ? width * bounds.height / bounds.width : width
        let thumbnail = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
        return thumbnail.jpegData(compressionQuality: 0.85)
    }

    // MARK: - Mutations

    func delete(_ book: Book) {
        try? FileManager.default.removeItem(at: Self.bookDirectory(book.id))
        books.removeAll { $0.id == book.id }
    }

    /// Saves a mutated book (position, lastOpenedAt) back to its manifest.
    func save(_ book: Book) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx] = book
        let snapshot = book
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.manifestURL(snapshot.id), options: .atomic)
            }
        }
    }

    func markOpened(_ book: Book) {
        var updated = book
        updated.lastOpenedAt = Date()
        save(updated)
    }

    func updatePosition(_ book: Book, chapterIndex: Int, chapterFraction: Double) {
        var updated = book
        updated.position = BookPosition(chapterIndex: chapterIndex, chapterFraction: chapterFraction)
        save(updated)
    }
}
