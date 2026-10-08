import Foundation

/// Mobipocket reader (.mobi / .azw / .azw3 / .prc / .kf7 / .pdb) — a
/// self-contained Palm Database reader, the PalmDOC decompressor, and an
/// HTML-to-chapters pass.
///
/// Design mirrors `LegacyDoc.swift` (the .doc reader): no external
/// dependencies, every structural assumption validated, and a corrupt or
/// DRM-locked file throws a clear, user-presentable error instead of emitting
/// garbage.
///
/// ## What was verified before being written here
///
/// The decompression was ported from a Python model that was differentially
/// tested against calibre's own C implementation (`cPalmdoc.decompress`) on
/// eight real books — six Gutenberg `.kf8` files, two calibre-produced
/// `.mobi`/`.azw3` files and a `.pdb` — matching every declared text length
/// exactly. Three details make the difference, and all three are places where
/// the widely-copied "flag byte" description of this format is wrong:
///
/// 1. **The command byte is not a flag byte.** `0` and `0x09...0x7F` are
///    literals (so a record can begin with literal `<html>`); `1...8` is a
///    literal RUN of that length; `0xC0...0xFF` is "space + `byte ^ 0x80`";
///    only `0x80...0xBF` is a back-reference. A decoder that reads the byte as
///    a bitmask produces mojibake on every real book.
/// 2. **Trailing entries must be stripped first.** Every text record ends with
///    a small table of variable-length byte counts, and `extraFlags` in the
///    header says how many. Decompressing them in place runs every record long
///    by exactly the trailing bytes.
/// 3. **EXTH lives INSIDE record 0**, right after the fixed header. There is
///    no separate EXTH record; text starts at record 1.
///
/// Not supported, and said so rather than half-done: KFX containers and
/// incremental INDX updates. Huff/CDIC compression ('DH') IS supported —
/// `HuffCdicReader.swift` — which is what every store-bought `.azw`/`.azw3`
/// carries.
public enum MobiParser {

    // MARK: - Errors

    public enum MobiError: Error, Equatable {
        /// Not a Palm Database, or one whose `type`/`creator` is not a book.
        case notAMobi
        /// A book this reader cannot decode: DRM-locked, or a KFX container.
        /// Silent noise is worse than an honest message.
        case unsupportedVariant(String)
        case malformed(String)
    }

    // MARK: - Result

    /// One chapter of a mobipocket book. `title` is the document's own
    /// heading text, or nil when the book has none for this span — never
    /// invented, so every title in the reader's contents list is the book's
    /// own words.
    public struct MobiChapter: Equatable {
        public let title: String?
        /// The chapter's paragraphs, each a block of prose. The reader needs
        /// them SEPARATE: handing it one joined string made every mobi read
        /// as a single unbroken paragraph, which is unreadable aloud and
        /// unscannable on the page.
        public let paragraphs: [String]
        /// The chapter's own markup, verbatim — what the display path embeds
        /// so italics, headings and illustrations survive the trip. Empty
        /// for the headless fallback (chunked prose with no structure to
        /// keep). Image references are `data-pool-index="N"` tokens into
        /// `MobiBook.inlineImages`.
        public let html: String
        /// The same paragraphs joined for callers that want prose as a
        /// string (shelf summaries, tests).
        public var text: String { paragraphs.joined(separator: "\n\n") }

        public init(title: String?, paragraphs: [String], html: String = "") {
            self.title = title
            self.paragraphs = paragraphs
            self.html = html
        }

        public init(title: String?, text: String) {
            self.title = title
            self.paragraphs = text.isEmpty ? [] : [text]
            self.html = ""
        }
    }

    /// One image extracted from the book's resource records — the payload a
    /// `recindex` reference in the text resolves to.
    public struct MobiImage: Equatable {
        public let data: Data
        public let mime: String
    }

    /// Everything the shelf and the reader need, and nothing they don't.
    public struct MobiBook: Equatable {
        public let title: String?
        public let author: String?
        public let publisher: String?
        public let language: String?
        /// First embedded image (usually the cover) exactly as stored, or nil
        /// when the book has no image records.
        public let cover: Data?
        public let chapters: [MobiChapter]
        /// Every image the text references, in pool order — the chapter
        /// HTML's `data-pool-index` tokens point into this array.
        public let inlineImages: [MobiImage]
        /// "mobi6" / "kf8" — which header flavour produced the chapters.
        public let variant: String
        /// First ~400 characters of prose, for a shelf card with no cover.
        public let summary: String
    }

    /// Ceiling on chapters from one book. A book whose markup carries thousands
    /// of headings must not build an array the reader then renders row by row.
    public static let maxChapters = 4_000

    /// Soft ceiling on one chapter's characters. Headless books chunk at this
    /// size (~15 minutes of prose): small enough to extract instantly, large
    /// enough that chapter navigation stays useful.
    public static let chapterTargetCharacters = 12_000

    /// Ceiling on decompressed text — a book that expands without bound must
    /// not take the app down with it.
    static let maxTextBytes = 64 * 1024 * 1024

    // MARK: - Entry point

