import Foundation

/// Legacy Word 97-2003 (.doc) text extraction — a self-contained
/// Compound File Binary reader plus the minimal FIB/piece-table walk that
/// pulls the main document text. Best-effort by design: anything that
/// doesn't match the expected layout throws a clear "convert to .docx"
/// error instead of emitting garbage.
///
/// Scope: v3 CFB (512-byte sectors — every real .doc), streams ≥ the mini
/// cutoff read through the FAT, smaller ones through the mini stream, and
/// the classic Word 97 FIB (nFib 0x00C1+): ccpText from FibRgLw97[3],
/// piece table (fcClx = FcLcb pair 33) in 1Table/0Table. Fastsaved and
/// encrypted docs fail loudly, not silently.
public enum LegacyDocParser {
    public static func extractText(archive: Data) throws -> String {
        let cfb = try CFBReader(archive)
        guard let wordDoc = try cfb.stream(named: "WordDocument") else {
            throw DocumentParseError.malformed("not a legacy Word document (no WordDocument stream)")
        }
        let tableFlag = Self.u16(wordDoc, 0x0A)
        let tableName = (tableFlag & 0x0200) != 0 ? "1Table" : "0Table"
        let table = try cfb.stream(named: tableName)
            ?? cfb.stream(named: "1Table")
            ?? cfb.stream(named: "0Table")

        let text = try extractMainText(wordDoc: wordDoc, table: table)
        guard !text.isEmpty else {
            throw DocumentParseError.malformed("no text found in the document body")
        }
        return text
    }

    // MARK: - FIB + piece table

    private static func extractMainText(wordDoc: Data, table: Data?) throws -> String {
        guard u16(wordDoc, 0) == 0xA5EC else {
            throw DocumentParseError.malformed("not a Word binary (bad magic)")
        }

        // FIB: base (32 bytes) → csw → rgW97 → cslw → rgLW97 → cbRgFcLcb →
        // FcLcb pairs. Walk it structurally instead of hardcoding offsets.
        var cursor = 32
        guard cursor + 2 <= wordDoc.count else {
            throw DocumentParseError.malformed("truncated FIB")
        }
        let cswValue = u16(wordDoc, cursor)
        cursor += 2 + Int(cswValue) * 2
        guard cursor + 2 <= wordDoc.count else {
            throw DocumentParseError.malformed("truncated FIB (rgW97)")
        }
        let cslwValue = u16(wordDoc, cursor)
        cursor += 2
        guard cursor + Int(cslwValue) * 4 <= wordDoc.count else {
            throw DocumentParseError.malformed("truncated FIB (rgLW97)")
        }
        var rgLW = [UInt32]()
        for _ in 0..<Int(cslwValue) {
            rgLW.append(u32(wordDoc, cursor))
            cursor += 4
        }
        // FibRgLw97[3] = ccpText — the main-document character count.
        let ccpText = rgLW.count > 3 ? Int(rgLW[3]) : 0

        guard cursor + 2 <= wordDoc.count else {
            throw DocumentParseError.malformed("truncated FIB (FcLcb)")
        }
        let cbRgFcLcb = Int(u16(wordDoc, cursor))
        cursor += 2

        // fcClx / lcbClx = FcLcb pair 33 (Word 97+ layout).
        let clxPair = 33
        guard cbRgFcLcb > clxPair, cursor + (clxPair + 1) * 8 + 4 <= wordDoc.count else {
            throw DocumentParseError.malformed("FIB has no piece table")
        }
        let pairOffset = cursor + clxPair * 8
        let fcClx = Int(u32(wordDoc, pairOffset))
        let lcbClx = Int(u32(wordDoc, pairOffset + 4))

        guard lcbClx > 0, let table, fcClx + lcbClx <= table.count, fcClx >= 0 else {
            // Very old non-piece-table documents: plain run between fcMin
            // (rgLW[1]) and fcMac (rgLW[2]) if those look sane.
            return try legacyRunText(wordDoc: wordDoc, rgLW: rgLW)
        }

        return try pieceTableText(table: table, clxOffset: fcClx, clxSize: lcbClx, wordDoc: wordDoc, ccpText: ccpText)
    }

