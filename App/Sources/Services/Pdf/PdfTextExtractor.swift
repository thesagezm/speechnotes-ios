import Foundation
import PDFKit
import SpeechLogic

/// One place where "which extractor" is decided, so the notes importer and
/// the book reader can never drift apart.
///
/// The policy is PDFKit, and only PDFKit. Papero used to sit in front of it
/// here — a webview running a vendored 1.5 MB layout engine — and it is gone
/// (purged 2026-10-03): on device it either failed outright or returned page
/// counts the document did not have ("page 9 does not exist, the document
/// has 5"), which put a working extractor out of reach. The per-page path
/// below keeps what papero never had: per-page offsets for the reader's
/// auto-scroll, and OCR for pages with no text layer.
///
/// Only PDFs go through here. The office formats reach the Books tab
/// through DocumentBook's EPUB conversion.
enum PdfTextExtractor {

    /// What an extraction produced.
    struct Extraction {
        /// The text to speak, in reading order.
        let text: String
        /// The document is a scan with no usable text layer.
        let isScanned: Bool
        /// UTF-16 offset into `text` where each page begins, for the reader's
        /// auto-scroll. Empty when the caller does not need them.
        let pageOffsets: [PdfPageOffset]
    }

    // MARK: - Notes import (whole document, capped)

    /// Extracts a document for a note import, honouring the importer's caps.
    /// Returns nil when the document yielded no text.
    static func text(
        for url: URL,
        maxPages: Int,
        maxCharacters: Int
    ) async -> Extraction? {
        // PDFKit is synchronous and can walk a long document; the note
        // importer is already async, so the walk goes off the main actor.
        let result = await Task.detached(priority: .userInitiated) {
            builtin(url: url, maxPages: maxPages, maxCharacters: maxCharacters)
        }.value
        guard let result else { return nil }
        return Extraction(text: result, isScanned: false, pageOffsets: [])
    }

    // MARK: - Book chapter (page range, cached)

    /// Extracts one chapter's pages, with the page offsets the reader scrolls
    /// by.
    static func chapterText(
        for url: URL,
        firstPage: Int,
        lastPage: Int
    ) async -> Extraction? {
        let key = "\(url.lastPathComponent)|builtin|\(firstPage)-\(lastPage)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let result = await Task.detached(priority: .userInitiated) {
            builtinChapter(url: url, firstPage: firstPage, lastPage: lastPage)
        }.value
        if let result {
            cache.setObject(Box(result), forKey: key)
        }
        return result
    }

    /// Drops the chapter cache — a reimport changes the document under the
    /// same name, and stale text would be worse than slow text.
    static func invalidateCache() {
        cache.removeAllObjects()
    }

    // MARK: - PDFKit

    private static func builtin(url: URL, maxPages: Int, maxCharacters: Int) -> String? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        var out = ""
        let pageCount = min(document.pageCount, maxPages)
        for index in 0..<pageCount {
            guard let page = document.page(at: index),
                  let pageString = page.string,
                  !pageString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if !out.isEmpty { out += "\n\n" }
            out += pageString
            if out.utf16.count > maxCharacters {
                out += "\n\n[Text truncated at \(maxCharacters / 1000)k characters — import large PDFs on the Books tab instead.]"
                break
            }
        }
        return out.isEmpty ? nil : out
    }

    /// The chapter path keeps PDFKit's per-page extraction and the per-page
    /// offsets the reader scrolls by. (The scanned-page OCR that used to live
    /// here still runs — in `PdfSpeechText`, which is this path's caller for
    /// pages with no text layer.)
    private static func builtinChapter(
        url: URL,
        firstPage: Int,
        lastPage: Int
    ) -> Extraction? {
        guard let document = PDFDocument(url: url) else { return nil }
        var text = ""
        var offsets: [PdfPageOffset] = []
        for pageNumber in firstPage...lastPage {
            guard pageNumber >= 0, pageNumber < document.pageCount,
                  let page = document.page(at: pageNumber),
                  PdfText.pageHasTextLayer(page) else { continue }
            let pageString = PdfText.pageText(page)
            guard !pageString.isEmpty else { continue }
            offsets.append(PdfPageOffset(page: pageNumber, utf16Offset: text.utf16.count))
            if !text.isEmpty { text += "\n\n" }
            text += pageString
        }
        guard !text.isEmpty else { return nil }
        return Extraction(text: text, isScanned: false, pageOffsets: offsets)
    }

    /// One chapter's worth of extractions, keyed by document and page range.
    /// Same reasoning as `PdfSpeechText`'s page cache: extraction is far too
    /// costly to repeat in a session, and NSCache evicts under memory
    /// pressure rather than pinning a big book.
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 32
        return cache
    }()

    /// NSCache holds objects; `Extraction` is a value.
    private final class Box: NSObject {
        let value: Extraction
        init(_ value: Extraction) { self.value = value }
    }
}
