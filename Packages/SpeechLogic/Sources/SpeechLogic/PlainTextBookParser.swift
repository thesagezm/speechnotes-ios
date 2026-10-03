import Foundation

/// Plain-text and Markdown book reader — the format Project Gutenberg still
/// ships more of than any other, and the one a TTS app is uniquely good at.
///
/// Two jobs, in order of how much they matter:
/// 1. **Chapters.** A 900 kB `.txt` imported as one chapter is unusable — the
///    contents list shows one row and resume always lands at the top. Real
///    text books carry one of four structures, and each gets its own
///    detection:
///    - Markdown headings (`#` … `######`), the strongest signal.
///    - Gutenberg's running headings: a SHORT line, alone between blank
///      lines, that matches `chapter|part|book|section|act|scene|letter|canto`
///      (case-insensitive) — the convention in the whole corpus.
///    - Numbered short lines (`I.`, `12.`, `Chapter 3: …`).
///    - Nothing: chunk by paragraph count, exactly as the office parsers do.
/// 2. **Encoding.** Gutenberg mixes UTF-8 with UTF-16 (the BOM tells you),
///    latin-1 and CP1252; a wrong guess turns every é into two mojibake
///    glyphs. The battery here mirrors `ImportService.decodeText` so a file
///    imported as a NOTE and the same file imported as a BOOK decode the
///    same way.
///
/// Markdown inline syntax (`**bold**`, `*em*`, backticks, `[text](url)`) is
/// stripped rather than spoken — the reader reads the words, not the markup.
public enum PlainTextBookParser {

    /// Ceiling on one document's characters — a 40 MB text dump must fail
    /// with a message rather than take the import down.
    public static let maxCharacters = 4_000_000

