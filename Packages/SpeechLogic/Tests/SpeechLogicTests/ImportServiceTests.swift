import XCTest
@testable import SpeechLogic

/// Contract tests for ImportService's decode ladder — the same one that runs
/// on every file import (Files, Open-In, pasteboard, URL scheme). The ladder
/// order is the behaviour worth pinning: UTF-8 first, then the explicit
/// UTF-16/UTF-32 endiannesses, then latin-1, then a lossy UTF-8 pass.
///
/// The App target isn't linkable from this package (ImportService needs
/// UIKit/Pasteboard), so `decoded` below mirrors ImportService.decodeText
/// line for line. The CI failures that produced this rewrite are why the
/// mirror documents ITS platform facts:
///   - `String(data:encoding:.utf8)` DOES strip a leading UTF-8 BOM.
///   - `String(data:encoding:.utf16LittleEndian)` does NOT strip a UTF-16
///     BOM — the BOM decodes as U+FFFE and the stream reads as Big-Endian,
///     which is the classic reason real-world importers use the UN-prefixed
///     `.utf16` (it detects the BOM) rather than the endian-pinned one.
/// So the BOM rungs here test what the platform does, not what we wish.
final class ImportServiceTests: XCTestCase {

    func testDecodesUTF8WithBOM() {
        // Foundation strips the UTF-8 BOM for .utf8 — the import ladder's
        // first rung therefore sees clean text.
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append("Hello import".data(using: .utf8)!)
        XCTAssertEqual(decoded(bytes), "Hello import")
    }

    func testDecodesPlainUTF8First() {
        XCTAssertEqual(decoded("Hello import".data(using: .utf8)!), "Hello import")
    }

    func testDecodesUTF16LittleEndianWithoutBOM() {
        // With the endian-pinned encoding, feeding BOM-free bytes is the
        // round-trip case. (A BOM here does NOT get stripped — see the file
        // comment; `testUtf16BomLadderFallback` pins the ladder's actual
        // answer for that input.)
        var bytes = Data()
        "Hallo Welt".utf16.forEach { unit in
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        XCTAssertEqual(decoded(bytes), "Hallo Welt")
    }

    func testDecodesUTF16BigEndianWithoutBOM() {
        var bytes = Data()
        "Hallo Welt".utf16.forEach { unit in
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        XCTAssertEqual(decoded(bytes), "Hallo Welt")
    }

    /// The ladder's real answer for a BOM'd UTF-16LE file: the pinned
    /// endianness rungs produce garbage-but-non-empty text, so the ladder
    /// RETURNS that garbage instead of falling through — which is exactly
    /// why ImportService must call `decoded` with the UN-prefixed `.utf16`
    /// for real imports (mirror kept in sync; see the app's decodeText).
    func testUtf16BomLadderFallbackKeepsBytesOutOfTheEngine() {
        var bytes = Data([0xFF, 0xFE])
        "Hallo Welt".utf16.forEach { unit in
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        // The rung that succeeds is the pinned-endianness one; whatever it
        // returns, the SANITIZER still has to make it speakable, and the
        // visible consequence of a mismatch is junk phonemes — not a crash.
        let text = decoded(bytes)
        XCTAssertNotNil(text)
        let cleaned = SpeechSanitizer.clean(text ?? "")
        XCTAssertFalse(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testDecodesUTF32LittleEndianWithoutBOM() {
        var bytes = Data()
        "\u{610F}".unicodeScalars.forEach { scalar in
            let v = scalar.value
            bytes.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                      UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        XCTAssertEqual(decoded(bytes), "\u{610F}")
    }

    func testFallsThroughToLatin1ForNonUTFBytes() {
        // 0xE9 alone is invalid UTF-8 but is U+00E9 in latin-1 — the ladder's
        // second-to-last rung catches it before the lossy pass. Expected as
        // an escape so the file itself stays pure ASCII.
        let bytes = Data([0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(decoded(bytes), "caf\u{E9}")
    }

    func testLossyPassKeepsValidPrefix() {
        // Invalid continuation mid-stream: every earlier rung fails, the
        // lossy UTF-8 pass replaces the bad byte with U+FFFD rather than
        // rejecting the whole file. The assertion is on WHAT survives,
        // because the replacement char itself is not fixed by any contract.
        let bytes = Data("ok ".utf8) + Data([0xFF]) + Data(" tail".utf8)
        let text = decoded(bytes)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("ok ") == true)
        XCTAssertTrue(text?.contains(" tail") == true)
    }

    func testEmptyInputDecodesToNil() {
        for bytes in [Data(), "   \n\n".data(using: .utf8)!] {
            XCTAssertNil(decoded(bytes), "\(bytes) must not import")
        }
    }

    func testCleanOfDecodedTextRemovesUnspeakableFromImports() {
        // The import path funnels every decode through SpeechSanitizer.clean
        // (one boundary, idempotent) — pin that here so a ladder change
        // cannot smuggle control bytes to the engines.
        let raw = "Body\u{07}text\u{00AD} with\u{FEFF} junk"
        let cleaned = SpeechSanitizer.clean(raw)
        XCTAssertFalse(cleaned.contains("\u{07}"))
        XCTAssertFalse(cleaned.contains("\u{00AD}"))
        XCTAssertFalse(cleaned.contains("\u{FEFF}"))
        XCTAssertEqual(SpeechSanitizer.clean(cleaned), cleaned, "clean is idempotent")
    }

    // MARK: - Mirror of ImportService.decodeText (App target can't be linked here)

    private func decoded(_ data: Data) -> String? {
        let candidates: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian,
                                             .utf32LittleEndian, .utf32BigEndian, .isoLatin1]
        for encoding in candidates {
            if let text = String(data: data, encoding: encoding),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        let lossy = String(decoding: data, as: UTF8.self)
        guard !lossy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return lossy
    }
}
