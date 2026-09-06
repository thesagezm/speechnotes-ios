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
}
