import XCTest
@testable import SpeechLogic

/// SelectionOffsetMapper: the bridge between "the reader selected this" and
/// "the engine starts reading here". The surfaces and the engine never read
/// the same bytes, so the mapper's whole job is to survive the difference
/// (whitespace) and refuse everything else.
final class SelectionOffsetMapperTests: XCTestCase {

    // MARK: - The happy path

    func testExactBlockMapsToItsOwnOffset() {
        // "The first sentence. " is 20 UTF-16 units, so the second sentence
        // starts at 20.
        let speech = "The first sentence. The second sentence. The third sentence."
        let block = "The second sentence."
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(blockText: block, blockOffset: 0, speechText: speech),
            20
        )
    }

    func testIntraBlockOffsetIsAdded() {
        // "Alpha " is 6 units; "beta " starts at 6, so "gamma" starts at 11.
        let speech = "Alpha beta gamma delta."
        let block = "beta gamma"
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(blockText: block, blockOffset: 5, speechText: speech),
            11
        )
    }

    func testOffsetAtTheEndOfTheBlockResolves() {
        // "Alpha beta" ends at 10 — the space before "gamma" in the speech
        // text.
        let speech = "Alpha beta gamma."
        let block = "Alpha beta"
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(blockText: block, blockOffset: block.utf16.count, speechText: speech),
            10
        )
    }

    // MARK: - Whitespace differences (the reason this module exists)

    func testNewlinesInTheBlockMatchSpacesInTheSpeechText() {
        let speech = "One two three four five."
        let block = "two\nthree\nfour"
        // The speech text holds "two three four" starting after "One ".
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(blockText: block, blockOffset: 0, speechText: speech),
            4
        )
    }

    func testCollapsedWhitespaceRunDoesNotShiftLaterOffsets() {
        let speech = "One two three."
        let block = "One   two"
        // The block's "w" (offset 7 — the run occupies 3, 4 and 5) is the
        // speech text's "w" at 5: the collapsed run must not move it.
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(blockText: block, blockOffset: 7, speechText: speech),
            5
        )
    }

    func testLeadingAndTrailingWhitespaceIsIgnored() {
        let speech = "The body of the article."
        let block = "\n\n  The body of the article.  \n"
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(blockText: block, blockOffset: 0, speechText: speech),
            0
        )
    }

    func testNonBreakingSpaceIsTreatedAsWhitespace() {
        let speech = "one two three"
        let block = "one\u{00A0}two"
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(blockText: block, blockOffset: 0, speechText: speech),
            0
        )
    }

    // MARK: - Refusals

    func testUnknownBlockIsNil() {
        XCTAssertNil(
            SelectionOffsetMapper.speechOffset(
                blockText: "a sentence the engine never said",
                blockOffset: 0,
                speechText: "The engine said something else entirely."
            )
        )
    }

    func testOutOfRangeBlockOffsetIsNil() {
        XCTAssertNil(
            SelectionOffsetMapper.speechOffset(
                blockText: "short",
                blockOffset: 99,
                speechText: "short text"
            )
        )
    }

    func testNegativeBlockOffsetIsNil() {
        XCTAssertNil(
            SelectionOffsetMapper.speechOffset(
                blockText: "short",
                blockOffset: -1,
                speechText: "short text"
            )
        )
    }

    func testEmptyInputsAreNil() {
        XCTAssertNil(SelectionOffsetMapper.speechOffset(blockText: "", blockOffset: 0, speechText: "text"))
        XCTAssertNil(SelectionOffsetMapper.speechOffset(blockText: "text", blockOffset: 0, speechText: ""))
    }

    // MARK: - The selected-text fallback

    func testSelectedTextFallbackFindsThePassage() {
        let speech = "The quick brown fox jumps over the lazy dog."
        let selected = "brown fox"
        // "The quick " is 10 units.
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(selectedText: selected, speechText: speech),
            10
        )
    }

    func testSelectedTextFallbackIsNilWhenAbsent() {
        XCTAssertNil(
            SelectionOffsetMapper.speechOffset(
                selectedText: "not in here",
                speechText: "something else"
            )
        )
    }

    func testSelectedTextFallbackSurvivesWhitespaceDifferences() {
        let speech = "The quick brown fox"
        XCTAssertEqual(
            SelectionOffsetMapper.speechOffset(selectedText: "quick\nbrown", speechText: speech),
            4
        )
    }
}
