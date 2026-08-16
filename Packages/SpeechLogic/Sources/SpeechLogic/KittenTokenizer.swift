// Generated 2026-08-16 from KittenML/KittenTTS kittentts/onnx_model.py
// (TextCleaner symbol table) — byte-exact port. Do not hand-edit the strings.

import Foundation

/// Phoneme → token-id mapping for KittenTTS models.
///
/// Kitten consumes IPA phonemes (espeak en-us style, with stress marks) —
/// the same dialect MisakiSwift's EnglishG2P emits for Kokoro. Unknown
/// characters are dropped, mirroring the reference implementation.
public enum KittenTokenizer {

    private static let pad = "$"
    private static let punctuation = ";:,.!?\u{a1}\u{bf}\u{2014}\u{2026}\"\u{ab}\u{bb}\"\" "
    private static let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    private static let ipa = "\u{251}\u{250}\u{252}\u{e6}\u{253}\u{299}\u{3b2}\u{254}\u{255}\u{e7}\u{257}\u{256}\u{f0}\u{2a4}\u{259}\u{258}\u{25a}\u{25b}\u{25c}\u{25d}\u{25e}\u{25f}\u{284}\u{261}\u{260}\u{262}\u{29b}\u{266}\u{267}\u{127}\u{265}\u{29c}\u{268}\u{26a}\u{29d}\u{26d}\u{26c}\u{26b}\u{26e}\u{29f}\u{271}\u{26f}\u{270}\u{14b}\u{273}\u{272}\u{274}\u{f8}\u{275}\u{278}\u{3b8}\u{153}\u{276}\u{298}\u{279}\u{27a}\u{27e}\u{27b}\u{280}\u{281}\u{27d}\u{282}\u{283}\u{288}\u{2a7}\u{289}\u{28a}\u{28b}\u{2c71}\u{28c}\u{263}\u{264}\u{28d}\u{3c7}\u{28e}\u{28f}\u{291}\u{290}\u{292}\u{294}\u{2a1}\u{295}\u{2a2}\u{1c0}\u{1c1}\u{1c2}\u{1c3}\u{2c8}\u{2cc}\u{2d0}\u{2d1}\u{2bc}\u{2b4}\u{2b0}\u{2b1}\u{2b2}\u{2b7}\u{2e0}\u{2e4}\u{2de}\u{2193}\u{2191}\u{2192}\u{2197}\u{2198}'\u{329}'\u{1d7b}"

    /// symbol → id, built exactly like the reference TextCleaner (first
    /// occurrence wins on duplicates).
    public static let vocabulary: [Character: Int] = {
        var dict: [Character: Int] = [:]
        for (index, symbol) in (pad + punctuation + letters + ipa).enumerated() {
            if dict[symbol] == nil {
                dict[symbol] = index
            }
        }
        return dict
    }()

    /// Start token prepended to every chunk.
    public static let bosToken = 0
    /// Tokens appended after the phonemes: ellipsis (id 10) then pad (id 0).
    public static let eosTokens = [10, 0]

    /// Mirrors the reference's `basic_english_tokenize` + `' '.join`:
    /// split into word/punctuation runs, re-join with single spaces.
    private static func regularizeSpacing(_ phonemes: String) -> String {
        var result = ""
        var current = ""
        var inWord = false
        for scalar in phonemes.unicodeScalars {
            let wordish = scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || scalar == "_"
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                continue  // spacing is re-inserted between runs
            }
            if wordish != inWord {
                if !current.isEmpty {
                    result += current
                    result += " "
                    current = ""
                }
                inWord = wordish
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { result += current }
        return result
    }

    /// Phonemes → token ids (no BOS/EOS added).
    public static func ids(for phonemes: String) -> [Int] {
        regularizeSpacing(phonemes).compactMap { vocabulary[$0] }
    }

    /// Full input sequence for the model: BOS + ids + EOS.
    public static func tokenize(_ phonemes: String) -> [Int] {
        [bosToken] + ids(for: phonemes) + eosTokens
    }
}
