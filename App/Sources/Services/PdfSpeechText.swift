import Foundation
import PDFKit
import SpeechLogic

/// PDF speech-text extraction for TTS: per-page `PdfText` extraction (lazy,
/// page-cached for the session) with a Vision OCR fallback for scanned pages
/// and for pages whose only text layer is a scanner watermark. All PDFKit +
/// Vision work runs on a detached task — the main actor only ever sees the
/// finished text, which BookPlaybackController then caches to `text/NNNN.txt`
/// like an epub's.
///
/// The watermark rule is what makes CamScanner scans work. Those PDFs carry
/// a real, invisible, selectable text layer whose entire content is
/// "Scanned by CamScanner" (~21 characters), so the plain "does this page
/// have 16 characters" probe said YES and the reader read the watermark out
/// loud instead of the page. `PdfOCR.shouldOCR` now asks the detector, and
/// `book.forceOCR` (manifest flag, user-toggleable) overrides it for the
/// scanner apps nobody has named yet — which also covers the MIXED document,
/// where the text pages read fine and only some pages are images.
enum PdfSpeechText {

    /// Session page-text cache. Extraction AND OCR are too costly to repeat
    /// within a playback session (the per-chapter files already cover
    /// cross-session reuse). NSCache is thread-safe and evicts under memory
    /// pressure, so a 1000-page scan can't pin the app. Keys carry the book
    /// id — page indices alone would collide across books.
    private static let pageTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 64
        return cache
    }()

    /// One chapter's speech text + the per-page UTF-16 offsets that let the
    /// reader auto-scroll the PDFView to the sounding page.
    ///
    /// PDFKit owns this path outright (papero was purged 2026-10-03). A page
    /// with no text layer, or only a scanner watermark, is OCR'd here, so
    /// scans keep working.
    static func chapterText(book: Book, chapterIndex: Int) async -> (text: String, pageOffsets: [PdfPageOffset])? {
        guard let chapters = book.pdfChapters,
              chapterIndex >= 0, chapterIndex < chapters.count else { return nil }
        let chapter = chapters[chapterIndex]
        let documentURL = BooksStore.originalFileURL(book)
        let cachePrefix = book.id.uuidString
        let forceOCR = book.forceOCR

        return await Task.detached(priority: .userInitiated) { () -> (String, [PdfPageOffset])? in
            guard let document = PDFDocument(url: documentURL) else { return nil }
            var text = ""
            var offsets: [PdfPageOffset] = []
            for pageNumber in chapter.startPage...chapter.endPage {
                guard pageNumber >= 0, pageNumber < document.pageCount,
                      let page = document.page(at: pageNumber) else { continue }
                let pageString = extract(page: page, cacheKey: "\(cachePrefix)-\(pageNumber)", forceOCR: forceOCR)
                guard !pageString.isEmpty else { continue }
                offsets.append(PdfPageOffset(page: pageNumber, utf16Offset: text.utf16.count))
                if !text.isEmpty { text += "\n\n" }
                text += pageString
            }
            guard !text.isEmpty else { return nil }
            return (text, offsets)
        }.value
    }

    private static func extract(page: PDFPage, cacheKey: String, forceOCR: Bool) -> String {
        let key = cacheKey as NSString
        if let cached = pageTextCache.object(forKey: key) {
            return cached as String
        }
        let result: String
        if PdfOCR.shouldOCR(page: page, forceOCR: forceOCR) {
            // Scanned page, or a watermark-only text layer: OCR it. An empty
            // OCR result just means the page contributes nothing; the
            // chapter continues.
            result = PdfOCR.text(page: page) ?? ""
        } else {
            result = PdfText.pageText(page)
        }
        pageTextCache.setObject(result as NSString, forKey: key)
        return result
    }
}
