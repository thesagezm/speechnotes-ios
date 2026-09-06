import XCTest
import PDFKit
import SpeechLogic

/// PDF spike — the CI contract test for PdfText against REAL documents (the
/// fixture-based unit tests in SpeechLogic cover the synthetic shapes; this
/// covers what real publishers' toolchains actually emit). Documents are
/// downloaded by the `pdf-spike` CI job into ~/pdf-spike (override with
/// PDF_SPIKE_DIR); marker lines "PDF-SPIKE ..." are grepped by the job's
/// failure-summary step.
final class PdfSpikeTests: XCTestCase {

    private func document(_ filename: String) throws -> PDFDocument {
        let dir = ProcessInfo.processInfo.environment["PDF_SPIKE_DIR"]
            ?? NSHomeDirectory() + "/pdf-spike"
        let url = URL(fileURLWithPath: dir).appendingPathComponent(filename)
        return try XCTUnwrap(
            PDFDocument(url: url),
            "PDFKit could not open \(filename) — downloaded file invalid?"
        )
    }

    /// The Linux From Scratch book ships a real PDF bookmark tree built by
    /// dblatex — the outline-chapter contract against a publisher's toolchain.
    func testLFSBookChaptersComeFromOutline() throws {
        let document = try document("LFS-BOOK-12.1.pdf")
        XCTAssertGreaterThanOrEqual(document.pageCount, 50, "unexpectedly small: \(document.pageCount) pages")

        let resolved = PdfText.resolveChapters(in: document)
        let head = resolved.chapters.prefix(5)
            .map { "\($0.label) p\($0.startPage)-\($0.endPage)" }
            .joined(separator: ", ")
        print("PDF-SPIKE lfs: source=\(resolved.source) chapters=\(resolved.chapters.count) pages=\(document.pageCount)")
        print("PDF-SPIKE lfs first chapters: \(head)")

        XCTAssertEqual(resolved.source, "outline", "LFS book is bookmark-built — outline must win")
        XCTAssertGreaterThanOrEqual(resolved.chapters.count, 5, "a 34-chapter book must yield many chapters")

        // First chapter's text must actually extract — the TTS path depends on it.
        let first = try XCTUnwrap(
            PdfText.chapterText(in: document, chapters: resolved.chapters, index: 0)
        )
        XCTAssertFalse(first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("PDF-SPIKE lfs chapter 0: \(first.text.utf16.count) chars, \(first.pageOffsets.count) pages")
    }

    /// ACL Anthology papers are the canonical two-column layout. The strict
    /// left→right ordering contract lives in the fixture tests; here we
    /// verify real-world text extraction works and LOG how often the gutter
    /// split engages on body pages.
    func testACLEntirelyTwoColumnPaperExtracts() throws {
        let document = try document("P02-1040.pdf")
        XCTAssertGreaterThanOrEqual(document.pageCount, 5)
        var splitPages = 0
        var checkedPages = 0
        for pageIndex in 0..<min(document.pageCount, 6) {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = PdfText.pageText(page)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "page \(pageIndex) extracted nothing")
            if PdfText.columnSplit(page: page, lines: PdfText.lines(of: page)) != nil {
                splitPages += 1
            }
            checkedPages += 1
        }
        print("PDF-SPIKE acl: pages checked=\(checkedPages) column-split engaged=\(splitPages)")
        let firstPageText = document.page(at: 0)?.string ?? ""
        print("PDF-SPIKE acl page 0 head: \(String(firstPageText.prefix(90)).replacingOccurrences(of: "\n", with: " / "))")
    }

    /// arXiv: hyperref usually emits section bookmarks, but NOT always —
    /// whichever path wins, chapters must resolve and extract fast.
    func testArxivPaperResolvesAndExtracts() throws {
        let document = try document("arxiv-1706.03762.pdf")
        XCTAssertGreaterThanOrEqual(document.pageCount, 5)

        let start = Date()
        let resolved = PdfText.resolveChapters(in: document)
        let resolveMs = Int(Date().timeIntervalSince(start) * 1000)
        print("PDF-SPIKE arxiv: source=\(resolved.source) chapters=\(resolved.chapters.count) resolve=\(resolveMs)ms")

        // Modern arXiv toolchains emit bookmarks; a bare one must fall through
        // to heading detection or page ranges — never nil/empty.
        XCTAssertGreaterThanOrEqual(resolved.chapters.count, 2, "chapters must resolve one way or another")

        let extractStart = Date()
        var chars = 0
        for index in 0..<min(5, resolved.chapters.count) {
            chars += PdfText.chapterText(in: document, chapters: resolved.chapters, index: index)?.text.utf16.count ?? 0
        }
        print("PDF-SPIKE arxiv: extracted \(chars) chars in \(Int(Date().timeIntervalSince(extractStart) * 1000))ms")
        XCTAssertGreaterThan(chars, 1000, "extraction produced suspiciously little text")

        let title = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(title.contains("Attention"), "expected the Transformer paper, got: \(String(title.prefix(80)))")
    }
}
