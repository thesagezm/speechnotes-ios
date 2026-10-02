import Foundation

/// RTF (Rich Text Format) reader — the format every word processor since
/// Word 2.0 can still write, and the one behind most "a file I can't open"
/// support requests.
///
/// Scope: the text-bearing parts of an RTF document, which is all this app
/// needs. Handled:
/// - Group nesting (`{`/`}`) with an explicit stack, so a `\par` inside a
///   nested group cannot leak into the paragraph buffer that opened it — the
///   classic bug that turns a whole document into one enormous line.
/// - `\uN?` Unicode escapes (with the ANSI fallback the control's optional
///   replacement character carries), `\'hh` byte escapes, and `\ansicpg`
///   codepages (1252, 1251, 65001 and the Latin-1 floor).
/// - Destination groups that carry content: `\~`, `\line`, `\par`, `\pard`,
///   `\sect`, `\page`, `\tab`, `\cell`, `\row`.
/// - Destinations that must be SKIPPED: the well-known metadata groups
///   (`\fonttbl`, `\colortbl`, `\stylesheet`, `\info`, `\listtable`, …) plus
///   every `\*\…` destination the reader does not understand, whose bodies
///   would otherwise be read aloud as gibberish.
/// - Emphasis (`\b`, `\i`, `\ul`) so a paragraph that is entirely emphasised,
///   short and unpunctuated can open a chapter — the RTF convention for a
///   title standing alone on its line.
/// - `\info`'s `\title`, `\author` and `\subject` for the shelf card.
///
/// Not handled, and said so rather than half-done: `\pict` image payloads
/// (hex blobs this reader skips rather than mis-speaks) and table borders
/// beyond splitting rows at `\cell`/`\row`.
public enum RtfParser {

    public static func parse(archive: Data) throws -> [DocumentChapter] {
        try parseFull(archive: archive).chapters
    }

    public static func parseFull(archive: Data) throws -> DocumentParseResult {
        let reader = RtfReader(data: archive)
        try reader.run()
        guard !reader.blocks.isEmpty else {
            throw DocumentParseError.malformed("no readable text in the RTF document")
        }
        return DocumentParseResult(chapters: chapterize(reader.blocks))
    }

    /// `\info` metadata for the shelf card: title, author, subject.
    public struct Metadata: Equatable {
        public let title: String?
        public let author: String?
        public let subject: String?
    }

    public static func metadata(archive: Data) -> Metadata? {
        let reader = RtfReader(data: archive)
        // The metadata pass never throws: a truncated file still has whatever
        // `\info` it managed to write.
        try? reader.run()
        return reader.metadata
    }
}

// MARK: - The reader

/// One streaming RTF reader.
private final class RtfReader {

    /// One output paragraph in progress.
    private struct Builder {
        var text = ""
        var emphasized = false
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isMarked = false

        var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A group on the stack: the state to restore on `}`.
    private struct GroupState {
        var builder: Builder
        var skipDepth: Int
        var infoKey: String?
    }

    /// Paragraphs, headings and table rows in document order.
    private(set) var blocks: [DocumentItem] = []
    private(set) var metadata: RtfParser.Metadata?

    private var builder = Builder()
    private var stack: [GroupState] = []
    /// Nesting depth of a destination we are skipping. >0 means "read nothing".
    private var skipDepth = 0
    /// Which `\info` field we are inside, if any.
    private var infoKey: String?
    /// Raw bytes seen inside an `\info` field (the builder is bypassed while
    /// skipDepth > 0, so metadata needs its own accumulation).
    private var infoBytes: [UInt8] = []
    private var infoTitle: String?
    private var infoAuthor: String?
    private var infoSubject: String?

    /// Byte-oriented input. RTF is a 7-bit syntax with `\'hh` escapes, so
    /// reading BYTES (not Characters) is what keeps `\'e9` recoverable as one
    /// byte — decoding to String first would have already turned it into `é`
    /// or a replacement character.
    private let bytes: [UInt8]
    private var index = 0
    /// Codepage from `\ansicpg`. CP1252 is the spec's floor for an RTF that
    /// doesn't declare one.
    private var codepage = 1252
    /// Single-byte text accumulated in the current group, decoded at flush.
    private var byteBuffer: [UInt8] = []

