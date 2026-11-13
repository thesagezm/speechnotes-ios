import XCTest
@testable import SpeechLogic

/// The whole additional-formats pipeline, end to end: every format
/// DocumentBook normalizes is parsed, converted with
/// `DocumentEpubConverter.epubData` (exactly what BooksStore.importBook
/// runs), and re-parsed with the app's own `EpubParser` — asserting the
/// contract the reader depends on:
///
/// 1. one spine entry per chapter (the TTS chapter pipeline reads these),
/// 2. the TOC labels match the chapter titles, in order — the reader's
///    contents list and the pages agree,
/// 3. every TOC href resolves onto the spine (the reader jumps by
///    spineIndex; an unresolved href is an untappable row),
/// 4. depths survive the round trip (0 for the flat navs the converter
///    writes; nesting preserved for books that ship their own),
///
/// so a normalized book's TOC and chapter separation can never silently
/// regress again.
final class DocumentBookRoundTripTests: XCTestCase {

    // MARK: - Assertions

    /// Runs the exact import → EPUB → manifest-parse loop and asserts the
    /// reader contract above against the expected chapter titles.
    private func assertRoundTrip(
        _ format: String,
        data: Data,
        expectedTitles: [String?],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try DocumentBook.parse(fileExtension: format, data: data)
        XCTAssertEqual(
            result.chapters.compactMap(\.title), expectedTitles.compactMap { $0 },
            file: file, line: line
        )
        XCTAssertEqual(
            result.chapters.count, expectedTitles.count,
            "chapter count disagrees", file: file, line: line
        )

        let epub = DocumentEpubConverter.epubData(
            chapters: result.chapters,
            title: "Round Trip",
            author: nil,
            images: result.images,
            cover: result.cover
        )
        let info = try EpubParser.parse(archive: epub)

        // One spine entry per chapter — the TTS chapter pipeline reads the
        // book by these paths.
        XCTAssertEqual(info.spine.count, result.chapters.count, file: file, line: line)
        // TOC ↔ chapter agreement, in order: untitled chapters fall back to
        // the converter's own "Chapter N" label.
        let expectedLabels = expectedTitles.enumerated().map { index, title in
            title ?? "Chapter \(index + 1)"
        }
        XCTAssertEqual(info.toc.map(\.label), expectedLabels, file: file, line: line)
        // Every TOC row lands on the spine — the reader's jump contract.
        let indexByHref = Dictionary(info.spine.enumerated().map { ($1, $0) },
                                     uniquingKeysWith: { first, _ in first })
        for entry in info.toc {
            XCTAssertNotNil(
                indexByHref[entry.href],
                "TOC row «\(entry.label)» (\(entry.href)) resolves to no spine entry",
                file: file, line: line
            )
        }
    }

    // MARK: - Markdown / plain text

    func testMarkdownRoundTrip() throws {
        let md = """
        # The Grand Book

        Intro paragraph before the first chapter.

        ## Chapter One

        Alpha prose.

        ## Chapter Two

        Beta prose.
        """
        try assertRoundTrip("md", data: Data(md.utf8), expectedTitles: [
            "The Grand Book", "Chapter One", "Chapter Two",
        ])
    }

    func testPlainTextGutenbergRoundTrip() throws {
        let txt = """
        THE GRAND BOOK

        Once upon a time prose began.

        Chapter One

        Alpha prose here.

        Chapter Two

        Beta prose here.
        """
        // The running headings open chapters; the preamble is an untitled
        // lead chapter (the converter labels it "Chapter 1").
        try assertRoundTrip("txt", data: Data(txt.utf8), expectedTitles: [
            nil, "Chapter One", "Chapter Two",
        ])
    }

    // MARK: - HTML / HTMLZ

    private let htmlBody = """
    <html><body>
    <h1>Chapter One</h1>
    <p>Alpha prose.</p>
    <h3>A section stays inside</h3>
    <p>Deep prose.</p>
    <h1>Chapter Two</h1>
    <p>Beta prose.</p>
    </body></html>
    """

    func testHTMLRoundTrip() throws {
        // h3 stays inside its chapter (the level 1–2 rule every reader
        // shares), so the TOC shows two chapters.
        try assertRoundTrip("html", data: Data(htmlBody.utf8), expectedTitles: [
            "Chapter One", "Chapter Two",
        ])
    }

