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
        // ustar magic + version "00" at offset 257 in EVERY header — the
        // exact 8 bytes node-tar (Joplin's extractor) matches on.
        XCTAssertEqual(String(data: data.subdata(in: 257..<263), encoding: .ascii), "ustar\0")
        XCTAssertEqual(String(data: data.subdata(in: 263..<265), encoding: .ascii), "00")
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

    // MARK: - Joplin-visible entry shape

    /// The 2026-10-24 device report was "Joplin (mobile AND linux) refuses
    /// the export", and the 2026-10-25 follow-up traced it to the ENTRY
    /// LAYOUT, not the field set: Joplin's `BaseItem.serialize` writes
    /// `title\n\nbody\n\nprops` with NO trailing newline, and its parser
    /// (a) scans lines from the end and stops at the first blank line — a
    /// trailing newline makes it read zero props and abort the whole
    /// import; (b) takes the title from the FIRST body line and overwrites
    /// any `title:` prop; (c) never writes `title`/`body`/`markup_language`
    /// as props at all.
    func testNoteEntryUsesJoplinSerializeLayout() {
        let data = JexExport.buildArchive(notes: [simpleNote], notebooks: [notebook])
        let text = String(decoding: data, as: UTF8.self)
        // The title rides the first body line…
        XCTAssertTrue(text.contains("First note\n\n# Hello"), "title line must lead the note entry")
        // …NOT as a prop, and the old invented props are gone.
        XCTAssertFalse(text.contains("\ntitle: "))
        XCTAssertFalse(text.contains("markup_language"))
        // Timestamps stay (Joplin's importer fills its DB from these keys).
        XCTAssertTrue(text.contains("created_time: 2023-11-14T22:15:00.000Z"))
        XCTAssertTrue(text.contains("updated_time: 2023-11-14T22:16:40.000Z"))
        XCTAssertTrue(text.contains("user_created_time: 2023-11-14T22:15:00.000Z"))
        XCTAssertTrue(text.contains("user_updated_time: 2023-11-14T22:16:40.000Z"))
        // Folder entries: title line + updated_time (created value — this
        // app has no other folder timestamp).
        XCTAssertTrue(text.contains("Inbox\n\nid: \(Self.hex("aa11"))"))
        XCTAssertTrue(text.contains("\nupdated_time: 2023-11-14T22:13:20.000Z"))
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

    // MARK: - Joplin parser simulation

    /// Reimplements Joplin's `BaseItem.unserialize` semantics STRICTLY (no
    /// trailing-blank tolerance, non-prop line = error, missing type_ =
    /// error) and runs it over every `.md` entry of a built archive. This
    /// is the test that would have caught the "still cannot import" round:
    /// a real Joplin aborts the WHOLE import on the first entry whose
    /// props do not parse.
    func testEveryEntrySurvivesJoplinUnserialize() throws {
        let noteWithEmptyBody = JexExport.NotePayload(
            id: Self.hex("ee55"),
            title: "Empty",
            markdownBody: "   \n\n  ",
            notebookId: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 16)
        let noteWithImage = JexExport.NotePayload(
            id: Self.hex("ff66"),
            title: "With image",
            markdownBody: "pic: ![p](:\(Self.hex("dd44")))",
            notebookId: Self.hex("aa11"),
            createdAt: Date(), updatedAt: Date(),
            images: [.init(id: Self.hex("dd44"), fileExtension: "png", mimeType: "image/png", data: png)]
        )
        let data = JexExport.buildArchive(
            notes: [simpleNote, noteWithEmptyBody, noteWithImage],
            notebooks: [notebook]
        )

        for (name, payload) in tarEntries(data) where name.hasSuffix(".md") {
            let content = String(decoding: payload, as: UTF8.self)
            var props: [String: String] = [:]
            var type = 0
            var titleFromBody = ""
            var body = ""
            let lines = content.components(separatedBy: "\n")
            var bodyStart = -1
            var index = lines.count - 1
            while index >= 0 {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.isEmpty { bodyStart = index; break }
                // Joplin throws "Invalid property format" on a colon-less
                // line inside the props region — mirrored as a failure.
                guard let colon = line.firstIndex(of: ":") else {
                    XCTFail("\(name): colon-less line in props: \(line)")
                    return
                }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key == "type_" { type = Int(value) ?? 0 } else { props[key] = value }
                index -= 1
            }
            // Joplin throws "Missing required property: type_" → import aborts.
            XCTAssertNotEqual(type, 0, "\(name): type_ missing — Joplin aborts the import")
            if bodyStart > 0 {
                let bodyLines = Array(lines[0..<bodyStart])
                titleFromBody = bodyLines.first ?? ""
                // body.splice(0, 2): title + blank separator leave the body.
                body = bodyLines.count > 2 ? bodyLines[2...].joined(separator: "\n") : ""
            }
            // Joplin's id-format gate (a malformedItem skip, but a must).
            if let id = props["id"], !id.isEmpty {
                XCTAssertTrue(id.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
                              "\(name): id not 32-hex: \(id)")
            }
            switch type {
            case 1:
                XCTAssertEqual(titleFromBody, {
                    if name.hasPrefix(Self.hex("bb22")) { return "First note" }
                    if name.hasPrefix(Self.hex("ee55")) { return "Empty" }
                    return "With image"
                }(), "\(name): title must ride the first body line")
                if name.hasPrefix(Self.hex("ee55")) {
                    XCTAssertEqual(body, "", "an empty note exports an empty body")
                }
                if name.hasPrefix(Self.hex("bb22")) {
                    XCTAssertEqual(body, "# Hello\n\nFirst paragraph.", "\(name): body must follow title + blank")
                }
            case 2:
                XCTAssertEqual(titleFromBody, "Inbox")
            case 4:
                XCTAssertEqual(titleFromBody, "\(Self.hex("dd44")).png")
                XCTAssertEqual(props["file_extension"], "png")
            default:
                break
            }
        }
    }

    /// Minimal ustar reader for the parser simulation — independent of
    /// JexImport's so a bug there cannot mask a bug here.
    private func tarEntries(_ data: Data) -> [(String, Data)] {
        var entries: [(String, Data)] = []
        var cursor = 0
        while cursor + 512 <= data.count {
            let header = [UInt8](data.subdata(in: cursor..<(cursor + 512)))
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = String(bytes: header[0..<100].prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let sizeField = (String(bytes: header[124..<136].prefix(while: { $0 != 0 && $0 != UInt8(ascii: " ") }),
                                    encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
            let size = Int(sizeField, radix: 8) ?? 0
            cursor += 512
            if size > 0, cursor + size <= data.count {
                entries.append((name, data.subdata(in: cursor..<(cursor + size))))
            }
            cursor += (size + 511) / 512 * 512
        }
        return entries
    }
}
