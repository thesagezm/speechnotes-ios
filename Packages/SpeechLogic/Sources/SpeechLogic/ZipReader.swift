import Foundation
import Compression

/// Minimal read-only ZIP reader — just enough for EPUB containers
/// (`application/epub+zip` is a ZIP archive whose META-INF/ entries the
/// reader must inspect for metadata + cover, while epub.js does the heavy
/// rendering inside the webview).
///
/// Deliberately no dependencies: the central directory is parsed by hand and
/// DEFLATE payloads go through Apple's Compression framework
/// (`COMPRESSION_ZLIB` is raw DEFLATE, exactly what ZIP method 8 stores).
/// Only `stored` (0) and `deflate` (8) are supported — those cover effectively
/// every EPUB; encrypted and zip64 archives fail with explicit errors instead
/// of corrupt data.
///
/// The whole file may be memory-mapped by the caller (`Data(contentsOf:,
/// options: .mappedIfSafe)`) — reading one entry touches only its own bytes.
public enum ZipReader {

    public struct Entry: Equatable {
        public let name: String
        public let isDirectory: Bool
        /// 0 = stored, 8 = deflate.
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
        /// IEEE CRC-32 of the UNCOMPRESSED payload, from the central
        /// directory — verified after extraction (size alone accepts
        /// corrupt-deflate garbage of plausible length).
        public let crc: UInt32
    }

    public enum ZipError: Error, Equatable {
        /// No end-of-central-directory record found — not a ZIP file (or truncated).
        case notAZipFile
        /// ZIP64 layout (offsets/sizes in the extra fields) — not worth
        /// supporting for EPUBs, which are never zip64 in practice.
        case unsupportedZip64
        case encryptedEntry(name: String)
        case unsupportedCompressionMethod(method: UInt16, entry: String)
        case corrupt(reason: String)
        case entryNotFound(name: String)
    }

    /// Parses the central directory. Cost is O(entry count), independent of
    /// payload size — safe to call on a 100 MB book.
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
        result.reserveCapacity(eocd.totalEntries)
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
    /// are touched, so a memory-mapped source never loads the whole book.
    public static func readEntry(_ name: String, in data: Data) throws -> Data {
        let all = try entries(in: data)
        if let entry = all.first(where: { $0.name == name }) {
            return try read(entry, in: data)
        }
        // Some publishers percent-encode entry names or fold case; the OPF
        // href resolution percent-DECODES, so an encoded archive name never
        // matches lexically. Resolve leniently before giving up.
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

        let output: Data
        switch entry.method {
        case 0:
            output = payload
        case 8:
            output = try inflate(payload, expectedSize: entry.uncompressedSize, entry: entry.name)
        default:
            throw ZipError.unsupportedCompressionMethod(method: entry.method, entry: entry.name)
        }
        guard crc32(output) == entry.crc else {
            throw ZipError.corrupt(reason: "CRC mismatch for \(entry.name) — archive is damaged")
        }
        return output
    }

    // MARK: - Inflate

    private static func inflate(_ payload: Data, expectedSize: Int, entry: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        // A hostile EPUB can declare an absurd uncompressed size — the zip
        // bomb is bounded here, before the allocation (M23).
        guard expectedSize <= 100 * 1024 * 1024 else {
            throw ZipError.corrupt(reason: "\(entry) declares \(expectedSize) bytes uncompressed — beyond the 100 MB safety cap")
        }
        guard !payload.isEmpty else {
            throw ZipError.corrupt(reason: "empty deflate payload for \(entry)")
        }
        var output = Data(count: expectedSize)
        // compression_decode_buffer takes raw pointers, so bind the buffer
        // base addresses; both buffers are non-empty (guards above).
        let decoded = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    dst.count,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    src.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expectedSize else {
            throw ZipError.corrupt(reason: "inflate \(entry): got \(decoded) bytes, expected \(expectedSize)")
        }
        return output
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

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Little-endian readers

    private static func u16le(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
