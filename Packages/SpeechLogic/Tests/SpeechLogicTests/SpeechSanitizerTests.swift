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

    func testPreservingOffsetsKeepsLineSeparatorsAsBreaks() {
        // U+2028/U+2029 are separators, not whitespace, so
        // Character.isWhitespace misses them — the sanitizer keeps them (and
        // clean() maps them to a newline) so the chunker's sentence
        // boundaries survive.
        let raw = "one\u{2028}two\u{2029}three"
        let cleaned = SpeechSanitizer.cleanedPreservingOffsets(raw)
        XCTAssertEqual(cleaned, raw)
        XCTAssertEqual(SpeechSanitizer.clean(raw), "one\ntwo\nthree")
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

    /// Emoji reach the phonemizer (it has no pronunciation for a pictograph
    /// and reads the character's name instead), so `clean` removes them.
    func testCleanDropsEmoji() {
        let raw = "Party \u{1F389} tonight \u{26A1} \u{2705} \u{274C} \u{2757} \u{2B50}"
        let cleaned = SpeechSanitizer.clean(raw)
        for symbol in ["\u{1F389}", "\u{26A1}", "\u{2705}", "\u{274C}", "\u{2757}", "\u{2B50}"] {
            XCTAssertFalse(cleaned.contains(symbol), "\(symbol) survived into speech text")
        }
        XCTAssertFalse(cleaned.contains("\u{FE0F}"), "variation selector survived")
    }

    /// The other half of the rule — a block-range implementation that strips
    /// "emoji" by codepoint range deletes content users type on purpose.
    /// Music notation, card suits, genetics and the dingbats-as-punctuation
    /// set are all ordinary note text.
    func testCleanKeepsProseSymbols() {
        let raw = "gen\n♀ ♂ ♯ ♭ ♪ ♫ ♠ ♥ ♦ ♣ ⚖ ⚗ ☎ ⚕ and ✓ ✗ ✔ ✖ ✂ \u{2764}"
        XCTAssertEqual(SpeechSanitizer.clean(raw), raw)
    }

    /// The astral-plane split the block-range version got wrong in both
    /// directions: pictures outside the astral emoji planes are dropped, prose
    /// symbols inside them are kept. 🎉 is U+1F389 and ⭐ is U+2B50 — both
    /// pictures; ♪ is U+266A and ✓ is U+2713 — neither is.
    func testEmojiIsAPropertyNotABlock() {
        XCTAssertTrue(SpeechSanitizer.isUnspeakable("\u{1F389}" as Unicode.Scalar))
        XCTAssertTrue(SpeechSanitizer.isUnspeakable("\u{2B50}" as Unicode.Scalar))
        XCTAssertFalse(SpeechSanitizer.isUnspeakable("\u{266A}" as Unicode.Scalar))
        XCTAssertFalse(SpeechSanitizer.isUnspeakable("\u{2713}" as Unicode.Scalar))
    }

    /// The import path stores the sanitizer's output as the note body, so an
    /// over-wide classification is DATA LOSS, not a speech quirk — this pins
    /// the exact case where a "strip the emoji blocks" implementation would
    /// have deleted the user's characters.
    func testCleanPreservesSymbolsForStorage() {
        let raw = "B major: \u{266F} then \u{2642}\u{2640} pair, \u{2660} suit"
        XCTAssertEqual(SpeechSanitizer.clean(raw), raw)
    }

    /// `cleanedPreservingOffsets` substitutes one scalar for one scalar, so
    /// the guarantee is per-scalar. An astral emoji is two UTF-16 units and
    /// becomes a one-unit space: the guarantee that holds is
    /// `unicodeScalars.count`, and a reader that indexes by UTF-16 must know
    /// that.
    func testPreservingOffsetsPreservesScalarCount() {
        let raw = "a\u{1F389}b\u{00AD}c"
        let cleaned = SpeechSanitizer.cleanedPreservingOffsets(raw)
        XCTAssertEqual(cleaned.unicodeScalars.count, raw.unicodeScalars.count)
        XCTAssertFalse(cleaned.contains("\u{1F389}"))
        XCTAssertEqual(cleaned.utf16.count, raw.utf16.count - 1,
                       "an astral scalar is 2 UTF-16 units and one scalar replaces it")
    }

    // MARK: - displaySafe (storage boundary, 2026-10-08)

    /// The stored note body is CONTENT, not speech text. The note-creation
    /// paths (import, clipboard, drop, JEX) store the sanitized result, so
    /// an emoji-stripping pass there was silent data loss — the device
    /// report of "number keycaps, colored circles and more not showing".
    /// displaySafe keeps every emoji class clean() strips.
    func testDisplaySafeKeepsEmoji() {
        // Keycap sequence, colored circle, diversity (base + skin tone),
        // flag pair, plain pictograph, VS-16 forms.
        let raw = "Priorities: 1\u{FE0F}\u{20E3} 2\u{FE0F}\u{20E3} 🔟\n"
            + "Status: 🔴 🟠 🟡 🟢\n"
            + "Thumbs: \u{1F44D}\u{1F3FB} \u{1F44D}\u{1F3FF}\n"
            + "Party \u{1F389} and \u{2705} done \u{274C} no \u{2B50} star"
        let safe = SpeechSanitizer.displaySafe(raw)
        XCTAssertEqual(safe, raw, "storage clean must not touch emoji content")
    }

    /// The other half of the storage contract: displaySafe still removes
    /// what no document should carry — control bytes, soft hyphens, bidi
    /// overrides, private-use glyphs. The zero-width JOINER is the one
    /// zero-width scalar kept: it is essential inside emoji compounds
    /// (family, profession sequences) and invisible everywhere else.
    func testDisplaySafeStillStripsControlJunk() {
        let raw = "Body\u{07}text with a soft\u{00AD}hyphen, \u{202E}bidi and \u{E000}pu"
        let safe = SpeechSanitizer.displaySafe(raw)
        XCTAssertFalse(safe.contains("\u{07}"))
        XCTAssertFalse(safe.contains("\u{00AD}"))
        XCTAssertFalse(safe.contains("\u{202E}"))
        XCTAssertFalse(safe.contains("\u{E000}"))
        XCTAssertTrue(safe.contains("Body text"),
                      "the replacement must not glue two words the source kept apart")
    }

    /// Idempotence: a second pass over stored text must be a no-op (the
    /// import paths may clean text that was already cleaned).
    func testDisplaySafeIsIdempotent() {
        let raw = "Clean \u{1F389} once 1\u{FE0F}\u{20E3} and \u{1F44D}\u{1F3FD} again"
        let once = SpeechSanitizer.displaySafe(raw)
        XCTAssertEqual(SpeechSanitizer.displaySafe(once), once)
    }

    /// The two contracts side by side: the SAME input, speech-cleaned on one
    /// side (emoji gone) and storage-cleaned on the other (emoji intact).
    func testSpeechVsStorageContractsDivergeExactlyOnEmoji() {
        let raw = "🟢 go \u{07} and \u{1F389} ok"
        let spoken = SpeechSanitizer.clean(raw)
        let stored = SpeechSanitizer.displaySafe(raw)
        XCTAssertFalse(spoken.contains("🟢"))
        XCTAssertTrue(stored.contains("🟢"))
        XCTAssertFalse(stored.contains("\u{07}"), "control bytes never survive storage")
    }
}
