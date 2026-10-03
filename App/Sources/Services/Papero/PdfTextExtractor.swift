import Foundation
import PDFKit
import SpeechLogic

/// One place where "which extractor" is decided, so the notes importer and
/// the book reader can never drift apart.
///
/// The policy, in full:
///
///   * `.builtin` — PDFKit, exactly as before this existed. Still the only
///     path that OCRs a scanned page, so it stays a first-class choice.
///   * `.papero` — papero, and a failure is a failure. Nothing silently
///     substitutes a different engine behind the user's back.
///   * `.automatic` — papero unless it cannot serve the document, in which
///     case PDFKit. "Cannot serve" is mostly papero's own verdict: a scanned
///     page set has no text layer to reconstruct, and an error — encrypted,
///     malformed, webview refused — falls back too.
///
/// Only PDFs go through here. The office formats reach the Books tab through
/// DocumentBook's EPUB conversion, which has no papero equivalent on the
/// device: papero's office support comes from Tika, which lives on papero's
/// server, not in its browser engine. That is a real limit of the
/// on-device route, not an oversight — the alternative is sending documents
/// to a server, which is a different product decision.
enum PdfTextExtractor {

    /// What an extraction produced.
    struct Extraction {
        /// The text to speak, in reading order.
        let text: String
        /// Which engine produced it — logged, so a report about a
        /// mis-extracted PDF can be answered without asking.
        let engine: PdfExtractionMode
        /// The document is a scan with no usable text layer.
        let isScanned: Bool
        /// UTF-16 offset into `text` where each page begins, for the reader's
        /// auto-scroll. Empty when the engine cannot supply it.
        let pageOffsets: [PdfPageOffset]
    }

    // MARK: - Notes import (whole document, capped)

    /// Extracts a document for a note import, honouring the importer's caps.
    /// Returns nil when neither engine produced text.
    static func text(
        for url: URL,
        maxPages: Int,
        maxCharacters: Int
    ) async -> Extraction? {
        let mode = PdfExtractionMode.current
        if mode.prefersPapero {
            if let result = await papero(url: url, pageRange: 1...maxPages, maxCharacters: maxCharacters) {
                return result
            }
            if mode == .papero { return nil }
            Log.shared.info("PdfTextExtractor: papero could not serve the document — using the built-in extractor")
        }
        guard let text = builtin(url: url, maxPages: maxPages, maxCharacters: maxCharacters) else { return nil }
        return Extraction(text: text, engine: .builtin, isScanned: false, pageOffsets: [])
    }

    // MARK: - Book chapter (page range, cached)

    /// Extracts one chapter's pages, with the page offsets the reader scrolls
    /// by.
    static func chapterText(
        for url: URL,
        firstPage: Int,
        lastPage: Int
    ) async -> Extraction? {
        let mode = PdfExtractionMode.current
        let key = "\(url.lastPathComponent)|\(mode.rawValue)|\(firstPage)-\(lastPage)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }

        var result: Extraction?
        if mode.prefersPapero {
            result = await papero(url: url, pageRange: firstPage...lastPage, maxCharacters: .max)
            if result == nil {
                if mode == .papero { return nil }
                Log.shared.info("PdfTextExtractor: papero could not serve pages \(firstPage)-\(lastPage) — using the built-in extractor")
            }
        }
        if result == nil {
            result = builtinChapter(url: url, firstPage: firstPage, lastPage: lastPage)
        }
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

    // MARK: - papero

    private static let extractor = PaperoExtractor()

    private static func papero(
        url: URL,
        pageRange: ClosedRange<Int>,
        maxCharacters: Int
    ) async -> Extraction? {
        do {
            let result = try await extractor.extract(pdf: url, pageRange: pageRange) { done, total in
                Log.shared.info("PdfTextExtractor: papero \(done)/\(total) pages")
            }
            // A scanned document has nothing for papero to reconstruct — no
            // text layer. Say so instead of handing back an empty string the
            // caller has to interpret; the built-in path OCRs it.
            if result.likelyScanned {
                Log.shared.info("PdfTextExtractor: papero reports a scanned document")
                return nil
            }
            let text = truncate(result.markdown, to: maxCharacters)
            guard !text.isEmpty else { return nil }
            return Extraction(
                text: text,
                engine: .papero,
                isScanned: false,
                pageOffsets: result.pageOffsets
            )
        } catch {
            Log.shared.info("PdfTextExtractor: papero failed — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Built-in (the pre-existing PDFKit path, unchanged)

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
        return Extraction(text: text, engine: .builtin, isScanned: false, pageOffsets: offsets)
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard limit != .max, text.utf16.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[..<index])
            + "\n\n[Text truncated at \(limit / 1000)k characters — import large PDFs on the Books tab instead.]"
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
