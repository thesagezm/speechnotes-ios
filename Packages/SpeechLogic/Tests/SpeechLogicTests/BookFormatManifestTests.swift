import Foundation
import XCTest
@testable import SpeechLogic

/// The manifest's `format` field is a CROSS-PLATFORM contract: the Linux app
/// writes deck manifests with the file's own extension ("pptx", "odp", …)
/// and reads them back through its `is_slides()`. Every byte this side
/// writes must open there, and every byte written there must open here.
/// These tests pin the round-trip at the exact boundary.
final class BookFormatManifestTests: XCTestCase {
    private func roundTrip(_ format: BookFormat) throws -> String {
        let encoded = try JSONEncoder().encode([format])
        let decoded = try JSONDecoder().decode([BookFormat].self, from: encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first, format, "the round-trip must preserve the value")
        return String(decoding: encoded, as: UTF8.self)
    }

    func testLinuxWrittenDeckManifestDecodesAsSlides() throws {
        // What a Linux-written manifest.json carries for a deck book.
        let json = Data(#"{"format":"pptx"}"#.utf8)
        let wrapper = try JSONDecoder().decode(FormatWrapper.self, from: json)
        XCTAssertEqual(wrapper.format, .slides("pptx"))
        XCTAssertTrue(wrapper.format.isSlides)

        for ext in ["ppsx", "potx", "odp"] {
            let row = try JSONDecoder().decode(FormatWrapper.self, from: Data(#"{"format":"\#(ext)"}"#.utf8))
            XCTAssertEqual(row.format, .slides(ext), "\(ext) is a deck format on both platforms")
        }
    }

    func testIOSReEncodesDeckAsItsOwnExtension() throws {
        // iOS re-encodes the deck as the extension — never a Swift-only
        // spelling — so the Linux app's is_slides() matches the bytes.
        XCTAssertEqual(try roundTrip(.slides("pptx")), #"["pptx"]"#)
        XCTAssertEqual(try roundTrip(.slides("ppsx")), #"["ppsx"]"#)
        XCTAssertEqual(try roundTrip(.slides("potx")), #"["potx"]"#)
        XCTAssertEqual(try roundTrip(.slides("odp")), #"["odp"]"#)
    }

    func testClassicFormatsRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.epub), #"["epub"]"#)
        XCTAssertEqual(try roundTrip(.pdf), #"["pdf"]"#)
        XCTAssertEqual(try roundTrip(.audio), #"["audio"]"#)
    }

    func testLinuxWrittenDocumentManifestDecodesAsDocument() throws {
        // What a Linux-written manifest.json carries for a headless book —
        // import_document stamps the file's OWN extension (books.rs:1732).
        // Every member of the DocFamily must open as a document here.
        for ext in ["mobi", "azw", "azw3", "prc", "pdb", "fb2", "rtf",
                    "html", "htm", "htmlz", "txt", "text"] {
            let row = try JSONDecoder().decode(FormatWrapper.self, from: Data(#"{"format":"\#(ext)"}"#.utf8))
            XCTAssertEqual(row.format, .document(ext), "\(ext) is a headless document on both platforms")
            XCTAssertTrue(row.format.isDocument)
            XCTAssertEqual(row.format.fileExtension, ext)
        }
    }

    func testIOSWrittenDocumentReEncodesAsItsOwnExtension() throws {
        // iOS re-encodes the document as the extension — never a Swift-only
        // spelling — so the Linux app's DocFamily::from_extension matches
        // the bytes.
        XCTAssertEqual(try roundTrip(.document("mobi")), #"["mobi"]"#)
        XCTAssertEqual(try roundTrip(.document("azw3")), #"["azw3"]"#)
        XCTAssertEqual(try roundTrip(.document("fb2")), #"["fb2"]"#)
        XCTAssertEqual(try roundTrip(.document("htmlz")), #"["htmlz"]"#)
        XCTAssertEqual(try roundTrip(.document("txt")), #"["txt"]"#)
    }

    func testDocumentExtensionSetMatchesTheLinuxDocFamily() {
        // The decode set IS the cross-platform list — the Linux DocFamily
        // (bookdoc.rs DocFamily::from_extension) plus the Markdown spellings
        // iOS reads. If one side grows, the other must hear about it.
        for ext in BookFormat.documentExtensions {
            XCTAssertTrue(
                ["mobi", "azw", "azw3", "prc", "pdb", "fb2", "rtf",
                 "html", "htm", "htmlz", "txt", "text", "md", "markdown"].contains(ext),
                "\(ext) must be a Linux DocFamily spelling or a Markdown one"
            )
        }
    }

    func testUppercaseDocumentExtensionNormalizesToLowercase() throws {
        // Tolerant on read (a hand-edited or future manifest may carry
        // "MOBI"), canonical lowercase on write.
        let wrapper = try JSONDecoder().decode(FormatWrapper.self, from: Data(#"{"format":"MOBI"}"#.utf8))
        XCTAssertEqual(wrapper.format, .document("mobi"))
        XCTAssertEqual(try roundTrip(.document("mobi")), #"["mobi"]"#)
    }

    func testUppercaseExtensionNormalizesToLowercase() throws {
        // Tolerant on read (a hand-edited or future manifest may carry
        // "PPTX"), canonical lowercase on write.
        let wrapper = try JSONDecoder().decode(FormatWrapper.self, from: Data(#"{"format":"PPTX"}"#.utf8))
        XCTAssertEqual(wrapper.format, .slides("pptx"))
        XCTAssertEqual(try roundTrip(.slides("pptx")), #"["pptx"]"#)
    }

    func testUnknownFormatIsRejectedLoudly() {
        // A format neither side knows must FAIL the decode — a manifest that
        // silently decoded into a wrong shape would shelf a husk.
        XCTAssertThrowsError(try JSONDecoder().decode(FormatWrapper.self, from: Data(#"{"format":"docx"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(FormatWrapper.self, from: Data(#"{"format":"slides"}"#.utf8)))
    }

    private struct FormatWrapper: Codable {
        var format: BookFormat
    }
}
