// Zip.swift — the deck stack's own read-only ZIP reader.
//
// Ported from the repo's SpeechLogic ZipReader contract (central directory by
// hand, stored + deflate only, CRC verified) with one deliberate difference:
// the DEFLATE decoder here is pure Swift. `import Compression` does not exist
// on Linux, and the deck reader must build and test everywhere the package
// does (the Linux CI loop is how the port is verified). The decoder
// implements RFC 1951 exactly — stored, fixed-Huffman and dynamic-Huffman
// blocks — with the same size and CRC checks the Compression-based reader has.
//
// Standalone on purpose (see Package.swift): the deck stack must not drag
// COpus/cmark into its importers, so it carries its own zip reading.

import Foundation

public enum DeckZip {

    public struct Entry: Equatable {
        public let name: String
        public let isDirectory: Bool
        /// 0 = stored, 8 = deflate.
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
        /// IEEE CRC-32 of the UNCOMPRESSED payload, verified after extraction.
        public let crc: UInt32
    }

    public enum ZipError: Error, Equatable {
        case notAZipFile
        case unsupportedZip64
        case encryptedEntry(name: String)
        case unsupportedCompressionMethod(method: UInt16, entry: String)
        case corrupt(reason: String)
        case entryNotFound(name: String)
    }

    /// Largest single part the deck reader decompresses (media included).
    public static let maxPart = 512 * 1024 * 1024
    /// Largest XML part the deck reader parses.
    public static let maxXMLPart = 96 * 1024 * 1024

