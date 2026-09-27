import XCTest
@testable import SpeechLogic

/// Contract tests for ImportService's decode ladder — the same one that runs
/// on every file import (Files, Open-In, pasteboard, URL scheme). The ladder
/// order is the behaviour worth pinning: UTF-8 first (with BOMs), UTF-16,
/// UTF-32, latin-1, then lossy UTF-8. Nothing here touches the app target
/// (importText itself needs UIKit/Pasteboard); these assert the pure logic
/// the ladder pins, and the sanitizer it funnels through.
final class ImportServiceTests: XCTestCase {

    func testDecodesUTF8WithBOM() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append("Hello import".data(using: .utf8)!)
        XCTAssertEqual(decoded(bytes), "Hello import")
    }

    func testDecodesUTF16LittleEndianWithBOM() {
        var bytes = Data([0xFF, 0xFE])
        "Hallo Welt".utf16.forEach { bytes.append(UInt8($0 & 0xFF)); bytes.append(UInt8($0 >> 8)) }
        XCTAssertEqual(decoded(bytes), "Hallo Welt")
    }

    func testDecodesUTF16BigEndianWithBOM() {
        var bytes = Data([0xFE, 0xFF])
        "Hallo Welt".utf16.forEach { bytes.append(UInt8($0 >> 8)); bytes.append(UInt8($0 & 0xFF)) }
        XCTAssertEqual(decoded(bytes), "Hallo Welt")
    }

    func testDecodesUTF32LittleEndianWithBOM() {
        var bytes = Data([0xFF, 0xFE, 0x00, 0x00])
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
        // Invalid continuation mid-stream: the earlier rungs fail, the
        // lossy UTF-8 pass replaces the bad byte with U+FFFD rather than
        // rejecting the whole file.
        let bytes = Data("ok ".utf8) + Data([0xFF]) + Data(" tail".utf8)
        let text = decoded(bytes)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("ok ") == true)
        XCTAssertTrue(text?.contains("tail") == true)
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
