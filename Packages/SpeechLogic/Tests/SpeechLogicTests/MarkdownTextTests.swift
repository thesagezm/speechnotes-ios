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
        // Mixed bullet markers are TWO lists by CommonMark spec (a list's
        // items share one bullet character), so each gets a paragraph
        // break — better TTS prosody either way.
        XCTAssertEqual(MarkdownText.plainText(input), "first\n\nsecond\n\nthird")
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
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Title text", spans: [.plain("Title text")]))
    }

    func testTablesParseAndSpeakRowWise() {
        let input = """
        | Name | Size |
        | --- | --- |
        | Kokoro | 192 MB |
        | Kitten | 82 MB |
        """
        let blocks = MarkdownText.blocks(input)
        XCTAssertEqual(blocks.first, .table(headers: [[.plain("Name")], [.plain("Size")]], rows: [[[.plain("Kokoro")], [.plain("192 MB")]], [[.plain("Kitten")], [.plain("82 MB")]]]))
        XCTAssertEqual(
            MarkdownText.plainText(input),
            "Name, Size\nKokoro, 192 MB\nKitten, 82 MB"
        )
    }

    func testReferenceLinksResolve() {
        // Resolved through a FULL document parse: reference definitions are
        // a document-level concept, so a standalone line cannot see them.
        let input = """
        See [the docs][d] and [the site][site].

        [d]: https://example.com/docs
        [site]: https://example.com
        """
        XCTAssertEqual(MarkdownText.plainText(input), "See the docs and the site.")

        let refs = MarkdownText.linkReferences(in: input)
        XCTAssertEqual(refs["d"]?.url, "https://example.com/docs")

        // The AST resolves the references: the paragraph's spans carry the
        // link, which the preview renders as a tappable run.
        guard case .paragraph(_, let spans)? = MarkdownText.blocks(input).first else {
            XCTFail("expected a paragraph"); return
        }
        XCTAssertTrue(spans.contains { $0.linkURL == "https://example.com/docs" && $0.text == "the docs" },
                      "reference link not resolved into a span: \(spans)")
    }

    /// Unresolved reference links speak their LABEL — the raw
    /// `[label][missing-key]` form was spoken as bracket soup and made the
    /// read-along text read wrong (v1.5 speakability fix). Bare `[word]`
    /// with no key stays literal (CommonMark: unresolved shortcut refs are
    /// plain text, and stripping every bracket would eat deliberate ones).
    func testUnresolvedReferenceLinksSpeakLabelOnly() {
        XCTAssertEqual(
            MarkdownText.plainText("Broken [link text][missing] stays readable."),
            "Broken link text stays readable."
        )
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
        // (The spans may split at the soft break — the TEXT is the contract;
        // the preview composes spans back into one flowing paragraph.)
        let blocks = MarkdownText.blocks("line one\nline two\n\nsecond paragraph")
        let texts = blocks.compactMap { block -> String? in
            if case .paragraph(let text, _) = block { return text }
            return nil
        }
        XCTAssertEqual(texts, ["line one\nline two", "second paragraph"])
    }

    func testBlocksHeadingsAndDivider() {
        let blocks = MarkdownText.blocks("# Title\n\ntext\n\n---\n\n### Sub")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title", spans: [.plain("Title")]),
            .paragraph(text: "text", spans: [.plain("text")]),
            .divider,
            .heading(level: 3, text: "Sub", spans: [.plain("Sub")]),
        ])
    }

    func testBlocksGroupLists() {
        let blocks = MarkdownText.blocks("- a\n- b\n\n1. one\n2. two")
        XCTAssertEqual(blocks, [
            .bulletList(items: [MarkdownText.ListItem(text: "a", spans: [.plain("a")]), MarkdownText.ListItem(text: "b", spans: [.plain("b")])]),
            .orderedList(items: [MarkdownText.ListItem(text: "one", spans: [.plain("one")]), MarkdownText.ListItem(text: "two", spans: [.plain("two")])]),
        ])
    }

    func testBlocksCodeKeptVerbatim() {
        let blocks = MarkdownText.blocks("```\n**not bold**\n```")
        XCTAssertEqual(blocks, [.code(language: nil, text: "**not bold**")])
    }

    func testBlocksQuoteStripsMarkersButKeepsInlineSyntax() {
        // The GFM AST resolves `**bold**` — the quote's TEXT loses the
        // markers and gains a bold span, which the preview renders bold.
        // (The old hand parser kept the raw markers for the display layer
        // to re-tokenize; the AST is the display layer now.)
        let blocks = MarkdownText.blocks("> quoted **bold**")
        guard case .quote(let text, let spans)? = blocks.first else {
            XCTFail("expected a quote"); return
        }
        XCTAssertEqual(text, "quoted bold")
        XCTAssertTrue(spans.contains { $0.bold && $0.text == "bold" },
                      "bold inside the quote lost: \(spans)")
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
            .paragraph(text: "after", spans: [.plain("after")]),
        ])
    }

    func testImageMixedWithTextStaysParagraph() {
        // (AST semantics: the image leaves the text and arrives as its own
        // span; the preview lifts image spans out of the paragraph flow.)
        let blocks = MarkdownText.blocks("text ![in](x.png) more")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text, let spans)? = blocks.first else {
            XCTFail("expected a paragraph"); return
        }
        XCTAssertEqual(text, "text in more")
        XCTAssertTrue(spans.contains { $0.imageURL == "x.png" && $0.imageAlt == "in" },
                      "inline image span missing: \(spans)")
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
        XCTAssertEqual(out, "note\n| H1 | H2 | H3 |\n| --- | --- | --- |\n|  |  |  |")
        // The caret lands in the first header cell, which is 2 units past the
        // start of the inserted table — i.e. just past "note\n| ".
        XCTAssertEqual(newCaret, ("note\n| " as NSString).length)
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

    // MARK: - Emoji survival (device report: "notes cannot render emojis")

    /// An emoji is just a character to the parser — it must survive every
    /// block type verbatim. The preview composes `Text` from the block's
    /// text, so anything the parser drops is a character the user never sees.
    func testBlocksPreserveEmojiInParagraphs() {
        let blocks = MarkdownText.blocks("Hello 🎉 world — café ☕ done ✅")
        XCTAssertEqual(blocks, [.paragraph(text: "Hello 🎉 world — café ☕ done ✅", spans: [.plain("Hello 🎉 world — café ☕ done ✅")])])
    }

    func testBlocksPreserveEmojiInHeadingsListsQuotesAndTables() {
        let heading = MarkdownText.blocks("# 🗓 Agenda")
        XCTAssertEqual(heading, [.heading(level: 1, text: "🗓 Agenda", spans: [.plain("🗓 Agenda")])])

        let list = MarkdownText.blocks("- ✅ done\n- 🚧 wip")
        XCTAssertEqual(list, [
            .bulletList(items: [
                MarkdownText.ListItem(text: "✅ done", spans: [.plain("✅ done")]),
                MarkdownText.ListItem(text: "🚧 wip", spans: [.plain("🚧 wip")]),
            ])
        ])

        let quote = MarkdownText.blocks("> 💡 idea")
        XCTAssertEqual(quote, [.quote("💡 idea", spans: [.plain("💡 idea")])])

        let table = MarkdownText.blocks("| a | b |\n|---|---|\n| 🎉 | ✅ |")
        XCTAssertEqual(table, [.table(headers: [[.plain("a")], [.plain("b")]], rows: [[[.plain("🎉")], [.plain("✅")]]])])
    }

    /// Inline runs split text on links/images; emoji must stay inside the
    /// text runs unchanged (the preview renders runs as composed `Text`).
    func testInlineRunsPreserveEmoji() {
        let runs = MarkdownText.inlineRuns("✅ before [link](https://example.com) after 🎉")
        let joined = runs.map { run -> String in
            if case .text(let s) = run { return s }
            return "<non-text>"
        }.joined()
        XCTAssertTrue(joined.contains("✅ before"), "emoji before a link lost: \(joined)")
        XCTAssertTrue(joined.contains("after 🎉"), "emoji after a link lost: \(joined)")
    }

    /// Emphasis stripping runs several regex passes; a ZWJ-sequence emoji
    /// (👨‍👩‍👧) contains a zero-width joiner that the speech sanitizer also
    /// strips — the PREVIEW path must never go through the sanitizer.
    func testSpeechInlineKeepsEmojiButSanitizerIsSpeechOnly() {
        let spoken = MarkdownText.speechInline("Party 🎉 tonight")
        XCTAssertEqual(spoken, "Party 🎉 tonight")
        // plainText() runs the sanitizer (engines can't pronounce emoji) —
        // that's expected and is why the preview must not use plainText.
        let plain = MarkdownText.plainText("Party 🎉 tonight")
        XCTAssertFalse(plain.contains("🎉"), "sanitizer should strip emoji from SPEECH text")
    }

    /// An image inside a mixed paragraph must survive into the preview runs.
    /// The paragraph's spans come from the document parse; rebuilding runs
    /// from the paragraph's PLAIN text cannot recover the image (the alt
    /// text replaced the `![…](…)` marker), which is how web images vanished
    /// from every paragraph that was not exactly one image.
    func testRunsFromParagraphSpansKeepInlineImages() {
        let markdown = "Before text ![cover](https://example.com/pic.jpg) after text"
        guard case .paragraph(_, let spans)? = MarkdownText.blocks(markdown).first else {
            return XCTFail("expected one paragraph block, got \(MarkdownText.blocks(markdown))")
        }
        let runs = MarkdownText.runs(from: spans)
        var sawImage = false
        for run in runs {
            if case .image(let alt, let url) = run {
                sawImage = true
                XCTAssertEqual(alt, "cover")
                XCTAssertEqual(url, "https://example.com/pic.jpg")
            }
        }
        XCTAssertTrue(sawImage, "inline image lost from paragraph runs: \(runs)")
        // The old path fed the FLATTENED text back through the parser — the
        // marker is gone there, which is exactly the failure this guards.
        let flattened = spans.map(\.text).joined()
        XCTAssertFalse(flattened.contains("!["), "test premise: span text carries no markers")
        XCTAssertFalse(MarkdownText.inlineRuns(flattened).contains { run in
            if case .image = run { return true }
            return false
        }, "premise check: a re-parse of the flattened text yields no image runs")
    }

    /// A one-image paragraph is lifted to an `.image` block; a mixed
    /// paragraph must stay a paragraph (the image renders inline via its
    /// spans).
    func testMixedImageParagraphStaysParagraph() {
        let blocks = MarkdownText.blocks("Look: ![x](https://example.com/a.png)")
        guard case .paragraph = blocks.first else {
            return XCTFail("mixed paragraph must not be lifted to an image block")
        }
    }
}
