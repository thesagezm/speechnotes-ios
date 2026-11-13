import XCTest
@testable import SpeechLogic

/// The MOBI/KF8 chapter index, built in the layout the format actually
/// ships — numeric TAGX tag codes, VWI-encoded values, CNCX label runs —
/// and the chapter cut that consumes it.
///
/// These fixtures exist because the first index reader parsed an INVENTED
/// layout (name-length-prefixed tag "names", fixed-slot CNCX records) that
/// no real writer emits: on every real book the reader returned empty and
/// the publisher's contents page was silently lost (chapters fell back to
/// h1/flow titles, "Chapter N" for books that style their headings). The
/// bytes here are the spec's own — KindleUnpack/mobiunpack's mobi_index
/// layout, byte for byte — so a regression that stops matching real books
/// fails in CI instead of on a shelf.
final class MobiIndexTests: XCTestCase {

    // MARK: - Byte helpers

    /// VWI encoding: 7 bits per byte, big-endian, terminated by the byte with
    /// the high bit set — the inverse of `MobiParser.vwi`.
    private func vwiBytes(_ value: Int) -> [UInt8] {
        precondition(value >= 0)
        var groups: [UInt8] = []
        var rest = value
        repeat {
            groups.insert(UInt8(rest & 0x7F), at: 0)
            rest >>= 7
        } while rest > 0
        groups[groups.count - 1] |= 0x80
        return groups
    }

