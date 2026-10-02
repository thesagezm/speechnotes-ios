import XCTest
@testable import SpeechLogic

/// Mobipocket reader tests.
///
/// The decompressor was validated against calibre's C implementation
/// (`cPalmdoc.decompress`) on eight real books before it was written, matching
/// every declared text length byte for byte. These tests build that same
/// structure by hand — a real Palm Database (header, record list, FAT-free
/// offsets) carrying a genuine PalmDOC stream — so the parts a real file
/// exercises (the record-offset list, the trailing-entry table, EXTH inside
/// record 0, the command-byte encoding) are all covered in CI without
/// shipping megabyte fixtures.
final class MobiParserTests: XCTestCase {

    // MARK: - Fixture builder

    /// A Palm Database with `records`, each holding `payload`. Record 0 is the
    /// header; records are laid out back to back after the 78-byte header plus
    /// the record list, which is the shape every real writer uses.
    private func makePDB(records: [Data]) -> Data {
        let listSize = records.count * 8
        let listEnd = 78 + listSize
        // Align the first record to a 4-byte boundary, as the format expects.
        var header = Data(count: 78)
        header.replaceSubrange(60..<64, with: Data("BOOK".utf8))
        header.replaceSubrange(64..<68, with: Data("MOBI".utf8))
        put(UInt16(records.count), at: 76, in: &header)

        var payload = Data()
        var offsets: [Int] = []
        var cursor = listEnd + 2 // +2 for the next-IDs list's terminating zero
        for record in records {
            offsets.append(cursor)
            // Records are contiguous bytes at their offset — NO per-record
            // checksum (an earlier draft prefixed [0,0] and had the reader
            // strip it; real files have no such bytes, so the reader was
            // fixed, and this fixture must mirror the format).
            payload.append(record)
            cursor += record.count
        }

        var list = Data(count: listSize)
        for (index, offset) in offsets.enumerated() {
            // Local list offsets — `78 + index * 8` would write at the PDB's
            // absolute offset into a listSize-byte buffer, and
            // replaceSubrange past endIndex is a runtime trap (signal 5).
            // The 78 lands in the concatenation below instead.
            put(UInt32(offset), at: index * 8, in: &list)
        }
        // The next-IDs list's terminating zero: exactly TWO bytes. (An
        // earlier draft allocated 2 and appended 2 more — 4 — which put
        // every record offset 2 bytes off; the bogus checksum strip used
        // to cancel it, and both were removed together.)
        let padding = Data(count: 2)
        return header + list + padding + payload
    }

