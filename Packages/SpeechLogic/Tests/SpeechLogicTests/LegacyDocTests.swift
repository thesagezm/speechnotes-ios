import XCTest
@testable import SpeechLogic

/// Legacy .doc extraction against a HAND-BUILT Word 97 document: a minimal
/// but structurally real CFB (header, FAT, directory) whose WordDocument
/// stream carries a genuine FIB with a two-piece table (one CP1252 piece,
/// one UTF-16 piece) in the 1Table stream. This exercises the whole chain —
/// DIFAT/FAT walk, directory scan, FIB structural walk, piece table — the
/// same path a real Word file takes.
final class LegacyDocTests: XCTestCase {
    private let sectorSize = 512

    /// Sector layout: 0 = FAT, 1 = directory, 2-3 = WordDocument, 4-5 = 1Table.
    private func buildDoc(
        compressedText: String,
        utf16Text: String
    ) -> Data {
        let compressedOffset = 1024 // bytes in the WordDocument stream
        let utf16Offset = 2048

        // WordDocument stream (4096 bytes ≥ the mini-stream cutoff).
        var wordDoc = Data(count: sectorSize * 2)
        put(UInt16(0xA5EC), at: 0x00, in: &wordDoc) // wIdent
        put(UInt16(0x00C1), at: 0x02, in: &wordDoc) // nFib (Word 97)
        put(UInt16(0x0200), at: 0x0A, in: &wordDoc) // fWhichTblStm → 1Table
        put(UInt16(14), at: 0x20, in: &wordDoc)     // csw
        // rgW97 (28 bytes of zeros) sits at 0x22; cslw at 0x3E.
        put(UInt16(22), at: 0x3E, in: &wordDoc)     // cslw
        let rgLWBase = 0x40
        put(UInt32(sectorSize * 2), at: rgLWBase, in: &wordDoc)           // [0] cbMac
        put(UInt32(compressedText.utf8.count + utf16Text.utf16.count), at: rgLWBase + 3 * 4, in: &wordDoc) // [3] ccpText
        let fcLcbBase = rgLWBase + 22 * 4 + 2
        put(UInt16(93), at: fcLcbBase - 2, in: &wordDoc) // cbRgFcLcb (pair count > 33)
        // Clx lives at the START of the 1Table stream.
        let clxOffset = 0
        let clxSize = 4 + (3 * 4) + (2 * 8) // marker+len + 3 CPs + 2 PCDs
        put(UInt32(clxOffset), at: fcLcbBase + 33 * 8, in: &wordDoc)      // fcClx
        put(UInt32(clxSize), at: fcLcbBase + 33 * 8 + 4, in: &wordDoc)    // lcbClx
        // The text pieces.
        let compressedBytes = Data(compressedText.utf8)
        wordDoc.replaceSubrange(compressedOffset..<compressedOffset + compressedBytes.count, with: compressedBytes)
        let utf16Bytes = utf16Text.data(using: String.Encoding.utf16LittleEndian)!
        wordDoc.replaceSubrange(utf16Offset..<utf16Offset + utf16Bytes.count, with: utf16Bytes)

        // 1Table stream (8 sectors = 4096 bytes ≥ the mini-stream cutoff,
        // so it stays on the regular FAT).
        var table = Data(count: 4096)
        var clx = Data()
        clx.append(0x02) // piece-table marker (no Prc segments)
        let plcSize = 3 * 4 + 2 * 8
        clx.append(contentsOf: withUnsafeBytes(of: UInt32(plcSize).littleEndian) { Data($0) })
        let cp0 = 0
        let cp1 = compressedText.utf8.count
        let cp2 = cp1 + utf16Text.utf16.count
        for value in [UInt32(cp0), UInt32(cp1), UInt32(cp2)] {
            clx.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Data($0) })
        }
        // PCD 0: compressed → fc = 0x40000000 | byteOffset/2.
        let pcd0: UInt32 = 0x4000_0000 | UInt32(compressedOffset / 2)
        clx.append(Data(repeating: 0, count: 2)) // flags
        clx.append(contentsOf: withUnsafeBytes(of: pcd0.littleEndian) { Data($0) })
        clx.append(Data(repeating: 0, count: 2)) // prm
        // PCD 1: UTF-16 → fc = byteOffset (no flag).
        clx.append(Data(repeating: 0, count: 2))
        clx.append(contentsOf: withUnsafeBytes(of: UInt32(utf16Offset).littleEndian) { Data($0) })
        clx.append(Data(repeating: 0, count: 2))
        table.replaceSubrange(0..<clx.count, with: clx)

        // FAT (sector 0): [0]=self, [1]=dir→END, WordDocument chain 2..9,
        // 1Table chain 10..17. 4096-byte streams span 8 sectors each.
        var fat = Data(count: sectorSize)
        func fatEntry(_ index: Int, _ value: UInt32) {
            fat.replaceSubrange(index * 4..<index * 4 + 4, with: withUnsafeBytes(of: value.littleEndian) { Data($0) })
        }
        fatEntry(0, 0xFFFF_FFFD)
        fatEntry(1, 0xFFFF_FFFE)
        for i in 0..<7 { fatEntry(2 + i, UInt32(3 + i)) }
        fatEntry(9, 0xFFFF_FFFE)
        for i in 0..<7 { fatEntry(10 + i, UInt32(11 + i)) }
        fatEntry(17, 0xFFFF_FFFE)

        // Directory: Root Entry, WordDocument, 1Table (128 bytes each —
        // exactly one 512-byte sector for all four slots).
        var directory = Data()
        func dirEntry(_ name: String, type: UInt8, start: UInt32, size: UInt64) {
            var entry = Data(count: 128)
            let nameUTF16 = name.data(using: String.Encoding.utf16LittleEndian)!
            entry.replaceSubrange(0..<nameUTF16.count, with: nameUTF16)
            put(UInt16(nameUTF16.count + 2), at: 64, in: &entry)
            entry.replaceSubrange(66..<67, with: Data([type]))
            put(UInt32(start), at: 116, in: &entry)
            put(UInt64(size), at: 120, in: &entry)
            directory.append(entry)
        }
        dirEntry("Root Entry", type: 5, start: 0xFFFF_FFFE, size: 0)
        dirEntry("WordDocument", type: 2, start: 2, size: UInt64(wordDoc.count))
        dirEntry("1Table", type: 2, start: 10, size: UInt64(table.count))

        // Assemble: header + sector 0 (FAT) + 1 (dir) + 2..9 (word) + 10..17 (table).
        var header = Data(count: 512)
        header.replaceSubrange(0..<8, with: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]))
        put(UInt16(9), at: 30, in: &header)          // sector shift → 512
        put(UInt16(6), at: 32, in: &header)          // mini sector shift → 64
        put(UInt32(1), at: 44, in: &header)          // number of FAT sectors
        put(UInt32(1), at: 48, in: &header)          // first directory sector
        put(UInt32(4096), at: 56, in: &header)       // mini stream cutoff
        put(UInt32(0xFFFF_FFFE), at: 60, in: &header) // first miniFAT = ENDOFCHAIN
        put(UInt32(0xFFFF_FFFE), at: 68, in: &header) // first DIFAT = ENDOFCHAIN
        put(UInt32(0), at: 76, in: &header)          // DIFAT[0] = FAT sector 0
        for i in 1..<109 {
            put(UInt32(0xFFFF_FFFF), at: 76 + i * 4, in: &header)
        }

        return header + fat + directory + wordDoc + table
    }

    private func put(_ value: UInt16, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<offset + 2, with: withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }

    private func put(_ value: UInt32, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<offset + 4, with: withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }

    private func put(_ value: UInt64, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<offset + 8, with: withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }

    func testExtractsBothPieceEncodings() throws {
        let text = try LegacyDocParser.extractText(
            archive: buildDoc(compressedText: "Hello from Word 97.\r", utf16Text: "Second piece \u{00E9}\u{2014}here.\r")
        )
        XCTAssertTrue(text.contains("Hello from Word 97."), "CP1252 piece missing: \(text)")
        XCTAssertTrue(text.contains("Second piece \u{00E9}\u{2014}here."), "UTF-16 piece missing: \(text)")
        // Word's \r paragraph separators survive for the caller to split on.
        XCTAssertTrue(text.contains("\r"))
    }

    func testRejectsNonWordFiles() {
        XCTAssertThrowsError(try LegacyDocParser.extractText(archive: Data("just text".utf8)))
        XCTAssertThrowsError(try LegacyDocParser.extractText(archive: Data()))
    }

    func testChunkSplitsHeadlessParagraphs() {
        let paragraphs = (0..<400).map { "Paragraph \($0)." }
        let chapters = DocumentEpubConverter.chunk(paragraphs: paragraphs)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].paragraphs.count, 150)
        XCTAssertEqual(chapters[2].paragraphs.count, 100)
        XCTAssertTrue(chapters.allSatisfy { $0.title == nil })
    }
}