    private func put(_ value: UInt16, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<offset + 2, with: withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    private func put(_ value: UInt32, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<offset + 4, with: withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    private func palmdocEncode(_ text: String) -> Data {
        // Literal-run PalmDOC stream — the encoding the decompressor was
        // validated against (every command is a literal run; round-trip exact).
        var out = Data()
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

    private func occurrences(of pattern: [UInt8], in bytes: [UInt8]) -> [Int] {
        guard pattern.count <= bytes.count else { return [] }
        var out: [Int] = []
        for start in 0...(bytes.count - pattern.count) {
            if Array(bytes[start..<(start + pattern.count)]) == pattern {
                out.append(start)
            }
        }
        return out
    }

    // MARK: - Fixture builders

    /// A Palm Database carrying `records` back to back — the same shape
    /// MobiParserTests builds (header + record list + contiguous payloads).
    private func makePDB(records: [Data]) -> Data {
        let listSize = records.count * 8
        let listEnd = 78 + listSize
        var header = Data(count: 78)
        header.replaceSubrange(60..<64, with: Data("BOOK".utf8))
        header.replaceSubrange(64..<68, with: Data("MOBI".utf8))
        put(UInt16(records.count), at: 76, in: &header)

        var payload = Data()
        var offsets: [Int] = []
        var cursor = listEnd + 2
        for record in records {
            offsets.append(cursor)
            payload.append(record)
            cursor += record.count
        }
        var list = Data(count: listSize)
        for (index, offset) in offsets.enumerated() {
            put(UInt32(offset), at: index * 8, in: &list)
        }
        return header + list + Data(count: 2) + payload
    }

    /// A MOBI header record (compression 2, UTF-8) — the fields the parser
    /// reads; the rest is zero-filled the way test-corpus writers leave it.
    private func makeHeaderRecord(textLength: Int, textRecordCount: Int, version: UInt32) -> Data {
        var record = Data(count: 16 + 232)
        put(UInt16(2), at: 0, in: &record)                              // PalmDOC compression
        put(UInt32(UInt32(textLength)), at: 4, in: &record)
        put(UInt16(UInt16(textRecordCount)), at: 8, in: &record)
        put(UInt16(4096), at: 10, in: &record)
        record.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        put(UInt32(232), at: 20, in: &record)
        put(UInt32(65001), at: 28, in: &record)                         // UTF-8
        put(version, at: 0x68, in: &record)                             // 6 = mobi6, 8 = KF8
        return record
    }

    /// A real-format chapter INDX: 0x18-byte header, TAGX with numeric
    /// [code][values] pairs (tag 1 = the entry's filepos + length, tag 2 =
    /// one value), then `entries` — each as (offset, length) into the text.
    private func makeINDX(entries: [(offset: Int, length: Int)]) -> Data {
        var record = Data("INDX".utf8)
        func append(_ value: UInt32) {
            record.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Data($0) })
        }
        // Header: length 0x18, unknown, type 0, idxt encode 4, entry count,
        // encoding — the parser reads header length (0x04) and count (0x10).
        append(UInt32(0x18))
        append(UInt32(0xFFFF_FFFF))
        record.append(contentsOf: [0x00, 0x00, 0x00, 0x04])              // type + idxt encode
        append(UInt32(entries.count))
        append(UInt32(1252))
        while record.count < 0x18 { record.append(0) }
        // TAGX: 2 tags, 1 control byte per entry, then [01 02][02 01].
        record.append(contentsOf: Data("TAGX".utf8))
        record.append(2)                                                 // tag count
        record.append(1)                                                 // control byte count
        record.append(contentsOf: [0x01, 0x02, 0x02, 0x01])
        // Entries: control byte (all tags apply — zero) + tag values.
        for entry in entries {
            record.append(0x00)
            record.append(contentsOf: vwiBytes(entry.offset))
            record.append(contentsOf: vwiBytes(entry.length))
            record.append(contentsOf: vwiBytes(entry.length))            // tag 2: any value
        }
        return record
    }

    /// A CNCX record: magic, then one [VWI length][label bytes] pair per
    /// label, in entry order.
    private func makeCNCX(labels: [String]) -> Data {
        var record = Data("CNCX".utf8)
        for label in labels {
            let bytes = Array(label.utf8)
            record.append(contentsOf: vwiBytes(bytes.count))
            record.append(contentsOf: bytes)
        }
        return record
    }

    /// A MOBI6 book whose text is `text` (single record) and whose chapter
    /// index names `labels` at the given raw offsets.
    private func makeIndexedBook(text: String, labels: [String], offsets: [Int]) -> Data {
        let header = makeHeaderRecord(textLength: text.utf8.count, textRecordCount: 1, version: 6)
        let stream = palmdocEncode(text)
        let index = makeINDX(entries: offsets.map { ($0, 10) })
        let cncx = makeCNCX(labels: labels)
        return makePDB(records: [header, stream, index, cncx])
    }

    private let chapterText =
        "<h1>Alpha</h1><p>Alpha prose.</p><mbp:pagebreak/>"
        + "<h1>Beta</h1><p>Beta prose.</p><mbp:pagebreak/>"
        + "<h1>Gamma</h1><p>Gamma prose.</p>"

    /// Byte offsets of the three `<h1` opens in the raw UTF-8 stream.
    private var chapterOffsets: [Int] {
        occurrences(of: Array("<h1".utf8), in: Array(chapterText.utf8))
    }

    // MARK: - Low-level readers

    func testVwiDecodesSpecEncoding() {
        let data = Data([0x81, 0x02, 0xAC, 0x80])
        // 0x81 terminates (high bit set) → 1.
        XCTAssertEqual(MobiParser.vwi(data, at: 0)?.value, 1)
        XCTAssertEqual(MobiParser.vwi(data, at: 0)?.next, 1)
        // 0x02 continues, 0xAC terminates → (2 << 7) | 0x2C = 300.
        XCTAssertEqual(MobiParser.vwi(data, at: 1)?.value, 300)
        XCTAssertEqual(MobiParser.vwi(data, at: 1)?.next, 3)
        // 0x80 is a bare zero.
        XCTAssertEqual(MobiParser.vwi(data, at: 3)?.value, 0)
        // Five continuation bytes never terminate within the bound → nil.
        XCTAssertNil(MobiParser.vwi(Data([0x01, 0x01, 0x01, 0x01, 0x01, 0x81]), at: 0))
    }

    func testIndexTagxReadsNumericTagTable() {
        let record = makeINDX(entries: [(0, 10), (20, 10)])
        guard let (controlByteCount, tags, entriesStart) = MobiParser.indexTagx(in: record) else {
            return XCTFail("TAGX not parsed")
        }
        XCTAssertEqual(controlByteCount, 1)
        XCTAssertEqual(tags, [MobiParser.IndexTag(code: 1, values: 2), MobiParser.IndexTag(code: 2, values: 1)])
        XCTAssertEqual(entriesStart, 0x22)
        let entries = MobiParser.indexEntries(
            in: record, controlByteCount: controlByteCount, tags: tags, entriesStart: entriesStart
        )
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?[0][1], [0, 10])
    }

