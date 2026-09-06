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
