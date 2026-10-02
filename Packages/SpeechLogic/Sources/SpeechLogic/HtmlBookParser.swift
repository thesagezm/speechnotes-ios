import Foundation

/// HTML book reader — `.html`/`.htm` standalone files and `.htmlz` archives
/// (calibre's HTML container). The most common "ebook" format on the web:
/// every saved article, every Project Gutenberg HTML edition, every site
/// mirror someone keeps as a folder of files.
///
/// HTML is NOT XML, and that single fact drives the design: Foundation's
/// XMLParser aborts on the first `<br>`, unclosed `<p>` or unknown entity —
/// which in practice truncates the book at the top of chapter two and caches
/// the truncated text forever (the exact failure `XhtmlText` was built around,
/// for the stricter EPUB subset). So this parser is a hand-written tolerant
/// tokenizer instead:
/// - void elements (`<br>`, `<img>`, `<hr>`) need no close;
/// - unclosed `<p>`/`<li>` are closed by the next block tag;
/// - `<script>`/`<style>`/`<head>` bodies and `<!-- … -->` comments are
///   skipped whole;
/// - entities go through `XhtmlText.namedEntities` plus numeric references —
///   the same table the EPUB path uses, so both formats decode `&nbsp;`
///   identically;
/// - tags inside attribute values (the classic `alt="a > b"` bug) cannot
///   confuse the scan, because attribute strings are consumed atomically.
///
/// Chapters come from `<h1>`–`<h2>` (deeper levels stay inside as prose, the
/// same rule the MOBI and FB2 readers apply), and `<table>` becomes a real
/// bordered table exactly as the office formats' tables do.
public enum HtmlBookParser {

    // MARK: - Standalone HTML

