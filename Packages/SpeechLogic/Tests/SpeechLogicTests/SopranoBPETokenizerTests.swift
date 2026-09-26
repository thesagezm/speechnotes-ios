import XCTest
@testable import SpeechLogic

/// Pins the Swift BPE port to the reference algorithm over Soprano-1.1's
/// real tokenizer. The expected ids below were generated with the reference
/// pre-tokenize/merge procedure (Python, over the actual tokenizer.json:
/// vocab 8192, 135 merges) — any drift in the Swift pre-tokenizer, digit
/// splitting or merge ranking breaks a fixture.
final class SopranoBPETokenizerTests: XCTestCase {

    /// The pieces the fixtures reach, with their REAL ids from
    /// KevinAHM/soprano-1.1-onnx tokenizer.json, plus the specials.
    private static let vocab: [String: Int] = [
        "[UNK]": 0, "[TEXT]": 1, "[START]": 2, "[STOP]": 3,
        "this": 8108, " ": 8004, "is": 8069, "the": 8063, "so": 8081,
        "p": 8046, "r": 8048, "an": 8061, "o": 8045, "s": 8049,
        "i": 8039, "ke": 8078, "t": 8050, "e": 8035, "st": 8073,
        ",": 8013, "un": 8149, "n": 8044, "ing": 8067, "f": 8036,
        "u": 8051, "ll": 8070, "y": 8055, "of": 8099, "l": 8042,
        "in": 8058, ".": 8015, "4": 8021, "2": 8019, "a": 8031,
        "le": 8082, "at": 8062, "$": 8007, "5": 8022, "he": 8077,
        "w": 8053, "or": 8076, "ld": 8139, "it": 8066, "'": 8010,
        "q": 8047, "ic": 8133, "k": 8041, "b": 8032, "ro": 8129,
        "x": 8054, "ju": 8128, "m": 8043, "ver": 8132, "z": 8056,
        "do": 8094, "g": 8037,
    ]

    /// All 135 merge pairs, in the file's rank order.
    private static let merges: [[String]] = [
        ["t", "h"], ["i", "n"], ["o", "u"], ["r", "e"], ["a", "n"], ["a", "t"],
        ["th", "e"], ["y", "ou"], ["o", "n"], ["i", "t"], ["in", "g"], ["m", "e"],
        ["i", "s"], ["l", "l"], ["t", "o"], ["e", "r"], ["s", "t"], ["n", "o"],
        ["a", "y"], ["o", "r"], ["h", "e"], ["k", "e"], ["s", "e"], ["v", "e"],
        ["s", "o"], ["l", "e"], ["g", "o"], ["th", "at"], ["b", "e"], ["l", "i"],
        ["w", "e"], ["an", "d"], ["h", "a"], ["w", "h"], ["a", "ll"], ["a", "s"],
        [".", "."], ["d", "o"], ["li", "ke"], ["c", "h"], ["a", "r"], ["o", "k"],
        ["o", "f"], ["m", "y"], ["y", "e"], ["e", "n"], ["g", "h"], ["o", "h"],
        ["l", "o"], ["u", "t"], ["a", "l"], ["th", "is"], ["f", "or"], ["wh", "at"],
        ["e", "d"], ["r", "i"], ["th", "an"], ["c", "o"], ["a", "c"], ["i", "d"],
        ["no", "w"], ["than", "k"], ["ok", "ay"], ["h", "o"], ["g", "e"], ["all", "y"],
        ["a", "h"], ["gh", "t"], ["e", "s"], ["w", "as"], ["ye", "ah"], ["j", "u"],
        ["r", "o"], ["d", "on"], ["ha", "ve"], ["v", "er"], ["i", "c"], ["a", "d"],
        ["ju", "st"], ["o", "d"], ["a", "re"], ["a", "m"], ["l", "d"], ["..", "."],
        ["c", "an"], ["u", "p"], ["on", "e"], ["no", "t"], ["l", "y"], ["k", "now"],
        ["w", "i"], ["a", "b"], ["u", "n"], ["t", "i"], ["i", "f"], ["ou", "t"],
        ["n", "e"], ["ge", "t"], ["b", "ut"], ["the", "re"], ["m", "o"], ["g", "u"],
        ["n", "a"], ["he", "re"], ["an", "t"], ["ri", "ght"], ["p", "e"], ["i", "r"],
        ["c", "a"], ["u", "se"], ["r", "y"], ["in", "k"], ["s", "u"], ["re", "ally"],
        ["so", "me"], ["d", "e"], ["wi", "th"], ["t", "u"], ["you", "r"], ["h", "i"],
        ["ou", "ld"], ["r", "a"], ["go", "od"], ["d", "id"], ["m", "u"], ["th", "ing"],
        ["go", "t"], ["g", "on"], ["w", "ant"], ["w", "ay"], ["m", "a"], ["ho", "w"],
        ["the", "y"], ["gon", "na"], ["p", "l"],
    ]