    private static func legacyRunText(wordDoc: Data, rgLW: [UInt32]) throws -> String {
        guard rgLW.count > 2 else {
            throw DocumentParseError.malformed("no piece table and no legacy text range")
        }
        let fcMin = Int(rgLW[1]), fcMac = Int(rgLW[2])
        guard fcMin >= 0, fcMac >= fcMin, fcMac <= wordDoc.count, fcMac - fcMin < 50_000_000 else {
            throw DocumentParseError.malformed("legacy text range out of bounds")
        }
        let bytes = wordDoc.subdata(in: fcMin..<fcMac)
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Clx = zero or more Prc (leading byte 1) then the marker byte 2 with
    /// a u32 length, then the PlcPcd: (n+1) CPs followed by n 8-byte Pcds.
    private static func pieceTableText(
        table: Data,
        clxOffset: Int,
        clxSize: Int,
        wordDoc: Data,
        ccpText: Int
    ) throws -> String {
        var cursor = clxOffset
        let clxEnd = clxOffset + clxSize
        // Skip Prc segments until the 0x02 marker.
        while cursor < clxEnd, table[cursor] == 0x01 {
            guard cursor + 3 <= table.count else { break }
            let cb = Int(u16(table, cursor + 1))
            cursor += 3 + cb
        }
        guard cursor < clxEnd, table[cursor] == 0x02 else {
            throw DocumentParseError.malformed("piece table marker not found")
        }
        cursor += 1
        guard cursor + 4 <= table.count else {
            throw DocumentParseError.malformed("piece table length missing")
        }
        let lcbPlcPcd = Int(u32(table, cursor))
        cursor += 4
        guard lcbPlcPcd > 0, cursor + lcbPlcPcd <= table.count else {
            throw DocumentParseError.malformed("piece table out of bounds")
        }

        let plc = table.subdata(in: cursor..<cursor + lcbPlcPcd)
        // n+1 CPs (u32) then n PCDs (8 bytes): n = (size - 4) / 12
        guard lcbPlcPcd >= 12, (lcbPlcPcd - 4) % 12 == 0 else {
            throw DocumentParseError.malformed("piece table shape invalid")
        }
        let pieceCount = (lcbPlcPcd - 4) / 12
        guard pieceCount > 0, pieceCount < 1_000_000 else {
            throw DocumentParseError.malformed("piece count out of range")
        }

        var out = String.UnicodeScalarView()
        for piece in 0..<pieceCount {
            let cpStart = Int(u32(plc, piece * 4))
            let cpEnd = Int(u32(plc, (piece + 1) * 4))
            guard cpEnd > cpStart else { continue }
            let length = cpEnd - cpStart
            if ccpText > 0 && cpStart >= ccpText { break } // main text only

            let pcdOffset = (pieceCount + 1) * 4 + piece * 8
            let fcField = u32(plc, pcdOffset + 2)
            let isCompressed = (fcField & 0x4000_0000) != 0
            // FcCompressed: the 30-bit field is the byte offset when
            // uncompressed, and byteOffset/2 when compressed — recover with
            // a doubling, never a halving.
            let offset = isCompressed
                ? Int(fcField & 0x3FFF_FFFF) * 2
                : Int(fcField & 0x3FFF_FFFF)
            let byteLength = isCompressed ? length : length * 2
            guard offset >= 0, offset + byteLength <= wordDoc.count else { continue }
            let chunk = wordDoc.subdata(in: offset..<offset + byteLength)

            if isCompressed {
                let decoded = String(data: chunk, encoding: .windowsCP1252) ?? String(decoding: chunk, as: UTF8.self)
                // No per-piece scalar truncation: Word's CP counts are
                // UTF-16 code units and prefixing scalars could split a
                // surrogate pair across pieces.
                out.append(contentsOf: decoded.unicodeScalars)
            } else {
                let decoded = String(data: chunk, encoding: .utf16LittleEndian)
                    ?? utf16String(from: chunk)
                out.append(contentsOf: decoded.unicodeScalars)
            }
        }
        return String(out)
    }

    // MARK: - Byte helpers

    /// UTF-16LE decode for data that failed strict `String(data:encoding:)`
    /// (odd lengths, lone surrogates) — lossy but never throws.
    private static func utf16String(from data: Data) -> String {
        var units = [UInt16]()
        units.reserveCapacity(data.count / 2)
        var i = 0
        while i + 1 < data.count {
            units.append(UInt16(data[data.startIndex + i]) | (UInt16(data[data.startIndex + i + 1]) << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}

/// Compound File Binary (OLE2) reader — just enough to pull streams by
/// name: header, DIFAT→FAT, directory scan, FAT and mini-FAT chains.
/// v3 (512-byte sectors) only.
private struct CFBReader {
    private let archive: Data
    private let sectorSize: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var miniContainer: Data = Data()

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF
    private static let fatSector: UInt32 = 0xFFFF_FFFD
    private static let difatSector: UInt32 = 0xFFFF_FFFC

    init(_ archive: Data) throws {
        self.archive = archive
        guard archive.count >= 512 else {
            throw DocumentParseError.malformed("not a compound file (too small)")
        }
        let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        for (index, byte) in signature.enumerated() where archive[archive.startIndex + index] != byte {
            throw DocumentParseError.malformed("not a compound file (bad signature)")
        }
        let shift = Int(Self.u16(archive, 30))
        guard shift == 9 else {
            throw DocumentParseError.malformed("unsupported compound file version (4096-byte sectors)")
        }
        sectorSize = 1 << shift

        // DIFAT: 109 header entries + chained DIFAT sectors.
        var fatSectors: [UInt32] = []
        for i in 0..<109 {
            let value = Self.u32(archive, 76 + i * 4)
            if value != Self.freeSector && value != Self.endOfChain { fatSectors.append(value) }
        }
        var difatSector = Self.u32(archive, 68)
        var difatGuard = 0
        while difatSector != Self.endOfChain && difatSector != Self.freeSector && difatGuard < 100_000 {
            difatGuard += 1
            let base = self.offset(of: difatSector)
            for i in 0..<(sectorSize / 4 - 1) {
                let value = Self.u32(archive, base + i * 4)
                if value != Self.freeSector { fatSectors.append(value) }
            }
            difatSector = Self.u32(archive, base + sectorSize - 4)
        }
        guard !fatSectors.isEmpty else {
            throw DocumentParseError.malformed("compound file has no FAT")
        }

        // FAT: concatenate all FAT sectors' entries.
        for sector in fatSectors {
            let base = self.offset(of: sector)
            for i in 0..<(sectorSize / 4) {
                fat.append(Self.u32(archive, base + i * 4))
            }
        }

        // Directory + mini streams.
        let dirChain = chain(start: Self.u32(archive, 48))
        var directory = Data()
        for sector in dirChain {
            if let data = sectorData(sector) { directory.append(data) }
        }

        let miniFatStart = Self.u32(archive, 60)
        if miniFatStart != Self.endOfChain && miniFatStart != Self.freeSector {
            for sector in chain(start: miniFatStart) {
                for i in 0..<(sectorSize / 4) {
                    let base = self.offset(of: sector)
                    miniFat.append(Self.u32(archive, base + i * 4))
                }
            }
        }
        if let root = entry(named: "Root Entry", in: directory) {
            let rootStart = Int(Self.u32(directory, root + 116))
            if rootStart >= 0 {
                miniContainer = Data()
                for sector in chain(start: UInt32(rootStart)) {
                    if let data = sectorData(sector) { miniContainer.append(data) }
                }
            }
        }
    }

    /// One whole sector's bytes, or nil past EOF — malformed/truncated
    /// compound files must throw, never trap on an out-of-bounds subdata.
    private func sectorData(_ sector: UInt32) -> Data? {
        let base = 512 + Int(sector) * sectorSize
        guard base < archive.count else { return nil }
        let end = min(base + sectorSize, archive.count)
        return archive.subdata(in: archive.startIndex + base..<archive.startIndex + end)
    }

    /// All streams whose name matches — a linear scan instead of walking
    /// the red-black directory tree (stream names we need are unique).
    func stream(named name: String) throws -> Data? {
        var directory = Data()
        for sector in chain(start: Self.u32(archive, 48)) {
            if let data = sectorData(sector) { directory.append(data) }
        }
        var offsetInDir = 0
        while offsetInDir + 128 <= directory.count {
            let base = offsetInDir
            let nameLen = Int(Self.u16(directory, base + 64))
            if nameLen >= 2, nameLen <= 64 {
                let utf16 = directory.subdata(in: directory.startIndex + base..<directory.startIndex + base + nameLen - 2)
                let entryName = String(data: utf16, encoding: .utf16LittleEndian)
                let type = directory[directory.startIndex + base + 66]
                if entryName == name && type == 2 {
                    // start/size live in the DIRECTORY data, not the archive
                    // at those offsets (the directory stream sits at its own
                    // file offset).
                    let start = Self.u32(directory, base + 116)
                    let size = Self.u64(directory, base + 120)
                    return try readStream(start: start, size: size)
                }
            }
            offsetInDir += 128
        }
        return nil
    }

    private func entry(named name: String, in directory: Data) -> Int? {
        var offsetInDir = 0
        while offsetInDir + 128 <= directory.count {
            let nameLen = Int(Self.u16(directory, offsetInDir + 64))
            if nameLen >= 2, nameLen <= 64 {
                let utf16 = directory.subdata(in: directory.startIndex + offsetInDir..<directory.startIndex + offsetInDir + nameLen - 2)
                if String(data: utf16, encoding: .utf16LittleEndian) == name {
                    return offsetInDir
                }
            }
            offsetInDir += 128
        }
        return nil
    }

    private func readStream(start: UInt32, size: UInt64) throws -> Data {
        guard size <= 200_000_000 else {
            throw DocumentParseError.malformed("stream implausibly large")
        }
        if size < Self.u32(archive, 56) { // mini stream cutoff (u32 per spec)
            var out = Data()
            var cursor = start
            var remaining = Int(size)
            var guardCounter = 0
            while cursor != Self.endOfChain && remaining > 0 {
                guardCounter += 1
                if guardCounter > 100_000 { throw DocumentParseError.malformed("mini chain loop") }
                let miniOffset = Int(cursor) * 64
                guard miniOffset + 64 <= miniContainer.count else { break }
                let take = min(64, remaining)
                out.append(miniContainer.subdata(in: miniOffset..<miniOffset + take))
                remaining -= take
                cursor = miniFat.indices.contains(Int(cursor)) ? miniFat[Int(cursor)] : Self.endOfChain
            }
            return out
        }
        var out = Data()
        var cursor = start
        var remaining = Int(size)
        var guardCounter = 0
        while cursor != Self.endOfChain && remaining > 0 {
            guardCounter += 1
            if guardCounter > 1_000_000 { throw DocumentParseError.malformed("chain loop") }
            guard let data = sectorData(cursor) else {
                throw DocumentParseError.malformed("chain sector past end of file")
            }
            let take = min(data.count, remaining)
            out.append(data.prefix(take))
            remaining -= take
            cursor = fat.indices.contains(Int(cursor)) ? fat[Int(cursor)] : Self.endOfChain
        }
        return out
    }

    private func chain(start: UInt32) -> [UInt32] {
        var sectors: [UInt32] = []
        var cursor = start
        var guardCounter = 0
        while cursor != Self.endOfChain && cursor != Self.freeSector && cursor != Self.difatSector {
            guardCounter += 1
            if guardCounter > 1_000_000 { break }
            sectors.append(cursor)
            guard fat.indices.contains(Int(cursor)) else { break }
            let next = fat[Int(cursor)]
            if next == cursor { break }
            cursor = next
        }
        return sectors
    }

    private func offset(of sector: UInt32) -> Int {
        512 + Int(sector) * sectorSize
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + i]) << (8 * i)
        }
        return value
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[data.startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}
