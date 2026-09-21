import XCTest
@testable import SpeechLogic

final class SpeechSanitizerTests: XCTestCase {

    // MARK: - clean(_:)

    func testCleanReplacesSoftHyphenAndZeroWidthWithSpace() {
        // Replaced, not deleted: deleting would join "hy"+"phen" into one word
        // the reader never saw. The whitespace normaliser collapses the runs.
        let raw = "hy\u{00AD}phen and ze\u{200B}ro and jo\u{200D}in"
        XCTAssertEqual(SpeechSanitizer.clean(raw), "hy phen and ze ro and jo in")
    }

    func testCleanJoinsWordsOnlyWhenThereIsNoGap() {
        // An unspeakable scalar with no space around it still becomes a space,
        // so "exam\u{00AD}ple" (a wrapped line) is spoken as two words rather
        // than the fused "example" the page never showed.
        let raw = "exam\u{00AD}ple"
        XCTAssertEqual(SpeechSanitizer.clean(raw), "exam ple")
    }

    func testCleanDropsBOMAndVariationSelectors() {
        let raw = "\u{FEFF}Hello \u{2764}\u{FE0F} world"
        XCTAssertEqual(SpeechSanitizer.clean(raw), "Hello \u{2764} world")
    }

    func testCleanDropsPrivateUseGlyphs() {
        // Icons from an embedded font (Wingdings-style) come through as PUA.
        XCTAssertEqual(SpeechSanitizer.clean("Star \u{F0A7} here"), "Star here")
    }

    func testCleanReplacesControlBytesWithSpace() {
        let raw = "one\u{00}two\u{07}three\u{1B}[0m\nfour\tfive\r\nsix"
        XCTAssertEqual(SpeechSanitizer.clean(raw), "one two three [0m\nfour five\nsix")
    }

    func testCleanCollapsesBlankLineRuns() {
        let raw = "first\n\n\n\n\nsecond"
        XCTAssertEqual(SpeechSanitizer.clean(raw), "first\n\nsecond")
    }

    func testCleanTrimsAndCollapsesHorizontalSpace() {
        let raw = "   spaced\u{00A0}\u{00A0}out   \n   and   more   "
        XCTAssertEqual(SpeechSanitizer.clean(raw), "spaced out\nand more")
    }

    func testCleanIsIdempotent() {
        let raw = "\u{FEFF}  a\u{00AD}b \n\n\n\n c \u{200B} \t d \u{07}"
        let once = SpeechSanitizer.clean(raw)
        XCTAssertEqual(SpeechSanitizer.clean(once), once)
    }

    func testCleanKeepsOrdinaryPunctuationAndUnicode() {
        let raw = "«Cafe\u{301}» — 3.14 … “quoted” 日本語。"
        XCTAssertEqual(SpeechSanitizer.clean(raw), raw)
    }

    func testCleanLeavesEmptyInputAlone() {
        XCTAssertEqual(SpeechSanitizer.clean(""), "")
        XCTAssertEqual(SpeechSanitizer.clean("\u{00AD}\u{200B}"), "")
    }

    // MARK: - cleanedPreservingOffsets(_:)

    func testPreservingOffsetsDoesNotChangeLength() {
        let raw = "hy\u{00AD}phen\nsecond\u{200B}line\nthird"
        let cleaned = SpeechSanitizer.cleanedPreservingOffsets(raw)
        XCTAssertEqual(cleaned.utf16.count, raw.utf16.count)
    }

    func testPreservingOffsetsTurnsBreaksIntoNewlines() {
        let raw = "one\u{2028}two\u{2029}three\rfour"
        XCTAssertEqual(
            SpeechSanitizer.cleanedPreservingOffsets(raw),
            "one\ntwo\nthree\nfour"
        )
    }

    func testPreservingOffsetsKeepsOffsetsStable() {
        // The read-along contract: a marker after the dirty span must still be
        // found at the same UTF-16 offset in the cleaned string. "dirty" is 5
        // units, then four unspeakable scalars, so MARKER starts at unit 9 in
        // BOTH strings — the whole point of the function.
        let raw = "dirty\u{00AD}\u{200B}\u{FEFF}\u{07}MARKER"
        let cleaned = SpeechSanitizer.cleanedPreservingOffsets(raw)
        XCTAssertEqual(cleaned.utf16.count, raw.utf16.count)
        let rawUnits = Array(raw.utf16)
        let cleanedUnits = Array(cleaned.utf16)
        let markerOffset = Array("MARKER".utf16)
        XCTAssertEqual(Array(rawUnits[9..<15]), markerOffset)
        XCTAssertEqual(Array(cleanedUnits[9..<15]), markerOffset)
    }

    // MARK: - snappedSpan

    func testSnappedSpanGrowsToWordBoundaries() {
        let text = "alpha beta gamma delta epsilon"
        // Ask for "eta gam" — expect it grown to whole words.
        let span = SpeechSanitizer.snappedSpan(in: text, offset: 7, length: 7, slack: 20)
        XCTAssertEqual(span.text, "beta gamma")
        XCTAssertEqual(span.startOffset, 6)
        XCTAssertEqual(span.endOffset, 16)
    }

    func testSnappedSpanClampsToTextBounds() {
        let text = "one two"
        let span = SpeechSanitizer.snappedSpan(in: text, offset: 0, length: 999)
        XCTAssertEqual(span.startOffset, 0)
        XCTAssertEqual(span.endOffset, text.utf16.count)
        XCTAssertEqual(span.text, text)
    }

    func testSnappedSpanSurvivesNoWhitespace() {
        // No boundary exists within the slack, so the span is returned as
        // asked for — snapping must never grow or shrink past what it found.
        let text = "abcdefghij"
        let span = SpeechSanitizer.snappedSpan(in: text, offset: 3, length: 3)
        XCTAssertEqual(span.startOffset, 3)
        XCTAssertEqual(span.endOffset, 6)
        XCTAssertEqual(span.text, "def")
    }
}
