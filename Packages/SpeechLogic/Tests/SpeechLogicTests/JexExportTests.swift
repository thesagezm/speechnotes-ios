import XCTest
@testable import SpeechLogic

final class JexExportTests: XCTestCase {

    private static func hex(_ prefix: String) -> String {
        // 32 lowercase hex chars per Joplin id convention.
        String((prefix + String(repeating: "0", count: 32)).prefix(32))
    }

    private var notebook: JexExport.NotebookPayload {
        .init(
            id: Self.hex("aa11"),
            title: "Inbox",
            parentId: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var simpleNote: JexExport.NotePayload {
        .init(
            id: Self.hex("bb22"),
            title: "First note",
            markdownBody: "# Hello\n\nFirst paragraph.",
            notebookId: Self.hex("aa11"),
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
    }

    // MARK: - Tar framing

    func testArchiveHasUstarMagicAndEndsWithTwoZeroBlocks() {
        let data = JexExport.buildArchive(notes: [simpleNote], notebooks: [notebook])
        XCTAssertGreaterThan(data.count, 2048)
        // ustar magic at offset 257 in EVERY header we write.
        let magicRange = data.subdata(in: 257..<262)
        XCTAssertEqual(String(data: magicRange, encoding: .ascii), "ustar")
        // End-of-archive = 1024 zero bytes.
        let tail = data.suffix(1024)
        XCTAssertTrue(tail.allSatisfy { $0 == 0 })
    }

    func testArchiveContainsNotebookAndNoteEntries() {
        let data = JexExport.buildArchive(notes: [simpleNote], notebooks: [notebook])
        let text = String(decoding: data, as: UTF8.self)
        // Notebook entry
        XCTAssertTrue(text.contains("\(Self.hex("aa11")).md"))
        XCTAssertTrue(text.contains("Inbox"))
        XCTAssertTrue(text.contains("type_: 2"))
        // Note entry
        XCTAssertTrue(text.contains("\(Self.hex("bb22")).md"))
        XCTAssertTrue(text.contains("parent_id: \(Self.hex("aa11"))"))
        XCTAssertTrue(text.contains("markup_language: 1"))
        XCTAssertTrue(text.contains("type_: 1"))
    }

    func testTypeFieldIsLastInMetadataBlock() {
        let data = JexExport.buildArchive(notes: [simpleNote], notebooks: [notebook])
        let text = String(decoding: data, as: UTF8.self)
        // The Joplin importer splits the metadata block on the `type_` line;
        // anything after it would be treated as another entry header.
        guard let range = text.range(of: "type_: 1") else {
            XCTFail("note metadata block missing")
            return
        }
        let after = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(after.isEmpty || after.hasPrefix("\0"), "unexpected bytes after type_ marker")
    }

    func testOrphanedNoteIsDropped() {
        // A note pointing at a notebook not in the archive must not make it
        // into the tar — Joplin rejects dangling parent_id.
        let orphan = JexExport.NotePayload(
            id: Self.hex("cc33"),
            title: "orphan",
            markdownBody: "no parent",
            notebookId: Self.hex("dead"), // not in notebooks[]
            createdAt: Date(),
            updatedAt: Date()
        )
        let data = JexExport.buildArchive(notes: [orphan], notebooks: [notebook])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("orphan"))
        XCTAssertTrue(text.contains("Inbox"))
    }

    func testImageResourceRoundTrip() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 32)
        let image = JexExport.ImagePayload(
            id: Self.hex("dd44"),
            fileExtension: "png",
            mimeType: "image/png",
            data: png
        )
        let note = JexExport.NotePayload(
            id: Self.hex("bb22"),
            title: "with image",
            markdownBody: "![pic](:\(Self.hex("dd44")))",
            notebookId: Self.hex("aa11"),
            createdAt: Date(), updatedAt: Date(),
            images: [image]
        )
        let data = JexExport.buildArchive(notes: [note], notebooks: [notebook])
        let blob = data as NSData
        // Resource blob present under resources/
        let needle = "resources/\(Self.hex("dd44")).png".data(using: .utf8)!
        XCTAssertTrue(blob.range(of: needle, in: NSRange(location: 0, length: blob.length)).location != NSNotFound)
        // The PNG magic must appear verbatim in the tar body.
        let pngMagic = png.prefix(8)
        XCTAssertTrue(blob.range(of: pngMagic, in: NSRange(location: 0, length: blob.length)).location != NSNotFound)
        // And the resource metadata line went out too.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("mime: image/png"))
        XCTAssertTrue(text.contains("type_: 4"))
    }

    func testUTCISOFormattingWithMilliseconds() {
        // Joplin's importer accepts plain ISO-8601 but the millisecond form
        // matches what its own exporter writes.
        let secs = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970
        XCTAssertEqual(secs, 1_700_000_000)
        let text = JexExport.buildArchive(notes: [], notebooks: [notebook])
        let string = String(decoding: text, as: UTF8.self)
        XCTAssertTrue(string.contains("created_time: 2023-11-14T22:13:20.000Z"))
    }
}