    /// Parses a whole mobipocket file. Pure and CPU-bound — callers run it
    /// off the main thread (a 50 MB `.azw3` spends real time in here).
    public static func parse(book data: Data) throws -> MobiBook {
        let pdb = try PalmDatabase(archive: data)
        guard let headerRecord = pdb.record(0) else {
            throw MobiError.malformed("missing book header record")
        }
        let header = try MobiHeader(record: headerRecord)
        if header.encryptionType != 0 {
            throw MobiError.unsupportedVariant(
                "This file is DRM-locked. Books bought from a store are encrypted and can't be read here."
            )
        }
        switch header.compression {
        case 1, 2:
            break
        case 17480:  // 0x4448 'DH' — Huff/CDIC, the compression every
                     // Kindle-produced .azw/.azw3 carries. The tables live in
                     // two resource records after the text records (a HUFF
                     // record + its CDIC dictionary records); decompressed
                     // differently, below.
            break
        default:
            throw MobiError.malformed("unknown compression \(header.compression)")
        }

        let records = try collectTextRecords(pdb: pdb, header: header)
        var body: [UInt8]
        if header.compression == 17480 {
            let huffTables = try collectHuffCdicRecords(pdb: pdb, header: header)
            var reader = try HuffCdicReader(huff: huffTables.huff, cdics: huffTables.cdics)
            var out: [UInt8] = []
            out.reserveCapacity(header.textLength)
            for record in records {
                out.append(contentsOf: reader.unpack(record))
                if out.count > maxTextBytes {
                    throw MobiError.malformed(
                        "text records exceed the \(maxTextBytes / (1024 * 1024)) MB cap"
                    )
                }
            }
            body = out
        } else {
            body = [UInt8](decompress(Data(records), compression: header.compression))
        }
        // Some writers end the last record with a sentinel '#'; it is not
        // content.
        if body.last == UInt8(ascii: "#") { body.removeLast() }
        let html = decode(Data(body), encoding: header.textEncoding)
        let meta = Exth(record: header.exthBlob)
        // One flatten, two consumers: the chapters AND the shelf summary read
        // the same item stream (the summary pass used to re-walk the whole
        // book, doubling import time on a 2 MB `.azw3`).
        let items = Self.items(from: html)
        // The display path keeps the book's own markup: `recindex` image
        // references become pool tokens, chapters cut at their headings
        // carry their verbatim HTML into the generated EPUB.
        let (displayHTML, inlineImages) = extractImages(from: html, pdb: pdb, header: header)

        return MobiBook(
            title: meta.title ?? header.title,
            author: meta.author,
            publisher: meta.publisher,
            language: meta.language,
            cover: coverImage(pdb: pdb, header: header, exth: meta),
            chapters: chapters(from: displayHTML, variant: header.isKF8 ? "kf8" : "mobi6"),
            inlineImages: inlineImages,
            variant: header.isKF8 ? "kf8" : "mobi6",
            summary: summary(from: items)
        )
    }

    /// True when `data` looks like a mobipocket book — cheap enough for an
    /// extension sniff, and it rejects a `.mobi` that is really a ZIP, which
    /// is the most common "wrong file" report.
    public static func looksLikeMobi(_ data: Data) -> Bool {
        guard data.count > 68 else { return false }
        let type = String(decoding: data[60..<64], as: UTF8.self)
        let creator = String(decoding: data[64..<68], as: UTF8.self)
        return type == "BOOK" && (creator == "MOBI" || creator == "REAd")
    }

    // MARK: - Header

    struct MobiHeader {
        var compression: UInt16 = 0
        var textLength = 0
        var textRecordCount = 0
        var recordSize = 0
        var encryptionType: UInt16 = 0
        var version = 0
        var textEncoding: String.Encoding = .windowsCP1252
        var title: String?
        var extraFlags: UInt16 = 0
        var exthBlob = Data()
        var isKF8 = false

        init(record: Data) throws {
            guard record.count >= 16 else {
                throw MobiError.malformed("header record too short")
            }
            compression = u16(record, 0)
            textLength = Int(u32(record, 4))
            textRecordCount = Int(u16(record, 8))
            recordSize = Int(u16(record, 10))
            encryptionType = u16(record, 12)
            // Ancient PRC files stop after the PalmDOC header (≤16 bytes):
            // no MOBI magic, no title, no EXTH. They still read.
            guard record.count > 16 else { return }

            let magic = String(decoding: record[16..<20], as: UTF8.self)
            guard magic == "MOBI" || magic == "BOOK" || magic == "TEXt" else {
                throw MobiError.notAMobi
            }
            guard recordSize > 0, recordSize <= 64 * 1024 else {
                throw MobiError.malformed("implausible record size \(recordSize)")
            }
            guard textRecordCount > 0, textRecordCount < 100_000 else {
                throw MobiError.malformed("implausible text record count \(textRecordCount)")
            }
            guard record.count >= 40 else { throw MobiError.malformed("truncated MOBI header") }
            version = Int(u32(record, 0x68))
            textEncoding = MobiParser.encoding(for: Int(u32(record, 28)))
            isKF8 = version == 8

            // Title: an offset/length pair, or zero/0xFFFFFFFF on writers that
            // keep the real title in EXTH only.
            let titleOffset = Int(u32(record, 0x54))
            let titleLength = Int(u32(record, 0x58))
            if titleOffset > 0, titleLength > 0,
               titleOffset + titleLength <= record.count,
               titleOffset + titleLength < 0xFFFF_FFFF {
                let value = MobiParser.decode(
                    Data(record[titleOffset..<(titleOffset + titleLength)]),
                    encoding: textEncoding
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                title = value.isEmpty ? nil : value
            }

            // extraFlags says how many trailing-entry counts each text record
            // ends with. The field only exists once the header is at least
            // 0xF4 bytes long, and a headerLength of exactly 0xE4 is a known
            // kindlegen bug where the field holds garbage.
            let headerLength = Int(u32(record, 20))
            if headerLength >= 0xE4, headerLength <= 0x1000, record.count >= 0xF4 {
                extraFlags = headerLength == 0xE4 ? 0 : u16(record, 0xF2)
            }

            // EXTH sits immediately after the fixed header when the flag word
            // at 0x80 has bit 6 set. Scanning for the "EXTH" magic as a
            // fallback catches writers that set that flag wrongly — common
            // enough to be worth the belt and braces.
            let exthFlag = record.count >= 0x84 ? u32(record, 0x80) : 0
            if exthFlag & 0x40 != 0 {
                let start = 16 + headerLength
                if start + 12 <= record.count,
                   String(decoding: record[start..<(start + 4)], as: UTF8.self) == "EXTH" {
                    exthBlob = Data(record[start...])
                }
            }
            if exthBlob.isEmpty, let found = MobiHeader.exthBlob(in: record) {
                exthBlob = found
            }
        }

        /// Locates an EXTH block by its magic and validates the declared
        /// length. nil when there is no plausible one.
        ///
        /// Two `Data` details bite here and both are now spelled out:
        /// `range(of:)` takes `Data` (not `[UInt8]`), and a Data SLICE keeps
        /// its absolute indices — so the range found in `record[16…]` indexes
        /// the original record directly and must NOT be offset by 16 again
        /// (that was the `Data.Index`/`String` subscript error CI caught).
        static func exthBlob(in record: Data) -> Data? {
            guard record.count > 28 else { return nil }
            let magic = Data([0x45, 0x58, 0x54, 0x48])  // "EXTH"
            guard let range = record[16...].range(of: magic) else { return nil }
            let base = range.lowerBound
            let count = Int(u32(record, base + 8))
            let length = Int(u32(record, base + 4))
            guard count >= 0, count < 2_000,
                  length >= 12, length <= record.count - base else { return nil }
            return record.subdata(in: base..<(base + length))
        }
    }