    public static func parse(archive: Data) throws -> [DocumentChapter] {
        let text = decode(archive)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentParseError.malformed("the file has no readable text")
        }
        guard text.utf16.count <= maxCharacters else {
            throw DocumentParseError.malformed(
                "the text is \(text.utf16.count / 1000)k characters — beyond the \(maxCharacters / 1_000_000)M cap"
            )
        }
        return chapterize(text)
    }

    /// The encoding battery. Order matters, and the first draft got it wrong
    /// in an instructive way: `String(data:encoding:.utf16BigEndian)` decodes
    /// ANY even-length byte run "successfully" — into CJK garbage — so a
    /// BOM-less latin-1 file came back as mojibake before latin-1 was ever
    /// reached. UTF-16/32 are therefore only tried when their BOM is present;
    /// latin-1 is the floor (it never fails, and every byte maps to a glyph).
    static func decode(_ data: Data) -> String {
        // 1. UTF-8 — validates strictly, so a Latin-1 file never decodes
        // here. The NUL test is what keeps UTF-16 out: a NUL byte is
        // perfectly VALID UTF-8, so without it every UTF-16 file "decoded"
        // here as the right-looking text with a NUL between each character
        // and the UTF-16 branches below were never reached.
        if let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains("\0"),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        // 2. UTF-16, BOM required.
        if data.count >= 2 {
            let first = data[data.startIndex]
            let second = data[data.startIndex + 1]
            if first == 0xFE, second == 0xFF,
               let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if first == 0xFF, second == 0xFE,
               let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        // 3. UTF-32, BOM required (rare, but Gutenberg has shipped them).
        if data.count >= 4 {
            let bytes = [UInt8](data.prefix(4))
            if bytes[0] == 0, bytes[1] == 0, bytes[2] == 0xFE, bytes[3] == 0xFF,
               let text = String(data: data.dropFirst(4), encoding: .utf32BigEndian),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if bytes == [0xFF, 0xFE, 0x00, 0x00],
               let text = String(data: data.dropFirst(4), encoding: .utf32LittleEndian),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        // 4. UTF-16 with NO BOM — Gutenberg and Windows editors both ship
        // these, and the battery's "UTF-16 only on a BOM" rule sent them to
        // latin-1, where the file reads as spaced-out letters with the
        // line breaks stripped (the test that caught it built its fixture
        // with `.utf16BigEndian`, which appends no BOM). The tell is a null
        // byte in every other position; the ambiguity guard refuses a file
        // where both parities are null-heavy (that is binary, not text).
        if let text = bomlessUTF16(data) { return text }
        // 5. Latin-1 — total, and correct for the Western corpus.
        if let text = String(data: data, encoding: .isoLatin1),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes BOM-less UTF-16 by its null-byte pattern, or nil when `data`
    /// is not that shape. Deliberately conservative: a file must look like
    /// text once decoded, or it is left to the latin-1 floor.
    private static func bomlessUTF16(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let sample = [UInt8](data.prefix(4096))
        let pairs = Double(sample.count / 2)
        guard pairs >= 2 else { return nil }
        var evenNulls = 0, oddNulls = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index % 2 == 0 { evenNulls += 1 } else { oddNulls += 1 }
        }
        let evenShare = Double(evenNulls) / pairs
        let oddShare = Double(oddNulls) / pairs
        // A little-endian file nulls the HIGH byte (odd positions); a
        // big-endian one the low byte. Only one parity may look like text.
        let bigEndian = evenShare > 0.3 && oddShare < 0.1
        let littleEndian = oddShare > 0.3 && evenShare < 0.1
        guard bigEndian != littleEndian else { return nil }
        let encoding: String.Encoding = littleEndian ? .utf16LittleEndian : .utf16BigEndian
        // No even-length requirement: a file can carry an odd number of
        // code units, and refusing those helped nobody.
        guard let text = String(data: data, encoding: encoding),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Reject a "decode" that is mostly control characters — that means
        // the pattern was a coincidence. The allowance is 1%, with a floor
        // so a short, genuinely clean string is not rejected by rounding.
        let controls = text.unicodeScalars.filter {
            $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }.count
        guard controls * 100 < max(text.count, 100) else { return nil }
        return text
    }

    // MARK: - Chapters

    /// Bound on one chapter's blocks — the same ceiling the office parsers
    /// use, so a heading-less 900 kB text file still chunks into units the
    /// reader can open one at a time.
    public static let chapterBlockLimit = 150

    /// Splits the text into chapters at its headings, or into `chapterBlockLimit`
    /// -paragraph chunks when it has none. A chapter that fills up carries its
    /// title onto the continuation so the contents list never shows "Chapter N"
    /// mid-section.
    static func chapterize(_ text: String) -> [DocumentChapter] {
        let blocks = textBlocks(from: text)
        guard !blocks.isEmpty else {
            return [DocumentChapter(title: nil, paragraphs: [])]
        }

        var chapters: [DocumentChapter] = []
        var title: String?
        var paragraphs: [String] = []

        func flush() {
            if !paragraphs.isEmpty || title != nil {
                chapters.append(DocumentChapter(title: title, paragraphs: paragraphs))
            }
            paragraphs = []
            // The title carries onto the continuation chapter on purpose —
            // clearing it here is what split one Gutenberg chapter into two.
        }

        for block in blocks {
            if let level = headingLevel(of: block) {
                // A heading closes whatever is open. Level 1–2 always opens a
                // chapter; deeper ones only when nothing is open (documents
                // whose only structure is h3+).
                let headingText = tidyHeading(block)
                guard !headingText.isEmpty else { continue }
                if level <= 2 || title == nil {
                    flush()
                    title = headingText
                } else {
                    paragraphs.append(headingText)
                    if paragraphs.count >= chapterBlockLimit { flush() }
                }
                continue
            }
            paragraphs.append(block)
            if paragraphs.count >= chapterBlockLimit { flush() }
        }
        flush()

        if chapters.isEmpty {
            return [DocumentChapter(title: nil, paragraphs: [])]
        }
        return chapters
    }

    /// A heading's spoken text: the `#` markers go, the words stay.
    static func tidyHeading(_ block: String) -> String {
        guard block.hasPrefix("#") else { return block }
        let withoutMarks = String(block.drop { $0 == "#" })
        return stripMarkdownInline(withoutMarks)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Blocks and headings

    /// Paragraph blocks: blank-line separated, hard-wrapped lines joined.
    /// Markdown inline syntax is stripped here, once, so both the heading
    /// detector and the chapter text see clean prose.
    ///
    /// Three things end a block. A blank line. A Markdown heading. And a
    /// line that ENDS A SENTENCE — a hard-wrapped paragraph only continues
    /// onto the next line while its sentence is unfinished, so "Alpha
    /// prose." / "Beta prose." are two paragraphs while "the lamp post
    /// stood quiet." stays one. Joining unconditionally glued a Gutenberg
    /// running heading to the prose under it: "Chapter One" + "Prose one."
    /// became one block, which then matched the running-heading pattern in
    /// full and swallowed both lines into the chapter title.
    static func textBlocks(from text: String) -> [String] {
        var out: [String] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            paragraph = []
            let cleaned = stripMarkdownInline(joined)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { out.append(cleaned) }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            // A Markdown heading is its own block, never joined to the
            // paragraph above it.
            if line.hasPrefix("#") {
                flush()
                out.append(line)
                continue
            }
            // So is a short running/numbered heading — "Chapter 7", "PART
            // TWO" — even when prose follows it on the very next line.
            if headingLevel(of: line) != nil {
                flush()
                out.append(line)
                continue
            }
            if let previous = paragraph.last, endsSentence(previous) {
                flush()
            }
            paragraph.append(line)
        }
        flush()
        return out
    }

    /// True when a line ends a sentence, so the next line opens a new
    /// paragraph rather than continuing this one. Closing punctuation after
    /// the full stop still counts — `"Go," she said.` ends the sentence.
    private static func endsSentence(_ line: String) -> Bool {
        for character in line.reversed() {
            if character.isWhitespace { continue }
            return "!?.".contains(character)
                || character == "\u{201D}" || character == "\""
                || character == ")" || character == "]"
        }
        return false
    }

    /// The heading level a block opens, or nil when it is prose.
    /// `#`/`##` win; a short line matching the Gutenberg running-heading
    /// vocabulary, or a numbered short line, comes next.
    static func headingLevel(of block: String) -> Int? {
        if block.hasPrefix("#") {
            let level = block.prefix { $0 == "#" }.count
            return min(max(level, 1), 6)
        }
        guard block.count <= 80, block.count >= 2 else { return nil }
        let range = NSRange(block.startIndex..., in: block)
        if runningHeading.firstMatch(in: block, range: range) != nil { return 2 }
        if numberedHeading.firstMatch(in: block, range: range) != nil { return 2 }
        return nil
    }

    /// "Chapter 7", "CHAPTER VII.", "Part Two", "BOOK THE SECOND", "Act I",
    /// "Letter 3", "Canto XXIV" — the running headings of the Gutenberg
    /// corpus, matched as a whole short line.
    static let runningHeading = try! NSRegularExpression(
        pattern: "^(chapter|part|book|section|act|scene|letter|canto|prologue|epilogue|preface|introduction|afterword|foreword)\\b[^\\n]{0,60}$",
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    /// "I.", "12.", "VII — The Letter", "3. The Garden" — numbered heads.
    static let numberedHeading = try! NSRegularExpression(
        pattern: "^((?:[IVXLC]+|\\d{1,3})[.:)—-]?)[ \\t]+[^\\n]{0,60}$",
        options: [.anchorsMatchLines]
    )

    /// `**bold**`, `*em*`, `_em_`, backticks, `[text](url)` and bare URLs —
    /// the reader speaks the words.
    static func stripMarkdownInline(_ text: String) -> String {
        var out = text
        // Links first, so the label survives and the target goes.
        out = out.replacingOccurrences(
            of: "\\[([^\\]]{0,200})\\]\\([^\\)]{0,400}\\)",
            with: "$1",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "!\\[([^\\]]{0,200})\\]\\([^\\)]{0,400}\\)",
            with: " ",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: "\\*{1,3}", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "(?<![\\p{L}\\p{N}])_{1,3}(?![\\p{L}\\p{N}])",
                                       with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "`{1,3}", with: "", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "https?://\\S{0,300}", with: " ", options: .regularExpression
        )
        return SpeechSanitizer.clean(out)
    }
}
