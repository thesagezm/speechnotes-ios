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
/// Not supported, and said so rather than half-done: Huff/CDIC compression
/// (`'DH'`), KFX containers, and incremental INDX updates.
public enum MobiParser {

    // MARK: - Errors

    public enum MobiError: Error, Equatable {
        /// Not a Palm Database, or one whose `type`/`creator` is not a book.
        case notAMobi
        /// A book this reader cannot decode: DRM-locked, or Huff/CDIC
        /// compressed. Both are proprietary, and silent noise is worse than an
        /// honest message.
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
        public let text: String

        public init(title: String?, text: String) {
            self.title = title
            self.text = text
        }
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
        case 1, 2, 17480:
            break  // 17480 is the "no compression" marker some writers emit
        case 65, 68:  // 'A', 'D' — the first byte of Huff/CDIC's "DH"
            throw MobiError.unsupportedVariant(
                "This book uses Huff/CDIC compression, which isn't supported yet."
            )
        default:
            throw MobiError.malformed("unknown compression \(header.compression)")
        }

        let records = try collectTextRecords(pdb: pdb, header: header)
        var body = decompress(records, compression: header.compression)
        // Some writers end the last record with a sentinel '#'; it is not
        // content.
        if body.last == UInt8(ascii: "#") { body.removeLast() }
        let html = decode(body, encoding: header.textEncoding)
        let meta = Exth(record: header.exthBlob)
        // One flatten, two consumers: the chapters AND the shelf summary read
        // the same item stream (the summary pass used to re-walk the whole
        // book, doubling import time on a 2 MB `.azw3`).
        let items = Self.items(from: html)

        return MobiBook(
            title: meta.title ?? header.title,
            author: meta.author,
            publisher: meta.publisher,
            language: meta.language,
            cover: coverImage(pdb: pdb, header: header),
            chapters: chapters(from: items, wholeBook: html),
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
    static func collectTextRecords(pdb: PalmDatabase, header: MobiHeader) throws -> Data {
        let count = header.textRecordCount
        guard pdb.recordCount >= 1 + count else {
            throw MobiError.malformed(
                "header declares \(count) text record(s) but the file has \(pdb.recordCount)"
            )
        }
        var out = Data()
        out.reserveCapacity(count * min(header.recordSize, 8192))
        for index in 0..<count {
            guard let record = pdb.record(1 + index) else {
                throw MobiError.malformed("text record \(index + 1) of \(count) is missing")
            }
            let cut = trailingEntryBytes(in: record, extraFlags: header.extraFlags)
            let payload = cut < record.count ? record.prefix(record.count - cut) : record
            out.append(payload)
            if out.count > maxTextBytes {
                throw MobiError.malformed(
                    "text records exceed the \(maxTextBytes / (1024 * 1024)) MB cap"
                )
            }
        }
        return out
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
        var flags = extraFlags >> 1
        while flags != 0 {
            if flags & 1 == 1 {
                guard record.count > total else { return 0 }
                total += trailingCount(in: record, upTo: record.count - total)
            }
            flags >>= 1
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
        if compression == 1 || compression == 17480 { return input }
        let bytes = [UInt8](input)
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
            let chunk = String(working[cursor..<range.lowerBound])
            cursor = range.upperBound
            let text = sanitize(replacing(anyTagRegex, in: chunk, with: " "))

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

        let tail = sanitize(replacing(anyTagRegex, in: String(working[cursor...]), with: " "))
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
    static func chapters(from items: [Item], wholeBook html: String) -> [MobiChapter] {
        guard !items.isEmpty else {
            let whole = sanitize(replacing(anyTagRegex, in: html, with: " "))
            return [MobiChapter(title: nil, text: whole)]
        }

        var result: [MobiChapter] = []
        var title: String?
        var buffer: [String] = []
        var characters = 0

        func flush() {
            let body = buffer.filter { !$0.isEmpty }.joined(separator: "\n\n")
            buffer = []
            characters = 0
            guard !body.isEmpty, result.count < maxChapters else { return }
            result.append(MobiChapter(title: title, text: body))
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
                    // Carry the section title onto the continuation so the
                    // contents list doesn't show "Chapter N" mid-section.
                    let carried = title
                    flush()
                    title = carried
                }
            }
        }
        flush()
        if result.isEmpty {
            let whole = sanitize(replacing(anyTagRegex, in: html, with: " "))
            return [MobiChapter(title: nil, text: whole)]
        }
        return result
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

    /// Metadata records. Only the handful the shelf shows are read; subjects,
    /// ASINs, UUIDs and update stamps are skipped rather than decoded.
    struct Exth {
        var title: String?
        var author: String?
        var publisher: String?
        var language: String?

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
                default: break
                }
                cursor += length
            }
        }
    }

    // MARK: - Cover

    /// The first image record. On every writer measured it is the cover. A
    /// record that isn't a JPEG or PNG payload means the layout differs, and
    /// writing it as `cover.jpg` would produce an undecodable file — so nil.
    static func coverImage(pdb: PalmDatabase, header: MobiHeader) -> Data? {
        let firstResource = 1 + header.textRecordCount
        guard pdb.recordCount > firstResource,
              let first = pdb.record(firstResource), first.count > 8 else { return nil }
        let isJPEG = first[0] == 0xFF && first[1] == 0xD8
        let isPNG = first[0] == 0x89 && first[1] == 0x50 && first[2] == 0x4E && first[3] == 0x47
        guard isJPEG || isPNG else { return nil }
        return first
    }

    // MARK: - Byte helpers

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + index]) << (8 * index)
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

        let listStart = 78
        let narrowEnd = listStart + count * 8
        // A zero first entry in the next-IDs list marks the padded layout.
        let isPadded = narrowEnd + 2 <= archive.count
            && MobiParser.u32(archive, narrowEnd) == 0
        let entrySize = isPadded ? 4 : 8
        offsets.reserveCapacity(count)
        var cursor = listStart
        for _ in 0..<count {
            guard cursor + 4 <= archive.count else {
                throw DBError.malformed("record list truncated")
            }
            // A zero offset marks a deleted record: keep the slot so every
            // later index stays right, and let record() return nil for it.
            offsets.append(Int(MobiParser.u32(archive, cursor)))
            cursor += entrySize
        }
    }

    /// Record bytes, 2-byte checksum stripped.
    func record(_ index: Int) -> Data? {
        guard offsets.indices.contains(index) else { return nil }
        let start = offsets[index]
        guard start > 0, start + 8 <= archive.count else { return nil }
        let end = offsets.indices.contains(index + 1) ? offsets[index + 1] : archive.count
        guard end > start, end <= archive.count else { return nil }
        return Data(archive[(start + 2)..<end])
    }
}
