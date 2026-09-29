import Foundation

/// Minimal store-only (uncompressed) ZIP writer — everything the
/// normalize-to-EPUB pipeline needs. Uncompressed keeps the writer ~100
/// lines and the output is still a valid ZIP that epub.js, ZipReader and
/// every unzip tool accept; document EPUBs are text and remain small.
///
/// The `mimetype` entry of an EPUB must be FIRST and STORED — callers order
/// entries accordingly (we never compress, so that invariant is automatic).
public enum ZipWriter {
    public static func archive(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        var offsets: [UInt32] = []

        let (dosTime, dosDate) = dosDateTime(Date())

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = CRC32.of(entry.data)
            let size = UInt32(entry.data.count)
            offsets.append(UInt32(out.count))

            // Local file header
            out.append(u32(0x04034b50))
            out.append(u16(20))          // version needed
            out.append(u16(0x0800))      // flags: UTF-8 names
            out.append(u16(0))           // method: stored
            out.append(u16(dosTime))
            out.append(u16(dosDate))
            out.append(u32(crc))
            out.append(u32(size))        // compressed size
            out.append(u32(size))        // uncompressed size
            out.append(u16(UInt16(nameBytes.count)))
            out.append(u16(0))           // extra length
            out.append(nameBytes)
            out.append(entry.data)

            // Central directory record
            central.append(u32(0x02014b50))
            central.append(u16(20))      // version made by
            central.append(u16(20))      // version needed
            central.append(u16(0x0800))
            central.append(u16(0))       // method
            central.append(u16(dosTime))
            central.append(u16(dosDate))
            central.append(u32(crc))
            central.append(u32(size))
            central.append(u32(size))
            central.append(u16(UInt16(nameBytes.count)))
            central.append(u16(0))       // extra
            central.append(u16(0))       // comment
            central.append(u16(0))       // disk number start
            central.append(u16(0))       // internal attributes
            central.append(u32(0))       // external attributes
            central.append(u32(offsets.last ?? 0))
            central.append(nameBytes)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)

        // End of central directory
        out.append(u32(0x06054b50))
        out.append(u16(0)) // this disk
        out.append(u16(0)) // start disk
        out.append(u16(UInt16(entries.count)))
        out.append(u16(UInt16(entries.count)))
        out.append(u32(UInt32(central.count)))
        out.append(u32(centralOffset))
        out.append(u16(0)) // comment length

        return out
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    private static func u16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// CRC-32 (IEEE 802.3), table-driven — the checksum ZIP requires per entry.
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func of(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