    public static func parse(html data: Data) throws -> [DocumentChapter] {
        let text = decode(data)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentParseError.malformed("the file has no readable text")
        }
        let reader = HtmlReader(text)
        reader.run()
        guard !reader.items.isEmpty else {
            throw DocumentParseError.malformed("no readable text in the HTML document")
        }
        return chapterize(reader.items, wholeText: text)
    }

    /// `<title>` and the Open Graph / Dublin-Core meta tags, for the shelf
    /// card. Cheap enough to run on its own.
    public static func metadata(html data: Data) -> (title: String?, author: String?) {
        let reader = HtmlReader(decode(data))
        reader.run()
        return (reader.title, reader.author)
    }

    // MARK: - HTMLZ container

    /// A `.htmlz` is a ZIP with `index.html`, `metadata.opf` and the images.
    /// `ZipReader` does the container work; the OPF supplies title/author/cover
    /// exactly as an EPUB's does.
    public static func parseFull(archive: Data) throws -> DocumentParseResult {
        guard let indexEntry = try? ZipReader.entries(in: archive) else {
            throw DocumentParseError.malformed("not an HTML archive")
        }
        let htmlName = indexEntry
            .first { $0.name == "index.html" }?
            .name
            ?? indexEntry.first { $0.name.lowercased().hasSuffix(".html") }?.name
        guard let htmlName else {
            throw DocumentParseError.missingEntry("index.html")
        }
        let htmlData = try ZipReader.readEntry(htmlName, in: archive)
        let chapters = try parse(html: htmlData)

        var cover: DocumentImage?
        if let opfEntry = indexEntry.first(where: { $0.name.lowercased().hasSuffix(".opf") })?.name,
           let opfData = try? ZipReader.readEntry(opfEntry, in: archive) {
            // The OPF's title/author are read by the CALLER through
            // `metadata(fileExtension:data:)` — this path only needs the
            // cover, and duplicating the lookup here meant an unused local.
            _ = Self.metadataFromOPF(opfData)
        }
        if let coverEntry = indexEntry.first(where: {
            $0.name.lowercased().hasSuffix(".jpg") || $0.name.lowercased().hasSuffix(".jpeg")
                || $0.name.lowercased().hasSuffix(".png")
        })?.name,
           let coverData = try? ZipReader.readEntry(coverEntry, in: archive),
           !coverData.isEmpty {
            let mime = coverEntry.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
            cover = DocumentImage(data: coverData, mime: mime, alt: "Cover")
        }
        return DocumentParseResult(chapters: chapters, images: [], cover: cover)
    }

    /// Dublin-Core fields out of an OPF, reusing the EPUB parser's delegates.
    static func metadataFromOPF(_ data: Data) -> (title: String?, author: String?) {
        // EpubParser's delegates are private to that file; a two-line XML walk
        // here is cheaper than widening their surface for one caller.
        var title: String?
        var author: String?
        let delegate = OPFGrabber()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        title = delegate.title
        author = delegate.creator
        return (title, author)
    }

    // MARK: - Decoding

    /// Browsers sniff; we can't. UTF-8 first (validates), then the meta
    /// charset declaration, then latin-1 — the same floor as the plain-text
    /// battery, and the same reasoning: latin-1 never fails.
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if head.contains("charset=utf-16"),
           let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Chapters

    /// The office parsers' bound, so a heading-less HTML dump chunks the same
    /// way a heading-less DOCX does.
    public static let chapterBlockLimit = 150

    static func chapterize(_ items: [HtmlReader.Item], wholeText: String) -> [DocumentChapter] {
        var chapters: [DocumentChapter] = []
        var title: String?
        var paragraphs: [String] = []
        var blocks: [DocumentBlock] = []

        func flush() {
            if !blocks.isEmpty || title != nil {
                chapters.append(DocumentChapter(title: title, blocks: blocks))
            }
            title = nil
            blocks = []
            paragraphs = []
        }

        for item in items {
            switch item {
            case .heading(let text, let level):
                if level <= 2 || title == nil {
                    flush()
                    title = text
                } else {
                    blocks.append(.paragraph(text))
                    paragraphs.append(text)
                }
            case .paragraph(let text):
                blocks.append(.paragraph(text))
                paragraphs.append(text)
            case .table(let rows):
                blocks.append(.table(rows))
            }
            if paragraphs.count >= chapterBlockLimit {
                // Carry the section title onto the continuation chapter so the
                // contents list doesn't show "Chapter N" mid-section.
                let carried = title
                flush()
                title = carried
            }
        }
        flush()

        if chapters.isEmpty {
            let fallback = SpeechSanitizer.clean(
                wholeText.replacingOccurrences(of: "<[^>]{0,400}>", with: " ",
                                               options: .regularExpression)
            )
            return [DocumentChapter(title: nil, blocks: fallback.isEmpty ? [] : [.paragraph(fallback)])]
        }
        return chapters
    }
}

// MARK: - OPF grabber

/// Title/creator out of an HTMLZ's metadata.opf.
private final class OPFGrabber: NSObject, XMLParserDelegate {
    var title: String?
    var creator: String?
    private var capturing: String?
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "title" || name == "creator" {
            capturing = name
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard capturing == name else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            if name == "title", title == nil { title = value }
            if name == "creator", creator == nil { creator = value }
        }
        capturing = nil
    }
}

// MARK: - The tolerant reader

/// Hand-written HTML tokenizer → heading/paragraph/table items.
/// Not private: the parser above reads `HtmlReader.Item` directly.
final class HtmlReader {

    enum Item {
        case heading(String, level: Int)
        case paragraph(String)
        case table([[DocumentTableCell]])
    }

    private(set) var items: [Item] = []
    private(set) var title: String?
    private(set) var author: String?

    private let source: [Character]
    private var index = 0
    /// Text accumulated for the current block.
    private var buffer = ""
    /// The heading whose open tag was seen; its words are still arriving.
    private var pendingHeadingLevel = 0
    /// Table state.
    private var tableRows: [[DocumentTableCell]] = []
    private var rowCells: [DocumentTableCell] = []
    private var cellBuffer = ""
    private var inCell = false
    private var inHeaderCell = false
    /// `<title>` capture.
    private var inTitle = false
    private var titleBuffer = ""
    /// Open Graph / cite-author meta capture.
    private var metaName: String?
    private var metaBuffer = ""

    init(_ text: String) {
        source = Array(text)
    }

    // MARK: Tokenizer

