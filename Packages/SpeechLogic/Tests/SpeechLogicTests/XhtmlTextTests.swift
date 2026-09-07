import XCTest
@testable import SpeechLogic

final class XhtmlTextTests: XCTestCase {

    func testParagraphsAndHeadingsBecomeSeparateBlocks() {
        let text = XhtmlText.plainText(from: """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head>
        <body><h1>Chapter One</h1><p>First paragraph.</p><p>Second paragraph.</p></body></html>
        """)
        XCTAssertEqual(text, "Chapter One\n\nFirst paragraph.\n\nSecond paragraph.")
    }

    func testInlineMarkupFlowsThrough() {
        let text = XhtmlText.plainText(from: "<p>It was <em>bright</em> and <strong>cold</strong>.</p>")
        XCTAssertEqual(text, "It was bright and cold.")
    }

    func testHeadStyleScriptDropped() {
        let text = XhtmlText.plainText(from: """
        <html><head><title>Hidden</title><style>p { color: red }</style></head>
        <body><script>var x = 1;</script><p>Visible</p></body></html>
        """)
        XCTAssertEqual(text, "Visible")
    }

    func testImageAltTextSurvives() {
        let text = XhtmlText.plainText(from: "<p>Before<img src=\"a.jpg\" alt=\"a lighthouse\"/>after</p>")
        XCTAssertEqual(text, "Before (image: a lighthouse) after")
    }

    func testAltlessImageVanishes() {
        let text = XhtmlText.plainText(from: "<p>Before<img src=\"a.jpg\"/>after</p>")
        XCTAssertEqual(text, "Before after")
    }

    func testBrActsAsParagraphBreak() {
        let text = XhtmlText.plainText(from: "<p>Line one<br/>Line two</p>")
        XCTAssertEqual(text, "Line one\n\nLine two")
    }

    func testWhitespaceRunsCollapse() {
        let text = XhtmlText.plainText(from: "<p>\n    It   was\t bright,\n\n  cold.\n  </p>")
        XCTAssertEqual(text, "It was bright, cold.")
    }

    func testTableCellsJoinWithCommas() {
        let text = XhtmlText.plainText(from: """
        <table><tr><td>Name</td><td>Count</td></tr><tr><td>A</td><td>2</td></tr></table>
        """)
        XCTAssertEqual(text, "Name, Count\n\nA, 2")
    }

    func testEmptyAndCoverOnlyInput() {
        XCTAssertEqual(XhtmlText.plainText(from: ""), "")
        XCTAssertEqual(XhtmlText.plainText(from: "<html><body></body></html>"), "")
    }

    func testNamespacedTagsAreMatchedByLocalName() {
        let text = XhtmlText.plainText(from: """
        <xhtml:p xmlns:xhtml="http://www.w3.org/1999/xhtml">Prefixed</xhtml:p>
        """)
        XCTAssertEqual(text, "Prefixed")
    }
}

// MARK: - Named entities + parse diagnostics (v1.5 sage round)

extension XhtmlTextTests {
    func testNamedEntitiesNoLongerTruncateTheChapter() {
        // `&nbsp;` and friends abort a strict XML parse — before the
        // pre-parse map, everything after the first entity was LOST.
        // (Assertions avoid raw NBSP: the paragraph normalizer collapses it
        // to a plain space, which is a rendering choice, not truncation.)
        let xhtml = "<html><body><p>Before&nbsp;the interruption.</p><p>After &mdash; and &#8212; numeric.</p></body></html>"
        let text = XhtmlText.plainText(from: xhtml)
        XCTAssertTrue(text.contains("Before"), text)
        XCTAssertTrue(text.contains("the interruption."), text)
        XCTAssertTrue(text.contains("After"), text)
        XCTAssertTrue(text.contains("numeric."), text)
    }

    func testUnknownNamedEntityIsStrippedNotFatal() {
        let xhtml = "<html><body><p>A &weirdentity; B &copy; C</p></body></html>"
        let text = XhtmlText.plainText(from: xhtml)
        XCTAssertTrue(text.contains("A"), text)
        XCTAssertTrue(text.contains("B"), text)   // content AFTER the unknown entity survived
        XCTAssertTrue(text.contains("C"), text)   // content AFTER the mapped one survived
    }

    func testReplacingNamedEntitiesMapsKnownAndStripsUnknown() {
        let out = XhtmlText.replacingNamedEntities("x&nbsp;y &mdash; z &weirdentity; w &#8212; n")
        XCTAssertFalse(out.contains("&nbsp;"), out)
        XCTAssertFalse(out.contains("&mdash;"), out)
        XCTAssertFalse(out.contains("weirdentity"), out)  // unknown token stripped (a strict parser treats it as fatal)
        XCTAssertTrue(out.contains("&#8212;"), out)       // numeric refs stay for the parser
    }

    func testExtractReportsUncompletedParse() {
        // A document that is genuinely malformed XML must be reported as
        // suspect so callers refuse to cache the truncated extraction.
        let broken = "<html><body><p>Fine text</p><p>&bogus; broken"
        let result = XhtmlText.extract(from: Data(broken.utf8))
        // The entity map strips &bogus; so this actually completes — force a
        // real failure instead: unterminated tag.
        let reallyBroken = "<html><body><p>Fine</p><p>D <unclosed"
        let r2 = XhtmlText.extract(from: Data(reallyBroken.utf8))
        XCTAssertFalse(r2.parseCompleted, "unterminated tag must fail the parse")
        _ = result
    }

    func testExtractReportsCompletedParse() {
        let ok = "<html><body><p>All &mdash; good</p></body></html>"
        let result = XhtmlText.extract(from: Data(ok.utf8))
        XCTAssertTrue(result.parseCompleted)
        XCTAssertTrue(result.text.contains("—"))
    }
}

// MARK: - Footnote scrubbing (v1.5 sage round)

extension XhtmlTextTests {

    func testFootnoteAsidesAndNoterefsAreScrubbed() {
        let xhtml = """
        <html><body>
        <p>Solid ground<sup class="noteref"><a href="#n1">12</a></sup> beneath us.</p>
        <aside epub:type="footnote" id="n1"><p>12. The footnote body that used to interrupt.</p></aside>
        <p>After the aside.</p>
        </body></html>
        """
        let text = XhtmlText.plainText(from: xhtml)
        XCTAssertTrue(text.contains("Solid ground beneath us."), text)
        XCTAssertFalse(text.contains("footnote body"), text)
        XCTAssertFalse(text.contains("12."), text)
        XCTAssertTrue(text.contains("After the aside."), text)
    }

    func testNonFootnoteAsidesAreKept() {
        // epub:type="pullquote"-style asides are CONTENT — never scrubbed.
        let xhtml = "<html><body><p>Main text.</p><aside epub:type=\"pullquote\"><p>A quoted aside.</p></aside></body></html>"
        let text = XhtmlText.plainText(from: xhtml)
        XCTAssertTrue(text.contains("A quoted aside."), text)
    }
}
