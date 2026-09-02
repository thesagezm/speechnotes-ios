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

    // MARK: - blocks() (reading view)

    func testBlocksRespectSingleLineBreaks() {
        let blocks = MarkdownText.blocks("line one\nline two\n\nsecond paragraph")
        XCTAssertEqual(blocks, [
            .paragraph("line one\nline two"),
            .paragraph("second paragraph"),
        ])
    }

    func testBlocksHeadingsAndDivider() {
        let blocks = MarkdownText.blocks("# Title\n\ntext\n\n---\n\n### Sub")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("text"),
            .divider,
            .heading(level: 3, text: "Sub"),
        ])
    }

    func testBlocksGroupLists() {
        let blocks = MarkdownText.blocks("- a\n- b\n\n1. one\n2. two")
        XCTAssertEqual(blocks, [
            .bulletList(items: ["a", "b"]),
            .orderedList(items: ["one", "two"]),
        ])
    }

    func testBlocksCodeKeptVerbatim() {
        let blocks = MarkdownText.blocks("```\n**not bold**\n```")
        XCTAssertEqual(blocks, [.code("**not bold**")])
    }

    func testBlocksQuoteStripsMarkersButKeepsInlineSyntax() {
        let blocks = MarkdownText.blocks("> quoted **bold**")
        XCTAssertEqual(blocks, [.quote("quoted **bold**")])
    }

    // MARK: - Inline images / links

    func testInlineRunsSplitsImagesAndText() {
        let runs = MarkdownText.inlineRuns("Look ![logo](x.png) here")
        XCTAssertEqual(runs, [
            .text("Look "),
            .image(alt: "logo", url: "x.png"),
            .text(" here"),
        ])
    }

    func testStandaloneImageBecomesImageBlock() {
        let blocks = MarkdownText.blocks("![my photo](p.png)\n\nafter")
        XCTAssertEqual(blocks, [
            .image(alt: "my photo", url: "p.png"),
            .paragraph("after"),
        ])
    }

    func testImageMixedWithTextStaysParagraph() {
        let blocks = MarkdownText.blocks("text ![in](x.png) more")
        XCTAssertEqual(blocks, [.paragraph("text ![in](x.png) more")])
    }

    func testPlainTextStripsImages() {
        // The image token AND its trailing space collapse so we don't get a
        // double-space between "Hello" and "world".
        XCTAssertEqual(
            MarkdownText.plainText("Hello ![x](y.png) world"),
            "Hello world"
        )
        XCTAssertEqual(
            MarkdownText.plainText("Hello![x](y.png)world"),
            "Helloworld"
        )
    }

    func testLinkTargetsEnumerated() {
        let md = "see [one](https://a.com) and [two](https://b.com)"
        let links = MarkdownText.linkTargets(in: md)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.map(\.label), ["one", "two"])
        XCTAssertEqual(links.map(\.url), ["https://a.com", "https://b.com"])
    }

    func testImageTokensEnumerated() {
        let md = "before ![a](x.png) middle ![b](y.jpg) after"
        let imgs = MarkdownText.imageTokens(in: md)
        XCTAssertEqual(imgs.count, 2)
        XCTAssertEqual(imgs.map(\.alt), ["a", "b"])
        XCTAssertEqual(imgs.map(\.url), ["x.png", "y.jpg"])
    }

    // MARK: - Slash menu

    func testSlashDetectsAtLineStart() {
        let t = MarkdownSlashMenu.detect(in: "hello\n/w", caretOffset: 8)
        XCTAssertNotNil(t)
        XCTAssertTrue(t!.isValid)
    }

    func testSlashRejectsMidWord() {
        XCTAssertNil(MarkdownSlashMenu.detect(in: "path/to/file", caretOffset: 12))
    }

    func testSlashAppliesRemovesPrefixAndInsertsSnippet() {
        let t = MarkdownSlashMenu.detect(in: "/bu", caretOffset: 3)!
        let cmd = MarkdownSlashMenu.commands.first { $0.id == "bullet" }!
        let (out, caret) = MarkdownSlashMenu.apply(cmd, in: "/bu", trigger: t)
        XCTAssertEqual(out, "- ")
        XCTAssertEqual(caret, 2)
    }

    func testSlashFilterMatchesById() {
        XCTAssertFalse(MarkdownSlashMenu.filter(prefix: "img").isEmpty)
        XCTAssertFalse(MarkdownSlashMenu.filter(prefix: "h").isEmpty)
    }
}