    /// Codepage → Foundation encoding. CP1252 decodes every Western and
    /// Central-European book byte-correctly and never fails, so it is the
    /// floor for any codepage this reader doesn't know exactly.
    static func encoding(for codepage: Int) -> String.Encoding {
        switch codepage {
        case 65001: return .utf8
        case 1251: return .windowsCP1251
        case 1250: return .windowsCP1250
        default: return .windowsCP1252
        }
    }

    /// The header's encoding first, then UTF-8, then CP1252, then a lossy
    /// pass — a real book in any encoding must come back as text, never nil.
    static func decode(_ data: Data, encoding: String.Encoding) -> String {
        if let text = String(data: data, encoding: encoding) { return text }
        if encoding != .utf8, let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Text records

    /// Concatenates the text records, stripping each one's trailing-entry
    /// table first. Text always starts at record 1: EXTH lives INSIDE record 0
    /// in mobipocket books, there is no separate EXTH record.
    ///
    /// Returns the STRIPPED records rather than a joined blob: PalmDOC
    /// decompresses the concatenation (a back-reference may span records),
    /// but Huff/CDIC decompresses RECORD BY RECORD (its bitstream restarts at
    /// each record boundary), so the caller needs the per-record payloads.
    static func collectTextRecords(pdb: PalmDatabase, header: MobiHeader) throws -> [Data] {
        let count = header.textRecordCount
        guard pdb.recordCount >= 1 + count else {
            throw MobiError.malformed(
                "header declares \(count) text record(s) but the file has \(pdb.recordCount)"
            )
        }
        var out: [Data] = []
        out.reserveCapacity(count)
        var total = 0
        for index in 0..<count {
            guard let record = pdb.record(1 + index) else {
                throw MobiError.malformed("text record \(index + 1) of \(count) is missing")
            }
            let cut = trailingEntryBytes(in: record, extraFlags: header.extraFlags)
            let payload = cut < record.count ? record.prefix(record.count - cut) : record
            out.append(Data(payload))
            total += payload.count
            if total > maxTextBytes {
                throw MobiError.malformed(
                    "text records exceed the \(maxTextBytes / (1024 * 1024)) MB cap"
                )
            }
        }
        return out
    }

    /// The HUFF record and its CDIC dictionary records, which sit among the
    /// resource records after the text records (found by magic — their
    /// position is not fixed). Missing tables are an error, not a fallback:
    /// the alternative is decoding the bitstream as noise.
    static func collectHuffCdicRecords(pdb: PalmDatabase, header: MobiHeader) throws -> (huff: Data, cdics: [Data]) {
        let firstResource = 1 + header.textRecordCount
        var huff: Data?
        var cdics: [Data] = []
        for index in firstResource..<pdb.recordCount {
            guard let record = pdb.record(index), record.count >= 16 else { continue }
            if record[0..<4] == Data("HUFF".utf8), huff == nil {
                huff = record
            } else if record[0..<4] == Data("CDIC".utf8) {
                cdics.append(record)
            }
        }
        guard let huff, !cdics.isEmpty else {
            throw MobiError.malformed(
                "Huff/CDIC compression is declared but its tables are missing"
            )
        }
        return (huff, cdics)
    }

    /// One variable-length count, read BACKWARDS from `size - 1`: seven bits
    /// per byte, least significant first, top bit marks the last byte.
    static func trailingCount(in record: Data, upTo size: Int) -> Int {
        var bitPosition = 0
        var result = 0
        var cursor = size
        while cursor > 0 && bitPosition < 28 {
            let byte = Int(record[record.startIndex + cursor - 1])
            result |= (byte & 0x7F) << bitPosition
            bitPosition += 7
            cursor -= 1
            if byte & 0x80 != 0 { return result }
        }
        return result
    }

    /// How many trailing bytes `extraFlags` says a record ends with:
    /// `extraFlags >> 1` is a bitfield of variable-length counts, and bit 0
    /// adds a final one-or-two-byte count. Getting this wrong is the classic
    /// "text decodes, but every record is a few characters off" bug.
    static func trailingEntryBytes(in record: Data, extraFlags: UInt16) -> Int {
        guard extraFlags != 0, !record.isEmpty else { return 0 }
        var total = 0
        // Entries occur in bit order — bit 1 (0x1, multibyte) nearest the
        // text, higher bits stacked toward the record's end — so peeling
        // from the END means the highest varint bit comes off first.
        var bit = 15
        while bit >= 1 {
            if extraFlags & (1 << bit) != 0 {
                guard record.count > total else { return 0 }
                total += trailingCount(in: record, upTo: record.count - total)
            }
            bit -= 1
        }
        if extraFlags & 1 == 1 {
            let offset = record.count - total - 1
            guard offset >= 0, offset < record.count else { return 0 }
            total += (Int(record[record.startIndex + offset]) & 0x3) + 1
        }
        return total
    }

    // MARK: - PalmDOC decompression

    /// The exact algorithm. Not the flag-byte scheme the format is usually
    /// described with — see the type comment.
    ///
    /// A back-reference whose distance is zero, or reaches past the start of
    /// the output, is skipped rather than clamped, exactly as the reference
    /// implementation does: clamping would splice unrelated bytes into prose.
    static func decompress(_ input: Data, compression: UInt16) -> Data {
        if compression == 1 { return input }        let bytes = [UInt8](input)
        var out = [UInt8]()
        out.reserveCapacity(min(bytes.count * 4, maxTextBytes))
        var index = 0
        let count = bytes.count
        while index < count {
            let command = bytes[index]
            index += 1
            if command >= 1 && command <= 8 {
                // A literal RUN of that many bytes.
                var remaining = Int(command)
                while remaining > 0 && index < count {
                    out.append(bytes[index])
                    index += 1
                    remaining -= 1
                }
            } else if command <= 0x7F {
                // 0 and 0x09...0x7F: the byte itself.
                out.append(command)
            } else if command >= 0xC0 {
                // The writer's space-plus-ASCII shorthand.
                out.append(0x20)
                out.append(command ^ 0x80)
            } else if index < count {
                // 0x80...0xBF: a back reference. The low 3 bits are length − 3,
                // the upper 14 bits the distance.
                let value = (UInt32(command) << 8) | UInt32(bytes[index])
                index += 1
                let distance = Int((value & 0x3FFF) >> 3)
                let length = Int(value & 0x7) + 3
                if distance > 0, distance <= out.count {
                    var source = out.count - distance
                    for _ in 0..<length {
                        out.append(out[source])
                        source += 1
                    }
                }
            }
            if out.count > maxTextBytes { break }
        }
        return Data(out)
    }

    // MARK: - Chapters

    /// One structural element of the book, in document order.
    enum Item {
        case heading(String)
        case paragraph(String)
    }

    /// Flattens the book's HTML into heading/paragraph items.
    ///
    /// mobipocket books are HTML, so the markup IS the structure: `<h1>`–`<h2>`
    /// open chapters, `<h3>`+ stay inside the current chapter as prose (books
    /// nest four deep, and every level opening a chapter makes an unusable
    /// contents list), and block tags separate paragraphs. Hard-wrapped source
    /// lines are rejoined into paragraphs — Gutenberg wraps at ~70 columns, so
    /// splitting on newlines would shred every sentence.
    static func items(from html: String) -> [Item] {
        var working = replacing(skippedElementsRegex, in: html, with: " ")
        working = replacing(pageBreakRegex, in: working, with: "\n\n")

        var items: [Item] = []
        // A heading OPENING tag (`<h1 …>`) vs. its CLOSING tag (`</h1>`): both
        // match the boundary pattern, and treating the closing tag as an
        // opening one is what made every fixture come back untitled.
        var pendingHeading = false
        var paragraph: [String] = []
        var cursor = working.startIndex

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = sanitize(paragraph.joined(separator: " "))
            paragraph = []
            guard !joined.isEmpty else { return }
            if pendingHeading {
                items.append(.heading(joined))
                pendingHeading = false
            } else {
                items.append(.paragraph(joined))
            }
        }

        for match in matches(of: blockBoundaryRegex, in: working) {
            guard let range = Range(match.range, in: working) else { continue }
            // A match that starts BEFORE the cursor would make
            // `working[cursor..<range.lowerBound]` a reversed range — the
            // slice traps or returns garbage, and a truncated back reference
            // in the decompressed text can produce an unbalanced tag whose
            // boundary match overlaps the previous one. Skip it and keep the
            // cursor where it is rather than slicing backwards.
            guard range.lowerBound >= cursor else { continue }
            let chunk = String(working[cursor..<range.lowerBound])
            cursor = range.upperBound
            // What's left after the boundary tags are INLINE tags (font, em,
            // span, a…). They vanish — browsers render inline markup without
            // whitespace, and replacing it with a space shredded words:
            // "<font>a</font>sh" decoded as "a sh" (the artifact the
            // word-diff against calibre's own conversion caught).
            let text = sanitize(XhtmlText.decodingEntitiesLeniently(replacing(anyTagRegex, in: chunk, with: "")))

            // Group 2 is a heading LEVEL, which only an OPENING `<hN …>` has.
            if match.range(at: 2).location != NSNotFound,
               let levelRange = Range(match.range(at: 2), in: working) {
                let level = Int(working[levelRange]) ?? 1
                // An opening heading tag ends whatever came before it; the text
                // inside is its title.
                flushParagraph()
                if !text.isEmpty {
                    if level <= 2 {
                        items.append(.heading(text))
                    } else {
                        // h3+ nests inside the chapter: its words are prose.
                        paragraph.append(text)
                    }
                }
                pendingHeading = level <= 2
                continue
            }

            if !text.isEmpty {
                if pendingHeading {
                    items.append(.heading(text))
                    pendingHeading = false
                } else {
                    paragraph.append(text)
                }
            }
            // Every other boundary ends a block: `</p>`, `<br/>`, `</h2>`, …
            flushParagraph()
        }

        let tail = sanitize(XhtmlText.decodingEntitiesLeniently(replacing(anyTagRegex, in: String(working[cursor...]), with: "")))
        if !tail.isEmpty {
            if pendingHeading { items.append(.heading(tail)) }
            else { paragraph.append(tail) }
        }
        flushParagraph()
        return items
    }

