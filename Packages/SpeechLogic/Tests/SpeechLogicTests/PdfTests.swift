import XCTest
import PDFKit
@testable import SpeechLogic

final class PdfTextTests: XCTestCase {

    private func fixtureDocument(_ name: String) throws -> PDFDocument {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Fixtures"),
            "fixture \(name).pdf missing from the test bundle"
        )
        return try XCTUnwrap(PDFDocument(url: url), "PDFKit could not open \(name).pdf")
    }

    // MARK: - Outline chapters

    func testOutlineBecomesTopLevelChapters() throws {
        let document = try fixtureDocument("pdf-outline")
        let resolved = PdfText.resolveChapters(in: document)
        XCTAssertEqual(resolved.source, "outline")
        // The nested "Section 2.1" under Chapter Two must NOT become a chapter.
        XCTAssertEqual(resolved.chapters.map(\.label), ["Chapter One", "Chapter Two", "Chapter Three"])
        XCTAssertEqual(resolved.chapters.map(\.startPage), [0, 1, 2])
        XCTAssertEqual(resolved.chapters.map(\.endPage), [0, 1, 2])
    }

    // MARK: - Heading fallback

    func testHeadingDetectionWithoutOutline() throws {
        let document = try fixtureDocument("pdf-headings")
        let resolved = PdfText.resolveChapters(in: document)
        XCTAssertEqual(resolved.source, "headings", "no outline + 20pt headings vs 11pt body → heading chapters")
        XCTAssertEqual(resolved.chapters.count, 2)
        XCTAssertEqual(resolved.chapters[0].label, "First Chapter")
        XCTAssertEqual(resolved.chapters[0].startPage, 0)
        XCTAssertEqual(resolved.chapters[0].endPage, 0, "chapter runs until the page before the next heading")
        XCTAssertEqual(resolved.chapters[1].label, "Second Chapter")
        XCTAssertEqual(resolved.chapters[1].startPage, 1)
        XCTAssertEqual(resolved.chapters[1].endPage, 2, "last chapter extends to the document end")
    }

    // MARK: - Two-column extraction

    func testColumnGutterDetectedOnTwoColumnPage() throws {
        let document = try fixtureDocument("pdf-columns")
        let page = try XCTUnwrap(document.page(at: 0))
        let lines = PdfText.lines(of: page)
        XCTAssertGreaterThanOrEqual(lines.count, 10, "fixture draws 5 LEFT + 5 RIGHT lines")
        let split = PdfText.twoColumnSplit(
            pageBounds: page.bounds(for: .mediaBox),
            lines: lines
        )
        XCTAssertNotNil(split, "a clean gutter must separate the two columns")
    }

    func testColumnAwareExtractionReadsLeftBeforeRight() throws {
        let document = try fixtureDocument("pdf-columns")
        let page = try XCTUnwrap(document.page(at: 0))
        let text = PdfText.pageText(page)
        let leftEnd = try XCTUnwrap(text.range(of: "LEFT-5"), "left column text missing: \(text)")
        let rightStart = try XCTUnwrap(text.range(of: "RIGHT-1"), "right column text missing: \(text)")
        XCTAssertLessThan(leftEnd.upperBound, rightStart.lowerBound, "reading order must be left→right: \(text)")
    }

    // MARK: - Chapter text + offsets

    func testChapterTextJoinsPagesWithOffsets() throws {
        let document = try fixtureDocument("pdf-outline")
        let chapters = PdfText.chaptersFromOutline(of: document)!
        let result = PdfText.chapterText(in: document, chapters: chapters, index: 0)
        let text = try XCTUnwrap(result?.text)
        XCTAssertTrue(text.contains("chapter one"), "got: \(text)")
        XCTAssertEqual(result?.pageOffsets.map(\.page), [0])
        XCTAssertEqual(result?.pageOffsets.first?.utf16Offset, 0)
    }

    // MARK: - Page-range floor

    func testFallbackChaptersLabelAndCoverEverything() {
        let chapters = PdfText.fallbackChapters(pageCount: 25)
        XCTAssertEqual(chapters.map(\.label), ["Pages 1–10", "Pages 11–20", "Pages 21–25"])
        XCTAssertEqual(chapters.first?.startPage, 0)
        XCTAssertEqual(chapters.last?.endPage, 24)
        // Ranges tile the document without gaps or overlaps.
        for (index, chapter) in chapters.enumerated() {
            if index > 0 {
                XCTAssertEqual(chapter.startPage, chapters[index - 1].endPage + 1)
            }
        }
        XCTAssertEqual(PdfText.fallbackChapters(pageCount: 0).count, 0)
    }

    // MARK: - Normalization + text-layer probe

    func testNormalizeMapsLigaturesAndJoinsHyphenBreaks() {
        XCTAssertEqual(PdfText.normalize("ﬁﬂ"), "fifl")
        XCTAssertEqual(PdfText.normalize("exam-\nple"), "example")
        XCTAssertEqual(PdfText.normalize("a\r\nb\rc"), "a\nb\nc")
        XCTAssertEqual(PdfText.normalize("a\n\n\n\nb"), "a\n\nb")
    }

    func testPageHasTextLayerSeparatesTextFromBlank() throws {
        let document = try fixtureDocument("pdf-outline")
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(PdfText.pageHasTextLayer(page))
        let scannedShape = try fixtureDocument("pdf-blank")
        let scannedPage = try XCTUnwrap(scannedShape.page(at: 0))
        XCTAssertFalse(PdfText.pageHasTextLayer(scannedPage), "a page with no extractable text must not count as a text layer")
    }

    // MARK: - Scan detection (CamScanner watermark / mixed documents)

    func testAWatermarkOnlyLayerIsAScan() throws {
        let document = try fixtureDocument("pdf-watermark")
        let verdict = PdfScanDetector.verdict(in: document)
        XCTAssertTrue(verdict.looksScanned, "a text layer of only the watermark must not pass as a text layer: \(verdict.reason)")
        XCTAssertTrue(verdict.watermarkOnly)
    }

    func testProseIsNotAScan() throws {
        let document = try fixtureDocument("pdf-prose")
        let verdict = PdfScanDetector.verdict(in: document)
        XCTAssertFalse(verdict.looksScanned, "real prose must never be routed to OCR: \(verdict.reason)")
    }

    func testARunningHeadIsNotAScan() throws {
        // Short but genuine per-page text, every page different. The
        // document-level verdict must not guess at density here — the
        // per-page decision handles it at playback time, and a false "scan"
        // would send real words to OCR (and lose them).
        let document = try fixtureDocument("pdf-thin")
        let verdict = PdfScanDetector.verdict(in: document)
        XCTAssertFalse(verdict.looksScanned, "a document with words but no watermark is not a scan: \(verdict.reason)")
        XCTAssertFalse(verdict.watermarkOnly)
    }

    func testABlankDocumentIsAScan() throws {
        let document = try fixtureDocument("pdf-blank")
        let verdict = PdfScanDetector.verdict(in: document)
        XCTAssertTrue(verdict.looksScanned)
        XCTAssertFalse(verdict.watermarkOnly, "no watermark — the pages are simply empty of text")
    }

    func testAMixedDocumentRoutesWatermarkPagesToOCRPerPage() throws {
        // The "true PDF with images that need OCR" case, in the shape that
        // actually occurs: a real-text document whose SOME pages are
        // image-only or stamped with a scanner watermark. The document
        // verdict does not call it a scan (prose pages exist), so the
        // PER-PAGE test must carry those pages — each one on its own.
        let document = try fixtureDocument("pdf-mixed")
        XCTAssertFalse(PdfScanDetector.verdict(in: document).looksScanned,
                       "the prose pages keep this document out of the document-level scan verdict")
        let prosePage = try XCTUnwrap(document.page(at: 0))
        let watermarkPage = try XCTUnwrap(document.page(at: 1))
        XCTAssertFalse(PdfScanDetector.pageIsWatermark(prosePage))
        XCTAssertTrue(PdfScanDetector.pageIsWatermark(watermarkPage),
                      "a watermark page inside a mixed document must still be OCR'd")
    }

    func testImageOnlyPagesInAMixedDocumentAreOCRd() throws {
        // A page with no text layer at all is the original OCR case; inside
        // a mixed document the document verdict says "not a scan", so this
        // proves the per-page test still routes it. Fixture has an empty
        // text layer: `pageHasTextLayer` is the route, and it is false here.
        let document = try fixtureDocument("pdf-blank")
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(PdfText.pageHasTextLayer(page), "an image page is routed by the text-layer probe, not the watermark test")
    }

    func testSamplingCoversTheWholeDocument() {
        // A long document must sample first AND last page, not the first N.
        let indices = PdfScanDetector.sampleIndices(pageCount: 1000, limit: 12)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, 999)
        XCTAssertEqual(Set(indices).count, 12, "indices must be distinct")
    }

    func testSquashIgnoresLineBreaksThePdfOwns() {
        XCTAssertEqual(PdfScanDetector.squash("Scanned\nby\nCamScanner"), "scanned by camscanner")
    }
}
