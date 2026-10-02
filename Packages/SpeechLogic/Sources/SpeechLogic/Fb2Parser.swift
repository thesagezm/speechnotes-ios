import Foundation

/// FictionBook (.fb2) parser — the format the largest free Russian-language
/// ebook library ships in, and the friendliest non-EPUB format to support
/// because it is plain XML.
///
/// What it handles:
/// - `<description><title-info>` for title, author, language and series, so
///   the shelf card shows the book's own metadata rather than the filename.
/// - `<body>` sections. A `<title>` with `<level>1` or `<level>2` opens a
///   chapter; deeper levels stay inside as prose. `<subtitle>` joins its title.
/// - `<table>` becomes a real `DocumentTableCell` table, exactly as the office
///   parsers' tables do, so the generated EPUB renders it as a table and the
///   TTS extractor reads it row by row.
/// - `<binary>` images referenced by `<image l:href="#id">` become
///   `DocumentImage`s and package into the EPUB; the one named inside
///   `<coverpage>` rides along as the shelf cover.
/// - Verse (`<v>`), epigraphs and citations.
///
/// ## The de-facto heading fallback
///
/// Plenty of FB2 files carry no `<title>` elements at all — the body is a
/// flat run of `<section>`s that begin with a bold line. Those books would
/// otherwise import as a single chapter. So the first paragraph of a section
/// is treated as a heading when it is entirely emphasised (`<strong>` or
/// `<emphasis>`), short, and not sentence-punctuated: the convention in every
/// such file, and the document's own words either way.
///
/// The result is `[DocumentChapter]` — the same currency
/// `DocumentEpubConverter` turns into an EPUB the reader, the TOC and the TTS
/// chapter pipeline already speak, so nothing downstream changes.
public enum Fb2Parser {

    public static func parse(archive: Data) throws -> [DocumentChapter] {
        try parseFull(archive: archive).chapters
    }

    public static func parseFull(archive: Data) throws -> DocumentParseResult {
        let delegate = Fb2Delegate()
        let parser = XMLParser(data: archive)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        // A parse that aborted with nothing collected means a truncated or
        // damaged file. A partial stream is kept: half a chapter beats none,
        // and FB2 in the wild is often slightly malformed.
        guard parsed || !delegate.items.isEmpty else {
            throw DocumentParseError.malformed(
                parser.parserError?.localizedDescription ?? "XML error"
            )
        }
        guard !delegate.items.isEmpty else {
            throw DocumentParseError.malformed("no readable text in the FictionBook")
        }
        let images = delegate.images
        return DocumentParseResult(
            chapters: chapterize(delegate.items),
            images: images,
            cover: delegate.coverIndex.flatMap { images.indices.contains($0) ? images[$0] : nil }
        )
    }

    /// Metadata the shelf card needs. Cheap enough to read on its own, so the
    /// manifest build can take the title without walking the body.
    public struct Metadata: Equatable {
        public let title: String?
        public let author: String?
        public let language: String?
        public let series: String?
    }

    public static func metadata(archive: Data) -> Metadata {
        let delegate = Fb2Delegate()
        let parser = XMLParser(data: archive)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return Metadata(
            title: delegate.titleText,
            author: delegate.authorText,
            language: delegate.languageText,
            series: delegate.seriesText
        )
    }
}

// MARK: - XML delegate

/// Streaming delegate: FB2 files run to tens of megabytes, so nothing is held
/// but the item stream and the decoded images.
private final class Fb2Delegate: NSObject, XMLParserDelegate {

    /// Depth of open `<title>` elements — 0 outside one.
    private var titleDepth = 0
    /// The `<level>` read inside the current `<title>`, if any.
    private var titleLevel = 1
    /// Where the next paragraph's words belong.
    private enum Pending {
        case body
        /// Directly inside a `<title>`: this paragraph IS its title.
        case title
        /// `<subtitle>`: the half after the em dash.
        case subtitle
    }
    private var pending: Pending = .body
    /// Text buffer for the current leaf-ish element.
    private var buffer = ""
    /// Emphasis depth inside the current paragraph.
    private var emphasisDepth = 0
    /// Section depth, and how many paragraphs this section has opened — the
    /// heading fallback only looks at the FIRST one.
    private var sectionDepth = 0
    private var paragraphsInSection = 0
    private var firstParagraphIsCandidate = false

    // Table state
    private var tableDepth = 0
    private var tableRows: [[DocumentTableCell]] = []
    private var rowCells: [DocumentTableCell] = []
    private var inHeaderCell = false

