import XCTest
@testable import SpeechLogic

/// Pins the Phonon Unigram tokenizer against the reference `tokenizers`
/// implementation: the fixture IS the hub's tokenizer.json, and every
/// expected id list was produced by
/// `Tokenizer.from_file(...).encode(text, add_special_tokens=False)` —
/// the exact ids the model was validated against.
final class PhononTokenizerTests: XCTestCase {

    private func makeTokenizer() throws -> PhononTokenizer {
        let url = Bundle.module.url(forResource: "phonon-tokenizer", withExtension: "json", subdirectory: "Fixtures")!
        return try PhononTokenizer(tokenizerData: try Data(contentsOf: url))
    }

    private struct Fixture: Decodable {
        let text: String
        let ids: [Int]
    }

    /// The 14 reference-verified cases: plain prose, punctuation, typographic
    /// quotes/dashes, accented letters, digits, off-alphabet symbols and
    /// emoji (byte fallback), whitespace collapse.
    func testEncodingMatchesReferenceIds() throws {
        let tokenizer = try makeTokenizer()
        let url = Bundle.module.url(forResource: "phonon-tokenizer-fixtures", withExtension: "json", subdirectory: "Fixtures")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 14)
        for fixture in fixtures {
            let ids = try tokenizer.encode(fixture.text)
            XCTAssertEqual(ids, fixture.ids, "ids diverge for «\(fixture.text)»")
        }
    }

    func testAudioSpecialsAreNeverEmittedFromUserText() throws {
        let tokenizer = try makeTokenizer()
        // Text that literally contains the control pieces must not inject
        // token 4/5/6 into the stream — those fall back to bytes.
        let ids = try tokenizer.encode("<|audio_bos|> <|audio_prompt|> <|audio_latent|>")
        XCTAssertFalse(ids.contains(PhononTokenizer.audioBosTokenID))
        XCTAssertFalse(ids.contains(PhononTokenizer.audioPromptTokenID))
        XCTAssertFalse(ids.contains(PhononTokenizer.audioLatentTokenID))
        XCTAssertFalse(ids.isEmpty)
    }

    func testEmptyAndWhitespaceOnlyEncodeToNothing() throws {
        let tokenizer = try makeTokenizer()
        XCTAssertEqual(try tokenizer.encode(""), [])
        XCTAssertEqual(try tokenizer.encode("   "), [])
        XCTAssertEqual(try tokenizer.encode("\n\t \n"), [])
    }

    func testTerminalPeriodAndCapitalizationAreNormalizerWork() throws {
        // The hub normalizer capitalizes the first letter and appends a final
        // period (steps 0-189 + the Alphabetic/N terminal period). The engine
        // hands the sanitizer's output straight in, so "hello world" must
        // encode the same ids as "Hello world." — the model never sees the
        // un-normalized form.
        let tokenizer = try makeTokenizer()
        XCTAssertEqual(try tokenizer.encode("hello world"), try tokenizer.encode("Hello world."))
    }

    func testDigitsAndCurrencySurviveByteFallback() throws {
        // The hub does NOT spell out currency/symbols (its known gap) —
        // "€5.50" must still encode deterministically via byte fallback,
        // never throw.
        let tokenizer = try makeTokenizer()
        let ids = try tokenizer.encode("It costs €5.50 today.")
        XCTAssertEqual(ids.count, 13)
        XCTAssertTrue(ids.allSatisfy { $0 >= 0 && $0 < 4001 })
    }
}