    /// Splits the book into chapters at its level-1/level-2 headings.
    ///
    /// A book with no headings at all (older Kindle conversions, and the
    /// `.doc`-style fixture set) chunks into ~12 000-character spans so the
    /// reader's one-chapter-at-a-time memory bound still holds.
    /// The prepared book markup: the same element/pagebreak stripping the
    /// item walk does, so chapters' HTML and their paragraphs always agree.
    static func prepare(_ html: String) -> String {
        var working = replacing(skippedElementsRegex, in: html, with: " ")
        working = replacing(pageBreakRegex, in: working, with: "\n\n")
        return working
    }

    /// The prepared markup cut at the level-1/2 heading tags — the same
    /// boundaries the item walk opens chapters at — so a chapter's HTML and
    /// its paragraphs cover exactly the same span of book.
    static func chapterSegments(from prepared: String) -> [String] {
        guard let headingRegex = try? NSRegularExpression(pattern: "(?i)<h[12]\\b[^>]*>") else {
            return [prepared]
        }
        let ns = prepared as NSString
        let matches = headingRegex.matches(
            in: prepared, range: NSRange(location: 0, length: ns.length)
        )
        guard matches.count >= 2 else { return [prepared] }
        var segments: [String] = []
        var cursor = 0
        for match in matches where match.range.location >= cursor {
            if match.range.location > cursor {
                segments.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            } else if segments.isEmpty {
                segments.append("")
            }
            cursor = match.range.location
        }
        if cursor < ns.length { segments.append(ns.substring(from: cursor)) }
        return segments
    }

