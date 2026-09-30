import XCTest
@testable import SpeechLogic

/// The normalize-to-EPUB pipeline: fixtures are BUILT in-test with ZipWriter
/// (a real docx/odt is just a zip of XML), parsed back, and the resulting
/// EPUB is validated by the app's own EpubParser — the same loop the real
/// import goes through.
final class DocumentEpubTests: XCTestCase {
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

    private func odtArchive(contentBody: String) -> Data {
        let contentXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:text>\(contentBody)</office:text></office:body>
        </office:document-content>
        """
        return ZipWriter.archive(entries: [
            ("mimetype", Data("application/vnd.oasis.opendocument.text".utf8)),
            ("content.xml", Data(contentXML.utf8)),
        ])
    }

    // MARK: - ZipWriter

    func testZipWriterOutputParsesWithZipReader() throws {
        let archive = ZipWriter.archive(entries: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("a/b/file.txt", Data("hello world".utf8)),
        ])
        let entries = try ZipReader.entries(in: archive)
        XCTAssertEqual(entries.map(\.name), ["mimetype", "a/b/file.txt"])
        XCTAssertEqual(try ZipReader.readEntry("a/b/file.txt", in: archive), Data("hello world".utf8))
        // CRC correctness: a flipped byte must be detectable by EpubParser's
        // own read path in real books; here we assert the stored CRC matches.
        XCTAssertEqual(CRC32.of(Data("hello world".utf8)), 0x0D4A_1185)
    }

    // MARK: - DOCX

    func testDocxHeadingsBecomeChapters() throws {
        let body = """
        <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Study Notes</w:t></w:r></w:p>
        <w:p><w:r><w:t>Intro paragraph one.</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Methods</w:t></w:r></w:p>
        <w:p><w:r><w:t>Method text.</w:t></w:r></w:p>
        <w:p><w:r><w:t>More method text.</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Subsection</w:t></w:r></w:p>
        <w:p><w:r><w:t>Deep text.</w:t></w:r></w:p>
        """
        let chapters = try DocxParser.parse(archive: docxArchive(documentBody: body))
        // Title + Heading1 + Heading2 open chapters; Heading2 is level 2 and
        // also opens one (1-2 both open).
        XCTAssertEqual(chapters.map(\.title), ["Study Notes", "Methods", "Subsection"])
        XCTAssertEqual(chapters[1].paragraphs, ["Method text.", "More method text."])
        XCTAssertEqual(chapters[2].paragraphs, ["Deep text."])
    }

    func testDocxHeadlessDocChunks() throws {
        var body = ""
        for i in 0..<310 {
            body += "<w:p><w:r><w:t>Paragraph \(i).</w:t></w:r></w:p>"
        }
        let chapters = try DocxParser.parse(archive: docxArchive(documentBody: body))
        // 310 paragraphs / 150 → 3 chapters, all untitled.
        XCTAssertEqual(chapters.count, 3)
        XCTAssertTrue(chapters.allSatisfy { $0.title == nil })
        XCTAssertEqual(chapters[0].paragraphs.count, 150)
        XCTAssertEqual(chapters[2].paragraphs.count, 10)
    }

    func testDocxEmptyParagraphsSkipped() throws {
        let body = """
        <w:p><w:r><w:t>Only real content.</w:t></w:r></w:p>
        <w:p><w:r></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr></w:p>
        """
        let chapters = try DocxParser.parse(archive: docxArchive(documentBody: body))
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].paragraphs, ["Only real content."])
    }

    func testDocxMissingDocumentXMLThrows() {
        let archive = ZipWriter.archive(entries: [("word/other.xml", Data("<x/>".utf8))])
        XCTAssertThrowsError(try DocxParser.parse(archive: archive))
    }

    // MARK: - ODT

    func testOdtHeadingsAndParagraphs() throws {
        let body = """
        <text:h text:outline-level="1">Chapter One</text:h>
        <text:p>First <text:span>spanned</text:span> paragraph.</text:p>
        <text:h text:outline-level="3">Deep heading</text:h>
        <text:p>After deep heading, same chapter (level 3 with a title open).</text:p>
        """
        let chapters = try OdtParser.parse(archive: odtArchive(contentBody: body))
        XCTAssertEqual(chapters[0].title, "Chapter One")
        // Level 3 does not reopen while a chapter is open.
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].paragraphs, [
            "First spanned paragraph.",
            "Deep heading",
            "After deep heading, same chapter (level 3 with a title open).",
        ])
    }

    // MARK: - PPTX

    private func pptxArchive(slideBodies: [String], withRels: Bool = true) -> Data {
        var entries: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("ppt/presentation.xml", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <p:sldIdLst>
                \(slideBodies.indices.map { "<p:sldId id=\"\($0 + 256)\" r:id=\"rIdSlide\($0 + 1)\"/>" }.joined(separator: "\n"))
              </p:sldIdLst>
            </p:presentation>
            """.utf8)),
        ]
        if withRels {
            entries.append(("ppt/_rels/presentation.xml.rels", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              \(slideBodies.indices.map { "<Relationship Id=\"rIdSlide\($0 + 1)\" Target=\"slides/slide\($0 + 1).xml\"/>" }.joined(separator: "\n"))
            </Relationships>
            """.utf8))
        )
        }
        for (index, body) in slideBodies.enumerated() {
            entries.append(("ppt/slides/slide\(index + 1).xml", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                   xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <p:cSld><p:spTree>\(body)</p:spTree></p:cSld>
            </p:sld>
            """.utf8))
        )
        }
        return ZipWriter.archive(entries: entries)
    }

    func testPptxSlidesBecomeChaptersInRelsOrder() throws {
        let archive = pptxArchive(slideBodies: [
            """
            <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
              <p:txBody><a:p><a:r><a:t>Opening Slide</a:t></a:r></a:p></p:txBody></p:sp>
            <p:sp><p:txBody>
              <a:p><a:r><a:t>First bullet</a:t></a:r></a:p>
              <a:p><a:r><a:t>Second bullet</a:t></a:r></a:p>
            </p:txBody></p:sp>
            """,
            "<p:sp><p:txBody><a:p><a:r><a:t>Closing</a:t></a:r></a:p></p:txBody></p:sp>",
        ])
        let chapters = try PptxParser.parse(archive: archive)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "Opening Slide")
        XCTAssertEqual(chapters[0].paragraphs, ["First bullet", "Second bullet"])
        XCTAssertEqual(chapters[1].title, "Slide 2") // no title shape → fallback
        XCTAssertEqual(chapters[1].paragraphs, ["Closing"])
    }

    func testPptxWithoutRelsFallsBackToNumericSort() throws {
        // 10 slides whose numeric order (1..10) differs from lexical order —
        // slide10 must come last.
        let archive = pptxArchive(
            slideBodies: (0..<10).map { "<p:sp><p:txBody><a:p><a:r><a:t>S\($0)</a:t></a:r></a:p></p:txBody></p:sp>" },
            withRels: false
        )
        let chapters = try PptxParser.parse(archive: archive)
        XCTAssertEqual(chapters.count, 10)
        XCTAssertEqual(chapters[9].paragraphs, ["S9"])
    }

    // MARK: - ODP

    func testOdpPagesBecomeChapters() throws {
        let contentXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0">
          <office:body><office:presentation>
            <draw:page>
              <draw:frame presentation:class="title">
                <draw:text-box><text:p>Title Slide</text:p></draw:text-box>
              </draw:frame>
              <draw:frame>
                <draw:text-box><text:p>Bullet one</text:p><text:p>Bullet two</text:p></draw:text-box>
              </draw:frame>
            </draw:page>
            <draw:page>
              <draw:frame>
                <draw:text-box><text:p>Untitled page body</text:p></draw:text-box>
              </draw:frame>
            </draw:page>
          </office:presentation></office:body>
        </office:document-content>
        """
        let archive = ZipWriter.archive(entries: [("content.xml", Data(contentXML.utf8))])
        let chapters = try OdpParser.parse(archive: archive)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "Title Slide")
        XCTAssertEqual(chapters[0].paragraphs, ["Bullet one", "Bullet two"])
        XCTAssertEqual(chapters[1].title, "Slide 2")
        XCTAssertEqual(chapters[1].paragraphs, ["Untitled page body"])
    }

    // MARK: - Converter → EpubParser round trip

    func testEpubOutputParsesWithEpubParser() throws {
        let chapters = [
            DocumentChapter(title: "One", paragraphs: ["Alpha", "Beta"]),
            DocumentChapter(title: "Two", paragraphs: [String(repeating: "Gamma ", count: 50)]),
            DocumentChapter(title: nil, paragraphs: ["Tail"]),
        ]
        let epub = DocumentEpubConverter.epubData(chapters: chapters, title: "Doc", author: "Me")
        let info = try EpubParser.parse(archive: epub)
        XCTAssertEqual(info.title, "Doc")
        XCTAssertEqual(info.creator, "Me")
        XCTAssertEqual(info.spine.count, 3)
        // TOC labels survive, including the fallback for untitled chapters.
        XCTAssertTrue(info.toc.contains { $0.label == "One" })
        XCTAssertTrue(info.toc.contains { $0.label == "Chapter 3" })
        // The TTS chapter pipeline reads chapter text straight from the
        // archive via spine hrefs — verify one resolves to real text.
        let first = try ZipReader.readEntry(info.spine[0], in: epub)
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(text.contains("<h1>One</h1>"))
        XCTAssertTrue(text.contains("<p>Alpha</p>"))
    }

    func testEscapeStripsForbiddenControls() {
        XCTAssertEqual(
            DocumentEpubConverter.escape("a<b>&\"c\u{0007}d\te"),
            "a&lt;b&gt;&amp;&quot;cd\te"
        )
    }

    // MARK: - v1.7.2: tables, images, covers

    /// Minimal 1×1 transparent GIF — a real decodable image the fixtures
    /// can ship as "media".
    private let tinyGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    private func docxArchiveWithNamespaces(documentBody: String) -> Data {
        let documentXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
          <w:body>\(documentBody)</w:body>
        </w:document>
        """
        return ZipWriter.archive(entries: [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
        ])
    }

    func testDocxTableKeepsRowsSpansAndHeader() throws {
        let body = """
        <w:p><w:r><w:t>Before table.</w:t></w:r></w:p>
        <w:tbl>
          <w:tr><w:trPr><w:tblHeader/></w:trPr>
            <w:tc><w:p><w:r><w:t>Item</w:t></w:r></w:p></w:tc>
            <w:tc><w:p><w:r><w:t>Qty</w:t></w:r></w:p></w:tc>
          </w:tr>
          <w:tr>
            <w:tc><w:p><w:r><w:t>Apples</w:t></w:r></w:p></w:tc>
            <w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p><w:r><w:t>Merged total 12</w:t></w:r></w:p></w:tc>
          </w:tr>
        </w:tbl>
        <w:p><w:r><w:t>After table.</w:t></w:r></w:p>
        """
        let chapters = try DocxParser.parse(archive: docxArchiveWithNamespaces(documentBody: body))
        // The table is one block in document order, not run-on paragraphs.
        XCTAssertEqual(chapters[0].paragraphs, ["Before table.", "After table."])
        XCTAssertEqual(chapters[0].blocks.count, 3)
        guard case .table(let rows)? = chapters[0].blocks.first(where: {
            if case .table = $0 { return true }
            return false
        }) else {
            return XCTFail("expected a table block")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0].text, "Item")
        XCTAssertTrue(rows[0][0].isHeader)
        XCTAssertEqual(rows[1][1].text, "Merged total 12")
        XCTAssertEqual(rows[1][1].columnSpan, 2)
        XCTAssertFalse(rows[1][0].isHeader)
    }

    func testDocxImageResolvedThroughRels() throws {
        let body = """
        <w:p><w:r><w:t>Intro.</w:t></w:r></w:p>
        <w:p><w:r><w:drawing><wp:docPr id="1" name="Chart" descr="Sales chart"/><a:blip r:embed="rId5" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/></w:drawing></w:r></w:p>
        """
        let archive = ZipWriter.archive(entries: [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data(docxDocument(body: body).utf8)),
            ("word/_rels/document.xml.rels", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId5" Target="media/image5.gif"/>
            </Relationships>
            """.utf8)),
            ("word/media/image5.gif", tinyGIF),
        ])
        let result = try DocxParser.parseFull(archive: archive)
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images[0].mime, "image/gif")
        XCTAssertEqual(result.images[0].alt, "Sales chart")
        guard case .image(let poolIndex)? = result.chapters[0].blocks.last else {
            return XCTFail("expected the image as the last block")
        }
        XCTAssertEqual(poolIndex, 0)
    }

    private func docxDocument(body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
          <w:body>\(body)</w:body>
        </w:document>
        """
    }

    func testOdtTableAndEmbeddedThumbnailCover() throws {
        let body = """
        <text:p>Lead.</text:p>
        <table:table>
          <table:table-header-rows>
            <table:table-row>
              <table:table-cell office:value-type="string"><text:p>Name</text:p></table:table-cell>
            </table:table-row>
          </table:table-header-rows>
          <table:table-row>
            <table:table-cell table:number-columns-spanned="2"><text:p>Wide cell</text:p></table:table-cell>
            <table:covered-table-cell/>
          </table:table-row>
        </table:table>
        """
        let contentXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
          <office:body><office:text>\(body)</office:text></office:body>
        </office:document-content>
        """
        let archive = ZipWriter.archive(entries: [
            ("mimetype", Data("application/vnd.oasis.opendocument.text".utf8)),
            ("content.xml", Data(contentXML.utf8)),
            ("Thumbnails/thumbnail.png", tinyGIF),
        ])
        let result = try OdtParser.parseFull(archive: archive)
        XCTAssertEqual(result.cover?.mime, "image/gif")
        guard case .table(let rows)? = result.chapters[0].blocks.last else {
            return XCTFail("expected a table block")
        }
        XCTAssertEqual(rows[0][0].text, "Name")
        XCTAssertTrue(rows[0][0].isHeader)
        // The spanned cell survives; the covered continuation does not.
        XCTAssertEqual(rows[1].count, 1)
        XCTAssertEqual(rows[1][0].columnSpan, 2)
    }

    func testPptxSlideWithTableAndImage() throws {
        let slideBody = """
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
          <p:txBody><a:p><a:r><a:t>Quarterly Deck</a:t></a:r></a:p></p:txBody></p:sp>
        <p:graphicFrame>
          <a:tbl>
            <a:tblPr firstRow="1"/>
            <a:tr><a:tc><a:p><a:r><a:t>Region</a:t></a:r></a:p></a:tc></a:tr>
            <a:tr><a:tc gridSpan="3"><a:p><a:r><a:t>All regions</a:t></a:r></a:p></a:tc></a:tr>
          </a:tbl>
        </p:graphicFrame>
        <p:pic><p:blipFill><a:blip r:embed="rId2"/></p:blipFill></p:pic>
        """
        let archive = ZipWriter.archive(entries: [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("ppt/presentation.xml", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <p:sldIdLst><p:sldId id="256" r:id="rIdSlide1"/></p:sldIdLst>
            </p:presentation>
            """.utf8)),
            ("ppt/_rels/presentation.xml.rels", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rIdSlide1" Target="slides/slide1.xml"/>
            </Relationships>
            """.utf8)),
            ("ppt/slides/slide1.xml", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                   xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                   xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <p:cSld><p:spTree>\(slideBody)</p:spTree></p:cSld>
            </p:sld>
            """.utf8)),
            ("ppt/slides/_rels/slide1.xml.rels", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId2" Target="../media/image2.gif"/>
            </Relationships>
            """.utf8)),
            ("ppt/media/image2.gif", tinyGIF),
        ])
        let result = try PptxParser.parseFull(archive: archive)
        XCTAssertEqual(result.chapters[0].title, "Quarterly Deck")
        XCTAssertEqual(result.images.count, 1)
        // Blocks in document order: table first, then the picture.
        guard case .table(let rows)? = result.chapters[0].blocks.first else {
            return XCTFail("expected a table block first")
        }
        XCTAssertEqual(rows[0][0].text, "Region")
        XCTAssertTrue(rows[0][0].isHeader)
        XCTAssertEqual(rows[1][0].columnSpan, 3)
        guard case .image(0)? = result.chapters[0].blocks.last else {
            return XCTFail("expected the image last")
        }
    }

    func testEpubImagesAndCoverRoundTripThroughEpubParser() throws {
        let chapters = [
            DocumentChapter(title: "Pics", blocks: [
                .paragraph("Look at this."),
                .image(0),
                .table([[DocumentTableCell(text: "A", isHeader: true)],
                        [DocumentTableCell(text: "B\nC")]]),
            ]),
        ]
        let images = [DocumentImage(data: tinyGIF, mime: "image/gif", alt: "A chart")]
        let cover = DocumentImage(data: tinyGIF, mime: "image/gif", alt: "cover")
        let epub = DocumentEpubConverter.epubData(
            chapters: chapters, title: "Doc", author: nil, images: images, cover: cover
        )
        let info = try EpubParser.parse(archive: epub)
        // The cover rides properties="cover-image" — EpubParser resolves it,
        // and buildManifest's shelf path picks it up from there.
        XCTAssertNotNil(info.coverPath)
        XCTAssertEqual(try ZipReader.readEntry(info.coverPath!, in: epub), tinyGIF)
        // The image entry is packaged and the chapter references it.
        XCTAssertEqual(try ZipReader.readEntry("OEBPS/images/img1.gif", in: epub), tinyGIF)
        let chapterXHTML = String(decoding: try ZipReader.readEntry(info.spine[0], in: epub), as: UTF8.self)
        XCTAssertTrue(chapterXHTML.contains("<img class=\"doc-image\" src=\"images/img1.gif\""))
        XCTAssertTrue(chapterXHTML.contains("<table class=\"doc-table\">"))
        XCTAssertTrue(chapterXHTML.contains("<th>A</th>"))
        XCTAssertTrue(chapterXHTML.contains("B<br/>C"))
        // TTS text extraction reads the same chapter without choking: cells
        // comma-joined, image contributes a boundary only (empty alt).
        let spoken = XhtmlText.plainText(from: chapterXHTML)
        XCTAssertTrue(spoken.contains("A, B, C"))
    }

    func testTextLinesRenderTablesForNoteImport() {
        let chapter = DocumentChapter(title: nil, blocks: [
            .paragraph("Para."),
            .table([[DocumentTableCell(text: "Apples")], [DocumentTableCell(text: "12")]]),
        ])
        XCTAssertEqual(chapter.textLines, ["Para.", "Apples", "12"])
    }
}
