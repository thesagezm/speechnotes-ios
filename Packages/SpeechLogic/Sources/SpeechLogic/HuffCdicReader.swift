import Foundation

/// Huff/CDIC decompression for mobipocket books — the `'DH'` compression word
/// (17480) every Kindle-produced `.azw`/`.azw3` carries.
///
/// Transcribed from KindleUnpack's `HuffcdicReader` (lib/mobi_uncompress.py),
/// whose algorithm is the same one calibre runs. The structure the widely
/// copied PalmDOC flag-byte description does not prepare you for:
///
/// 1. **The HUFF record holds TWO tables.** `off1` (u32 at HUFF+8) points at
///    256 u32 "dict1" entries; `off2` (HUFF+12) at 64 u32 "dict2" entries.
///    Each dict1 entry packs `codelen` (bits 0–4), `term` (bit 7) and
///    `maxcode` (bits 8–31): the top byte of a 32-bit bitstream lookahead
///    indexes dict1 directly, `codelen` bits are consumed, and for
///    non-terminal entries dict2's mincode/maxcode ladder (entries consumed
///    two at a time — a canonical Huffman walk) extends the code length
///    until the code falls inside `[mincode[codelen], maxcode[codelen]]`.
///    The phrase index is `maxcode − code`, right-shifted back to the
///    codelen's scale.
/// 2. **The CDIC records hold the phrase dictionary.** Entry headers are u16
///    at `16 + 2·i`: payload length in bits 0–14, "still compressed" in bit
///    15; the payload sits at `18 + 2·i`. A compressed entry recursively
///    expands through the same bitstream — the real book this was validated
///    on (a 7.6 MB LWW `Pocket Pediatrics` `.azw3`, 6052 dictionary entries)
///    carries dozens that need the second pass.
///
/// One instance per book: the dictionary is shared and lazily expanded across
/// all of that book's text records, exactly like KindleUnpack's reader.
struct HuffCdicReader {

    enum HuffError: Error, Equatable {
        case badHuffHeader
        case badCdicHeader
    }

    /// dict1 entry: the code length this top-byte block starts, whether the
    /// entry is terminal (the index is final at this length), and the max
    /// code value the block covers, pre-shifted to the 32-bit scale.
    private let dict1: [(codelen: Int, term: Bool, maxcode: Int)]
    /// Canonical-code ladders for the non-terminal walk, indexed by codelen
    /// 0…32, values pre-shifted to the 32-bit lookahead's scale.
    private let mincode: [Int]
    private let maxLadder: [Int]
    /// The CDIC phrase dictionary; entries expand in place on first use.
    private var dictionary: [(bytes: [UInt8], expanded: Bool)]

