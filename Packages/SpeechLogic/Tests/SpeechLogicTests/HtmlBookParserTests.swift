import XCTest
@testable import SpeechLogic

/// The tolerant HTML reader: void elements, unclosed blocks, entities inside
/// attributes, script/style bodies and the `<title>`/meta metadata — the
/// shapes real saved pages and Project Gutenberg HTML editions have.
final class HtmlBookParserTests: XCTestCase {

    func testHeadingsBecomeChapters() throws {
        let html = """
        <html><head><title>A Saved Book</title></head><body>
        <h1>Part One</h1><p>Alpha prose.</p>
        <h2>Nested</h2><p>Beta prose.</p>
        <h1>Part Two</h1><p>Gamma prose.</p>
        </body></html>
        """
        let chapters = try HtmlBookParser.parse(html: Data(html.utf8))
        XCTAssertEqual(chapters.map(\.title), ["Part One", "Nested", "Part Two"])
        XCTAssertEqual(chapters[0].paragraphs, ["Alpha prose."])
        XCTAssertEqual(chapters[2].paragraphs, ["Gamma prose."])
    }

    func testUnclosedParagraphsAreClosedByTheNextBlockTag() throws {
        // HTML, not XHTML: no </p> anywhere. A strict XML parser aborts here
        // and the chapter list would end at the first <br>.
        let html = """
        <h1>Chapter</h1>
        <p>First paragraph.
        <p>Second paragraph.
        <br>
        Third paragraph after a br.
        """
        let chapters = try HtmlBookParser.parse(html: Data(html.utf8))
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].paragraphs, [
            "First paragraph.", "Second paragraph.", "Third paragraph after a br."
        ])
    }

    func testScriptAndStyleBodiesAreNeverRead() throws {
        let html = """
        <head><style>p { color: red; font-family: "a > b" }</style>
        <script>var x = "</p>";</script></head>
        <body><p>Visible prose.</p></body>
        """
        let chapters = try HtmlBookParser.parse(html: Data(html.utf8))
        let text = chapters.map(\.paragraphs).flatMap { $0 }.joined(separator: " ")
        XCTAssertTrue(text.contains("Visible prose."))
        XCTAssertFalse(text.contains("color: red"))
        XCTAssertFalse(text.contains("var x"))
    }

    func testEntitiesDecodeIncludingOnesInsideAttributes() throws {
        let html = """
        <h1>Caf&eacute; &amp; Cr&egrave;me &#8212; na&iuml;ve</h1>
        <p>Fifty&nbsp;percent&nbsp;wide&nbsp;&mdash; really.</p>
        <img alt="a > b" src="x.png">
        <p>After the image with a stray &unknownentity; kept.</p>
        """
        let chapters = try HtmlBookParser.parse(html: Data(html.utf8))
        XCTAssertEqual(chapters[0].title, "Café & Crème — naïve")
        XCTAssertTrue(chapters[0].paragraphs.contains("Fifty percent wide — really."))
        XCTAssertTrue(chapters[0].paragraphs.contains("After the image with a stray &unknownentity; kept."))
    }

    func testTableBecomesATableBlock() throws {
        let html = """
        <h1>Data</h1>
        <table><tr><th>Name</th><th>Qty</th></tr>
        <tr><td>Apples</td><td>12</td></tr></table>
        <p>After.</p>
        """
        let chapters = try HtmlBookParser.parse(html: Data(html.utf8))
        guard case .table(let rows)? = chapters[0].blocks.first(where: {
            if case .table = $0 { return true }
            return false
        }) else {
            return XCTFail("expected a table block")
        }
        XCTAssertEqual(rows[0][0].text, "Name")
        XCTAssertTrue(rows[0][0].isHeader)
        XCTAssertEqual(rows[1][1].text, "12")
        // The paragraphs around it survive in order.
        XCTAssertTrue(chapters[0].paragraphs.contains("After."))
    }

    func testDeepHeadingStaysInsideItsChapter() throws {
        let html = "<h1>Part</h1><p>Intro.</p><h3>A subsection</h3><p>Body.</p>"
        let chapters = try HtmlBookParser.parse(html: Data(html.utf8))
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "Part")
        XCTAssertTrue(chapters[0].paragraphs.contains("A subsection"))
    }

    func testTitleAndMetaAuthor() throws {
        let html = """
        <html><head><title>The Real Title</title>
        <meta name="author" content="Someone Real">
        </head><body><p>x</p></body></html>
        """
        let meta = HtmlBookParser.metadata(html: Data(html.utf8))
        XCTAssertEqual(meta.title, "The Real Title")
        XCTAssertEqual(meta.author, "Someone Real")
    }

    func testHeadinglessPageChunks() throws {
        let paragraphs = (0..<400).map { "<p>Paragraph \($0).</p>" }
        let html = "<body>" + paragraphs.joined() + "</body>"
        let chapters = try HtmlBookParser.parse(html: Data(html.utf8))
        XCTAssertEqual(chapters.count, 3)
        XCTAssertTrue(chapters.allSatisfy { $0.title == nil })
        XCTAssertEqual(chapters[0].paragraphs.count, 150)
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try HtmlBookParser.parse(html: Data()))
        XCTAssertThrowsError(try HtmlBookParser.parse(html: Data("   ".utf8)))
    }

    // MARK: - HTMLZ images (the Linux resolver's two tiers)

    private func pngFixture() -> Data {
        Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 7, count: 20)
    }

    func testHTMLZImagesResolveByExactPathThenByBasename() throws {
        // Both srcs name the same entry — the first through its own path
        // (the exact tier), the second through its file name alone (the
        // basename tier, for mirrors that kept the site's tree). Each
        // occurrence joins the pool, the chapter block points at it.
        let html = """
        <html><body>
        <h1>Pictures</h1>
        <p>Before.</p>
        <img src="site/assets/fig.png" alt="a figure">
        <img src="fig.png">
        <p>After.</p>
        </body></html>
        """
        let fig = pngFixture()
        let archive = ZipWriter.archive(entries: [
            ("index.html", Data(html.utf8)),
            ("site/assets/fig.png", fig),
        ])
        let result = try HtmlBookParser.parseFull(archive: archive)
        XCTAssertEqual(result.images.count, 2)
        XCTAssertEqual(result.images[0].mime, "image/png")
        XCTAssertEqual(result.images[0].data, fig)
        XCTAssertEqual(result.images[1].data, fig)
        let blocks = result.chapters[0].blocks
        let imageIndexes = blocks.compactMap { block -> Int? in
            if case .image(let index) = block { return index }
            return nil
        }
        XCTAssertEqual(imageIndexes, [0, 1])
        // The prose keeps its order around the images.
        XCTAssertEqual(result.chapters[0].paragraphs, ["Before.", "After."])
    }

    func testHTMLZUnresolvableSrcsDropTheirTag() throws {
        // An src the archive does not hold (an absolute URL, a file the
        // mirror lost) loses its image — a broken image icon helps nobody.
        let html = """
        <html><body>
        <p>Prose.</p>
        <img src="https://example.org/remote.png">
        <img src="missing.jpg">
        <img src="">
        <p>More prose.</p>
        </body></html>
        """
        let archive = ZipWriter.archive(entries: [
            ("index.html", Data(html.utf8)),
            ("cover.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0])),
        ])
        let result = try HtmlBookParser.parseFull(archive: archive)
        XCTAssertTrue(result.images.isEmpty)
        let imageBlocks = result.chapters.flatMap { $0.blocks }.filter {
            if case .image = $0 { return true }
            return false
        }
        XCTAssertTrue(imageBlocks.isEmpty)
        XCTAssertEqual(result.chapters[0].paragraphs, ["Prose.", "More prose."])
        // The cover convention is separate: the first image ENTRY rides as
        // the shelf cover regardless of what the HTML references.
        XCTAssertEqual(result.cover?.mime, "image/jpeg")
    }
}