    /// Splits the book into chapters that keep their own markup.
    ///
    /// KF8 (`.azw3`) and MOBI6 carry different structure, and the one
    /// h1/h2-heading rule served both badly:
    ///
    /// * **KF8** rawML is a sequence of XHTML "flows" — `<html>…</html>` —
    ///   whose section content sits AFTER each flow's close, and a
    ///   reference-book's flows carry 165 `<h1>`s and 265 `<h2>`s
    ///   (the 2026-10-08 device report: "the division of chapters is not
    ///   accurate"). The flow boundary is the book's own chapter structure:
    ///   each flow plus the content that follows it up to the next flow is
    ///   one chapter, titled by its first `<h1>`.
    /// * **MOBI6** keeps the heading rule: chapters at level-1/2 headings,
    ///   h3+ staying inside as prose.
    ///
    /// Both paths keep the markup verbatim — italics, headings and
    /// illustrations reach the generated EPUB. A book with no structure at
    /// all (older conversions, the `.doc`-style fixture set) chunks into
    /// ~12 000-character spans of paragraphs.
    static func chapters(from html: String, variant: String) -> [MobiChapter] {
        if variant == "kf8" {
            let flowChapters = kf8FlowChapters(from: html)
            if !flowChapters.isEmpty { return flowChapters }
        }
        return headingChapters(from: html)
    }

    /// KF8: one chapter per flow. The flow's `<html>…</html>` wrapper and its
    /// following bare content (the section markup a KF8 writer puts after
    /// `</html>`) both belong to the chapter; the title is the chapter's own
    /// first `<h1>` text, never invented. Front-matter flows without an h1
    /// take their `epub:type` (titlepage, copyright-page, toc…) as a title.
    static func kf8FlowChapters(from html: String) -> [MobiChapter] {
        guard let flowRegex = try? NSRegularExpression(pattern: "(?i)<html\\b[^>]*>.+?</html\\s*>") else {
            return []
        }
        let ns = html as NSString
        let matches = flowRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        // The flows must actually tile the book — a single stray <html>…</html>
        // inside one MOBI6-style document is not a KF8 structure, and cutting
        // it would throw away everything around it.
        guard matches.count >= 2 else { return [] }

        var result: [MobiChapter] = []
        var boundaries: [Int] = []
        for match in matches where result.count < maxChapters {
            // Chapter span: this flow's OPEN through the next flow's open
            // (the flow itself + the section content after its close).
            boundaries.append(match.range.location)
        }
        guard !boundaries.isEmpty else { return [] }
        // Preamble before the first flow (the XML declaration) belongs to
        // the first chapter; a real KF8 file starts its first flow within
        // the first hundred bytes.
        for (index, start) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : ns.length
            let span = ns.substring(with: NSRange(location: start, length: end - start))
            let prepared = prepare(span)
            let items = Self.items(from: prepared)
            var title: String?
            var paragraphs: [String] = []
            for item in items {
                switch item {
                case .heading(let text):
                    if title == nil { title = text } else { paragraphs.append(text) }
                case .paragraph(let text):
                    paragraphs.append(text)
                }
            }
            if paragraphs.isEmpty && title == nil { continue }
            if title == nil, let sectionTitle = kf8SectionTitle(in: prepared) {
                title = sectionTitle
            }
            result.append(MobiChapter(title: title, paragraphs: paragraphs, html: prepared))
        }
        return result
    }

    /// A title for a front-matter flow with no `<h1>`: its own
    /// `epub:type="…"` on the section element ("titlepage", "toc", …) —
    /// capitalized for the contents list. nil when the flow declares neither.
    static func kf8SectionTitle(in prepared: String) -> String? {
        guard let typeRegex = try? NSRegularExpression(pattern: #"epub:type="([a-z-]+)""#) else {
            return nil
        }
        guard let match = typeRegex.firstMatch(
            in: prepared, range: NSRange(prepared.startIndex..., in: prepared)
        ), let range = Range(match.range(at: 1), in: prepared) else { return nil }
        let raw = String(prepared[range])
        let readable = raw.replacingOccurrences(of: "-", with: " ")
        return readable.prefix(1).uppercased() + readable.dropFirst()
    }

