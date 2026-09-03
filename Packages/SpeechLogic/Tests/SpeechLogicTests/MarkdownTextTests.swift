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
        // Mixed bullet markers form one list; the ordered list is a separate
        // block, so it gets a real paragraph break (better TTS prosody).
        XCTAssertEqual(MarkdownText.plainText(input), "first\nsecond\n\nthird")
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

    // MARK: - New scanner features

    func testTaskListsSpeakToDoAndDone() {
        let input = """
        - [ ] buy milk
        - [x] ship the app
        """
        XCTAssertEqual(MarkdownText.plainText(input), "To do: buy milk\nDone: ship the app")
        let blocks = MarkdownText.blocks(input)
        guard case .bulletList(let items) = blocks.first else {
            XCTFail("expected bullet list"); return
        }
        XCTAssertFalse(items[0].isDone)
        XCTAssertTrue(items[1].isTask)
        XCTAssertTrue(items[1].isDone)
    }

    func testSetextHeadings() {
        let blocks = MarkdownText.blocks("Title text\n===========\n\nnext")
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Title text"))
    }

    func testTablesParseAndSpeakRowWise() {
        let input = """
        | Name | Size |
        | --- | --- |
        | Kokoro | 192 MB |
        | Kitten | 82 MB |
        """
        let blocks = MarkdownText.blocks(input)
        XCTAssertEqual(blocks.first, .table(headers: ["Name", "Size"], rows: [["Kokoro", "192 MB"], ["Kitten", "82 MB"]]))
        XCTAssertEqual(
            MarkdownText.plainText(input),
            "Name, Size\nKokoro, 192 MB\nKitten, 82 MB"
        )
    }

    func testReferenceLinksResolve() {
        let input = """
        See [the docs][d] and [the site][site].

        [d]: https://example.com/docs
        [site]: https://example.com
        """
        XCTAssertEqual(MarkdownText.plainText(input), "See the docs and the site.")

        let refs = MarkdownText.linkReferences(in: input)
        XCTAssertEqual(refs["d"]?.url, "https://example.com/docs")

        let runs = MarkdownText.inlineRuns("See [the docs][d] now", references: refs)
        XCTAssertEqual(runs, [
            .text("See "),
            .link(label: "the docs", url: "https://example.com/docs"),
            .text(" now"),
        ])
    }

    func testAutolinksBecomeLinkRuns() {
        let runs = MarkdownText.inlineRuns("go to <https://example.com> now")
        XCTAssertEqual(runs, [
            .text("go to "),
            .link(label: "https://example.com", url: "https://example.com"),
            .text(" now"),
        ])
    }

    func testEscapedMarkersSurvive() {
        XCTAssertEqual(MarkdownText.plainText(#"\*not italic\* and \_not\_ me"#), "*not italic* and _not_ me")
    }

    func testNestedListLevels() {
        let input = """
        - top
          - nested
        - top again
        """
        let blocks = MarkdownText.blocks(input)
        guard case .bulletList(let items) = blocks.first else {
            XCTFail("expected bullet list"); return
        }
        XCTAssertEqual(items.map(\.level), [0, 1, 0])
        XCTAssertEqual(items.map(\.text), ["top", "nested", "top again"])
    }

    func testCodeLanguageCaptured() {
        let blocks = MarkdownText.blocks("```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks.first, .code(language: "swift", text: "let x = 1"))
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
            .bulletList(items: [MarkdownText.ListItem(text: "a"), MarkdownText.ListItem(text: "b")]),
            .orderedList(items: [MarkdownText.ListItem(text: "one"), MarkdownText.ListItem(text: "two")]),
        ])
    }

    func testBlocksCodeKeptVerbatim() {
        let blocks = MarkdownText.blocks("```\n**not bold**\n```")
        XCTAssertEqual(blocks, [.code(language: nil, text: "**not bold**")])
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
        // Image tokens keep their alt text (so TTS still announces them),
        // only the URL wrapper goes.
        XCTAssertEqual(
            MarkdownText.plainText("Hello ![x](y.png) world"),
            "Hello x world"
        )
        XCTAssertEqual(
            MarkdownText.plainText("Hello![x](y.png)world"),
            "Helloxworld"
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

    func testSlashDetectsAfterListPrefixes() {
        let t = MarkdownSlashMenu.detect(in: "- /w", caretOffset: 4)
        XCTAssertNotNil(t)
        XCTAssertTrue(t!.isValid)
    }

    func testSlashAppliesRemovesPrefixAndInsertsSnippet() {
        let t = MarkdownSlashMenu.detect(in: "/bu", caretOffset: 3)!
        let cmd = MarkdownSlashMenu.commands.first { $0.id == "bullet" }!
        let (out, caret) = MarkdownSlashMenu.apply(cmd, in: "/bu", trigger: t)
        XCTAssertEqual(out, "- ")
        // Caret lands at the start of the placeholder marker ("]") for the
        // link / image commands, and at end-of-snippet otherwise — bullet
        // has no markdown marker in its placeholder so we expect the end.
        XCTAssertEqual(caret, "- ".utf16.count)
    }

    func testSlashApplyDeletesTypedFilterText() {
        let draft = "note\n/tbl"
        let caret = draft.utf16.count
        let t = MarkdownSlashMenu.detect(in: draft, caretOffset: caret)!
        let cmd = MarkdownSlashMenu.commands.first { $0.id == "table" }!
        let (out, newCaret, _) = MarkdownSlashMenu.apply(cmd, in: draft, trigger: t, caret: caret)
        XCTAssertEqual(out, "note\n| |\n| --- |\n| |")
        XCTAssertEqual(newCaret, out.utf16.count)
    }

    func testSlashWrapCommandWrapsSelection() {
        let draft = "/bold text here"
        let t = MarkdownSlashMenu.detect(in: draft, caretOffset: 1)!
        let cmd = MarkdownSlashMenu.commands.first { $0.id == "bold" }!
        let selStart = 1
        let selEnd = draft.utf16.count
        let (out, _, sel) = MarkdownSlashMenu.apply(cmd, in: draft, trigger: t, caret: 1, selection: selStart..<selEnd)
        XCTAssertEqual(out, "**bold text here**")
        XCTAssertEqual(sel, 2..<16)
    }

    func testSlashFilterMatchesById() {
        XCTAssertFalse(MarkdownSlashMenu.filter(prefix: "img").isEmpty)
        XCTAssertFalse(MarkdownSlashMenu.filter(prefix: "h").isEmpty)
    }

    func testSlashFilterFuzzyMatches() {
        // "tbl" → Table, "chk"-like input → todo/checked via keywords.
        XCTAssertTrue(MarkdownSlashMenu.filter(prefix: "tbl").contains { $0.id == "table" })
        XCTAssertTrue(MarkdownSlashMenu.filter(prefix: "task").contains { $0.id == "todo" })
    }
}