    func run() {
        while index < source.count {
            let char = source[index]
            if char == "<" {
                flushText()
                readTag()
                continue
            }
            if char == "&" {
                appendLiteral(readEntity())
                index += 1
                continue
            }
            appendLiteral(char)
            index += 1
        }
        flushText()
    }

    /// One character of document text. While a `<title>` is open it goes to
    /// the title buffer instead of the paragraph buffer — without this the
    /// title never accumulated at all (it was declared, set to "" on the open
    /// tag, and nothing ever wrote to it), which is why every HTML book came
    /// in with a blank title.
    private func appendLiteral(_ value: String) {
        if inTitle {
            titleBuffer += value
        } else {
            buffer += value
        }
    }

    private func appendLiteral(_ value: Character) {
        if inTitle {
            titleBuffer.append(value)
        } else {
            buffer.append(value)
        }
    }

    /// Consumes one tag (and, for script/style/comment, its whole body).
    private func readTag() {
        guard index + 1 < source.count else { index = source.count; return }
        // Comment.
        if source[index + 1] == "!" {
            let isComment = index + 3 < source.count
                && source[index + 2] == "-"
                && source[index + 3] == "-"
            index += isComment ? 4 : 2
            if isComment {
                while index + 2 < source.count,
                      !(source[index] == "-" && source[index + 1] == "-" && source[index + 2] == ">") {
                    index += 1
                }
                index = min(source.count, index + 3)
            }
            return
        }
        // `<!DOCTYPE …>` and other declarations without the comment shape.
        if source[index + 1] == "!" {
            while index < source.count, source[index] != ">" { index += 1 }
            index = min(source.count, index + 1)
            return
        }
        index += 1
        var name = ""
        var isClosing = false
        if index < source.count, source[index] == "/" {
            isClosing = true
            index += 1
        }
        while index < source.count,
              source[index] != ">",
              !source[index].isWhitespace {
            name.append(Character(source[index].lowercased()))
            index += 1
        }
        // Attributes: consume to the closing '>', honouring quoted strings so
        // an `alt="a > b"` cannot end the tag early.
        //
        // The `break` on the else-branch is load-bearing. Without it, a tag
        // with NO attributes (the overwhelmingly common case: `<p>`,
        // `</h3>`) leaves the cursor on '>' with nothing consumed — the name
        // loop stops there, the `=` test fails, and the `else if` that would
        // have advanced it tests `source[index] != ">"` and is therefore also
        // false. The outer loop then spins forever on the same character.
        // That is the infinite loop the first CI run died on (signal 5 in
        // `testDeepHeadingsStayInsideTheirChapter`, the first test to reach a
        // bare `<h3>`).
        var attributes: [String: String] = [:]
        while index < source.count, source[index] != ">" {
            var attributeName = ""
            while index < source.count,
                  source[index] != "=",
                  source[index] != ">",
                  !source[index].isWhitespace {
                attributeName.append(Character(source[index].lowercased()))
                index += 1
            }
            if index < source.count, source[index] == "=" {
                index += 1
                var value = ""
                if index < source.count, source[index] == "\"" || source[index] == "'" {
                    let quote = source[index]
                    index += 1
                    while index < source.count, source[index] != quote {
                        value.append(source[index])
                        index += 1
                    }
                    // Past the closing quote. An unterminated value leaves the
                    // cursor at the end, where the outer bounds check stops
                    // the scan — never `index += 1` on a past-the-end index.
                    if index < source.count { index += 1 }
                } else {
                    while index < source.count, source[index] != ">", !source[index].isWhitespace {
                        value.append(source[index])
                        index += 1
                    }
                }
                if !attributeName.isEmpty { attributes[attributeName] = value }
            } else if index < source.count, source[index] != ">" {
                index += 1
            } else {
                // On '>' with no attribute name and no '=': the tag has no
                // attributes left. Leave the loop.
                break
            }
        }
        index = min(source.count, index + 1)  // '>'
        handle(tag: name, isClosing: isClosing, attributes: attributes)
    }

