import XCTest
@testable import SpeechLogic

/// RTF reader tests — the escape battery the Linux `rtf.rs` suite pins
/// (hex escapes, codepages, `\u`/`\uc` fallback semantics). The chapter
/// conventions (bold-scope titles, chunking) ride in
/// DocumentBookRoundTripTests.
final class RtfParserTests: XCTestCase {

    private func joinedText(_ data: Data) throws -> String {
        try RtfParser.parse(archive: data).flatMap { chapter in
            chapter.blocks.compactMap { block in
                if case .paragraph(let text) = block { return text }
                return nil
            }
        }.joined()
    }

    func testHexEscapesAndTheDefaultCodepageDecode() throws {
        // \'e9 is é in cp1252 — the floor an RTF without \ansicpg uses.
        let text = try joinedText(Data("{\\rtf1 Caf\\'e9.}".utf8))
        XCTAssertTrue(text.contains("Café."), "\(text)")
    }

    func testAnAnsicpgNamesItsCodepage() throws {
        // "Привет" in windows-1251.
        var rtf = Data("{\\rtf1\\ansi\\ansicpg1251 ".utf8)
        rtf.append(contentsOf: [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2])
        rtf.append(Data(".}".utf8))
        let text = try joinedText(rtf)
        XCTAssertTrue(text.contains("Привет"), "\(text)")
    }

    func testUnicodeEscapesDecodeAndSwallowTheirFallback() throws {
        // \u8212? — an em dash with the `?` fallback consumed; \uc1 tells
        // the reader to skip the one ANSI byte after each escape. (The
        // reader used to consume the fallback bytes AT the \uc word,
        // which ate the text after a bare `\uc1 `.)
        let text = try joinedText(Data("{\\rtf1\\uc1 A\\u8212?B}".utf8))
        XCTAssertTrue(text.contains("A\u{2014}B"), "\(text)")
        XCTAssertFalse(text.contains("?"), "\(text)")
    }

    func testNegativeUnicodeEscapesDecodeAsTheirHighBMPCharacters() throws {
        // RTF spells characters over 32767 with a negative parameter —
        // the same bits re-read as i16. 汉 (U+6C49) arrives as
        // \u-37815. (The dropped-sign read this used to carry decoded
        // 37815 instead — a different character entirely — and the
        // low-32 scalar read dropped the character altogether.)
        let text = try joinedText(Data("{\\rtf1\\uc1 \\u-37815?}".utf8))
        XCTAssertTrue(text.contains("\u{6C49}"), "\(text)")
    }
}