    // Images
    private var binaryID: String?
    private var binaryBuffer = ""
    /// Image ids referenced by the paragraph being built, emitted after it.
    private var pendingImageIDs: [String] = []
    private var inBody = false
    private var inCoverpage = false
    private var coverImageID: String?
    private(set) var images: [DocumentImage] = []
    private var imagePool: [String: Int] = [:]
    private(set) var coverIndex: Int?

    // Metadata. Each capture has its OWN buffer: sharing one produced
    // "en en" as the author on the first fixture run, because `<lang>en</lang>`
    // was still in the buffer when `<first-name>` started.
    private var titleBuffer = ""
    private var capturingTitle = false
    private var languageBuffer = ""
    private var capturingLanguage = false
    private var seriesBuffer = ""
    private var capturingSeries = false
    private var nameBuffer = ""
    private var capturingName = false
    private var authorParts: [String] = []
    private(set) var titleText: String?
    private(set) var authorText: String?
    private(set) var languageText: String?
    private(set) var seriesText: String?

    /// The parse's item stream: headings, paragraphs, images and tables.
    private(set) var items: [DocumentItem] = []

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch Fb2Delegate.local(elementName) {
        case "body":
            inBody = true
        case "coverpage":
            inCoverpage = true
        case "binary":
            binaryID = attributeDict["id"]
            binaryMime = attributeDict["content-type"] ?? "image/jpeg"
            binaryBuffer = ""
        case "image":
            let href = attributeDict["l:href"]
                ?? attributeDict["href"]
                ?? attributeDict["xlink:href"]
            if let href, href.hasPrefix("#") {
                let id = String(href.dropFirst())
                if inCoverpage, coverImageID == nil { coverImageID = id }
                if inBody { pendingImageIDs.append(id) }
            }
        case "title":
            titleDepth += 1
            titleLevel = 1
            buffer = ""
        case "level":
            buffer = ""
        case "p":
            pending = titleDepth > 0 ? .title : .body
            buffer = ""
            emphasisDepth = 0
            if titleDepth == 0, sectionDepth > 0 {
                paragraphsInSection += 1
                firstParagraphIsCandidate = paragraphsInSection == 1
            } else {
                firstParagraphIsCandidate = false
            }
        case "subtitle":
            pending = titleDepth > 0 ? .subtitle : .body
            buffer = ""
        case "strong", "emphasis":
            emphasisDepth += 1
        case "v", "text":
            buffer = ""
        case "th":
            inHeaderCell = true
            buffer = ""
        case "td":
            buffer = ""
        case "table":
            tableDepth += 1
            if tableDepth == 1 { tableRows = [] }
        case "tr":
            rowCells = []
        case "section":
            sectionDepth += 1
            paragraphsInSection = 0
        case "book-title":
            capturingTitle = true
            titleBuffer = ""
        case "lang":
            capturingLanguage = true
            languageBuffer = ""
        case "series":
            capturingSeries = true
            seriesBuffer = ""
        case "first-name", "middle-name", "last-name", "nick":
            capturingName = true
            nameBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if binaryID != nil {
            binaryBuffer += string
            return
        }
        // Each capture owns its buffer: sharing one produced "en en" as the
        // author on the first fixture run, because `<lang>en</lang>` was still
        // in the buffer when `<first-name>` began.
        if capturingTitle { titleBuffer += string; return }
        if capturingLanguage { languageBuffer += string; return }
        if capturingSeries { seriesBuffer += string; return }
        if capturingName { nameBuffer += string; return }
        if titleDepth > 0 || pending == .body { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Fb2Delegate.local(elementName)
        switch name {
        case "binary":
            appendBinary()
        case "p", "v", "text", "subtitle":
            closeTextElement(named: name)
        case "level":
            let value = Fb2Delegate.tidy(buffer)
            buffer = ""
            if let level = Int(value), level > 0 { titleLevel = level }
        case "title":
            titleDepth = max(0, titleDepth - 1)
            pending = .body
            buffer = ""
        case "strong", "emphasis":
            emphasisDepth = max(0, emphasisDepth - 1)
        case "th", "td":
            let text = Fb2Delegate.tidy(buffer)
            buffer = ""
            if tableDepth > 0 {
                rowCells.append(DocumentTableCell(text: text, columnSpan: 1, isHeader: inHeaderCell))
            }
            inHeaderCell = false
        case "tr":
            if tableDepth > 0, !rowCells.isEmpty {
                tableRows.append(rowCells)
                rowCells = []
            }
        case "table":
            tableDepth = max(0, tableDepth - 1)
            if tableDepth == 0, !tableRows.isEmpty {
                items.append(.table(tableRows))
                tableRows = []
            }
        case "section":
            sectionDepth = max(0, sectionDepth - 1)
        case "coverpage":
            inCoverpage = false
            resolveCover()
        case "body":
            inBody = false
            resolveCover()
        case "book-title":
            let value = Fb2Delegate.tidy(titleBuffer)
            if !value.isEmpty, titleText == nil { titleText = value }
            capturingTitle = false
        case "lang":
            let value = Fb2Delegate.tidy(languageBuffer)
            if !value.isEmpty, languageText == nil { languageText = value }
            capturingLanguage = false
        case "series":
            let value = Fb2Delegate.tidy(seriesBuffer)
            if !value.isEmpty, seriesText == nil { seriesText = value }
            capturingSeries = false
        case "first-name", "middle-name", "last-name", "nick":
            let value = Fb2Delegate.tidy(nameBuffer)
            if !value.isEmpty { authorParts.append(value) }
            capturingName = false
            if authorText == nil, !authorParts.isEmpty {
                authorText = authorParts.joined(separator: " ")
            }
        default:
            break
        }
    }

    // MARK: Element handling

    private func appendBinary() {
        defer {
            binaryID = nil
            binaryBuffer = ""
        }
        guard let id = binaryID else { return }
        // FB2 wraps base64 in whitespace; `ignoreUnknownCharacters` keeps the
        // decode from failing on a stray newline in a hand-edited file.
        guard let data = Data(
            base64Encoded: binaryBuffer,
            options: .ignoreUnknownCharacters
        ), !data.isEmpty else { return }
        guard let mime = Fb2Delegate.displayableMime(for: binaryMime) else { return }
        if let existing = imagePool[id] {
            images[existing] = DocumentImage(data: data, mime: mime, alt: "")
        } else {
            imagePool[id] = images.count
            images.append(DocumentImage(data: data, mime: mime, alt: ""))
        }
    }

    private var binaryMime = "image/jpeg"

    private func resolveCover() {
        guard coverIndex == nil, let id = coverImageID else { return }
        coverIndex = imagePool[id]
    }

    private func closeTextElement(named name: String) {
        let text = Fb2Delegate.tidy(buffer)
        buffer = ""
        let wasCandidate = firstParagraphIsCandidate
        firstParagraphIsCandidate = false

        // Inside a `<title>` the words ARE the title — the title element wraps
        // them in `<p>` and `<subtitle>`, so they arrive as ordinary paragraph
        // events and nothing else distinguishes them.
        if titleDepth > 0 {
            guard !text.isEmpty else { return }
            switch pending {
            case .subtitle:
                // The half after the em dash joins its title.
                if case .heading(let existing, let level) = items.last {
                    items[items.count - 1] = .heading(existing + " — " + text, level: level)
                }
            default:
                items.append(.heading(text, level: titleLevel))
                pending = .subtitle
            }
            return
        }

        guard !text.isEmpty else { return }
        // The de-facto heading convention: a section's first paragraph that is
        // entirely emphasised, short and unpunctuated is its title.
        if name == "p", wasCandidate, emphasisDepth > 0,
           text.count <= 120,
           !text.hasSuffix("."), !text.hasSuffix(","), !text.hasSuffix(";"),
           !text.hasSuffix("!"), !text.hasSuffix("?") {
            items.append(.heading(text, level: 1))
            return
        }
        append(text)
    }

    /// Body paragraph, then any images the paragraph referenced.
    private func append(_ text: String) {
        items.append(.paragraph(text))
        guard !pendingImageIDs.isEmpty else { return }
        let ids = pendingImageIDs
        pendingImageIDs = []
        for id in ids {
            if let index = imagePool[id] { items.append(.image(index)) }
        }
    }

    // MARK: Helpers

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func capturesName(_ name: String) -> Bool {
        ["first-name", "middle-name", "last-name", "nick"].contains(name)
    }

    /// Whitespace and NBSP tidy. FB2's typographic characters arrive as real
    /// characters already; all this does is collapse the indentation
    /// pretty-printed files carry inside `<p>`.
    static func tidy(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let joined = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let collapsed = joined.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A mime type UIImage can decode, or nil — SVG and unknown payloads are
    /// dropped rather than packaged into an EPUB that would show a broken icon.
    static func displayableMime(for mime: String) -> String? {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "image/jpeg"
        case "image/png": return "image/png"
        case "image/gif": return "image/gif"
        case "image/webp": return "image/webp"
        default: return nil
        }
    }
}

// MARK: - Chapterization

/// A level 1–2 `<title>` opens a chapter; deeper titles stay inside as prose.
/// Headless books chunk into ~150-item chapters — the same bound the office
/// parsers use, so the reader's one-chapter-at-a-time memory bound holds.
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
        case .heading(let text, let level):
            if level <= 2 || currentTitle == nil {
                flush()
                currentTitle = text
            } else {
                currentBlocks.append(.paragraph(text))
            }
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
