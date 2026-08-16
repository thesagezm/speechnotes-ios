import XCTest
@testable import SpeechLogic

final class MarkdownTextTests: XCTestCase {

    func testHeadingsAndEmphasis() {
        let input = """
        # Title

        Some **bold** and *italic* and `code` text.

        ### Section
        """
        let output = MarkdownText.plainText(input)
        XCTAssertEqual(output, "Title\n\nSome bold and italic and code text.\n\nSection")
    }

    func testLinksAndImages() {
        let input = "Read [the docs](https://example.com) now. ![chart](img.png)"
        XCTAssertEqual(MarkdownText.plainText(input), "Read the docs now. chart")
    }

    func testListsKeepContent() {
        let input = """
        - first
        * second
        1. third
        """
        XCTAssertEqual(MarkdownText.plainText(input), "first\nsecond\nthird")
    }

    func testBlockquotesAndRules() {
        let input = """
        > quoted wisdom
        ---

        after the break
        """
        XCTAssertEqual(MarkdownText.plainText(input), "quoted wisdom\n\nafter the break")
    }

    func testFencedCodeContentKeptVerbatim() {
        let input = """
        before
        ```
        let x = **not stripped**
        ```
        after
        """
        XCTAssertEqual(
            MarkdownText.plainText(input),
            "before\n\nlet x = **not stripped**\n\nafter"
        )
    }

    func testPlainTextPassesThrough() {
        let input = "Just a normal note.\nSecond line."
        XCTAssertEqual(MarkdownText.plainText(input), input)
    }

    func testBoldWithAsteriskWordBoundaries() {
        // A stray asterisk in prose (3 * 4 = 12) must survive.
        XCTAssertEqual(MarkdownText.plainText("3 * 4 = 12"), "3 * 4 = 12")
        XCTAssertEqual(MarkdownText.plainText("**whole phrase** stays"), "whole phrase stays")
    }

    func testStrikethrough() {
        XCTAssertEqual(MarkdownText.plainText("~~old idea~~ new idea"), "old idea new idea")
    }

    func testUnderscoreEmphasis() {
        XCTAssertEqual(MarkdownText.plainText("__strong__ and _em_"), "strong and em")
        // snake_case identifiers must not be mangled
        XCTAssertEqual(MarkdownText.plainText("use my_var_name here"), "use my_var_name here")
    }
}