    init(data: Data) {
        bytes = [UInt8](data)
    }

    // MARK: Run

    func run() throws {
        // The signature is `{\rtfN` — the `{` plus a backslash plus `rtf`.
        // Checking the two bytes `{r` (which a naive reader does) rejects every
        // real RTF file.
        guard bytes.count > 6,
              bytes[0] == UInt8(ascii: "{"),
              bytes[1] == UInt8(ascii: "\\"),
              bytes[2] == UInt8(ascii: "r"),
              bytes[3] == UInt8(ascii: "t"),
              bytes[4] == UInt8(ascii: "f") else {
            throw DocumentParseError.malformed("not an RTF document")
        }
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                stack.append(GroupState(
                    builder: builder, skipDepth: skipDepth, infoKey: infoKey
                ))
                index += 1
            case UInt8(ascii: "}"):
                closeGroup()
            case UInt8(ascii: "\\"):
                index += 1
                // `\'hh` is a byte escape, not a control word: handle it here
                // so it never reaches `controlWord()` (which would read the
                // `'` as an empty word and lose the byte).
                if index < bytes.count, bytes[index] == UInt8(ascii: "'") {
                    index += 1
                    hexEscape()
                    continue
                }
                controlWord()
            case UInt8(ascii: "\r"), UInt8(ascii: "\n"):
                index += 1
            default:
                // Literal text, but only when we are not inside a destination.
                if skipDepth > 0 {
                    if infoKey != nil { infoBytes.append(byte) }
                    index += 1
                    continue
                }
                byteBuffer.append(byte)
                index += 1
            }
        }
        flushParagraph()
        finishMetadata()
    }

    /// Flushes the group the `}` closes: its paragraph text becomes content
    /// and the enclosing group's state comes back.
    ///
    /// RTF has two paragraph conventions and this handles both: writers that
    /// wrap each paragraph in its own group (`{\pard …}`) and writers that
    /// rely on `\par` inside one long group. Detecting "the parent already has
    /// text" is what tells them apart — without it, the second style produces
    /// one chapter containing the whole document.
    private func closeGroup() {
        if !byteBuffer.isEmpty { decodeByteBufferIntoBuilder() }
        let parentHasText = stack.last.map { !$0.builder.isEmpty } ?? false
        if !builder.isEmpty {
            let finished = builder
            builder = Builder()
            if parentHasText {
                emit(finished)
            } else {
                // Keep accumulating into the parent: this group was a
                // formatting scope, not a paragraph.
                if let last = stack.indices.last {
                    stack[last].builder.text += finished.text
                    stack[last].builder.emphasized =
                        stack[last].builder.emphasized || finished.emphasized
                }
            }
        }
        // An `\info` field's text arrives as raw bytes inside the group that
        // held it, never through the builder (the builder is bypassed while
        // skipDepth > 0) — so it is captured at the group's close.
        if let key = infoKey, !infoBytes.isEmpty {
            captureInfo(key: key, raw: Data(infoBytes))
            infoBytes = []
        }
        guard let state = stack.popLast() else {
            builder = Builder()
            index += 1
            return
        }
        builder = state.builder
        skipDepth = state.skipDepth
        infoKey = state.infoKey
        index += 1
    }

    // MARK: Control words

    private func controlWord() {
        var word = ""
        while index < bytes.count {
            let byte = bytes[index]
            let isLetter = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            if !isLetter { break }
            word.append(Character(UnicodeScalar(byte)))
            index += 1
        }
        // Optional signed numeric parameter.
        var parameter = 0
        var hasParameter = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
            hasParameter = true
            index += 1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                parameter = parameter * 10 + Int(bytes[index] - 48)
                index += 1
            }
        } else if index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
            hasParameter = true
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                parameter = parameter * 10 + Int(bytes[index] - 48)
                index += 1
            }
        }
        // A single space after a control word is a delimiter, not content.
        if index < bytes.count, bytes[index] == UInt8(ascii: " ") {
            index += 1
        }
        apply(word: word, parameter: parameter, hasParameter: hasParameter)
    }

    private func apply(word: String, parameter: Int, hasParameter: Bool) {
        switch word {
        case "ansicpg" where hasParameter:
            codepage = parameter

        // Destinations to skip entirely.
        case "fonttbl", "colortbl", "stylesheet", "listtable", "listoverridetable",
             "generator", "pict", "object", "themedata", "colorschememapping",
             "datastore", "xmlnstbl", "latentstyles", "rsidtbl", "mmathPr",
             "upr", "header", "footer", "headerl", "headerr", "footerl", "footerr",
             "footnote", "ftnsep", "ftnsepc", "ftncn", "aftnsep", "aftnsepc", "aftncn":
            skipDepth += 1
        case "info":
            skipDepth += 1
            infoKey = nil
        case "title", "author", "subject", "keywords", "operator", "company",
             "category", "doccomm" where skipDepth > 0:
            // An `\info` child: capture its text, but never read it aloud.
            infoKey = word
            infoBytes = []

        case "b":
            builder.isBold = parameter != 0
            if builder.isBold { builder.isMarked = true }
        case "i":
            builder.isItalic = parameter != 0
            if builder.isItalic { builder.isMarked = true }
        case "ul", "ulw", "uld", "uldb":
            builder.isUnderlined = parameter != 0
            if builder.isUnderlined { builder.isMarked = true }
        case "ulnone":
            builder.isUnderlined = false
        case "plain":
            builder.isBold = false
            builder.isItalic = false
            builder.isUnderlined = false
            builder.isMarked = false

        case "par", "sect", "page", "line":
            flushParagraph()
        case "pard":
            // A destination change that starts a new paragraph for many
            // writers; flushing is what makes RTF's "paragraph = group" and
            // "paragraph = \par" styles both work.
            flushParagraph()
        case "tab":
            appendText(" ")
        case "cell":
            appendText(", ")
        case "row":
            flushParagraph()

        case "u" where hasParameter:
            // The Unicode escape's optional replacement character follows as
            // `?` or a space, which must be swallowed.
            if index < bytes.count,
               bytes[index] == UInt8(ascii: "?") || bytes[index] == UInt8(ascii: " ") {
                index += 1
            }
            if let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: parameter)) {
                appendText(String(Character(scalar)))
            }

        case "uc" where hasParameter:
            // Skipped count after `\uN`: consume that many characters.
            let count = max(0, parameter)
            var skipped = 0
            while skipped < count, index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\\") || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") {
                    break
                }
                index += 1
                skipped += 1
            }

        case "emdash":
            appendText("\u{2014}")
        case "endash":
            appendText("\u{2013}")
        case "lquote", "rsquo":
            appendText("\u{2018}")
        case "rquote", "lsquo":
            appendText("\u{2019}")
        case "ldblquote":
            appendText("\u{201C}")
        case "rdblquote":
            appendText("\u{201D}")
        case "bullet":
            appendText("\u{2022}")
        case "nbsp":
            appendText("\u{00A0}")

        default:
            break
        }
    }

    /// `\'hh` — one byte in the document's codepage.
    private func hexEscape() {
        guard index + 1 < bytes.count else { index = bytes.count; return }
        let high = hexValue(bytes[index])
        let low = hexValue(bytes[index + 1])
        index += 2
        guard high >= 0, low >= 0 else { return }
        byteBuffer.append(UInt8(high * 16 + low))
    }

    private func hexValue(_ byte: UInt8) -> Int {
        switch byte {
        case 48...57: return Int(byte - 48)          // 0-9
        case 65...70: return Int(byte - 65) + 10     // A-F
        case 97...102: return Int(byte - 97) + 10    // a-f
        default: return -1
        }
    }

    // MARK: Text accumulation

    private func appendText(_ value: String) {
        guard skipDepth == 0 else { return }
        if !byteBuffer.isEmpty { decodeByteBufferIntoBuilder() }
        builder.text += value
        if builder.isBold || builder.isItalic || builder.isUnderlined {
            builder.emphasized = true
        }
    }

    /// The single-byte buffer accumulates `\'hh` and other raw 8-bit bytes;
    /// it is decoded once, in the document's codepage, when text is needed.
    private func decodeByteBufferIntoBuilder() {
        guard !byteBuffer.isEmpty else { return }
        let encoding = Self.encoding(for: codepage)
        if let decoded = String(data: Data(byteBuffer), encoding: encoding) {
            builder.text += decoded
        } else {
            builder.text += String(decoding: byteBuffer, as: UTF8.self)
        }
        if builder.isBold || builder.isItalic || builder.isUnderlined {
            builder.emphasized = true
        }
        byteBuffer = []
    }

    static func encoding(for codepage: Int) -> String.Encoding {
        switch codepage {
        case 65001: return .utf8
        case 1251: return .windowsCP1251
        case 1250: return .windowsCP1250
        default: return .windowsCP1252
        }
    }

    // MARK: Paragraphs

    private func flushParagraph() {
        if !byteBuffer.isEmpty { decodeByteBufferIntoBuilder() }
        let finished = builder
        builder = Builder()
        guard !finished.isEmpty else { return }
        emit(finished)
    }

    private func emit(_ value: Builder) {
        // While a destination is being skipped there is nothing to emit: the
        // builder is bypassed entirely (raw bytes go to `infoBytes`), so this
        // only fires for a group that closed while still marked as skipped.
        guard skipDepth == 0 else { return }
        let text = tidy(value.text)
        guard !text.isEmpty else { return }
        // An emphasised, short, unpunctuated line standing on its own is a
        // heading — the same convention the FB2 and MOBI readers use.
        let looksLikeHeading = value.isMarked
            && value.emphasized
            && text.count <= 120
            && !text.hasSuffix(".")
            && !text.hasSuffix(",")
            && !text.hasSuffix(";")
            && !text.hasSuffix("!")
            && !text.hasSuffix("?")
        if looksLikeHeading {
            blocks.append(.heading(text, level: 2))
        } else {
            blocks.append(.paragraph(text))
        }
    }

    private func captureInfo(key: String, raw: Data) {
        let encoding = Self.encoding(for: codepage)
        let text = String(data: raw, encoding: encoding)
            ?? String(decoding: raw, as: UTF8.self)
        let value = tidy(text)
        guard !value.isEmpty else { return }
        switch key {
        case "title": infoTitle = infoTitle ?? value
        case "author": infoAuthor = infoAuthor ?? value
        case "subject": infoSubject = infoSubject ?? value
        default: break
        }
    }

    private func finishMetadata() {
        guard infoTitle != nil || infoAuthor != nil || infoSubject != nil else { return }
        metadata = RtfParser.Metadata(
            title: infoTitle, author: infoAuthor, subject: infoSubject
        )
    }

    private func tidy(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        out = out.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // An RTF writer's empty paragraph is often a couple of stray spaces
        // plus a tab; the tidy above handles it.
        return out
    }
}

// MARK: - Chapterization

/// RTF carries no outline structure, so chapters are the emphasised
/// standalone lines; everything between them is one chapter. A document with
/// none chunks into ~150-item chapters — the same bound the office parsers use.
private func chapterize(_ items: [DocumentItem]) -> [DocumentChapter] {
    var chapters: [DocumentChapter] = []
    var currentTitle: String?
    var currentBlocks: [DocumentBlock] = []

    func flush() {
        if !currentBlocks.isEmpty || currentTitle != nil {
            chapters.append(DocumentChapter(title: currentTitle, blocks: currentBlocks))
        }
        currentTitle = nil
        currentBlocks = []
    }

    for item in items {
        switch item {
        case .heading(let text, _):
            flush()
            currentTitle = text
        case .paragraph(let text):
            currentBlocks.append(.paragraph(text))
            if currentBlocks.count >= 150 { flush() }
        case .image(let index):
            currentBlocks.append(.image(index))
            if currentBlocks.count >= 150 { flush() }
        case .table(let rows):
            currentBlocks.append(.table(rows))
            if currentBlocks.count >= 150 { flush() }
        }
    }
    flush()
    if chapters.isEmpty { return [DocumentChapter(title: nil, paragraphs: [])] }
    return chapters
}