    private func put(_ value: UInt16, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<offset + 2, with: withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    private func put(_ value: UInt32, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<offset + 4, with: withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    /// A MOBI6 header with an EXTH block (title/author) appended, as real
    /// books have it inside record 0.
    private func makeHeaderRecord(
        compression: UInt16 = 2,
        textLength: Int,
        textRecordCount: Int,
        recordSize: Int = 4096,
        encryption: UInt16 = 0,
        extraFlags: UInt16 = 0,
        exthTitle: String? = nil,
        exthAuthor: String? = nil,
        headerLength: Int = 232
    ) -> Data {
        // EXTH records are built with appends: the `put` helper wraps
        // Data.replaceSubrange, which TRAPS when the range extends past
        // endIndex — appending to fresh/4-byte Data that way is a runtime
        // crash (signal 5), not a write. (`put` stays for the in-bounds
        // fixed-offset fields below.)
        func appended(_ value: UInt32, to data: inout Data) {
            data.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Data($0) })
        }

        var entries: [Data] = []
        for (type, value) in [(503, exthTitle), (100, exthAuthor)] {
            guard let value, !value.isEmpty else { continue }
            var entry = Data()
            appended(UInt32(type), to: &entry)
            appended(UInt32(8 + value.utf8.count), to: &entry)
            entry.append(contentsOf: Array(value.utf8))
            entries.append(entry)
        }
        let exthPayloadBytes = entries.reduce(0) { $0 + $1.count }
        var exth = Data("EXTH".utf8)
        // The declared EXTH header length includes the 8 bytes after the
        // magic (magic 4 + length 4 + count 4 + entries — the "12 +" is not
        // an error; a real reader validates entries against it).
        appended(UInt32(12 + exthPayloadBytes), to: &exth)
        appended(UInt32(entries.count), to: &exth)
        for entry in entries { exth.append(entry) }

        // The fixed header is `headerLength` bytes; EXTH starts at
        // 16 + headerLength. Pad the header out to that length.
        var record = Data(count: 16 + headerLength)
        put(compression, at: 0, in: &record)
        put(UInt32(UInt32(textLength)), at: 4, in: &record)
        put(UInt16(UInt16(textRecordCount)), at: 8, in: &record)
        put(UInt16(UInt16(recordSize)), at: 10, in: &record)
        put(encryption, at: 12, in: &record)
        record.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        put(UInt32(UInt32(headerLength)), at: 20, in: &record)
        put(UInt32(2), at: 24, in: &record)            // type: a book
        put(UInt32(65001), at: 28, in: &record)        // codepage: UTF-8
        put(UInt32(6), at: 0x68, in: &record)          // mobi version 6
        if headerLength >= 0xE4, record.count >= 0xF4 {
            put(extraFlags, at: 0xF2, in: &record)
        }
        // The EXTH flag word at 0x80 tells a reader to look for the block.
        // (Spelled `UInt32` — a bare integer literal is ambiguous between the
        // UInt16 and UInt32 overloads, and the ambiguity only shows up in a
        // Swift 6 compiler, not in review.)
        put(UInt32(0x40), at: 0x80, in: &record)
        // The header keeps its full `headerLength` bytes — a real MOBI6
        // header is 232 bytes and EXTH follows it at 16 + headerLength. (An
        // earlier draft trimmed bytes 0x84..<248 to shrink the fixture,
        // which moved the EXTH block and broke the reader's primary
        // extraction path.)
        record.append(exth)
        return record
    }

