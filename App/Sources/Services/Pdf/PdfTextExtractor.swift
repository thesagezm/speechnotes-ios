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
/// has 5"), which put a working extractor out of reach.
///
/// Chapter-side OCR lives in `PdfSpeechText` (the live playback path) and
/// `PdfOCR` (the shared Vision call); the note-import path below shares the
/// same decision through `PdfOCR.shouldOCR`, so a CamScanner scan importing
/// as a note now OCRs instead of yielding the invisible watermark.
enum PdfTextExtractor {

    /// What an extraction produced.
    struct Extraction {
        /// The text to speak, in reading order.
        let text: String
        /// The document's text layer is absent, or is a scanner watermark —
        /// the text came from OCR.
        let isScanned: Bool
        /// UTF-16 offset into `text` where each page begins, for the reader's
        /// auto-scroll. Empty when the caller does not need them.
        let pageOffsets: [PdfPageOffset]
    }

    // MARK: - Notes import (whole document, capped)

    /// Extracts a document for a note import, honouring the importer's caps.
    /// Returns nil when the document yielded no text.
    ///
    /// Scanned pages are OCR'd — the pages whose only text layer is a
    /// CamScanner watermark included, which is what "a CamScanner book as a
    /// note" used to get wrong: three words and nothing else.
    static func text(
        for url: URL,
        maxPages: Int,
        maxCharacters: Int,
        maxOCRPages: Int = 25,
        forceOCR: Bool = false
    ) async -> Extraction? {
        // PDFKit is synchronous and can walk a long document; the note
        // importer is already async, so the walk goes off the main actor.
        let result = await Task.detached(priority: .userInitiated) {
            builtin(url: url, maxPages: maxPages, maxCharacters: maxCharacters,
                    maxOCRPages: maxOCRPages, forceOCR: forceOCR)
        }.value
        guard let result else { return nil }
        return Extraction(text: result.text, isScanned: result.isScanned, pageOffsets: [])
    }

    // MARK: - Book chapter (page range, cached)

    /// Extracts one chapter's pages, with the page offsets the reader scrolls
    /// by. NOTE: the live chapter path is `PdfSpeechText.chapterText`, which
    /// owns the per-page cache and OCR. This entry point stays for callers
    /// that hold a URL rather than a `Book` (and for the tests).
    static func chapterText(
        for url: URL,
        firstPage: Int,
        lastPage: Int,
        forceOCR: Bool = false
    ) async -> Extraction? {
        let key = "\(url.lastPathComponent)|builtin|\(firstPage)-\(lastPage)|\(forceOCR)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let result = await Task.detached(priority: .userInitiated) {
            builtinChapter(url: url, firstPage: firstPage, lastPage: lastPage, forceOCR: forceOCR)
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

    // MARK: - PDFKit + Vision

    private static func builtin(
        url: URL,
        maxPages: Int,
        maxCharacters: Int,
        maxOCRPages: Int,
        forceOCR: Bool
    ) -> (text: String, isScanned: Bool)? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        var out = ""
        var ocrPages = 0
        let pageCount = min(document.pageCount, maxPages)
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageString: String
            if PdfOCR.shouldOCR(page: page, forceOCR: forceOCR) {
                // Scanned page (or a watermark-only layer). The OCR cap is
                // the note importer's own — a note is not a book, and Vision
                // costs about a third of a second per page. Past the cap the
                // page is dropped (its text layer, if any, is the watermark
                // — appending it would be worse than dropping it).
                if ocrPages >= maxOCRPages { continue }
                pageString = PdfOCR.text(page: page) ?? ""
                if !pageString.isEmpty { ocrPages += 1 }
            } else {
                pageString = page.string ?? ""
            }
            guard !pageString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if !out.isEmpty { out += "\n\n" }
            out += pageString
            if out.utf16.count > maxCharacters {
                out += "\n\n[Text truncated at \(maxCharacters / 1000)k characters — import large PDFs on the Books tab instead.]"
                break
            }
        }
        guard !out.isEmpty else { return nil }
        return (out, ocrPages > 0)
    }

    /// The chapter path keeps PDFKit's per-page extraction and the per-page
    /// offsets the reader scrolls by, plus the same OCR decision.
    private static func builtinChapter(
        url: URL,
        firstPage: Int,
        lastPage: Int,
        forceOCR: Bool
    ) -> Extraction? {
        guard let document = PDFDocument(url: url) else { return nil }
        var text = ""
        var offsets: [PdfPageOffset] = []
        var ocrPages = 0
        for pageNumber in firstPage...lastPage {
            guard pageNumber >= 0, pageNumber < document.pageCount,
                  let page = document.page(at: pageNumber) else { continue }
            let pageString: String
            if PdfOCR.shouldOCR(page: page, forceOCR: forceOCR) {
                pageString = PdfOCR.text(page: page) ?? ""
                if !pageString.isEmpty { ocrPages += 1 }
            } else {
                pageString = PdfText.pageText(page)
            }
            guard !pageString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            offsets.append(PdfPageOffset(page: pageNumber, utf16Offset: text.utf16.count))
            if !text.isEmpty { text += "\n\n" }
            text += pageString
        }
        guard !text.isEmpty else { return nil }
        return Extraction(text: text, isScanned: ocrPages > 0, pageOffsets: offsets)
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