    init(huff: Data, cdics: [Data]) throws {
        guard huff.count >= 16, huff.prefix(4) == Data("HUFF".utf8) else {
            throw HuffError.badHuffHeader
        }
        let off1 = Int(MobiParser.u32(huff, 8))
        let off2 = Int(MobiParser.u32(huff, 12))
        guard off1 >= 24, off2 >= off1, off2 + 4 * 64 <= huff.count else {
            throw HuffError.badHuffHeader
        }

        var table1: [(codelen: Int, term: Bool, maxcode: Int)] = []
        table1.reserveCapacity(256)
        for index in 0..<256 {
            let value = MobiParser.u32(huff, off1 + 4 * index)
            let codelen = Int(value & 0x1F)
            guard codelen > 0 else { throw HuffError.badHuffHeader }
            let term = value & 0x80 != 0
            // ((maxcode + 1) << (32 - codelen)) - 1, on the 24-bit payload.
            // The parens are load-bearing: in Swift `-` binds TIGHTER than
            // `<<`, so the unparenthesized form shifts by (32 − codelen − 1)
            // and every maxcode comes out half-size.
            let maxcode = ((Int(value >> 8) + 1) << (32 - codelen)) - 1
            table1.append((codelen, term, maxcode))
        }
        dict1 = table1

        // dict2: 64 u32s consumed as (mincode, maxcode) pairs per codelen
        // 1…32. Both ladders carry a 0 sentinel at index 0 so the walk's
        // `codelen` can index them directly.
        var mins: [Int] = [0]
        var maxs: [Int] = [0]
        for codelen in 1...32 {
            guard off2 + 8 * (codelen - 1) + 8 <= huff.count else {
                throw HuffError.badHuffHeader
            }
            let min = Int(MobiParser.u32(huff, off2 + 8 * (codelen - 1)))
            let max = Int(MobiParser.u32(huff, off2 + 8 * (codelen - 1) + 4))
            mins.append(min << (32 - codelen))
            maxs.append(((max + 1) << (32 - codelen)) - 1)
        }
        mincode = mins
        maxLadder = maxs

        var entries: [(bytes: [UInt8], expanded: Bool)] = []
        var remainingPhrases = -1
        for cdic in cdics {
            guard cdic.count >= 16, cdic.prefix(4) == Data("CDIC".utf8) else {
                throw HuffError.badCdicHeader
            }
            let phrases = Int(MobiParser.u32(cdic, 8))
            let bits = Int(MobiParser.u32(cdic, 12)) & 0xF
            if remainingPhrases < 0 { remainingPhrases = phrases }
            // n = min(1 << bits, phrases - alreadyCollected) — a multi-CDIC
            // dictionary fills each record to the smaller of its index
            // capacity and what is left of the book's phrase count.
            let already = entries.count
            let declared = min(1 << bits, max(0, phrases - already))
            let count = min(declared, remainingPhrases)
            guard 18 + 2 * count <= cdic.count else { throw HuffError.badCdicHeader }
            for index in 0..<count {
                let header = MobiParser.u16(cdic, 16 + 2 * index)
                let length = Int(header & 0x7FFF)
                let entryOffset = 18 + 2 * index
                guard entryOffset + length <= cdic.count else { throw HuffError.badCdicHeader }
                entries.append((
                    [UInt8](cdic[entryOffset..<(entryOffset + length)]),
                    header & 0x8000 == 0
                ))
            }
            remainingPhrases -= count
        }
        guard !entries.isEmpty else { throw HuffError.badCdicHeader }
        dictionary = entries
    }

    /// Decompresses one record payload (trailing-entry table already
    /// stripped). Reads the bitstream through a 64-bit window: `code` is the
    /// 32 bits starting at bit `n`; consuming `codelen` bits decrements `n`,
    /// and when `n` runs dry the window slides four bytes — KindleUnpack's
    /// exact loop, padded with eight zero bytes so the final lookahead never
    /// reads past the end. The loop ends on `bitsLeft < 0`, not on the padding.
    mutating func unpack(_ payload: Data) -> [UInt8] {
        var bytes = [UInt8](payload)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        var bitsLeft = payload.count * 8
        var pos = 0
        var window = Self.load64(bytes, 0)
        var n = 32

        var out: [UInt8] = []
        out.reserveCapacity(4096)

        while true {
            if n <= 0 {
                pos += 4
                guard pos + 8 <= bytes.count else { break }
                window = Self.load64(bytes, pos)
                n += 32
            }
            // code = (window >> n) & 0xFFFFFFFF — the 32-bit lookahead.
            let code = Int(truncatingIfNeeded: UInt32(truncatingIfNeeded: window >> UInt64(n)))
            let (baseCodelen, term, tableMax) = dict1[code >> 24]
            var codelen = baseCodelen
            var maxcode = tableMax
            if !term {
                // Canonical walk: extend the code length until the code falls
                // inside [mincode[codelen], maxcode[codelen]].
                while codelen < mincode.count, code < mincode[codelen] {
                    codelen += 1
                }
                guard codelen < maxLadder.count else { break }
                maxcode = maxLadder[codelen]
            }
            n -= codelen
            bitsLeft -= codelen
            if bitsLeft < 0 { break }
            let reference = (maxcode - code) >> (32 - codelen)
            guard reference >= 0, reference < dictionary.count else { break }
            if !dictionary[reference].expanded {
                let raw = dictionary[reference].bytes
                dictionary[reference].expanded = true
                dictionary[reference].bytes = unpack(Data(raw))
            }
            out.append(contentsOf: dictionary[reference].bytes)
        }
        return out
    }

    private static func load64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(bytes[offset + index]) }
        return value
    }
}