    func testHTMLZRoundTrip() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf">
          <metadata><title>The Grand Book</title><creator>An Author</creator></metadata>
        </package>
        """
        let archive = ZipWriter.archive(entries: [
            ("index.html", Data(htmlBody.utf8)),
            ("metadata.opf", Data(opf.utf8)),
        ])
        try assertRoundTrip("htmlz", data: archive, expectedTitles: [
            "Chapter One", "Chapter Two",
        ])
    }

    // MARK: - FictionBook

    func testFB2RoundTrip() throws {
        let fb2 = """
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
          <description><title-info><book-title>The Grand Book</book-title></title-info></description>
          <body>
            <section><title><p>Chapter One</p></title><p>Alpha prose.</p></section>
            <section><title><p>Chapter Two</p></title><p>Beta prose.</p></section>
          </body>
        </FictionBook>
        """
        try assertRoundTrip("fb2", data: Data(fb2.utf8), expectedTitles: [
            "Chapter One", "Chapter Two",
        ])
    }

    // MARK: - RTF

    func testRTFRoundTrip() throws {
        // The bold-scope convention (`{\b Title}\par`) — WordPad and calibre
        // both write titles this way. isMarked must survive the group merge,
        // or the titles are paragraphs and the whole book is one chapter.
        let rtf = "{\\rtf1\\ansi\n{\\b Chapter One}\\par\nAlpha prose.\\par\n{\\b Chapter Two}\\par\nBeta prose.\\par\n}"
        try assertRoundTrip("rtf", data: Data(rtf.utf8), expectedTitles: [
            "Chapter One", "Chapter Two",
        ])
    }

    // MARK: - DOCX

    private func docxArchive(documentBody: String) -> Data {
        let documentXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>\(documentBody)</w:body>
        </w:document>
        """
        return ZipWriter.archive(entries: [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
        ])
    }

    func testDOCXRoundTrip() throws {
        let body = """
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter One</w:t></w:r></w:p>
        <w:p><w:r><w:t>Alpha prose.</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>A section stays inside</w:t></w:r></w:p>
        <w:p><w:r><w:t>Deep prose.</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter Two</w:t></w:r></w:p>
        <w:p><w:r><w:t>Beta prose.</w:t></w:r></w:p>
        """
        // Heading2 is level 2, which opens chapters too — the office rule the
        // existing parser tests pin. Keep the expectation honest: three.
        try assertRoundTrip("docx", data: docxArchive(documentBody: body), expectedTitles: [
            "Chapter One", "A section stays inside", "Chapter Two",
        ])
    }

    // MARK: - Depth preservation (the reader's TOC tree input)

    /// A book that ships its OWN nested nav must keep that nesting through
    /// EpubParser — the drop-down tree in BookReaderView renders from these
    /// depths, and the manifest snapshot now carries them (BooksStore used
    /// to drop the field, flattening every TOC and re-parsing every launch).
    func testNestedNavDepthsSurviveTheParse() throws {
        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body>
            <nav epub:type="toc" id="toc">
              <ol>
                <li><a href="part1.xhtml">Part One</a>
                  <ol>
                    <li><a href="ch1.xhtml">Chapter One</a></li>
                    <li><a href="ch2.xhtml">Chapter Two</a></li>
                  </ol>
                </li>
                <li><a href="part2.xhtml">Part Two</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:test</dc:identifier>
            <dc:title>Nested</dc:title>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="p1" href="part1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="p2" href="part2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="p1"/>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            <itemref idref="p2"/>
          </spine>
        </package>
        """
        let epub = ZipWriter.archive(entries: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
        ])
        let info = try EpubParser.parse(archive: epub)

        XCTAssertEqual(info.toc.map(\.label), ["Part One", "Chapter One", "Chapter Two", "Part Two"])
        XCTAssertEqual(info.toc.map(\.depth), [0, 1, 1, 0])
        // And the whole tree resolves onto the spine — the nested rows are
        // tappable, not just displayed.
        let indexByHref = Dictionary(info.spine.enumerated().map { ($1, $0) },
                                     uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(info.toc.compactMap { indexByHref[$0.href] }, [0, 1, 2, 3])
    }
}