    /// MOBI6: the heading-delimited path (KF8's fallback too, for a book
    /// whose flows did not tile).
    static func headingChapters(from html: String) -> [MobiChapter] {
        let prepared = prepare(html)
        let segments = chapterSegments(from: prepared)
        if segments.count <= 1 {
            let items = Self.items(from: prepared)
            guard !items.isEmpty else {
                let whole = sanitize(XhtmlText.decodingEntitiesLeniently(replacing(anyTagRegex, in: prepared, with: "")))
                return [MobiChapter(title: nil, text: whole)]
            }
            var result: [MobiChapter] = []
            var title: String?
            var buffer: [String] = []
            var characters = 0
            func flush() {
                let paragraphs = buffer.filter { !$0.isEmpty }
                buffer = []
                characters = 0
                guard !paragraphs.isEmpty, result.count < maxChapters else { return }
                result.append(MobiChapter(title: title, paragraphs: paragraphs))
                title = nil
            }
            for item in items {
                switch item {
                case .heading(let text):
                    flush()
                    title = text
                case .paragraph(let text):
                    buffer.append(text)
                    characters += text.utf16.count
                    if characters >= chapterTargetCharacters {
                        let carried = title
                        flush()
                        title = carried
                    }
                }
            }
            flush()
            if result.isEmpty {
                let whole = sanitize(XhtmlText.decodingEntitiesLeniently(replacing(anyTagRegex, in: prepared, with: "")))
                return [MobiChapter(title: nil, text: whole)]
            }
            return result
        }

        var result: [MobiChapter] = []
        for segment in segments where result.count < maxChapters {
            let items = Self.items(from: segment)
            var title: String?
            var paragraphs: [String] = []
            for item in items {
                switch item {
                case .heading(let text):
                    // The segment OPENED with this heading; anything after
                    // is prose (h1/h2 open segments, so a second heading in
                    // one segment cannot happen — but a malformed one is
                    // prose, not a chapter split).
                    if title == nil { title = text } else { paragraphs.append(text) }
                case .paragraph(let text):
                    paragraphs.append(text)
                }
            }
            if paragraphs.isEmpty && title == nil { continue }
            result.append(MobiChapter(
                title: title,
                paragraphs: paragraphs,
                html: segment
            ))
        }
        if result.isEmpty {
            let whole = sanitize(XhtmlText.decodingEntitiesLeniently(replacing(anyTagRegex, in: prepared, with: "")))
            return [MobiChapter(title: nil, text: whole)]
        }
        return result
    }

    // MARK: - Inline images