    func testSkeletonWidthIsRejected() {
        // The KF8 skeleton INDX carries a much longer header (0xAA) and chunk
        // sizes rather than TOC rows — the width gate must skip it so the
        // scan reaches the orthogonal chapter index behind it.
        var skeleton = makeINDX(entries: [(0, 10), (20, 10)])
        put(UInt32(0xAA), at: 4, in: &skeleton)
        XCTAssertNil(MobiParser.indexTagx(in: skeleton))
    }

    func testLabelLooksLikeTextRejectsGarbage() {
        XCTAssertTrue(MobiParser.labelLooksLikeText("Part I — Dawn"))
        XCTAssertTrue(MobiParser.labelLooksLikeText("1. The Garden"))
        XCTAssertFalse(MobiParser.labelLooksLikeText(""))
        XCTAssertFalse(MobiParser.labelLooksLikeText(String(repeating: "\u{01}", count: 40)))
        XCTAssertFalse(MobiParser.labelLooksLikeText(String(repeating: "a", count: 600)))
    }

    // MARK: - The real-format index on a whole book (MOBI6)

    func testRealFormatIndexYieldsPublisherTOCAndCut() throws {
        let labels = ["Dawn", "Noon", "Dusk"]
        let offsets = chapterOffsets
        XCTAssertEqual(offsets.count, 3)
        let book = try MobiParser.parse(book: makeIndexedBook(
            text: chapterText, labels: labels, offsets: offsets
        ))
        // The publisher's TOC survives into the book — the field the first
        // reader always left empty on real files.
        XCTAssertEqual(book.toc.map(\.label), labels)
        XCTAssertEqual(book.toc.map(\.offset), offsets)
        // And the chapter cut follows it: the publisher's labels win over the
        // h1 echoes, and the pagebreaks between chapters do NOT drift the
        // offsets (the cut is on the raw stream's coordinates).
        XCTAssertEqual(book.chapters.map(\.title), labels)
        XCTAssertEqual(book.chapters.map(\.text), ["Alpha prose.", "Beta prose.", "Gamma prose."])
    }

    func testGarbageLabelsFallBackToHeadings() throws {
        // A misparsed CNCX (control bytes where labels should be) must not
        // ship binary garbage as chapter names: the label gate rejects the
        // index, and the heading path rules as it always has.
        let garbageLabels = [String(repeating: "\u{01}", count: 40), "\u{02}\u{03}", "\u{1F}x"]
        let book = try MobiParser.parse(book: makeIndexedBook(
            text: chapterText, labels: garbageLabels, offsets: chapterOffsets
        ))
        XCTAssertTrue(book.toc.isEmpty)
        XCTAssertEqual(book.chapters.map(\.title), ["Alpha", "Beta", "Gamma"])
    }

    func testDescendingOffsetsAreRejected() throws {
        // A contents page walks forward; offsets that move backward are a
        // misread index, not a TOC.
        let book = try MobiParser.parse(book: makeIndexedBook(
            text: chapterText, labels: ["Dawn", "Noon", "Dusk"], offsets: chapterOffsets.reversed()
        ))
        XCTAssertTrue(book.toc.isEmpty)
        XCTAssertEqual(book.chapters.map(\.title), ["Alpha", "Beta", "Gamma"])
    }

