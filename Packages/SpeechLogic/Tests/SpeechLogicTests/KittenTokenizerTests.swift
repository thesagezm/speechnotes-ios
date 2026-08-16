import XCTest
@testable import SpeechLogic

final class KittenTokenizerTests: XCTestCase {

    func testVocabularyMatchesReferenceTable() {
        // Reference: TextCleaner in KittenML/KittenTTS onnx_model.py —
        // 178 symbols, 3 duplicates collapse (Python dict), 175 entries.
        XCTAssertEqual(KittenTokenizer.vocabulary.count, 175)
        XCTAssertEqual(KittenTokenizer.vocabulary["$"], 0)          // pad
        XCTAssertEqual(KittenTokenizer.vocabulary[";"], 1)
        XCTAssertEqual(KittenTokenizer.vocabulary[" "], 16)         // after the quote cluster (12 is «)
        XCTAssertEqual(KittenTokenizer.vocabulary["…"], 10)         // EOS symbol
        XCTAssertEqual(KittenTokenizer.vocabulary["A"], 17)
        XCTAssertEqual(KittenTokenizer.vocabulary["a"], 43)
        // Reference builds its dict last-wins: duplicates keep their final id.
        XCTAssertEqual(KittenTokenizer.vocabulary["\""], 15)        // '"' also occupies 11 and 14
        XCTAssertEqual(KittenTokenizer.vocabulary["'"], 176)       // "'" also occupies 174
        XCTAssertEqual(KittenTokenizer.vocabulary["\u{329}"], 175) // combining mark is its own entry
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
        // The comma and space both map to table ids (',' = 3, ' ' = 16).
        XCTAssertTrue(spaced.contains(3))
        XCTAssertTrue(spaced.contains(16))
        XCTAssertEqual(spaced.filter { $0 == 16 }.count, 3) // 2 gaps + 1 before '!'
    }

    func testEmptyPhonemesStillProduceWrappers() {
        XCTAssertEqual(KittenTokenizer.tokenize(""), [0, 10, 0])
    }

    func testCombiningMarksKeepBaseScalar() {
        // The reference iterates codepoints, so a base+mark cluster ("d" +
        // U+032A dental) keeps the base's id and drops the unknown mark.
        // A Character-keyed table would lose BOTH — the bug this locks out.
        // ('d' = 46; U+032A has no table entry.)
        XCTAssertEqual(KittenTokenizer.ids(for: "d̪").first, 46)
    }
}
