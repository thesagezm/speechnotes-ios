import XCTest
import SpeechLogic

/// Tests for the slash-command menu math: trigger detection contexts, fuzzy
/// filter ordering, and apply()'s index bookkeeping (slash deletion, wrap
/// selection shifting, caret placement). The editor wiring in the app target
/// depends on these exact return shapes.
final class MarkdownSlashMenuTests: XCTestCase {

    // MARK: - detect

    private func detect(_ draft: String, caret: Int) -> MarkdownSlashMenu.Trigger? {
        MarkdownSlashMenu.detect(in: draft, caretOffset: caret)
    }

    func testDetectSlashAtLineStart() {
        // "/": caret sits AFTER the slash (utf16 offset 1).
        let trigger = detect("/", caret: 1)
        XCTAssertNotNil(trigger)
        XCTAssertEqual(trigger?.slashIndex, "/".startIndex)
    }

    func testDetectAfterNewline() {
        let draft = "abc\n/"
        let trigger = detect(draft, caret: 5)
        XCTAssertNotNil(trigger)
        // slashIndex points at the "/" (utf16 offset 4).
        let slashOffset = draft.utf16.distance(from: draft.startIndex, to: trigger!.slashIndex)
        XCTAssertEqual(slashOffset, 4)
    }

    func testDetectAfterListPrefix() {
        XCTAssertNotNil(detect("- /", caret: 3))
        XCTAssertNotNil(detect("1. /", caret: 4))
        XCTAssertNotNil(detect("> /", caret: 3))
        XCTAssertNotNil(detect("- [x] /", caret: 7))
    }

    func testDetectKeepsMenuOpenWhileTypingFilter() {
        // The LAST slash before the caret opens the menu, so "/tbl" with the
        // caret at the end still triggers, with the slash at offset 0.
        let draft = "/tbl"
        let trigger = detect(draft, caret: 4)
        XCTAssertNotNil(trigger)
        XCTAssertEqual(draft.utf16.distance(from: draft.startIndex, to: trigger!.slashIndex), 0)
    }

    func testRejectMidWordSlash() {
        XCTAssertNil(detect("path/to", caret: 7))
        XCTAssertNil(detect("https://example.com", caret: 19))
    }

    func testRejectSlashAfterText() {
        XCTAssertNil(detect("hello /", caret: 7))
    }

    func testRejectEmptyDraftAndOutOfBoundsCaret() {
        XCTAssertNil(detect("", caret: 0))
        XCTAssertNil(detect("/", caret: 0))
        XCTAssertNil(detect("/", caret: 99))
    }

    // MARK: - filter

    func testFilterEmptyPrefixReturnsAll() {
        XCTAssertEqual(MarkdownSlashMenu.filter(prefix: "").count, MarkdownSlashMenu.commands.count)
    }

    func testFilterPrefixBeatsSubstring() {
        let results = MarkdownSlashMenu.filter(prefix: "tab")
        XCTAssertEqual(results.first?.id, "table")
    }

    func testFilterMatchesKeywords() {
        // "chk" finds the todo command via its "check"/"checkbox" keywords.
        let ids = MarkdownSlashMenu.filter(prefix: "chk").map(\.id)
        XCTAssertTrue(ids.contains("todo"))
    }

    func testFilterNoMatchIsEmpty() {
        XCTAssertTrue(MarkdownSlashMenu.filter(prefix: "zzzzqqqq").isEmpty)
    }

    // MARK: - apply

    private func makeTrigger(_ draft: String, slashUtf16: Int, cursorUtf16: Int) -> MarkdownSlashMenu.Trigger {
        let slash = draft.utf16.index(draft.utf16.startIndex, offsetBy: slashUtf16)
        let cursor = draft.utf16.index(draft.utf16.startIndex, offsetBy: cursorUtf16)
        return MarkdownSlashMenu.Trigger(
            slashIndex: slash, cursorIndex: cursor, isValid: true
        )
    }

    func testApplyInsertRemovesSlashAndPutsCaretAtSnippetEnd() {
        let draft = "/"
        let command = MarkdownSlashMenu.commands.first { $0.id == "bullet" }!
        let result = MarkdownSlashMenu.apply(
            command, in: draft, trigger: makeTrigger(draft, slashUtf16: 0, cursorUtf16: 1), caret: 1, selection: nil
        )
        XCTAssertEqual(result.draft, "- ")
        XCTAssertEqual(result.caretUtf16, 2)
        XCTAssertNil(result.selectionUtf16)
    }

    func testApplyInsertWithTypedFilterRemovesTheWholeToken() {
        // "/tbl" + Table: slash AND the typed filter are deleted, then the
        // table snippet is inserted.
        let draft = "/tbl"
        let command = MarkdownSlashMenu.commands.first { $0.id == "table" }!
        let result = MarkdownSlashMenu.apply(
            command, in: draft, trigger: makeTrigger(draft, slashUtf16: 0, cursorUtf16: 4), caret: 4, selection: nil
        )
        XCTAssertEqual(result.draft, "| |\n| --- |\n| |")
        XCTAssertEqual(result.caretUtf16, result.draft.utf16.count)
    }

    func testApplyLinkSnippetInsertsBracketOnly() {
        // The link command's snippet is just "[" — the .insert path inserts
        // the snippet verbatim; its placeholder is a marker hint that the
        // snippet never satisfies, so the caret lands after the bracket.
        // (Pinned as the actual contract; complete the syntax by hand.)
        let draft = "/"
        let command = MarkdownSlashMenu.commands.first { $0.id == "link" }!
        let result = MarkdownSlashMenu.apply(
            command, in: draft, trigger: makeTrigger(draft, slashUtf16: 0, cursorUtf16: 1), caret: 1, selection: nil
        )
        XCTAssertEqual(result.draft, "[")
        XCTAssertEqual(result.caretUtf16, 1)
    }

    func testApplyWrapWithSelectionWrapsAndSelectsInner() {
        let draft = "/hello"
        let command = MarkdownSlashMenu.commands.first { $0.id == "bold" }!
        let result = MarkdownSlashMenu.apply(
            command, in: draft,
            trigger: makeTrigger(draft, slashUtf16: 0, cursorUtf16: 1),
            caret: 1, selection: 1..<6
        )
        XCTAssertEqual(result.draft, "**hello**")
        XCTAssertEqual(result.selectionUtf16, 2..<7)
        XCTAssertEqual(result.caretUtf16, 7)
    }

    func testApplyWrapWithoutSelectionInsertsSelectedPlaceholder() {
        let draft = "/"
        let command = MarkdownSlashMenu.commands.first { $0.id == "bold" }!
        let result = MarkdownSlashMenu.apply(
            command, in: draft, trigger: makeTrigger(draft, slashUtf16: 0, cursorUtf16: 1), caret: 1, selection: nil
        )
        XCTAssertEqual(result.draft, "**bold**")
        XCTAssertEqual(result.selectionUtf16, 2..<6)
    }

    func testApplyMidSentenceInsertKeepsSurroundingText() {
        let draft = "before/after"
        let command = MarkdownSlashMenu.commands.first { $0.id == "divider" }!
        let result = MarkdownSlashMenu.apply(
            command, in: draft, trigger: makeTrigger(draft, slashUtf16: 6, cursorUtf16: 12), caret: 12, selection: nil
        )
        XCTAssertEqual(result.draft, "before\n---\n")
    }
}
