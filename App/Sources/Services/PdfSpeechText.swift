import Foundation
import PDFKit
import UIKit
import Vision
import SpeechLogic

/// PDF speech-text extraction for TTS: per-page `PdfText` extraction (lazy,
/// page-cached for the session) with a Vision OCR fallback for scanned pages
/// that have no text layer. All PDFKit + Vision work runs on a detached task
/// — the main actor only ever sees the finished text, which
/// BookPlaybackController then caches to `text/NNNN.txt` like an epub's.
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
    static func chapterText(book: Book, chapterIndex: Int) async -> (text: String, pageOffsets: [PdfPageOffset])? {
        guard let chapters = book.pdfChapters,
              chapterIndex >= 0, chapterIndex < chapters.count else { return nil }
        let chapter = chapters[chapterIndex]
        let documentURL = BooksStore.originalFileURL(book)
        let cachePrefix = book.id.uuidString
        return await Task.detached(priority: .userInitiated) { () -> (String, [PdfPageOffset])? in
            guard let document = PDFDocument(url: documentURL) else { return nil }
            var text = ""
            var offsets: [PdfPageOffset] = []
            for pageNumber in chapter.startPage...chapter.endPage {
                guard pageNumber >= 0, pageNumber < document.pageCount,
                      let page = document.page(at: pageNumber) else { continue }
                let pageString = extract(page: page, cacheKey: "\(cachePrefix)-\(pageNumber)")
                guard !pageString.isEmpty else { continue }
                offsets.append(PdfPageOffset(page: pageNumber, utf16Offset: text.utf16.count))
                if !text.isEmpty { text += "\n\n" }
                text += pageString
            }
            guard !text.isEmpty else { return nil }
            return (text, offsets)
        }.value
    }

    private static func extract(page: PDFPage, cacheKey: String) -> String {
        let key = cacheKey as NSString
        if let cached = pageTextCache.object(forKey: key) {
            return cached as String
        }
        let result: String
        if PdfText.pageHasTextLayer(page) {
            result = PdfText.pageText(page)
        } else {
            // Scanned page: no text layer — OCR it. An empty OCR result just
            // means the page contributes nothing; the chapter continues.
            result = ocr(page: page) ?? ""
        }
        pageTextCache.setObject(result as NSString, forKey: key)
        return result
    }

    /// Vision OCR for scanned pages: render at ~2× and recognize with
    /// `.accurate`, language correction OFF (the engine wants the original
    /// words, not autocorrected ones). A failure degrades to an empty page,
    /// never an abort — one bad page must not end a chapter.
    private static func ocr(page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let thumbnail = page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox
        )
        guard let cgImage = thumbnail.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
            Log.shared.info("PdfSpeechText: OCR page produced \(lines.utf16.count) chars")
            return lines.isEmpty ? nil : PdfText.normalize(lines)
        } catch {
            Log.shared.info("PdfSpeechText: OCR failed — \(error.localizedDescription)")
            return nil
        }
    }
}