    /// PalmDOC "compressed" bytes for text made only of literals and back
    /// references the way a real writer emits them. This is the encoding the
    /// decompressor was proven against.
    private func palmdocEncode(_ text: String) -> Data {
        var out = Data()
        // Emit everything as literal runs of up to 8 — valid input in every
        // command-byte case, and the round-trip is exact.
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let take = min(8, bytes.count - index)
            out.append(UInt8(take))
            out.append(contentsOf: bytes[index..<(index + take)])
            index += take
        }
        return out
    }

    private func sampleBook(textRecords: [String], extraFlags: UInt16 = 0) -> Data {
        let payloads = textRecords.map { palmdocEncode($0) }
        let declared = textRecords.joined().utf8.count
        let header = makeHeaderRecord(
            textLength: declared,
            textRecordCount: payloads.count,
            extraFlags: extraFlags
        )
        return makePDB(records: [header] + payloads)
    }

    // MARK: - Decompression

    func testLiteralBytesDecodeThemselves() {
        // '<' is 0x3C — a literal, NOT a flag byte with four back-references.
        // This single assertion is the whole reason the parser exists: every
        // widely-copied flag-byte decoder fails exactly here.
        let out = MobiParser.decompress(Data("<html><body>".utf8), compression: 2)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "<html><body>")
    }

    func testLiteralRunCommand() {
        // 8 then eight literals, then 3 and three more.
        var input = Data([8])
        input.append(contentsOf: Array("abcdefgh".utf8))
        input.append(3)
        input.append(contentsOf: Array("ijk".utf8))
        let out = MobiParser.decompress(input, compression: 2)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abcdefghijk")
    }

    func testSpacePlusAsciiShorthand() {
        // 0xC0-0xFF is the byte-pair form: ' ' then (byte ^ 0x80) —
        // 0xC1 → " A", 0xE9 → " i" (mobile-read wiki, PalmDOC).
        let out = MobiParser.decompress(Data([0xC1, 0xE9]), compression: 2)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), " A i")
    }

    func testBackReferenceRepeatsEarlierBytes() {
        // 'a' literal, then a back reference: distance 1, length 3 → "aaaa".
        // value = (distance << 3) | (length - 3) = (1 << 3) | 0 = 0x0008.
        // The high byte must be in 0x80...0xBF to be read as a reference.
        var input = Data([0x61])       // 'a' as a literal
        input.append(0x80)             // reference high byte
        input.append(0x08)             // distance 1, length 3
        let out = MobiParser.decompress(input, compression: 2)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "aaaa")
    }

    func testOutOfRangeBackReferenceIsSkippedNotClamped() {
        // A reference pointing before the start of the output must emit
        // nothing — clamping would splice unrelated bytes into the prose.
        var input = Data([0x61])       // one literal 'a'
        input.append(0x80)
        input.append(0x40)             // distance 8, way past the output
        let out = MobiParser.decompress(input, compression: 2)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "a")
    }

    func testUncompressedCompressionReturnsInput() {
        let input = Data("plain text".utf8)
        XCTAssertEqual(MobiParser.decompress(input, compression: 1), input)
        // 17480 ('DH', Huff/CDIC) is NOT a pass-through — parse() rejects it
        // as an unsupported variant rather than decoding its bitstream as
        // PalmDOC commands and producing noise.
    }

    // MARK: - Trailing entries

    func testTrailingEntryBytesAreStripped() {
        // extraFlags 3 = the multibyte overlap (0x1, nearest the text) plus
        // one backward-varint entry (0x2, toward the record's end). Real
        // record tails look exactly like this — calibre books end
        // `…<text> 00 81`: a 0x00 multibyte count (N = 0) and a one-byte
        // size varint 0x81 (high bit = terminator, value 1).
        //
        // Here the varint entry carries one data byte. Entries peel from the
        // END, and bit 0 (multibyte) sits nearest the text, so the byte
        // order is [text][multibyte][entry data][size varint]:
        var record = Data("body".utf8)
        record.append(0x00)   // multibyte count byte: N = (0x00 >> 1) & 3 = 0
        record.append(0x41)   // the entry's one data byte
        record.append(0x82)   // size varint: high bit set, value 2
        let cut = MobiParser.trailingEntryBytes(in: record, extraFlags: 3)
        XCTAssertEqual(cut, 3)
        XCTAssertEqual(String(decoding: record.prefix(record.count - cut), as: UTF8.self), "body")
    }

    func testZeroExtraFlagsMeansNoStripping() {
        let record = Data("body".utf8)
        XCTAssertEqual(MobiParser.trailingEntryBytes(in: record, extraFlags: 0), 0)
    }

    // MARK: - Whole-book parse

    func testParsesASingleRecordBook() throws {
        let html = "<html><body><p>The first line of prose.</p></body></html>"
        let book = try MobiParser.parse(book: sampleBook(textRecords: [html]))
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("The first line of prose."))
        XCTAssertNil(book.title)
        XCTAssertEqual(book.variant, "mobi6")
    }

    func testHeadingsBecomeTitledChapters() throws {
        let html = "<html><body>"
            + "<h1>Chapter One</h1><p>Alpha text.</p>"
            + "<h2>Chapter Two</h2><p>Beta text.</p>"
            + "</body></html>"
        let book = try MobiParser.parse(book: sampleBook(textRecords: [html]))
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter One", "Chapter Two"])
        XCTAssertEqual(book.chapters[0].text, "Alpha text.")
        XCTAssertEqual(book.chapters[1].text, "Beta text.")
    }

    func testDeepHeadingsStayInsideTheirChapter() throws {
        // h3 nests: the reader's contents list must not gain a row per h3.
        let html = "<html><body><h1>Part One</h1><p>Intro.</p>"
            + "<h3>A subsection</h3><p>Body of the subsection.</p></body></html>"
        let book = try MobiParser.parse(book: sampleBook(textRecords: [html]))
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].title, "Part One")
        XCTAssertTrue(book.chapters[0].text.contains("A subsection"))
        XCTAssertTrue(book.chapters[0].text.contains("Body of the subsection."))
    }

    func testMultiRecordTextConcatenates() throws {
        let book = try MobiParser.parse(book: sampleBook(textRecords: [
            "<html><body><h1>One</h1><p>First half.",
            "Second half.</p></body></html>",
        ]))
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("First half."))
        XCTAssertTrue(book.chapters[0].text.contains("Second half."))
    }

    func testExthMetadataBecomesTitleAndAuthor() throws {
        let html = "<html><body><p>Body.</p></body></html>"
        let header = makeHeaderRecord(
            textLength: html.utf8.count,
            textRecordCount: 1,
            exthTitle: "A Real Book",
            exthAuthor: "A Writer"
        )
        let pdb = makePDB(records: [header, palmdocEncode(html)])
        let book = try MobiParser.parse(book: pdb)
        XCTAssertEqual(book.title, "A Real Book")
        XCTAssertEqual(book.author, "A Writer")
    }

    func testEditorialMarkersAreStripped() throws {
        let html = "<html><body><p>[Illustration] The prose itself. [Pg 42]</p></body></html>"
        let book = try MobiParser.parse(book: sampleBook(textRecords: [html]))
        let text = book.chapters[0].text
        XCTAssertTrue(text.contains("The prose itself."))
        XCTAssertFalse(text.contains("[Illustration]"))
        XCTAssertFalse(text.contains("[Pg 42]"))
    }

    func testScriptAndStyleBodiesAreNeverRead() throws {
        let html = "<html><head><style>p { color: red }</style></head>"
            + "<body><p>Visible prose.</p></body></html>"
        let book = try MobiParser.parse(book: sampleBook(textRecords: [html]))
        let text = book.chapters.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Visible prose."))
        XCTAssertFalse(text.contains("color: red"))
    }

    func testSummaryIsFirstProse() throws {
        let html = "<html><body><h1>Title Here</h1><p>The opening sentence of the book.</p></body></html>"
        let book = try MobiParser.parse(book: sampleBook(textRecords: [html]))
        XCTAssertTrue(book.summary.hasPrefix("The opening sentence"))
    }

    // MARK: - Failures, honestly reported

    func testDRMLockedBookSaysSo() {
        let header = makeHeaderRecord(textLength: 10, textRecordCount: 1, encryption: 2)
        let pdb = makePDB(records: [header, Data("x".utf8)])
        XCTAssertThrowsError(try MobiParser.parse(book: pdb)) { error in
            guard case MobiParser.MobiError.unsupportedVariant(let message) = error else {
                return XCTFail("expected unsupportedVariant, got \(error)")
            }
            XCTAssertTrue(message.contains("DRM"), message)
        }
    }

    func testHuffCDICBookSaysSoRatherThanProducingNoise() {
        // 'DH' = 0x4448 = 17480 — the compression word IS the two ASCII
        // bytes, read big-endian.
        let header = makeHeaderRecord(compression: 17480, textLength: 10, textRecordCount: 1)
        let pdb = makePDB(records: [header, Data("x".utf8)])
        XCTAssertThrowsError(try MobiParser.parse(book: pdb)) { error in
            guard case MobiParser.MobiError.unsupportedVariant(let message) = error else {
                return XCTFail("expected unsupportedVariant, got \(error)")
            }
            XCTAssertTrue(message.contains("Huff/CDIC"), message)
        }
    }

    func testNonBookFileIsRejected() {
        XCTAssertThrowsError(try MobiParser.parse(book: Data("just some text".utf8)))
        XCTAssertThrowsError(try MobiParser.parse(book: Data()))
        // A ZIP named .mobi: the type/creator check catches it.
        var zipLike = Data(repeating: 0x50, count: 200)
        zipLike.replaceSubrange(60..<64, with: Data("BOOK".utf8))
        zipLike.replaceSubrange(64..<68, with: Data("ZIPS".utf8))
        XCTAssertThrowsError(try MobiParser.parse(book: zipLike))
    }

    func testHeaderClaimingMoreRecordsThanExistThrows() {
        let header = makeHeaderRecord(textLength: 10, textRecordCount: 5)
        let pdb = makePDB(records: [header, Data("x".utf8)])
        XCTAssertThrowsError(try MobiParser.parse(book: pdb))
    }

    // MARK: - Sniffing

    func testLooksLikeMobi() throws {
        let book = sampleBook(textRecords: ["<p>x</p>"])
        XCTAssertTrue(MobiParser.looksLikeMobi(book.prefix(200)))
        XCTAssertFalse(MobiParser.looksLikeMobi(Data("not a book".utf8)))
        XCTAssertFalse(MobiParser.looksLikeMobi(Data()))
    }
}