    private static let tokenizer = SopranoBPETokenizer(vocab: vocab, merges: merges)!

    /// The exact ids the reference algorithm produces for these inputs.
    func testReferenceFixtures() {
        let cases: [(String, [Int])] = [
            ("This is the Soprano spike test, running fully offline.", [
                8108, 8004, 8069, 8004, 8063, 8004, 8081, 8046, 8048, 8061, 8045,
                8004, 8049, 8046, 8039, 8078, 8004, 8050, 8035, 8073, 8013, 8004,
                8048, 8149, 8044, 8067, 8004, 8036, 8051, 8070, 8055, 8004, 8099,
                8036, 8042, 8058, 8035, 8015,
            ]),
            ("42 apples at $5.", [
                8021, 8019, 8004, 8031, 8046, 8046, 8082, 8049, 8004, 8062,
                8004, 8007, 8022, 8015,
            ]),
            ("Hello world, it's a test.", [
                8077, 8070, 8045, 8004, 8053, 8076, 8139, 8013, 8004, 8066,
                8010, 8049, 8004, 8031, 8004, 8050, 8035, 8073, 8015,
            ]),
            ("The quick brown fox jumps over the lazy dog.", [
                8063, 8004, 8047, 8051, 8133, 8041, 8004, 8032, 8129, 8053,
                8044, 8004, 8036, 8045, 8054, 8004, 8128, 8043, 8046, 8049,
                8004, 8045, 8132, 8004, 8063, 8004, 8042, 8031, 8056, 8055,
                8004, 8094, 8037, 8015,
            ]),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(Self.tokenizer.encode(text), expected, "encoding drifted for: \(text)")
        }
    }

    /// Characters with no pieces in the vocab become [UNK] (0), never crash
    /// and never disappear — the model decides what to do with them.
    func testUnknownCharactersMapToUNK() {
        XCTAssertEqual(Self.tokenizer.encode("语"), [0])
    }

    /// Digits(individual_digits: true) — every digit stands alone, the rest
    /// of the run stays together.
    func testDigitsSplitIndividually() {
        XCTAssertEqual(SopranoBPETokenizer.splitDigits(in: "abc123def"), ["abc", "1", "2", "3", "def"])
    }

    /// The export's pre_tokenizer Split: `\s+|\w+|[^\w\s]+`, every piece kept.
    func testPreTokenizerSplitsWordsWhitespaceSymbols() {
        XCTAssertEqual(
            SopranoBPETokenizer.preTokens(in: "Well — said: it's."),
            ["Well", " ", "—", " ", "said", ":", " ", "it", "'", "s", "."]
        )
    }

    /// make(from:) accepts both HF merge encodings.
    func testMakeFromTokenizerJSON() {
        let json: [String: Any] = [
            "model": [
                "vocab": ["a": 5, "b": 6, "ab": 7, "[UNK]": 0],
                "merges": [["a", "b"]],
            ] as [String: Any]
        ]
        let tokenizer = SopranoBPETokenizer.make(from: json)
        XCTAssertNotNil(tokenizer)
        XCTAssertEqual(tokenizer?.encode("ab"), [7])
    }
}