    /// Every image the text's `recindex` references point at, in first-use
    /// order, with the references rewritten to `data-pool-index` tokens.
    ///
    /// `recindex` is 1-based over the resource records that follow the text
    /// records. Writers disagree about the exact base — the mobiunpack
    /// convention is `firstResource + n - 1` — so both bases are tried and
    /// whichever lands on a real image payload wins. A reference that lands
    /// on nothing (FLIS/FCIS records have the same position) drops its
    /// image; the text never breaks.
    static func extractImages(
        from html: String,
        pdb: PalmDatabase,
        header: MobiHeader
    ) -> (html: String, images: [MobiImage]) {
        guard let refRegex = try? NSRegularExpression(pattern: #"(?i)recindex\s*=\s*"?(\d+)"?"#) else {
            return (html, [])
        }
        let firstResource = 1 + header.textRecordCount
        guard pdb.recordCount > firstResource else { return (html, []) }

        var pool: [MobiImage] = []
        var poolByRecord: [Int: Int] = [:]

        func image(at recordNumber: Int) -> MobiImage? {
            if let known = poolByRecord[recordNumber] { return pool[known] }
            guard let record = pdb.record(recordNumber), record.count > 4 else { return nil }
            let mime: String
            if record[0] == 0xFF, record[1] == 0xD8 {
                mime = "image/jpeg"
            } else if record[0] == 0x89, record[1] == 0x50, record[2] == 0x4E, record[3] == 0x47 {
                mime = "image/png"
            } else if record[0] == 0x47, record[1] == 0x49, record[2] == 0x46 {
                mime = "image/gif"
            } else {
                return nil
            }
            let image = MobiImage(data: record, mime: mime)
            poolByRecord[recordNumber] = pool.count
            pool.append(image)
            return image
        }

        let ns = html as NSString
        var out = ""
        var cursor = 0
        for match in refRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.range(at: 1).location != NSNotFound else { continue }
            let numberText = ns.substring(with: match.range(at: 1))
            guard let number = Int(numberText), number > 0 else { continue }
            // Try the mobiunpack base, then the raw base.
            let image = image(at: firstResource + number - 1) ?? image(at: firstResource + number)
            if match.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            if let image {
                // `data-pool-index` is the attribute the converter swaps for
                // the pool's real href; nothing in book HTML uses it.
                out += #"data-pool-index="\#(pool.firstIndex(where: { $0 == image }) ?? 0)"#
            } else {
                // Unresolvable: keep the reference harmlessly inert.
                out += #"data-pool-index="-1""#
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return (out, pool)
    }

    /// Gutenberg's editorial furniture, which a reader would never say:
    /// `[Illustration]`, `[Pg 42]`, footnote markers, emphasis marks, the
    /// glyph references encrypted-font KP7 files leave behind — and the
    /// control bytes an engine chokes on, which `SpeechSanitizer` owns.
    static func sanitize(_ text: String) -> String {
        var out = replacing(editorialMarkerRegex, in: text, with: " ")
        out = replacing(glyphReferenceRegex, in: out, with: "")
        // Emphasis: keep the words, drop the marks.
        out = replacing(emphasisRegex, in: out, with: "")
        out = replacing(underscoreEmphasisRegex, in: out, with: "")
        out = out.replacingOccurrences(of: "────", with: " ")
            .replacingOccurrences(of: "————", with: " ")
        out = out.replacingOccurrences(of: "\u{0}", with: "")
        return SpeechSanitizer.clean(out)
    }

    /// First ~400 characters of prose, for a shelf card with no cover.
    static func summary(from items: [Item]) -> String {
        let prose = items.compactMap { item -> String? in
            if case .paragraph(let text) = item { return text }
            return nil
        }
        let condensed = replacing(whitespaceRunRegex, in: prose.joined(separator: " "), with: " ")
        return String(condensed.prefix(400))
    }

    // MARK: - Regexes (compiled once — the book walk runs them over megabytes)

    /// `<head>`, `<style>`, `<script>` and their bodies: never content.
    private static let skippedElementsPattern =
        "(?is)<(script|style|head)\\b[^>]*>.*?</\\1\\s*>"
    private static let pageBreakPattern = "(?i)<mbp:pagebreak\\s*/?>"
    /// Every element that ends a text block, plus the heading openings.
    /// Group 1 = block tag name, group 2 = heading level.
    private static let blockBoundaryPattern =
        "(?i)</?(p|div|li|tr|blockquote|section|article|dd|dt|pre|figcaption)\\b[^>]*>"
            + "|<h([1-6])\\b[^>]*>"
            + "|</h[1-6]>"
            + "|<br\\s*/?>"
    private static let anyTagPattern = "<[^>]{0,400}>"
    private static let editorialMarkerPattern =
        "\\[\\s*(?:Illustration|Pg\\s+[ivxlcdm\\d]+|Footnote[^\\]]*|Transcriber'?s? note[^\\]]*)\\]"
    private static let glyphReferencePattern = "\\(cid:\\d+\\)"
    private static let emphasisPattern = "\\*{1,3}"
    private static let underscoreEmphasisPattern = "(?<![\\p{L}\\p{N}])_{1,3}(?![\\p{L}\\p{N}])"
    private static let whitespaceRunPattern = "\\s+"

    private static let skippedElementsRegex = try? NSRegularExpression(
        pattern: skippedElementsPattern, options: []
    )
    private static let pageBreakRegex = try? NSRegularExpression(pattern: pageBreakPattern, options: [])
    private static let blockBoundaryRegex = try? NSRegularExpression(
        pattern: blockBoundaryPattern, options: []
    )
    private static let anyTagRegex = try? NSRegularExpression(pattern: anyTagPattern, options: [])
    private static let editorialMarkerRegex = try? NSRegularExpression(
        pattern: editorialMarkerPattern, options: [.caseInsensitive]
    )
    private static let glyphReferenceRegex = try? NSRegularExpression(
        pattern: glyphReferencePattern, options: []
    )
    private static let emphasisRegex = try? NSRegularExpression(pattern: emphasisPattern, options: [])
    private static let underscoreEmphasisRegex = try? NSRegularExpression(
        pattern: underscoreEmphasisPattern, options: []
    )
    private static let whitespaceRunRegex = try? NSRegularExpression(pattern: whitespaceRunPattern, options: [])

    private static func replacing(
        _ regex: NSRegularExpression?,
        in text: String,
        with replacement: String
    ) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// Regex matches over a whole string, tolerating a pattern that failed to
    /// compile (which would be a developer error — the patterns above are
    /// literals — but must not take a book import down with it).
    private static func matches(
        of regex: NSRegularExpression?,
        in text: String
    ) -> [NSTextCheckingResult] {
        guard let regex else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // MARK: - EXTH

    /// Metadata records. The handful the shelf and the cover path show are
    /// read; subjects, ASINs, UUIDs and update stamps are skipped rather
    /// than decoded.
    struct Exth {
        var title: String?
        var author: String?
        var publisher: String?
        var language: String?
        /// EXTH 201/203, decoded: the record offset (from the first resource
        /// record) of the cover / cover thumbnail. KindleUnpack's semantics;
        /// `-1` when the writer left the field unset (`0xFFFFFFFF`).
        var coverOffset: Int = -1
        var thumbnailOffset: Int = -1

        init(record: Data) {
            guard record.count >= 12,
                  String(decoding: record[0..<4], as: UTF8.self) == "EXTH" else { return }
            let count = Int(u32(record, 8))
            var cursor = 12
            for _ in 0..<count {
                guard cursor + 8 <= record.count else { break }
                let type = Int(u32(record, cursor))
                let length = Int(u32(record, cursor + 4))
                guard length >= 8, cursor + length <= record.count else { break }
                let payload = Data(record[(cursor + 8)..<(cursor + length)])
                let text = MobiParser.decode(payload, encoding: .utf8)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch type {
                case 100 where !text.isEmpty: author = author ?? text
                case 101 where !text.isEmpty: publisher = publisher ?? text
                case 503 where !text.isEmpty: title = title ?? text
                case 524 where !text.isEmpty: language = language ?? text
                case 201 where payload.count >= 4:
                    let value = Int(u32(payload, payload.count - 4))
                    if value != 0xFFFF_FFFF { coverOffset = value }
                case 203 where payload.count >= 4:
                    let value = Int(u32(payload, payload.count - 4))
                    if value != 0xFFFF_FFFF { thumbnailOffset = value }
                default: break
                }
                cursor += length
            }
        }
    }

    // MARK: - Cover

    /// The book's cover image record.
    ///
    /// The 2026-10-08 device report ("the cover page doesn't show") had two
    /// layers: Huff/CDIC books never got this far (unsupported-variant
    /// import error), and for the books that did, FIRST-image-record is
    /// wrong on every KF8 — the real book measured had a 243×65 publisher
    /// LOGO as its first image record while the cover (517×372) sat at the
    /// EXTH 201 offset, 97 records later. Order of preference:
    ///
    /// 1. **EXTH 201 (KF8 cover offset)** — the writer's own declaration.
    /// 2. **EXTH 203 (thumbnail offset)** — calibre writes this one.
    /// 3. **First image record** — MOBI6 books and writers that set neither.
    static func coverImage(pdb: PalmDatabase, header: MobiHeader, exth: Exth) -> Data? {
        let firstResource = 1 + header.textRecordCount
        guard pdb.recordCount > firstResource else { return nil }
        for offset in [exth.coverOffset, exth.thumbnailOffset] where offset >= 0 {
            let index = firstResource + offset
            guard index < pdb.recordCount, let record = pdb.record(index),
                  let image = Self.imagePayload(record) else { continue }
            return image
        }
        // The first resource record is NOT the cover. In a real book it is
        // usually the two-byte `INDX` index — which is exactly why no mobi
        // ever showed a cover: the magic-byte check ran against `INDX` and
        // gave up there. The resource records hold an index, a FLIS/FCIS
        // pair, a DCTL and then the book's images, in no guaranteed order, so
        // the cover is the first record that actually IS an image. Writers
        // that set neither EXTH field land here — but note a KF8's first
        // image may be a small logo rather than the cover; that is the
        // writer's choice, honored as declared.
        for index in firstResource..<pdb.recordCount {
            guard let record = pdb.record(index), record.count > 8,
                  let image = Self.imagePayload(record) else { continue }
            return image
        }
        return nil
    }

    /// A record's bytes when they are a decodable image payload (JPEG, PNG
    /// or GIF), nil otherwise. A record that is none of these is index or
    /// layout furniture, and writing it as `cover.jpg` would produce an
    /// undecodable file.
    static func imagePayload(_ record: Data) -> Data? {
        guard record.count > 8 else { return nil }
        let isJPEG = record[0] == 0xFF && record[1] == 0xD8
        let isPNG = record[0] == 0x89 && record[1] == 0x50
            && record[2] == 0x4E && record[3] == 0x47
        let isGIF = record[0] == 0x47 && record[1] == 0x49 && record[2] == 0x46
        return isJPEG || isPNG || isGIF ? record : nil
    }

    // MARK: - Byte helpers

    /// PalmDB/MOBI structure fields are stored BIG-endian (68k-era format).
    /// The first draft read these little-endian — every header field decoded
    /// as a byte-swapped value (a 574-record book counted as 15874), so no
    /// real book could parse past the record list.
    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return (UInt16(data[data.startIndex + offset]) << 8)
            | UInt16(data[data.startIndex + offset + 1])
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + offset + index])
        }
        return value
    }
}