    /// Parses the central directory. O(entry count), independent of payload size.
    public static func entries(in data: Data) throws -> [Entry] {
        let eocd = try endOfCentralDirectory(in: data)
        if eocd.totalEntries == 0xFFFF || eocd.directoryOffset == 0xFFFF_FFFF {
            throw ZipError.unsupportedZip64
        }
        guard eocd.directoryOffset >= 0,
              eocd.directoryOffset <= data.count,
              eocd.directorySize >= 0,
              eocd.directoryOffset + eocd.directorySize <= data.count else {
            throw ZipError.corrupt(reason: "central directory out of bounds")
        }
        // subdata() returns an independent, zero-based copy — that kills the
        // classic Data slice "indices stay absolute" trap for all parsing below.
        let directory = data.subdata(in: eocd.directoryOffset ..< eocd.directoryOffset + eocd.directorySize)

        var result: [Entry] = []
        result.reserveCapacity(min(eocd.totalEntries, 50_000))
        var cursor = 0
        for _ in 0..<eocd.totalEntries {
            guard directory.count >= cursor + 46,
                  u32le(directory, cursor) == 0x0201_4b50 else {
                throw ZipError.corrupt(reason: "bad central directory entry at \(cursor)")
            }
            let flags = u16le(directory, cursor + 8)
            let method = u16le(directory, cursor + 10)
            let compressedSize = Int(u32le(directory, cursor + 20))
            let uncompressedSize = Int(u32le(directory, cursor + 24))
            let crc = u32le(directory, cursor + 16)
            let nameLength = Int(u16le(directory, cursor + 28))
            let extraLength = Int(u16le(directory, cursor + 30))
            let commentLength = Int(u16le(directory, cursor + 32))
            let localHeaderOffset = Int(u32le(directory, cursor + 42))
            guard compressedSize != 0xFFFF_FFFF && uncompressedSize != 0xFFFF_FFFF && localHeaderOffset != 0xFFFF_FFFF else {
                throw ZipError.unsupportedZip64
            }
            guard directory.count >= cursor + 46 + nameLength else {
                throw ZipError.corrupt(reason: "truncated central directory name")
            }
            let name = String(decoding: directory[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if flags & 0x0001 != 0 {
                throw ZipError.encryptedEntry(name: name)
            }
            result.append(Entry(
                name: name,
                isDirectory: name.hasSuffix("/"),
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                crc: crc
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    /// Reads and (when needed) inflates one entry. Only the entry's own bytes
    /// are touched, so a memory-mapped source never loads the whole deck.
    public static func readEntry(_ name: String, in data: Data) throws -> Data {
        let all = try entries(in: data)
        if let entry = all.first(where: { $0.name == name }) {
            return try read(entry, in: data)
        }
        // Some producers percent-encode entry names or fold case; resolve
        // leniently before giving up (the OPC layer resolves targets the
        // same way).
        let fold: (String) -> String = { ($0.removingPercentEncoding ?? $0).lowercased() }
        if let entry = all.first(where: { fold($0.name) == fold(name) }) {
            return try read(entry, in: data)
        }
        throw ZipError.entryNotFound(name: name)
    }

    public static func read(_ entry: Entry, in data: Data) throws -> Data {
        guard data.count >= entry.localHeaderOffset + 30,
              u32le(data, entry.localHeaderOffset) == 0x0403_4b50 else {
            throw ZipError.corrupt(reason: "bad local header for \(entry.name)")
        }
        // Local header name/extra lengths can legally differ from the central
        // directory's — the data offset must come from the LOCAL record.
        let localNameLength = Int(u16le(data, entry.localHeaderOffset + 26))
        let localExtraLength = Int(u16le(data, entry.localHeaderOffset + 28))
        let dataStart = entry.localHeaderOffset + 30 + localNameLength + localExtraLength
        let dataEnd = dataStart + entry.compressedSize
        guard dataStart >= 0 && dataEnd <= data.count else {
            throw ZipError.corrupt(reason: "entry payload out of bounds: \(entry.name)")
        }
        let payload = data.subdata(in: dataStart ..< dataEnd)

        let output: [UInt8]
        switch entry.method {
        case 0:
            output = [UInt8](payload)
        case 8:
            output = try inflate(payload, expectedSize: entry.uncompressedSize, entry: entry.name)
        default:
            throw ZipError.unsupportedCompressionMethod(method: entry.method, entry: entry.name)
        }
        guard crc32(output) == entry.crc else {
            throw ZipError.corrupt(reason: "CRC mismatch for \(entry.name) — archive is damaged")
        }
        return Data(output)
    }

    // MARK: - Inflate (RFC 1951, raw DEFLATE — ZIP method 8)

    /// The canonical Huffman code-length order of the CL alphabet.
    private static let clOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    /// Length base values for codes 257–285.
    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    /// Extra bits for lengths 257–285.
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    /// Distance base values for codes 0–29.
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    /// Extra bits for distances 0–29.
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private struct Huffman {
        /// counts[n] = number of codes of length n; symbols in canonical order.
        var counts: [Int]
        var symbols: [Int]

        init(lengths: [Int]) throws {
            var counts = [Int](repeating: 0, count: 16)
            for l in lengths where l > 0 {
                guard l <= 15 else { throw DeckZip.ZipError.corrupt(reason: "huffman code length over 15") }
                counts[l] += 1
            }
            // Check over-subscription: sum(count[l] << (15 - l)) must not exceed 1 << 15.
            var left: Int = 1
            for l in 1...15 {
                left <<= 1
                left -= counts[l]
                if left < 0 { throw DeckZip.ZipError.corrupt(reason: "over-subscribed huffman code") }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for l in 1..<15 { offsets[l + 1] = offsets[l] + counts[l] }
            var symbols = [Int](repeating: 0, count: lengths.count)
            for (sym, l) in lengths.enumerated() where l > 0 {
                symbols[offsets[l]] = sym
                offsets[l] += 1
            }
            self.counts = counts
            self.symbols = symbols
        }

        /// Decode one symbol. Huffman codes are packed MSB-first of the code,
        /// while the DEFLATE bit stream is LSB-first — so codes are read bit
        /// by bit, most-significant code bit first.
        func decode(_ r: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for len in 1...15 {
                code |= r.bit()
                let count = counts[len]
                if code - first < count {
                    return symbols[index + (code - first)]
                }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw DeckZip.ZipError.corrupt(reason: "invalid huffman code")
        }
    }

    private struct BitReader {
        let bytes: [UInt8]
        var pos = 0
        var bitBuf = 0
        var bitCount = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bit() -> Int {
            if bitCount == 0 {
                guard pos < bytes.count else {
                    // A truncated stream decodes zeros rather than crashing;
                    // the CRC check after inflate rejects the result.
                    bitBuf = 0
                    bitCount = 1
                    return 0
                }
                bitBuf = Int(bytes[pos])
                pos += 1
                bitCount = 8
            }
            let b = bitBuf & 1
            bitBuf >>= 1
            bitCount -= 1
            return b
        }

        mutating func bits(_ n: Int) -> Int {
            var v = 0
            for i in 0..<n {
                v |= bit() << i
            }
            return v
        }

        /// Align to the next byte boundary (end of a stored block's header).
        mutating func alignByte() {
            bitCount = 0
        }
    }

    private static func inflate(_ payload: Data, expectedSize: Int, entry: String) throws -> [UInt8] {
        guard expectedSize >= 0 else {
            throw ZipError.corrupt(reason: "\(entry): negative declared size")
        }
        // A hostile deck can declare an absurd uncompressed size — the zip
        // bomb is bounded here, before the allocation.
        guard expectedSize <= maxPart else {
            throw ZipError.corrupt(reason: "\(entry) declares \(expectedSize) bytes uncompressed — beyond the \(maxPart) byte safety cap")
        }
        guard !payload.isEmpty else {
            throw ZipError.corrupt(reason: "empty deflate payload for \(entry)")
        }
        var r = BitReader([UInt8](payload))
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)
        var fixedLit: Huffman?
        var fixedDist: Huffman?

        decodeLoop: while true {
            let final = r.bit()
            let type = r.bits(2)
            switch type {
            case 0:
                // Stored: align, LEN, NLEN, raw bytes.
                r.alignByte()
                guard r.pos + 4 <= r.bytes.count else {
                    throw ZipError.corrupt(reason: "\(entry): truncated stored block header")
                }
                let len = Int(r.bytes[r.pos]) | (Int(r.bytes[r.pos + 1]) << 8)
                let nlen = Int(r.bytes[r.pos + 2]) | (Int(r.bytes[r.pos + 3]) << 8)
                r.pos += 4
                guard len ^ 0xFFFF == nlen else {
                    throw ZipError.corrupt(reason: "\(entry): stored block length check failed")
                }
                guard r.pos + len <= r.bytes.count else {
                    throw ZipError.corrupt(reason: "\(entry): truncated stored block")
                }
                out.append(contentsOf: r.bytes[r.pos..<(r.pos + len)])
                r.pos += len
            case 1, 2:
                var lit: Huffman
                var dist: Huffman
                if type == 1 {
                    if fixedLit == nil {
                        var lengths = [Int](repeating: 8, count: 288)
                        for i in 144..<256 { lengths[i] = 9 }
                        for i in 256..<280 { lengths[i] = 7 }
                        fixedLit = try Huffman(lengths: lengths)
                        fixedDist = try Huffman(lengths: [Int](repeating: 5, count: 30))
                    }
                    lit = fixedLit!
                    dist = fixedDist!
                } else {
                    // Dynamic: code-length code, then the two alphabets.
                    let hlit = r.bits(5) + 257
                    let hdist = r.bits(5) + 1
                    let hclen = r.bits(4) + 4
                    var clLengths = [Int](repeating: 0, count: 19)
                    for i in 0..<hclen {
                        clLengths[clOrder[i]] = r.bits(3)
                    }
                    let cl = try Huffman(lengths: clLengths)
                    var lengths = [Int]()
                    lengths.reserveCapacity(hlit + hdist)
                    while lengths.count < hlit + hdist {
                        let sym = try cl.decode(&r)
                        switch sym {
                        case 0...15:
                            lengths.append(sym)
                        case 16:
                            guard let prev = lengths.last else {
                                throw ZipError.corrupt(reason: "\(entry): repeat with no previous length")
                            }
                            let n = 3 + r.bits(2)
                            lengths.append(contentsOf: [Int](repeating: prev, count: n))
                        case 17:
                            lengths.append(contentsOf: [Int](repeating: 0, count: 3 + r.bits(3)))
                        case 18:
                            lengths.append(contentsOf: [Int](repeating: 0, count: 11 + r.bits(7)))
                        default:
                            throw ZipError.corrupt(reason: "\(entry): bad code-length symbol \(sym)")
                        }
                    }
                    guard lengths.count == hlit + hdist else {
                        throw ZipError.corrupt(reason: "\(entry): code lengths overflow the alphabet")
                    }
                    lit = try Huffman(lengths: Array(lengths[0..<hlit]))
                    dist = try Huffman(lengths: Array(lengths[hlit...]))
                }
                // Inflate the block body.
                block: while true {
                    let sym = try lit.decode(&r)
                    switch sym {
                    case 0..<256:
                        out.append(UInt8(sym))
                    case 256:
                        break block
                    case 257..<286:
                        let li = sym - 257
                        let length = lengthBase[li] + r.bits(lengthExtra[li])
                        let dsym = try dist.decode(&r)
                        guard dsym < 30 else {
                            throw ZipError.corrupt(reason: "\(entry): bad distance symbol \(dsym)")
                        }
                        let distance = distBase[dsym] + r.bits(distExtra[dsym])
                        guard distance > 0, out.count >= distance else {
                            throw ZipError.corrupt(reason: "\(entry): distance \(distance) before start")
                        }
                        // Byte-by-byte: LZ77 overlaps by design.
                        let start = out.count - distance
                        for i in 0..<length {
                            out.append(out[start + i])
                        }
                    default:
                        throw ZipError.corrupt(reason: "\(entry): bad literal symbol \(sym)")
                    }
                }
            default:
                throw ZipError.corrupt(reason: "\(entry): reserved block type")
            }
            if final == 1 { break decodeLoop }
            if out.count > maxPart {
                throw ZipError.corrupt(reason: "\(entry): inflated past the \(maxPart) byte safety cap")
            }
        }
        guard out.count == expectedSize else {
            throw ZipError.corrupt(reason: "inflate \(entry): got \(out.count) bytes, expected \(expectedSize)")
        }
        return out
    }

    // MARK: - End of central directory

    private struct EOCD {
        let totalEntries: Int
        let directoryOffset: Int
        let directorySize: Int
    }

    /// Scans backwards over the tail (max comment 65_535 + record 22) for the
    /// EOCD signature 0x06054b50.
    private static func endOfCentralDirectory(in data: Data) throws -> EOCD {
        let tailLength = min(data.count, 65_535 + 22)
        let tailStart = data.count - tailLength
        // Independent zero-based copy: absolute offset = tailStart + found.
        let tail = data.subdata(in: tailStart ..< data.count)
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        if tail.count < 22 { throw ZipError.notAZipFile }
        var found = -1
        scan: for i in stride(from: tail.count - 22, through: 0, by: -1) {
            for j in 0..<4 where tail[i + j] != signature[j] { continue scan }
            found = i
            break
        }
        guard found >= 0 else { throw ZipError.notAZipFile }
        return EOCD(
            totalEntries: Int(u16le(tail, found + 10)),
            directoryOffset: Int(u32le(tail, found + 16)),
            directorySize: Int(u32le(tail, found + 12))
        )
    }

    // MARK: - CRC-32

    /// IEEE CRC-32 lookup table (the zip standard's polynomial).
    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Little-endian readers

    private static func u16le(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[data.startIndex + offset])
            | (UInt32(data[data.startIndex + offset + 1]) << 8)
            | (UInt32(data[data.startIndex + offset + 2]) << 16)
            | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }
}
