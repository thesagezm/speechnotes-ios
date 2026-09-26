import XCTest
@testable import SpeechLogic

/// JEX IMPORT tests. The centerpiece is the round trip: everything
/// `JexExport.buildArchive` writes, `JexImport.parse` must read back —
/// that symmetry is the contract (the "fix importing the jex" report was
/// about the import side not existing at all).
final class JexImportTests: XCTestCase {

    private static func hex(_ prefix: String) -> String {
        String((prefix + String(repeating: "0", count: 32)).prefix(32))
    }

    private func exportFixture() -> Data {
        JexExport.buildArchive(
            notes: [
                .init(
                    id: Self.hex("bb22"),
                    title: "First note",
                    markdownBody: "# Hello\n\nFirst paragraph.\n\nSome body text.",
                    notebookId: Self.hex("aa11"),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    images: [
                        .init(
                            id: Self.hex("cc33"),
                            fileExtension: "png",
                            mimeType: "image/png",
                            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
                        )
                    ]
                ),
                .init(
                    id: Self.hex("dd44"),
                    title: "Unfiled note",
                    markdownBody: "No notebook here.",
                    notebookId: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_300),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_400)
                ),
            ],
            notebooks: [
                .init(id: Self.hex("aa11"), title: "Inbox", parentId: nil,
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            ]
        )
    }

    // MARK: - Round trip

    func testRoundTripNotesNotebooksAndResources() throws {
        let archive = try JexImport.parse(exportFixture())
        XCTAssertEqual(archive.notebooks.count, 1)
        XCTAssertEqual(archive.notes.count, 2)
        XCTAssertEqual(archive.resources.count, 1)

        let notebook = archive.notebooks[0]
        XCTAssertEqual(notebook.id, Self.hex("aa11"))
        XCTAssertEqual(notebook.title, "Inbox")

        let note = archive.notes.first { $0.id == Self.hex("bb22") }
        XCTAssertNotNil(note)
        XCTAssertEqual(note?.notebookId, Self.hex("aa11"))
        XCTAssertTrue(note?.body.contains("Some body text.") ?? false)
        XCTAssertEqual(note?.createdAt.timeIntervalSince1970 ?? 0, 1_700_000_100, accuracy: 1.0)
        XCTAssertEqual(note?.updatedAt.timeIntervalSince1970 ?? 0, 1_700_000_200, accuracy: 1.0)

        let unfiled = archive.notes.first { $0.id == Self.hex("dd44") }
        XCTAssertNotNil(unfiled)
        XCTAssertNil(unfiled?.notebookId)

        let resource = archive.resources.first { $0.id == Self.hex("cc33") }
        XCTAssertNotNil(resource)
        XCTAssertEqual(resource?.fileExtension, "png")
        XCTAssertEqual(resource?.data.count, 11)
    }

    func testRoundTripUUIDMapping() {
        // A UUID this app exported must come back as the same UUID.
        let original = UUID()
        let mapped = JexImport.uuid(fromJoplinId: JexExport.joplinId(original))
        XCTAssertEqual(mapped, original)
        // A foreign Joplin id (not a reconstitutable UUID) must NOT force
        // an id — the caller assigns a fresh one.
        XCTAssertNil(JexImport.uuid(fromJoplinId: "zz" + String(repeating: "9", count: 30)))
    }

    // MARK: - Real Joplin shape

    /// Joplin's own writer: body, blank line, metadata block, `type_` last —
    /// with the note body carrying `../resources/<id>.png` links.
    func testParsesJoplinWrittenEntry() throws {
        let id = Self.hex("ee55")
        let resourceId = Self.hex("ff66")
        let entry = """
        The note body.

        ![cover](../resources/\(resourceId).png)

        id: \(id)
        parent_id: \(Self.hex("aa11"))
        created_time: 2026-09-08T16:00:43.123Z
        updated_time: 2026-09-08T16:00:43.123Z
        markup_language: 1
        type_: 1
        """
        let data = tarArchive(entries: [
            ("\(id).md", Data(entry.utf8)),
            ("resources/\(resourceId).png", Data([0x89, 0x50, 0x4E, 0x47, 1, 2]))
        ])
        let archive = try JexImport.parse(data)
        XCTAssertEqual(archive.notes.count, 1)
        let note = archive.notes[0]
        XCTAssertEqual(note.id, id)
        XCTAssertTrue(note.body.contains("The note body."))
        XCTAssertEqual(note.resources[resourceId], "../resources/\(resourceId).png")
        XCTAssertEqual(archive.resources.count, 1)
        XCTAssertEqual(archive.resources[0].fileExtension, "png")
    }

    /// A folder entry: FIRST LINE is the title (Joplin's RAW format has no
    /// separate title line for folders).
    func testParsesFolderEntry() throws {
        let id = Self.hex("aa11")
        let entry = """
        Inbox

        id: \(id)
        created_time: 2026-09-08T16:00:43.000Z
        type_: 2
        """
        let data = tarArchive(entries: [("\(id).md", Data(entry.utf8))])
        let archive = try JexImport.parse(data)
        XCTAssertEqual(archive.notebooks.count, 1)
        XCTAssertEqual(archive.notebooks[0].id, id)
        XCTAssertEqual(archive.notebooks[0].title, "Inbox")
    }

    /// Resource metadata (type_ 4) supplies the mime when the file name has
    /// no extension — the import must still resolve an extension from the
    /// mime.
    func testResourceMetadataSuppliesMime() throws {
        let id = Self.hex("ff66")
        let meta = """
        id: \(id)
        title: \(id).png
        mime: image/png
        filename:
        created_time: 2026-09-08T16:00:43.123Z
        type_: 4
        """
        let data = tarArchive(entries: [
            ("\(id).md", Data(meta.utf8)),
            ("resources/\(id)", Data([0x89, 0x50, 0x4E, 0x47, 9]))
        ])
        let archive = try JexImport.parse(data)
        XCTAssertEqual(archive.resources.count, 1)
        XCTAssertEqual(archive.resources[0].fileExtension, "png")
        XCTAssertEqual(archive.resources[0].mime, "image/png")
    }

    // MARK: - Rejections

    func testRejectsNonTarData() {
        XCTAssertThrowsError(try JexImport.parse(Data("hello world this is not a tar".utf8))) { error in
            guard case JexImport.ImportError.notATar = error else {
                return XCTFail("expected notATar, got \(error)")
            }
        }
    }

    func testRejectsEmptyArchive() {
        // Valid tar framing (two zero blocks) but no entries.
        XCTAssertThrowsError(try JexImport.parse(Data(count: 1024))) { error in
            guard case JexImport.ImportError.notATar = error else {
                return XCTFail("expected notATar for zero-block payload, got \(error)")
            }
        }
    }

    // MARK: - Fixture builder

    /// Minimal ustar writer for hand-built archives (independent of
    /// JexExport so a bug there can't mask a bug here).
    private func tarArchive(entries: [(String, Data)]) -> Data {
        var out = Data()
        for (name, payload) in entries {
            var header = [UInt8](repeating: 0, count: 512)
            let nameBytes = Array(name.utf8)
            header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
            func octal(_ value: Int, at offset: Int, width: Int) {
                let s = String(value, radix: 8)
                let padded = String(repeating: "0", count: max(0, width - 1 - s.count)) + s
                let bytes = Array(padded.utf8)
                header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            }
            octal(0o644, at: 100, width: 8)
            octal(0, at: 108, width: 8)
            octal(0, at: 116, width: 8)
            octal(payload.count, at: 124, width: 12)
            octal(1_700_000_000, at: 136, width: 12)
            header[156] = UInt8(ascii: "0")
            let magic = Array("ustar\0".utf8)
            header.replaceSubrange(257..<(257 + magic.count), with: magic)
            // Checksum: field blanked with spaces while summing.
            for i in 148..<156 { header[i] = UInt8(ascii: " ") }
            var checksum = 0
            for b in header { checksum += Int(b) }
            octal(checksum, at: 148, width: 8)
            out.append(contentsOf: header)
            out.append(payload)
            let pad = (512 - (payload.count % 512)) % 512
            if pad > 0 { out.append(Data(count: pad)) }
        }
        out.append(Data(count: 1024))
        return out
    }
}