// MARK: - Palm Database (PDB)

/// Minimal Palm Database reader: the header, the record-offset list, and
/// record access by index. v0 — the only kind mobipocket books use.
///
/// The record list has a documented quirk: when the "next record IDs" list
/// begins with a zero, the offsets list is padded to a 32-bit boundary (four
/// bytes per entry instead of eight). Both layouts are handled, because the
/// first draft read only the eight-byte form and every book written by a
/// 32-bit-era Palm tool decoded as offsets of zero.
struct PalmDatabase {
    let archive: Data
    private(set) var recordCount = 0
    private var offsets: [Int] = []

    enum DBError: Error, Equatable {
        case malformed(String)
    }

    init(archive: Data) throws {
        self.archive = archive
        guard archive.count > 86 else {
            throw DBError.malformed("file too small for a Palm Database")
        }
        let type = String(decoding: archive[60..<64], as: UTF8.self)
        let creator = String(decoding: archive[64..<68], as: UTF8.self)
        // BOOKMOBI is every Kindle-era book; REAd is ancient PRC.
        guard type == "BOOK", creator == "MOBI" || creator == "REAd" else {
            throw MobiParser.MobiError.notAMobi
        }
        let count = Int(MobiParser.u16(archive, 76))
        guard count > 0, count < 200_000 else {
            throw DBError.malformed("record count \(count) out of range")
        }
        recordCount = count

        // Two record-list layouts exist: 8 bytes per entry (offset, id,
        // attributes) and 4 bytes per entry (offset only). The spec's hint —
        // "a zero first entry in the next-IDs list means the list is padded" —
        // is NOT usable: a normal book's next-IDs list is ALL ZEROS ("no next
        // record"), so the hint is true for essentially every real `.azw3` and
        // the 8-byte list then read as garbage (the first two tests passed only
        // because their fixture wrote an empty next-IDs list too). Choosing by
        // VALIDITY instead is undecidable-by-heuristic in the wrong direction
        // and is what a real reader has to do: read both and keep the one whose
        // offsets are all inside the file and non-decreasing.
        let narrow = offsets(reading: 8, count: count)
        let padded = offsets(reading: 4, count: count)
        if looksValid(padded) && !looksValid(narrow) {
            offsets = padded
        } else {
            offsets = narrow
        }
    }

    /// Reads `count` offsets with the given entry stride. An entry that runs
    /// off the end yields a sentinel that `looksValid` rejects.
    private func offsets(reading entrySize: Int, count: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(count)
        var cursor = 78
        for _ in 0..<count {
            guard cursor + 4 <= archive.count else {
                result.append(-1)
                cursor += entrySize
                continue
            }
            let offset = Int(MobiParser.u32(archive, cursor))
            result.append(offset > 0 ? offset : -1)
            cursor += entrySize
        }
        return result
    }

    /// A layout is plausible when every offset is inside the file, the list
    /// runs forwards (records are stored in order), and the stride still fits.
    private func looksValid(_ candidate: [Int]) -> Bool {
        guard !candidate.isEmpty else { return false }
        var previous = 0
        for offset in candidate {
            guard offset >= 78, offset + 2 < archive.count else { return false }
            guard offset >= previous else { return false }
            previous = offset
        }
        return true
    }

    /// Record bytes at the entry's offset. A deleted record (offset 0, or
    /// the sentinel a truncated list produced) reads as nil rather than a
    /// slice at a nonsense index. There is NO per-record checksum in the
    /// format — an earlier draft stripped two bytes, which shifted every
    /// real book's records and broke the header magic.
    func record(_ index: Int) -> Data? {
        guard offsets.indices.contains(index) else { return nil }
        let start = offsets[index]
        guard start > 78, start < archive.count else { return nil }
        let end = offsets.indices.contains(index + 1) ? offsets[index + 1] : archive.count
        guard end > start, end <= archive.count else { return nil }
        return Data(archive[start..<end])
    }
}
