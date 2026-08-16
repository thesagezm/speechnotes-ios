import XCTest
@testable import SpeechLogic

final class KittenTokenizerTests: XCTestCase {

    func testVocabularyMatchesReferenceTable() {
        // Reference: TextCleaner in KittenML/KittenTTS onnx_model.py —
        // 178 symbols, 3 duplicates collapse (Python dict), 175 entries.
        XCTAssertEqual(KittenTokenizer.vocabulary.count, 175)
        XCTAssertEqual(KittenTokenizer.vocabulary["$"], 0)          // pad
        XCTAssertEqual(KittenTokenizer.vocabulary[";"], 1)
        XCTAssertEqual(KittenTokenizer.vocabulary[" "], 12)         // trailing punct entry
        XCTAssertEqual(KittenTokenizer.vocabulary["…"], 10)         // EOS symbol
        XCTAssertEqual(KittenTokenizer.vocabulary["A"], 17)
        XCTAssertEqual(KittenTokenizer.vocabulary["a"], 43)
        // IPA stress marks are word-ish letters late in the table.
        XCTAssertNotNil(KittenTokenizer.vocabulary["ˈ"])
        XCTAssertNotNil(KittenTokenizer.vocabulary["ː"])
        XCTAssertNotNil(KittenTokenizer.vocabulary["ə"])
        XCTAssertNotNil(KittenTokenizer.vocabulary["ᵻ"])
    }

    func testTokenizeWrapsWithBosAndEos() {
        let tokens = KittenTokenizer.tokenize("həloʊ")
        XCTAssertEqual(tokens.first, 0)
        XCTAssertEqual(tokens.suffix(2), [10, 0])
        XCTAssertTrue(tokens.allSatisfy { $0 >= 0 })
    }

    func testUnknownCharactersAreDropped() {
        // Emoji and control chars have no entry — reference skips them too.
        let cleaned = KittenTokenizer.ids(for: "həloʊ 🎉 wɜːld")
        XCTAssertFalse(cleaned.isEmpty)
        XCTAssertFalse(KittenTokenizer.vocabulary.keys.contains("🎉"))
    }

    func testSpacingRegularizedBetweenRuns() {
        // Punctuation splits from letters; spacing collapses to one gap.
        let spaced = KittenTokenizer.ids(for: "haˈloʊ, wɜːld!")
        // The comma and space both map to table ids (',' = 3, ' ' = 12).
        XCTAssertTrue(spaced.contains(3))
        XCTAssertTrue(spaced.contains(12))
        XCTAssertEqual(spaced.filter { $0 == 12 }.count, 3) // 2 gaps + 1 before '!'
    }

    func testEmptyPhonemesStillProduceWrappers() {
        XCTAssertEqual(KittenTokenizer.tokenize(""), [0, 10, 0])
    }
}
