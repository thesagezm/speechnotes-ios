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
}