    func testBookWithoutIndexStillParsesByHeadings() throws {
        let header = makeHeaderRecord(textLength: chapterText.utf8.count, textRecordCount: 1, version: 6)
        let stream = palmdocEncode(chapterText)
        let book = try MobiParser.parse(book: makePDB(records: [header, stream]))
        XCTAssertTrue(book.toc.isEmpty)
        XCTAssertEqual(book.chapters.map(\.title), ["Alpha", "Beta", "Gamma"])
    }

    // MARK: - KF8 (azw3)

    /// A rawML with two flows — the KF8 shape the flow cut was verified
    /// against — plus FDST + skeleton + orthogonal index + CNCX records.
    private func makeKF8Book(labels: [String], offsets: [Int]) throws -> Data {
        let rawML = "<html><body><h1>One</h1><p>one.</p></html>"
            + "<html><body><h1>Two</h1><p>two.</p></html>"
        let header = makeHeaderRecord(textLength: rawML.utf8.count, textRecordCount: 1, version: 8)
        let stream = palmdocEncode(rawML)
        var fdst = Data("FDST".utf8)
        fdst.append(Data(count: 16))
        var skeleton = makeINDX(entries: [(0, 60), (60, 60)])
        put(UInt32(0xAA), at: 4, in: &skeleton)
        let orth = makeINDX(entries: offsets.map { ($0, 10) })
        let cncx = makeCNCX(labels: labels)
        return makePDB(records: [header, stream, fdst, skeleton, orth, cncx])
    }

    private let kf8RawML =
        "<html><body><h1>One</h1><p>one.</p></html>"
        + "<html><body><h1>Two</h1><p>two.</p></html>"

    private var kf8FlowOffsets: [Int] {
        occurrences(of: Array("<html".utf8), in: Array(kf8RawML.utf8))
    }

    func testKF8FlowCutTakesPublisherLabels() throws {
        let offsets = kf8FlowOffsets
        XCTAssertEqual(offsets.count, 2)
        let book = try MobiParser.parse(book: try makeKF8Book(
            labels: ["Dawn", "Dusk"], offsets: offsets
        ))
        // One index entry per flow: the verified flow cut stays, and the
        // publisher's labels replace the h1 echoes — the azw3 TOC survives.
        XCTAssertEqual(book.toc.map(\.label), ["Dawn", "Dusk"])
        XCTAssertEqual(book.chapters.map(\.title), ["Dawn", "Dusk"])
        XCTAssertEqual(book.chapters.map(\.text), ["one.", "two."])
        // The chapters keep their markup, stripped of the flow wrapper.
        XCTAssertFalse(book.chapters[0].html.lowercased().contains("<html"))
        XCTAssertTrue(book.chapters[0].html.contains("<h1>One</h1>"))
    }

    func testKF8CountMismatchWithBadOffsetsFallsBackToFlows() throws {
        // Three index entries against two flows, at offsets that sit mid-flow
        // (no `<html` follows): the flow-start gate rejects the cut, and the
        // h1-titled flow path rules — never a mid-flow chop.
        let book = try MobiParser.parse(book: try makeKF8Book(
            labels: ["A", "B", "C"], offsets: [10, 25, 35]
        ))
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters.map(\.title), ["One", "Two"])
    }

    func testKF8CountMatchLabelsFlowsEvenWhenOffsetsAreJunk() throws {
        // Count-match pairing needs no offsets: two entries, two flows, and
        // the labels map in document order even when the offsets point
        // nowhere near a flow start.
        let book = try MobiParser.parse(book: try makeKF8Book(
            labels: ["Alpha Chapter", "Omega Chapter"], offsets: [7, 19]
        ))
        XCTAssertEqual(book.chapters.map(\.title), ["Alpha Chapter", "Omega Chapter"])
        XCTAssertEqual(book.chapters.count, 2)
    }
}
