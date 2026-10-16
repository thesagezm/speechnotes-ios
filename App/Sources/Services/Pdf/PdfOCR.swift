import Foundation
import PDFKit
import UIKit
import Vision
import SpeechLogic

/// Vision OCR for PDF pages — ONE implementation, shared by every caller.
///
/// Two things live here that used to live in `PdfSpeechText` alone:
///
/// 1. The render + recognize itself. The book playback path used to own this
///    privately, which is why the note importer had no OCR at all: a scanned
///    PDF dragged onto the notes list yielded the invisible watermark and
///    nothing else. One enum, both callers, no drift.
/// 2. The decision of WHICH pages to OCR — `shouldOCR`, the one per-page
///    test every extraction path calls. The user's `forceOCR` flag overrides
///    everything; then the cheap text-layer probe; then the watermark test
///    (`PdfScanDetector`), which is what catches the scan whose ONLY text is
///    "Scanned by CamScanner" — a real, selectable text layer that used to
///    sail past the old character-count check.
///
/// Cost shape (why the caps exist): `.accurate` recognition is roughly a
/// third of a second per page on device, and it holds a full-resolution
/// bitmap per page. A note import is bounded by `maxPages` and
/// `maxOCRPages` before this is called; a book chapter renders lazily and
/// never asks for more than its own pages.
enum PdfOCR {

    /// Renders one page at ~2× and recognizes it with `.accurate`, language
    /// correction OFF (the engine wants the original words, not autocorrected
    /// ones). Returns nil for a page that produced nothing — which is
    /// information, not an error: the page simply contributes nothing.
    ///
    /// The 2× render is the practical quality ceiling. Dense textbook scans
    /// want more, but a full-bleed render of an A4 page at 3× is ~3 MB of
    /// bitmap per page and Vision's request holds every page it recognizes
    /// in the session; 2× is the point where a 300-page scan stays inside
    /// the app's memory budget.
    static func text(page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        guard let cgImage = page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox
        ).cgImage else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
            Log.shared.info("PdfOCR: page OCR produced \(lines.utf16.count) chars")
            return lines.isEmpty ? nil : PdfText.normalize(lines)
        } catch {
            Log.shared.info("PdfOCR: recognition failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether a page should be OCR'd rather than read from its text layer.
    /// The three ways that answer comes out true:
    ///
    /// - the caller forced OCR (a scan whose watermark the detector doesn't
    ///   recognize, or a mixed document the user wants fully OCR'd),
    /// - the page's text layer IS a watermark (the CamScanner shape),
    /// - the page has no text layer at all (the classic image-only scan).
    ///
    /// The order matters for cost: `pageHasTextLayer` is a cheap string read,
    /// and the watermark test is one more string pass — a genuine text page
    /// (the overwhelmingly common case) exits through both probes without
    /// ever paying for a render.
    static func shouldOCR(page: PDFPage, forceOCR: Bool) -> Bool {
        if forceOCR { return true }
        if !PdfText.pageHasTextLayer(page) { return true }
        return PdfScanDetector.pageIsWatermark(page)
    }
}