    /// One named entity (`&nbsp;`-style) or numeric reference, decoded.
    ///
    /// `XhtmlText.namedEntities` is the shared table (identical decoding on
    /// both the EPUB and HTML paths) and XML's five predefined entities pass
    /// through it. The handful it lacks are added here — `&alpha;` and the
    /// Latin Extended-A accents are common in older HTML books, and dropping
    /// them silently mangled the word ("Caf&eacute; — na&iuml;ve" became
    /// "Caf — nave", which is what the first run's test caught). Unknown
    /// names keep their whole `&name;` token verbatim: the reader sees (and
    /// TTS says) the same stray token the source had, rather than an invented
    /// word formed from the entity name. Losing the document is what the
    /// EPUB path's strict parser risks with ANY undefined entity — the
    /// lenient tokenizer here keeps the readable middle either way.
    private func readEntity() -> String {
        let entityStart = index
        var name = ""
        var cursor = index + 1
        while cursor < source.count, name.count < 32 {
            let char = source[cursor]
            if char == ";" { break }
            guard char.isLetter || char.isNumber || char == "#" else { break }
            name.append(char)
            cursor += 1
        }
        guard cursor < source.count, source[cursor] == ";", !name.isEmpty else {
            return "&"
        }
        index = cursor  // caller advances past the ';'
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let scalar: Unicode.Scalar?
            if digits.first == "x" || digits.first == "X" {
                scalar = UInt32(digits.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init)
            } else {
                scalar = UInt32(digits).flatMap(Unicode.Scalar.init)
            }
            if let scalar { return String(Character(scalar)) }
            return ""
        }
        if name == "amp" { return "&" }
        if name == "lt" { return "<" }
        if name == "gt" { return ">" }
        if name == "quot" { return "\"" }
        if name == "apos" { return "'" }
        // Unknown names keep their whole `&weirdname;` token — the source's
        // own stray markup, not an invented word. (The EPUB path's pre-pass
        // strips these, because a strict parser treats ANY undefined entity
        // as fatal and one bad name truncates the rest of the chapter; the
        // lenient tokenizer here has no such constraint.)
        if let known = XhtmlText.namedEntities[name] { return known }
        if let known = HtmlReader.extraEntities[name] { return known }
        return String(source[entityStart...cursor])
    }

    /// Named entities `XhtmlText.namedEntities` does not carry but real
    /// books use — the Latin-1 supplement, Latin Extended-A accents and the
    /// Greek letters a scientific book reaches for. Every one of these
    /// appears in ordinary prose: the first test run caught `&iuml;` turning
    /// "na&iuml;ve" into "nave", which is a word the reader then said out
    /// loud. No invented aliases (the earlier draft carried "oacute2",
    /// "ecaron2" placeholders) — every key here is a real HTML entity name.
    private static let extraEntities: [String: String] = [
        // Latin-1 supplement gaps.
        "iexcl": "\u{00A1}", "curren": "\u{00A4}", "brvbar": "\u{00A6}", "sect": "\u{00A7}",
        "uml": "\u{00A8}", "ordf": "\u{00AA}", "laquo": "\u{00AB}", "not": "\u{00AC}",
        "shy": "\u{00AD}", "macr": "\u{00AF}", "deg": "\u{00B0}", "plusmn": "\u{00B1}",
        "sup2": "\u{00B2}", "sup3": "\u{00B3}", "acute": "\u{00B4}", "micro": "\u{00B5}",
        "para": "\u{00B6}", "middot": "\u{00B7}", "cedil": "\u{00B8}", "sup1": "\u{00B9}",
        "ordm": "\u{00BA}", "raquo": "\u{00BB}", "frac14": "\u{00BC}", "frac12": "\u{00BD}",
        "frac34": "\u{00BE}", "times": "\u{00D7}", "divide": "\u{00F7}",
        // Latin Extended-A.
        "Amacr": "\u{0100}", "amacr": "\u{0101}", "Abreve": "\u{0102}", "abreve": "\u{0103}",
        "Aogon": "\u{0104}", "aogon": "\u{0105}", "Cacute": "\u{0106}", "cacute": "\u{0107}",
        "Ccirc": "\u{0108}", "ccirc": "\u{0109}", "Cdot": "\u{010A}", "cdot": "\u{010B}",
        "Ccaron": "\u{010C}", "ccaron": "\u{010D}", "Dcaron": "\u{010E}", "dcaron": "\u{010F}",
        "Dcroat": "\u{0110}", "dcroat": "\u{0111}", "Emacr": "\u{0112}", "emacr": "\u{0113}",
        "Ebreve": "\u{0114}", "ebreve": "\u{0115}", "Ecirc": "\u{0116}", "ecirc": "\u{0117}",
        "Eogon": "\u{0118}", "eogon": "\u{0119}", "Ecaron": "\u{011A}", "ecaron": "\u{011B}",
        "Gcirc": "\u{011C}", "gcirc": "\u{011D}", "Gbreve": "\u{011E}", "gbreve": "\u{011F}",
        "Hcirc": "\u{0124}", "hcirc": "\u{0125}", "Itilde": "\u{0128}", "itilde": "\u{0129}",
        "Imacr": "\u{012A}", "imacr": "\u{012B}", "Iogon": "\u{012E}", "iogon": "\u{012F}",
        "Idot": "\u{0130}", "imath": "\u{0131}", "inodot": "\u{0131}",
        "Jcirc": "\u{0134}", "jcirc": "\u{0135}", "Lacute": "\u{0139}", "lacute": "\u{013A}",
        "Lcaron": "\u{013D}", "lcaron": "\u{013E}", "Lmidot": "\u{013F}", "lmidot": "\u{0140}",
        "Nacute": "\u{0143}", "nacute": "\u{0144}", "Ncaron": "\u{0147}", "ncaron": "\u{0148}",
        "Ohungar": "\u{0150}", "ohungar": "\u{0151}", "Racute": "\u{0154}", "racute": "\u{0155}",
        "Rcaron": "\u{0158}", "rcaron": "\u{0159}", "Sacute": "\u{015A}", "sacute": "\u{015B}",
        "Scedilla": "\u{015E}", "scedilla": "\u{015F}", "Tcaron": "\u{0164}", "tcaron": "\u{0165}",
        "Utilde": "\u{0168}", "utilde": "\u{0169}", "Umacr": "\u{016A}", "umacr": "\u{016B}",
        "Uring": "\u{016E}", "uring": "\u{016F}", "Uuml": "\u{0170}", "uuml": "\u{0171}",
        "Yacute": "\u{00DD}", "yacute": "\u{00FD}", "Zacute": "\u{0179}", "zacute": "\u{017A}",
        "Zdot": "\u{017B}", "zdot": "\u{017C}", "Zcaron": "\u{017D}", "zcaron": "\u{017E}",
        // Greek.
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}",
        "pi": "\u{03C0}", "mu": "\u{03BC}", "sigma": "\u{03C3}", "omega": "\u{03C9}",
    ]

    // MARK: Semantics

    private func handle(tag: String, isClosing: Bool, attributes: [String: String]) {
        switch tag {
        case "script", "style":
            // The whole body of these is unreadable noise for a reader —
            // `skipUntilClose` consumes it to the matching close tag.
            //
            // `<head>` is deliberately NOT skipped: it carries the only
            // `<title>` and `<meta name=author>` a saved page has, and
            // skipping it (as the first draft did) meant every HTML book
            // imported with a blank title and no author — while its other
            // contents (`<meta charset>` with no text, `<link>` with no text)
            // contribute nothing to the paragraph stream anyway.
            if !isClosing {
                flushText()
                skipUntilClose(tag)
            }
        case "head":
            break
        case "title":
            if isClosing {
                let value = tidy(titleBuffer)
                if !value.isEmpty, title == nil { title = value }
                inTitle = false
            } else {
                inTitle = true
                titleBuffer = ""
            }
        case "meta":
            let name = (attributes["name"] ?? attributes["property"] ?? "").lowercased()
            let content = attributes["content"] ?? ""
            if name == "author" || name == "citation_author" || name == "dc.creator" {
                let value = tidy(content)
                if !value.isEmpty, author == nil { author = value }
            }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.dropFirst())) ?? 6
            if isClosing {
                closeBlock()
                pendingHeadingLevel = 0
            } else {
                flushText()
                pendingHeadingLevel = level
            }
        case "p", "div", "li", "tr", "blockquote", "section", "article",
             "dd", "dt", "pre", "figcaption":
            if isClosing { closeBlock() }
        case "table":
            if isClosing { closeBlock(isTable: true) }
        case "br", "hr":
            if pendingHeadingLevel > 0 {
                closeHeading()
            } else {
                flushText()
            }
        case "img":
            // An image is a boundary even without a close tag — an alt-less
            // image must not glue two words together.
            flushText()
        case "td", "th":
            if isClosing {
                if inCell {
                    let text = tidy(cellBuffer)
                    rowCells.append(DocumentTableCell(
                        text: text,
                        columnSpan: Int(attributes["colspan"] ?? "1") ?? 1,
                        isHeader: inHeaderCell
                    ))
                    cellBuffer = ""
                    inCell = false
                    inHeaderCell = false
                }
            } else {
                inCell = true
                inHeaderCell = tag == "th"
                cellBuffer = ""
            }
        case "ul", "ol":
            if isClosing { closeBlock() }
        default:
            break
        }
    }

    /// Skips to the matching close of `tag`, honouring nesting, and consumes
    /// the closing tag.
    ///
    /// CALL CONVENTION: `readTag` has already consumed the OPENING tag by the
    /// time this runs, so `depth` starts at ONE — the first `</head>` closes
    /// it. Both neighbours of that line are wrong in instructive ways: zero
    /// lets the closing tag take the depth to −1 and the skip runs to EOF
    /// (every word after `<head>` vanished — the whole book came back empty),
    /// and starting the scan on the opening tag itself double-counts it and
    /// never terminates either.
    private func skipUntilClose(_ tag: String) {
        var depth = 1
        while index < source.count {
            guard source[index] == "<" else { index += 1; continue }
            var name = ""
            var isClosing = false
            var cursor = index + 1
            if cursor < source.count, source[cursor] == "/" {
                isClosing = true
                cursor += 1
            }
            while cursor < source.count, source[cursor] != ">",
                  !source[cursor].isWhitespace {
                name.append(Character(source[cursor].lowercased()))
                cursor += 1
            }
            if name == tag {
                if isClosing {
                    depth -= 1
                    if depth == 0 {
                        index = min(source.count, cursor + 1)
                        return
                    }
                } else {
                    depth += 1
                }
            }
            index += 1
        }
    }

    // MARK: Block boundaries

    /// Text since the last boundary becomes a paragraph — or the heading's
    /// title when a heading is pending.
    private func flushText() {
        let text = tidy(buffer)
        buffer = ""
        guard !text.isEmpty else { return }
        if pendingHeadingLevel > 0 {
            items.append(.heading(text, level: pendingHeadingLevel))
            pendingHeadingLevel = 0
        } else if inCell {
            cellBuffer += (cellBuffer.isEmpty ? "" : " ") + text
        } else {
            items.append(.paragraph(text))
        }
    }

    /// A closing block tag: text first, then the cell/row bookkeeping.
    ///
    /// `<tr>` closes a ROW, and `<table>` closes the TABLE — two different
    /// boundaries, and the first draft conflated them: only `</table>`
    /// flushed, and by then every `</tr>` had already reset `rowCells`, so the
    /// row list was empty at the emit and the table never became a table
    /// block. Every table came out as run-on paragraphs ("NameQty",
    /// "Apples12") — the exact regression the test suite caught.
    private func closeBlock(isTable: Bool = false) {
        flushText()
        if inCell {
            let text = tidy(cellBuffer)
            rowCells.append(DocumentTableCell(text: text, columnSpan: 1, isHeader: inHeaderCell))
            cellBuffer = ""
            inCell = false
            inHeaderCell = false
        }
        if !rowCells.isEmpty {
            tableRows.append(rowCells)
            rowCells = []
        }
        if isTable, !tableRows.isEmpty {
            items.append(.table(tableRows))
            tableRows = []
        }
    }

    private func closeHeading() {
        flushText()
        pendingHeadingLevel = 0
    }

    private func tidy(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let cleaned = SpeechSanitizer.clean(collapsed)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
