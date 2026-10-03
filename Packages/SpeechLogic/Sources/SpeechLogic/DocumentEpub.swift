import Foundation

/// One image extracted from an office document, ready to be written into the
/// normalized EPUB. `mime` comes from the media file's extension; `alt` from
/// the document's own drawing description when it has one (the TTS text
/// extractor reads the alt attribute).
public struct DocumentImage: Equatable {
    public let data: Data
    public let mime: String
    public let alt: String

    public init(data: Data, mime: String, alt: String = "") {
        self.data = data
        self.mime = mime
        self.alt = alt
    }
}

/// One cell of a parsed office-document table. `columnSpan` carries
/// w:gridSpan / table:number-columns-spanned / a:tc@gridSpan so the emitted
/// HTML keeps its columns aligned; header rows come from w:tblHeader and
/// table:table-header-rows (and a:tbl@firstRow for decks).
public struct DocumentTableCell: Equatable {
    public var text: String
    public var columnSpan: Int
    public var isHeader: Bool

    public init(text: String, columnSpan: Int = 1, isHeader: Bool = false) {
        self.text = text
        self.columnSpan = columnSpan
        self.isHeader = isHeader
    }
}

/// One content block of a document chapter. v1.7.2: the old model was
/// paragraphs only — images were dropped entirely and tables were flattened
/// into run-on paragraphs, which the user rightly called out. Blocks keep
/// the document's real structure so the EPUB can show images full-width and
/// render tables as tables.
public enum DocumentBlock: Equatable {
    case paragraph(String)
    /// Index into the parse result's image pool.
    case image(Int)
    case table([[DocumentTableCell]])
    /// Format-native markup, written into the chapter VERBATIM (after
    /// token substitution). The mobipocket reader produces this: the book's
    /// text records ARE HTML, so the markup is the document — re-tokenizing
    /// it into plain paragraphs is what made every mobi lose its italics,
    /// headings and images (the "mobi renders badly" report).
    case html(String)
}

/// One chapter of a parsed office document: an optional heading title and
/// the content blocks under it. The common currency of the normalize-to-EPUB
/// pipeline (DOCX/ODT/PPTX/ODP/DOC) — every parser reduces its format to
/// this, and one converter turns it into a real EPUB the existing reader,
/// TOC and TTS chapter pipeline already understand.
///
/// `paragraphs` survives as a computed view so the text-only consumers (and
/// every test written against the paragraph-only model) keep working.
public struct DocumentChapter: Equatable {
    public var title: String?
    public var blocks: [DocumentBlock]

    public init(title: String?, paragraphs: [String]) {
        self.title = title
        self.blocks = paragraphs.map { .paragraph($0) }
    }

    public init(title: String?, blocks: [DocumentBlock]) {
        self.title = title
        self.blocks = blocks
    }

    /// The chapter's plain paragraph text — the historical API shape.
    public var paragraphs: [String] {
        blocks.compactMap { block in
            if case .paragraph(let text) = block { return text }
            return nil
        }
    }

    /// Speakable lines for the note-import path: paragraphs as-is, tables as
    /// one comma-joined line PER ROW (matching XhtmlText's table reading),
    /// images dropped (their alt text lives in the parse result, not the
    /// chapter). Nothing a document contains is silently lost when it
    /// becomes a note.
    public var textLines: [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let text):
                return [text]
            case .image:
                return []
            case .table(let rows):
                return rows.map { row in
                    row.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: ", ")
                }
            case .html(let markup):
                // Native markup speaks tag-free; the display keeps the tags.
                let text = DocumentEpubConverter.strippedText(markup)
                return text.isEmpty ? [] : [text]
            }
        }
    }
}

/// What a full parse produces: the chapterized text PLUS everything needed
/// to build the EPUB's media (images referenced by blocks, and an optional
/// embedded cover such as docProps/thumbnail.jpeg).
public struct DocumentParseResult: Equatable {
    public var chapters: [DocumentChapter]
    public var images: [DocumentImage]
    public var cover: DocumentImage?

    public init(chapters: [DocumentChapter], images: [DocumentImage] = [], cover: DocumentImage? = nil) {
        self.chapters = chapters
        self.images = images
        self.cover = cover
    }
}

/// Internal chapterization input — the flat per-document item stream the
/// delegates emit before chapters are cut.
enum DocumentItem {
    case heading(String, level: Int)
    case paragraph(String)
    case image(Int)
    case table([[DocumentTableCell]])
}

extension DocumentItem {
    /// Slides convert their item stream straight to chapter blocks — the
    /// slide title is carried separately, so a heading item never occurs.
    var asBlock: DocumentBlock? {
        switch self {
        case .paragraph(let text): return .paragraph(text)
        case .image(let index): return .image(index)
        case .table(let rows): return .table(rows)
        case .heading: return nil
        }
    }
}

/// Shared image-pool bookkeeping: blocks reference images by pool index so
/// the same media file used twice is stored (and shipped) once.
final class DocumentImagePool {
    private(set) var targets: [String] = []
    private var altByTarget: [String: String] = [:]
    private var indexByTarget: [String: Int] = [:]

    func index(for target: String, alt: String) -> Int {
        if let existing = indexByTarget[target] {
            if (altByTarget[target] ?? "").isEmpty, !alt.isEmpty {
                altByTarget[target] = alt
            }
            return existing
        }
        targets.append(target)
        indexByTarget[target] = targets.count - 1
        altByTarget[target] = alt
        return targets.count - 1
    }

    func alt(for target: String) -> String {
        altByTarget[target] ?? ""
    }
}

/// Error type for the office-document parsers — user-presentable strings
/// ride BooksStore.importError.
public enum DocumentParseError: Error, Equatable {
    case missingEntry(String)
    case malformed(String)
}

extension DocumentParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingEntry(let name):
            return "The file is missing \(name) — it may be a renamed file of a different kind."
        case .malformed(let why):
            return "The document is malformed: \(why)"
        }
    }
}

// MARK: - Shared relationship + media helpers

enum DocumentMedia {
    /// Lexically resolves a relationship target against the base part's
    /// directory ("word" + "media/img1.png" → "word/media/img1.png";
    /// "ppt/slides" + "../media/img1.png" → "ppt/media/img1.png"). Purely
    /// lexical — zip entry names are raw strings.
    static func resolveTarget(baseDir: String, _ target: String) -> String {
        guard !target.hasPrefix("/") else { return String(target.dropFirst()) }
        var stack = baseDir.split(separator: "/").map(String.init)
        for part in target.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(part)
            }
        }
        return stack.joined(separator: "/")
    }

    /// Displayable image mime for a media file extension, or nil for the
    /// formats neither WebKit nor UIImage can show (WMF/EMF metafiles are
    /// common in legacy Word docs — dropping them beats a broken image).
    static func mime(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp", "dib": return "image/bmp"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return nil
        }
    }

    static func fileExtension(forMime mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/bmp": return "bmp"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        default: return "bin"
        }
    }

    /// Loads a relationship's target as a DocumentImage, or nil when the
    /// entry is missing/external/undisplayable.
    static func loadImage(target: String, alt: String, archive: Data) -> DocumentImage? {
        let ext = (target as NSString).pathExtension
        guard let mime = mime(forExtension: ext) else { return nil }
        guard let data = try? ZipReader.readEntry(target, in: archive), !data.isEmpty else { return nil }
        return DocumentImage(data: data, mime: mime, alt: alt)
    }

    /// Resolves a parse's image pool to DocumentImages — pool-ALIGNED, with
    /// a transparent 1×1 GIF standing in for any entry that fails to load
    /// (blocks reference pool indexes; a shifted array would attach every
    /// later image to the wrong block).
    static func resolvePool(_ pool: DocumentImagePool, archive: Data) -> [DocumentImage] {
        pool.targets.map { target in
            loadImage(target: target, alt: pool.alt(for: target), archive: archive)
                ?? DocumentImage(data: transparentPixelGIF, mime: "image/gif", alt: "")
        }
    }

    /// The office suites' embedded document thumbnails, in preference order
    /// (OOXML writes docProps/thumbnail.jpeg; ODF writes
    /// Thumbnails/thumbnail.png).
    static func embeddedThumbnail(archive: Data) -> DocumentImage? {
        let candidates = [
            "docProps/thumbnail.jpeg",
            "docProps/thumbnail.png",
            "Thumbnails/thumbnail.png",
        ]
        for candidate in candidates {
            guard let data = try? ZipReader.readEntry(candidate, in: archive), !data.isEmpty,
                  let mime = mime(forExtension: (candidate as NSString).pathExtension) else { continue }
            return DocumentImage(data: data, mime: mime, alt: "Document thumbnail")
        }
        return nil
    }

    /// Pixel dimensions straight from the file headers (PNG IHDR, GIF
    /// logical screen, BMP DIB header, JPEG SOF scan). Full-width display
    /// is decided from these: real figures/photos get the reader's whole
    /// content width; small icons/logos keep their natural size.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(64))
        func be(_ i: Int) -> Int { bytes.count > i + 3 ? (Int(bytes[i]) << 24 | Int(bytes[i+1]) << 16 | Int(bytes[i+2]) << 8 | Int(bytes[i+3])) : 0 }
        func le(_ i: Int) -> Int { bytes.count > i + 1 ? Int(bytes[i]) | (Int(bytes[i+1]) << 8) : 0 }
        // PNG
        if bytes.count > 24, bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return (be(16), be(20))
        }
        // GIF
        if bytes.count > 10, String(decoding: bytes[0...2], as: UTF8.self) == "GIF" {
            return (le(6), le(8))
        }
        // BMP
        if bytes.count > 26, bytes[0] == 0x42, bytes[1] == 0x4D {
            return (le(18), le(22))
        }
        // JPEG: walk markers to the first SOF
        if bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            var i = 2
            let all = [UInt8](data.prefix(256 * 1024))
            while i + 9 < all.count {
                guard all[i] == 0xFF, all[i+1] != 0x00, all[i+1] != 0xFF else { i += 1; continue }
                let marker = all[i+1]
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    return (Int(all[i+7]) << 8 | Int(all[i+8]), Int(all[i+5]) << 8 | Int(all[i+6]))
                }
                let length = Int(all[i+2]) << 8 | Int(all[i+3])
                i += 2 + length
            }
        }
        return nil
    }

    /// 1×1 transparent GIF — the placeholder that keeps the image pool
    /// index-aligned when a media entry cannot be loaded (a corrupt archive
    /// must not shift every later image onto the wrong block).
    static let transparentPixelGIF = Data(
        base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    ) ?? Data()
}

// MARK: - DOCX

/// WordprocessingML (DOCX) parser — heading structure, tables and images out
/// of word/document.xml, media targets resolved through
/// word/_rels/document.xml.rels. Footnotes remain out of scope.
public enum DocxParser {
    public static func parse(archive: Data) throws -> [DocumentChapter] {
        try parseFull(archive: archive).chapters
    }

    public static func parseFull(archive: Data) throws -> DocumentParseResult {
        let documentXML: Data
        do {
            documentXML = try ZipReader.readEntry("word/document.xml", in: archive)
        } catch let ZipReader.ZipError.entryNotFound(name) {
            throw DocumentParseError.missingEntry(name)
        }

        // rId → zip path. The rels file is optional only for documents with
        // no relationships at all — absent means no images, not an error.
        var relsByRID: [String: String] = [:]
        if let relsData = try? ZipReader.readEntry("word/_rels/document.xml.rels", in: archive) {
            let grabber = AttributeGrabber(elements: ["Relationship"])
            let parser = XMLParser(data: relsData)
            parser.delegate = grabber
            parser.parse()
            for attrs in grabber.captured(for: "Relationship") {
                guard let id = attrs["Id"], let target = attrs["Target"] else { continue }
                guard attrs["TargetMode"] != "External" else { continue }
                relsByRID[id] = DocumentMedia.resolveTarget(baseDir: "word", target)
            }
        }

        let pool = DocumentImagePool()
        let delegate = DocxDelegate(relsByRID: relsByRID, pool: pool)
        let parser = XMLParser(data: documentXML)
        parser.delegate = delegate
        guard parser.parse() else {
            throw DocumentParseError.malformed(parser.parserError?.localizedDescription ?? "XML error")
        }

        let images = DocumentMedia.resolvePool(pool, archive: archive)

        return DocumentParseResult(
            chapters: chapterize(delegate.items),
            images: images,
            cover: DocumentMedia.embeddedThumbnail(archive: archive)
        )
    }
}

private final class DocxDelegate: NSObject, XMLParserDelegate {
    struct Paragraph {
        var text: String = ""
        var headingLevel: Int = 0 // 0 = body text, 1...6
    }

    private let relsByRID: [String: String]
    private let pool: DocumentImagePool

    private(set) var items: [DocumentItem] = []
    private var altByRID: [String: String] = [:]
    private var pendingImageIndexes: [Int] = []

    private var current: Paragraph?
    private var inText = false

    // Table state (w:tbl / w:tr / w:tc; nested tables' content is dropped —
    // a table inside a cell is rare in documents meant to be read aloud,
    // and keeping only the outer row's text avoids scrambled output).
    private var tblDepth = 0
    private var tableRows: [[DocumentTableCell]] = []
    private var rowCells: [DocumentTableCell] = []
    private var rowIsHeader = false
    private var inCell = false
    private var cellLines: [String] = []
    private var cellLine = ""
    private var cellSpan = 1

    init(relsByRID: [String: String], pool: DocumentImagePool) {
        self.relsByRID = relsByRID
        self.pool = pool
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch Self.local(elementName) {
        case "p":
            if tblDepth == 0 {
                current = Paragraph()
            } else if inCell {
                cellLine = ""
            }
            inText = false
        case "pStyle":
            guard current != nil else { return }
            let style = attributeDict["w:val"] ?? attributeDict.values.first { $0.hasPrefix("Heading") } ?? ""
            if style == "Title" {
                current?.headingLevel = 1
            } else if style.hasPrefix("Heading"), let level = Int(style.dropFirst("Heading".count)) {
                current?.headingLevel = min(max(level, 1), 6)
            }
        case "t":
            inText = true
        case "tab":
            if tblDepth == 0 {
                current?.text += " "
            } else if inCell {
                cellLine += " "
            }
        case "br":
            if tblDepth == 0 {
                current?.text += "\n"
            } else if inCell {
                cellLine += "\n"
            }
        case "tbl":
            tblDepth += 1
            if tblDepth == 1 { tableRows = [] }
        case "tr":
            if tblDepth == 1 {
                rowCells = []
                rowIsHeader = false
            }
        case "tblHeader":
            if tblDepth == 1 { rowIsHeader = true }
        case "tc":
            if tblDepth == 1 {
                inCell = true
                cellLines = []
                cellLine = ""
                cellSpan = 1
            }
        case "gridSpan":
            let raw = attributeDict["w:val"] ?? attributeDict.values.first ?? "1"
            cellSpan = max(1, Int(raw) ?? 1)
        case "blip":
            // DrawingML image reference (r:embed, or r:link for linked
            // pictures — same target lookup, the link target is still a
            // package part when embedded).
            if let rid = attributeDict["r:embed"] ?? attributeDict["r:link"] {
                recordImage(rid: rid)
            }
        case "imagedata":
            // Legacy VML image (w:object).
            if let rid = attributeDict["r:id"] {
                recordImage(rid: rid)
            }
        case "docPr":
            // The drawing's accessible name/description — the best alt text
            // the document offers.
            let alt = attributeDict["descr"] ?? attributeDict["name"] ?? ""
            if !alt.isEmpty { latestImageAlt = alt }
        default:
            break
        }
    }

    private var latestImageAlt = ""

    private func recordImage(rid: String) {
        // Images inside table cells are dropped for now — they complicate
        // the cell text model and are rare in prose documents.
        guard tblDepth == 0, let target = relsByRID[rid] else { return }
        let alt = latestImageAlt
        latestImageAlt = ""
        pendingImageIndexes.append(pool.index(for: target, alt: alt))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        if tblDepth == 0 {
            guard var paragraph = current else { return }
            paragraph.text += string
            current = paragraph
        } else if inCell {
            cellLine += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch Self.local(elementName) {
        case "t":
            inText = false
        case "p":
            if tblDepth == 0 {
                flushParagraphWithImages()
            } else if inCell {
                cellLines.append(cellLine)
            }
        case "tc":
            if inCell, tblDepth == 1 {
                let text = cellLines
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                rowCells.append(DocumentTableCell(text: text, columnSpan: cellSpan, isHeader: rowIsHeader))
                inCell = false
            }
        case "tr":
            if tblDepth == 1, !rowCells.isEmpty {
                tableRows.append(rowCells)
                rowCells = []
            }
        case "tbl":
            tblDepth = max(0, tblDepth - 1)
            if tblDepth == 0, !tableRows.isEmpty {
                items.append(.table(tableRows))
                tableRows = []
            }
        default:
            break
        }
    }

    /// A body paragraph ended: emit its text, then any images the paragraph
    /// carried (inline and anchored drawings both live inside runs of a
    /// w:p — they surface as their own block right after the text).
    private func flushParagraphWithImages() {
        if var paragraph = current {
            paragraph.text = paragraph.text
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.text.isEmpty {
                items.append(
                    paragraph.headingLevel > 0
                        ? .heading(paragraph.text, level: paragraph.headingLevel)
                        : .paragraph(paragraph.text)
                )
            }
        }
        current = nil
        inText = false
        for index in pendingImageIndexes {
            items.append(.image(index))
        }
        pendingImageIndexes = []
    }

    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

// MARK: - ODT

/// OpenDocument Text parser — text:h / text:p, draw:image frames and
/// table:table out of content.xml. Media hrefs point at package paths
/// ("Pictures/…", sometimes with leading "../"), normalized lexically.
public enum OdtParser {
    public static func parse(archive: Data) throws -> [DocumentChapter] {
        try parseFull(archive: archive).chapters
    }

    public static func parseFull(archive: Data) throws -> DocumentParseResult {
        let contentXML: Data
        do {
            contentXML = try ZipReader.readEntry("content.xml", in: archive)
        } catch let ZipReader.ZipError.entryNotFound(name) {
            throw DocumentParseError.missingEntry(name)
        }
        let pool = DocumentImagePool()
        let delegate = OdtDelegate(pool: pool)
        let parser = XMLParser(data: contentXML)
        parser.delegate = delegate
        guard parser.parse() else {
            throw DocumentParseError.malformed(parser.parserError?.localizedDescription ?? "XML error")
        }
        let images = DocumentMedia.resolvePool(pool, archive: archive)
        return DocumentParseResult(
            chapters: chapterize(delegate.items),
            images: images,
            cover: DocumentMedia.embeddedThumbnail(archive: archive)
        )
    }
}

private final class OdtDelegate: NSObject, XMLParserDelegate {
    private let pool: DocumentImagePool
    private(set) var items: [DocumentItem] = []
    private var currentText: String?
    private var currentHeadingLevel = 0
    private var inside = false
    private var pendingImageIndexes: [Int] = []

    // Table state
    private var tblDepth = 0
    private var inHeaderRows = false
    private var tableRows: [[DocumentTableCell]] = []
    private var rowCells: [DocumentTableCell] = []
    private var inCell = false
    private var cellIsCovered = false
    private var cellLines: [String] = []
    private var cellLine = ""
    private var cellSpan = 1

    init(pool: DocumentImagePool) {
        self.pool = pool
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch DocxDelegate.local(elementName) {
        case "h":
            inside = true
            currentText = ""
            let level = Int(attributeDict["text:outline-level"] ?? "1") ?? 1
            currentHeadingLevel = min(max(level, 1), 6)
        case "p":
            inside = true
            currentText = ""
            currentHeadingLevel = 0
            if tblDepth > 0 { cellLine = "" }
        case "tab":
            append(" ")
        case "line-break":
            append("\n")
        case "s":
            // text:s is a run of literal spaces (c attribute, default 1).
            let count = Int(attributeDict["text:c"] ?? "1") ?? 1
            append(String(repeating: " ", count: count))
        case "table":
            tblDepth += 1
            if tblDepth == 1 { tableRows = [] }
        case "table-header-rows":
            inHeaderRows = true
        case "table-row":
            if tblDepth == 1 {
                rowCells = []
            }
        case "table-cell":
            if tblDepth == 1 {
                inCell = true
                cellIsCovered = false
                cellLines = []
                cellLine = ""
                let raw = attributeDict["table:number-columns-spanned"] ?? "1"
                cellSpan = max(1, Int(raw) ?? 1)
            }
        case "covered-table-cell":
            if tblDepth == 1 {
                // The masked continuation of a spanned cell — HTML's colspan
                // already covers it; emitting it would duplicate the column.
                inCell = true
                cellIsCovered = true
                cellLines = []
                cellLine = ""
                cellSpan = 1
            }
        case "image":
            // draw:image carries xlink:href to the package picture. Images
            // inside table cells are dropped (same rule as DOCX): they
            // would land in the block stream ahead of their own table.
            if tblDepth == 0,
               let href = attributeDict["xlink:href"] ?? attributeDict["href"], !href.isEmpty {
                let target = DocumentMedia.resolveTarget(baseDir: "", href)
                pendingImageIndexes.append(pool.index(for: target, alt: ""))
            }
        default:
            break
        }
    }

    /// Text goes to the paragraph outside tables, and to the current cell
    /// line inside them.
    private func append(_ value: String) {
        if tblDepth > 0, inCell {
            cellLine += value
        } else if inside, currentText != nil {
            currentText? += value
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch DocxDelegate.local(elementName) {
        case "h", "p":
            if tblDepth > 0, inCell {
                cellLines.append(cellLine)
                cellLine = ""
            } else if inside {
                flushParagraph()
            }
        case "table-cell", "covered-table-cell":
            if inCell, tblDepth == 1 {
                if !cellIsCovered {
                    let text = cellLines
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    rowCells.append(DocumentTableCell(text: text, columnSpan: cellSpan, isHeader: inHeaderRows))
                }
                inCell = false
                cellIsCovered = false
            }
        case "table-row":
            if tblDepth == 1, !rowCells.isEmpty {
                tableRows.append(rowCells)
                rowCells = []
            }
        case "table-header-rows":
            inHeaderRows = false
        case "table":
            tblDepth = max(0, tblDepth - 1)
            if tblDepth == 0, !tableRows.isEmpty {
                items.append(.table(tableRows))
                tableRows = []
            }
        case "frame":
            // Images sit in draw:frames, sometimes with no paragraph around
            // them — the frame close is their last chance to land.
            flushPendingImages()
        default:
            break
        }
    }

    private func flushParagraph() {
        if let text = currentText {
            let clean = text
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                items.append(currentHeadingLevel > 0 ? .heading(clean, level: currentHeadingLevel) : .paragraph(clean))
            }
        }
        currentText = nil
        inside = false
        currentHeadingLevel = 0
        flushPendingImages()
    }

    private func flushPendingImages() {
        for index in pendingImageIndexes {
            items.append(.image(index))
        }
        pendingImageIndexes = []
    }
}

// MARK: - PPTX (slides as chapters)

/// PowerPoint parser — one chapter per slide, slide ORDER resolved through
/// ppt/presentation.xml + its relationships (rIds), numeric-name sort as
/// the fallback. Slide media comes from each slide's own rels part
/// (ppt/slides/_rels/slideN.xml.rels). Speaker notes are out of scope.
public enum PptxParser {
    public static func parse(archive: Data) throws -> [DocumentChapter] {
        try parseFull(archive: archive).chapters
    }

    public static func parseFull(archive: Data) throws -> DocumentParseResult {
        let slidePaths = try orderedSlidePaths(archive: archive)
        guard !slidePaths.isEmpty else {
            throw DocumentParseError.malformed("no slides found")
        }
        let pool = DocumentImagePool()
        var chapters: [DocumentChapter] = []
        for (index, path) in slidePaths.enumerated() {
            // This slide's own relationships — targets are relative to
            // ppt/slides/.
            var relsByRID: [String: String] = [:]
            let relsPath = (path as NSString).deletingLastPathComponent
                + "/_rels/" + ((path as NSString).lastPathComponent as String) + ".rels"
            if let relsData = try? ZipReader.readEntry(relsPath, in: archive) {
                let grabber = AttributeGrabber(elements: ["Relationship"])
                let parser = XMLParser(data: relsData)
                parser.delegate = grabber
                parser.parse()
                for attrs in grabber.captured(for: "Relationship") {
                    guard let id = attrs["Id"], let target = attrs["Target"] else { continue }
                    guard attrs["TargetMode"] != "External" else { continue }
                    relsByRID[id] = DocumentMedia.resolveTarget(baseDir: "ppt/slides", target)
                }
            }

            let xml = try ZipReader.readEntry(path, in: archive)
            let delegate = SlideDelegate(relsByRID: relsByRID, pool: pool)
            let parser = XMLParser(data: xml)
            parser.delegate = delegate
            guard parser.parse() else {
                throw DocumentParseError.malformed("slide \(index + 1): \(parser.parserError?.localizedDescription ?? "XML error")")
            }
            chapters.append(
                DocumentChapter(
                    title: delegate.title ?? "Slide \(index + 1)",
                    blocks: delegate.items.compactMap(\.asBlock)
                )
            )
        }
        let images = DocumentMedia.resolvePool(pool, archive: archive)
        return DocumentParseResult(
            chapters: chapters,
            images: images,
            cover: DocumentMedia.embeddedThumbnail(archive: archive)
        )
    }

    /// Reads ppt/presentation.xml's sldIdLst (rIds) and maps them through
    /// ppt/_rels/presentation.xml.rels to slide files. Any deck that ships
    /// without one of the two falls back to natural numeric sort of
    /// ppt/slides/slideN.xml.
    private static func orderedSlidePaths(archive: Data) throws -> [String] {
        let entries = try ZipReader.entries(in: archive)
        let names = Set(entries.map(\.name))

        var rels: [String: String] = [:] // rId -> target path
        if names.contains("ppt/_rels/presentation.xml.rels") {
            let data = try ZipReader.readEntry("ppt/_rels/presentation.xml.rels", in: archive)
            let delegate = AttributeGrabber(elements: ["Relationship"])
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            for attrs in delegate.captured(for: "Relationship") {
                guard let id = attrs["Id"], let target = attrs["Target"] else { continue }
                // Targets are relative to ppt/ (e.g. "slides/slide1.xml").
                rels[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "ppt/" + target
            }
        }

        var ordered: [String] = []
        if names.contains("ppt/presentation.xml") {
            let data = try ZipReader.readEntry("ppt/presentation.xml", in: archive)
            let delegate = AttributeGrabber(elements: ["sldId"])
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            for attrs in delegate.captured(for: "sldId") {
                // r:id is the namespaced attribute; XMLParser hands the
                // qualified name through.
                if let rId = attrs["r:id"] ?? attrs["id"], let path = rels[rId] {
                    ordered.append(path)
                }
            }
        }
        ordered = ordered.filter { names.contains($0) }

        if ordered.isEmpty {
            ordered = names
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { slideNumber($0) < slideNumber($1) }
        }
        return ordered
    }

    private static func slideNumber(_ path: String) -> Int {
        let stem = (path as NSString).deletingPathExtension
        let digits = stem.split(separator: "/").last.map { String($0).filter(\.isNumber) } ?? ""
        return Int(digits) ?? Int.max
    }
}

/// One slide's content in document order: the title shape's first paragraph
/// becomes the title, everything else becomes blocks (paragraphs, picture
/// blocks, DrawingML tables).
private final class SlideDelegate: NSObject, XMLParserDelegate {
    private let relsByRID: [String: String]
    private let pool: DocumentImagePool

    private(set) var title: String?
    private(set) var items: [DocumentItem] = []
    private var inTitleShape = false
    private var currentText: String?

    // Table state (a:tbl inside p:graphicFrame)
    private var tblDepth = 0
    private var tableRows: [[DocumentTableCell]] = []
    private var rowCells: [DocumentTableCell] = []
    private var nextRowIsHeader = false
    private var inCell = false
    private var cellLines: [String] = []
    private var cellLine = ""
    private var cellSpan = 1
    private var pendingImageIndexes: [Int] = []

    init(relsByRID: [String: String], pool: DocumentImagePool) {
        self.relsByRID = relsByRID
        self.pool = pool
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch DocxDelegate.local(elementName) {
        case "ph":
            let kind = attributeDict["type"] ?? ""
            inTitleShape = kind == "title" || kind == "ctrTitle"
        case "p":
            if tblDepth > 0, inCell {
                cellLine = ""
            } else {
                currentText = ""
            }
        case "t":
            if currentText == nil && !(tblDepth > 0 && inCell) { currentText = "" }
        case "blip":
            if let rid = attributeDict["r:embed"] ?? attributeDict["r:link"],
               let target = relsByRID[rid] {
                pendingImageIndexes.append(pool.index(for: target, alt: ""))
            }
        case "pic":
            break // images flush at the pic close, below
        case "tbl":
            tblDepth += 1
            if tblDepth == 1 {
                tableRows = []
                nextRowIsHeader = false
            }
        case "tblPr":
            if tblDepth == 1, (attributeDict["firstRow"] ?? "0") == "1" {
                nextRowIsHeader = true
            }
        case "tr":
            if tblDepth == 1 {
                rowCells = []
            }
        case "tc":
            if tblDepth == 1 {
                inCell = true
                cellLines = []
                cellLine = ""
                cellSpan = max(1, Int(attributeDict["gridSpan"] ?? "1") ?? 1)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if tblDepth > 0, inCell {
            cellLine += string
        } else {
            currentText? += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch DocxDelegate.local(elementName) {
        case "p":
            if tblDepth > 0, inCell {
                cellLines.append(cellLine)
                cellLine = ""
            } else if var text = currentText {
                text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    if inTitleShape && title == nil {
                        title = text
                    } else {
                        items.append(.paragraph(text))
                    }
                }
            }
            currentText = nil
        case "pic":
            // The whole picture shape ended — its image lands as a block.
            for index in pendingImageIndexes {
                items.append(.image(index))
            }
            pendingImageIndexes = []
        case "tc":
            if inCell, tblDepth == 1 {
                let text = cellLines
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                rowCells.append(DocumentTableCell(text: text, columnSpan: cellSpan, isHeader: nextRowIsHeader))
                inCell = false
            }
        case "tr":
            if tblDepth == 1, !rowCells.isEmpty {
                tableRows.append(rowCells)
                rowCells = []
                nextRowIsHeader = false
            }
        case "tbl":
            tblDepth = max(0, tblDepth - 1)
            if tblDepth == 0, !tableRows.isEmpty {
                items.append(.table(tableRows))
                tableRows = []
            }
        case "sp":
            inTitleShape = false
        default:
            break
        }
    }
}

/// Minimal attribute collector for relationship/ordering XML — captures the
/// attribute dictionaries of the named elements (local-name matched).
private final class AttributeGrabber: NSObject, XMLParserDelegate {
    private let targets: Set<String>
    private var captured: [String: [[String: String]]] = [:]

    init(elements: [String]) {
        targets = Set(elements)
    }

    func captured(for element: String) -> [[String: String]] {
        captured[element] ?? []
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = DocxDelegate.local(elementName)
        if targets.contains(local) {
            captured[local, default: []].append(attributeDict)
        }
    }
}

// MARK: - ODP (slides as chapters)

/// OpenDocument Presentation parser — one chapter per draw:page; the frame
/// marked presentation:class="title" provides the chapter title. Page media
/// (draw:image frames) and tables ride along like the ODT parser's.
public enum OdpParser {
    public static func parse(archive: Data) throws -> [DocumentChapter] {
        try parseFull(archive: archive).chapters
    }

    public static func parseFull(archive: Data) throws -> DocumentParseResult {
        let contentXML: Data
        do {
            contentXML = try ZipReader.readEntry("content.xml", in: archive)
        } catch let ZipReader.ZipError.entryNotFound(name) {
            throw DocumentParseError.missingEntry(name)
        }
        let pool = DocumentImagePool()
        let delegate = OdpDelegate(pool: pool)
        let parser = XMLParser(data: contentXML)
        parser.delegate = delegate
        guard parser.parse() else {
            throw DocumentParseError.malformed(parser.parserError?.localizedDescription ?? "XML error")
        }
        let images = DocumentMedia.resolvePool(pool, archive: archive)
        return DocumentParseResult(
            chapters: delegate.pages,
            images: images,
            cover: DocumentMedia.embeddedThumbnail(archive: archive)
        )
    }
}

private final class OdpDelegate: NSObject, XMLParserDelegate {
    private let pool: DocumentImagePool

    private(set) var pages: [DocumentChapter] = []
    private var currentTitle: String?
    private var pageBlocks: [DocumentBlock] = []
    private var inTitleFrame = false
    private var inPage = false
    private var currentText: String?
    private var pendingImageIndexes: [Int] = []

    // Table state — same shape as ODT's
    private var tblDepth = 0
    private var inHeaderRows = false
    private var tableRows: [[DocumentTableCell]] = []
    private var rowCells: [DocumentTableCell] = []
    private var inCell = false
    private var cellIsCovered = false
    private var cellLines: [String] = []
    private var cellLine = ""
    private var cellSpan = 1

    init(pool: DocumentImagePool) {
        self.pool = pool
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch DocxDelegate.local(elementName) {
        case "page":
            inPage = true
            currentTitle = nil
            pageBlocks = []
        case "frame":
            inTitleFrame = inPage && (attributeDict["presentation:class"] == "title")
        case "h", "p":
            if inPage {
                if tblDepth > 0, inCell {
                    cellLine = ""
                } else {
                    currentText = ""
                }
            }
        case "image":
            // Cell images are dropped for the same block-ordering reason.
            if inPage, tblDepth == 0,
               let href = attributeDict["xlink:href"] ?? attributeDict["href"], !href.isEmpty {
                let target = DocumentMedia.resolveTarget(baseDir: "", href)
                pendingImageIndexes.append(pool.index(for: target, alt: ""))
            }
        case "table":
            tblDepth += 1
            if tblDepth == 1 { tableRows = [] }
        case "table-header-rows":
            inHeaderRows = true
        case "table-row":
            if tblDepth == 1 { rowCells = [] }
        case "table-cell":
            if tblDepth == 1 {
                inCell = true
                cellIsCovered = false
                cellLines = []
                cellLine = ""
                let raw = attributeDict["table:number-columns-spanned"] ?? "1"
                cellSpan = max(1, Int(raw) ?? 1)
            }
        case "covered-table-cell":
            if tblDepth == 1 {
                inCell = true
                cellIsCovered = true
                cellLines = []
                cellLine = ""
                cellSpan = 1
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if tblDepth > 0, inCell {
            cellLine += string
        } else {
            currentText? += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch DocxDelegate.local(elementName) {
        case "h", "p":
            if tblDepth > 0, inCell {
                cellLines.append(cellLine)
                cellLine = ""
            } else if var text = currentText {
                text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    if inTitleFrame && currentTitle == nil {
                        currentTitle = text
                    } else {
                        pageBlocks.append(.paragraph(text))
                    }
                }
            }
            currentText = nil
        case "table-cell", "covered-table-cell":
            if inCell, tblDepth == 1 {
                if !cellIsCovered {
                    let text = cellLines
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    rowCells.append(DocumentTableCell(text: text, columnSpan: cellSpan, isHeader: inHeaderRows))
                }
                inCell = false
                cellIsCovered = false
            }
        case "table-row":
            if tblDepth == 1, !rowCells.isEmpty {
                tableRows.append(rowCells)
                rowCells = []
            }
        case "table-header-rows":
            inHeaderRows = false
        case "table":
            tblDepth = max(0, tblDepth - 1)
            if tblDepth == 0, !tableRows.isEmpty {
                pageBlocks.append(.table(tableRows))
                tableRows = []
            }
        case "frame":
            inTitleFrame = false
            // Page images can sit in frames with no text around them.
            for index in pendingImageIndexes {
                pageBlocks.append(.image(index))
            }
            pendingImageIndexes = []
        case "page":
            if inPage {
                let chapter = DocumentChapter(
                    title: currentTitle ?? "Slide \(pages.count + 1)",
                    blocks: pageBlocks
                )
                pages.append(chapter)
            }
            inPage = false
        default:
            break
        }
    }
}

// MARK: - Chapterization (shared)

/// Turns a flat item stream (legacy .doc text) into ~150-item chapters —
/// the headless path of chapterize().
public extension DocumentEpubConverter {
    static func chunk(paragraphs: [String]) -> [DocumentChapter] {
        chapterize(paragraphs.map { DocumentItem.paragraph($0) })
    }
}

/// Splits a heading-annotated item stream into chapters: a level 1-2
/// heading opens a chapter; deeper headings only open one when nothing is
/// open yet (documents whose only structure is h3+). Headless documents (a
/// contract, a lecture note) chunk into ~150-item chapters (paragraphs,
/// images and tables each count one) so the reader's one-chapter-at-a-time
/// memory bound still holds.
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
            let opensChapter = level <= 2 || currentTitle == nil
            if opensChapter {
                flush()
                currentTitle = text
            } else {
                currentBlocks.append(.paragraph(text))
            }
        case .paragraph(let text):
            currentBlocks.append(.paragraph(text))
            if currentBlocks.count >= 150 {
                // Carry the section title onto the continuation chapter so
                // the TOC doesn't show "Chapter N" mid-section.
                let carried = currentTitle
                flush()
                currentTitle = carried
            }
        case .image(let index):
            currentBlocks.append(.image(index))
            if currentBlocks.count >= 150 {
                let carried = currentTitle
                flush()
                currentTitle = carried
            }
        case .table(let rows):
            currentBlocks.append(.table(rows))
            if currentBlocks.count >= 150 {
                let carried = currentTitle
                flush()
                currentTitle = carried
            }
        }
    }
    flush()

    if chapters.isEmpty {
        return [DocumentChapter(title: nil, paragraphs: [])]
    }
    return chapters
}

// MARK: - EPUB conversion

/// Turns DocumentChapters into a valid EPUB 3 (with NCX fallback) the
/// existing import pipeline, epub.js reader and TTS spine pipeline consume
/// unchanged. Store-only zip, mimetype first.
///
/// v1.7.2: image blocks become real `<img>` elements backed by packaged
/// media entries, tables become bordered HTML tables, and an optional cover
/// rides the manifest with `properties="cover-image"` so EpubParser (and
/// thus the shelf) picks it up automatically.
public enum DocumentEpubConverter {
    public static func epubData(
        chapters: [DocumentChapter],
        title: String,
        author: String?,
        identifier: String = UUID().uuidString
    ) -> Data {
        epubData(chapters: chapters, title: title, author: author, identifier: identifier, images: [], cover: nil)
    }

    public static func epubData(
        chapters: [DocumentChapter],
        title: String,
        author: String?,
        identifier: String = UUID().uuidString,
        images: [DocumentImage],
        cover: DocumentImage?
    ) -> Data {
        let language = "en"
        var manifestItems = ""
        var spineItems = ""
        var navItems = ""
        var ncxItems = ""
        var files: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            (
                "META-INF/container.xml",
                Data("""
                <?xml version="1.0" encoding="utf-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                  </rootfiles>
                </container>
                """.utf8)
            ),
        ]

        // Media entries first (chapters reference them by href). A class
        // per image: real figures go full width, small icons keep size.
        var imageHREFs: [String] = []
        var imageClasses: [String] = []
        for (index, image) in images.enumerated() {
            let ext = DocumentMedia.fileExtension(forMime: image.mime)
            let href = "images/img\(index + 1).\(ext)"
            imageHREFs.append(href)
            let size = DocumentMedia.pixelSize(of: image.data)
            imageClasses.append(
                size?.width ?? 0 >= 320 && size?.height ?? 0 >= 320 ? "doc-image" : "doc-image-inline"
            )
            manifestItems += "<item id=\"img\(index + 1)\" href=\"\(href)\" media-type=\"\(image.mime)\"/>\n"
            files.append((name: "OEBPS/\(href)", data: image.data))
        }
        if let cover {
            let ext = DocumentMedia.fileExtension(forMime: cover.mime)
            manifestItems += "<item id=\"cover-image\" href=\"cover.\(ext)\" media-type=\"\(cover.mime)\" properties=\"cover-image\"/>\n"
            files.append((name: "OEBPS/cover.\(ext)", data: cover.data))
        }

        for (index, chapter) in chapters.enumerated() {
            let id = "ch\(index + 1)"
            let href = "\(id).xhtml"
            let label = chapter.title ?? "Chapter \(index + 1)"
            manifestItems += "<item id=\"\(id)\" href=\"\(href)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "<itemref idref=\"\(id)\"/>\n"
            navItems += "<li><a href=\"\(href)\">\(escape(label))</a></li>\n"
            ncxItems += """
                <navPoint id="np\(index + 1)" playOrder="\(index + 1)">
                  <navLabel><text>\(escape(label))</text></navLabel>
                  <content src="\(href)"/>
                </navPoint>
                """
            files.append((name: "OEBPS/\(href)", data: Data(chapterXHTML(chapter, index: index + 1, imageHREFs: imageHREFs, imageClasses: imageClasses).utf8)))
        }

        let creatorLine = author.map { "<dc:creator>\(escape($0))</dc:creator>" } ?? ""
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:\(identifier)</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            \(creatorLine)
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            \(manifestItems)
          </manifest>
          <spine toc="ncx">
            \(spineItems)
          </spine>
        </package>
        """
        files.append(("OEBPS/content.opf", Data(opf.utf8)))

        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)">
          <head><meta charset="utf-8"/><title>Contents</title></head>
          <body>
            <nav epub:type="toc" id="toc">
              <ol>
                \(navItems)
              </ol>
            </nav>
          </body>
        </html>
        """
        files.append(("OEBPS/nav.xhtml", Data(nav.utf8)))

        let ncx = """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="urn:uuid:\(identifier)"/><meta name="dtb:depth" content="1"/></head>
          <docTitle><text>\(escape(title))</text></docTitle>
          <navMap>
            \(ncxItems)
          </navMap>
        </ncx>
        """
        files.append(("OEBPS/toc.ncx", Data(ncx.utf8)))

        return ZipWriter.archive(entries: files)
    }

    /// Document-reader CSS: images run the reader's full content width the
    /// way note previews do, and tables get real collapsed borders — the
    /// office pipeline's output should look like the document, not like
    /// run-on text.
    private static let chapterCSS = """
        <style>
          img.doc-image { width: 100%; height: auto; display: block; margin: 0.6em auto; }
          img.doc-image-inline { max-width: 100%; height: auto; display: block; margin: 0.6em auto; }
          div.doc-table-wrap { overflow-x: auto; width: 100%; }
          table.doc-table { border-collapse: collapse; margin: 0.8em 0; }
          table.doc-table th, table.doc-table td { border: 1px solid #8a8a8a; padding: 4px 7px; text-align: left; vertical-align: top; }
          table.doc-table th { background: rgba(128, 128, 128, 0.15); font-weight: 600; }
        </style>
        """

    private static func chapterXHTML(_ chapter: DocumentChapter, index: Int, imageHREFs: [String], imageClasses: [String]) -> String {
        var body = ""
        if let title = chapter.title {
            body += "<h1>\(escape(title))</h1>\n"
        }
        for block in chapter.blocks {
            switch block {
            case .paragraph(let text):
                body += "<p>\(escape(text))</p>\n"
            case .image(let poolIndex):
                guard imageHREFs.indices.contains(poolIndex) else { continue }
                let cls = imageClasses.indices.contains(poolIndex) ? imageClasses[poolIndex] : "doc-image-inline"
                body += "<p class=\"doc-image-wrap\"><img class=\"\(cls)\" src=\"\(imageHREFs[poolIndex])\" alt=\"\"/></p>\n"
            case .table(let rows):
                body += "<div class=\"doc-table-wrap\">\n" + tableXHTML(rows) + "</div>\n"
            case .html(let markup):
                // Native markup (mobi): already HTML — the ONLY edits are
                // the image tokens the parser left (`data-pool-index="N"`
                // → the pool's real href) and a tidying pass that closes
                // void tags so the XHTML never breaks the chapter.
                body += DocumentEpubConverter.inlineMarkupXHTML(markup, imageHREFs: imageHREFs) + "\n"
            }
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
          <head><meta charset="utf-8"/>\(chapterCSS)<title>Chapter \(index)</title></head>
          <body>
            \(body)
          </body>
        </html>
        """
    }

    /// Format-native markup → chapter body. Closes the void tags old HTML
    /// leaves open (`<br>`, `<img …>`), escapes bare ampersands, and swaps
    /// the parser's image tokens for real pool references. The epub.js
    /// renderer injects chapter content through `innerHTML`, which parses
    /// forgivingly — this pass covers the structural cases, not a full XML
    /// rewrite.
    static func inlineMarkupXHTML(_ markup: String, imageHREFs: [String]) -> String {
        var out = markup
        // Image tokens → pool hrefs. An unknown index becomes an empty src,
        // which the reader ignores, rather than a dangling reference.
        let tokenRegex = try? NSRegularExpression(pattern: #"data-pool-index="(\d+)""#)
        out = replacing(tokenRegex, in: out) { [ns = out as NSString] match in
            guard match.range(at: 1).location != NSNotFound,
                  imageHREFs.indices.contains(Int(ns.substring(with: match.range(at: 1))) ?? -1)
            else { return "" }
            return imageHREFs[Int(ns.substring(with: match.range(at: 1)))!]
        }
        // Void tags → self-closing, attributes untouched.
        let voidRegex = try? NSRegularExpression(
            pattern: #"<(br|hr|img|meta|link)((?:[^>"]|"[^"]*")*?)(/?)>"#
        )
        out = replacing(voidRegex, in: out) { [ns = out as NSString] match in
            guard match.range(at: 1).location != NSNotFound else { return ns.substring(with: match.range) }
            let name = ns.substring(with: match.range(at: 1))
            let attrs = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2)) : ""
            return "<\(name)\(attrs)/>"
        }
        // Bare `&` → `&amp;` (an existing entity is left alone).
        out = replacing(
            try? NSRegularExpression(pattern: #"&(?!(?:[A-Za-z][A-Za-z0-9]*|#\d+|#x[0-9A-Fa-f]+);)"#),
            in: out, with: "&amp;"
        )
        return out
    }

    /// Tag-stripped text of native markup — the speech path for `.html`
    /// blocks.
    static func strippedText(_ markup: String) -> String {
        var out = replacing(
            try? NSRegularExpression(pattern: "<[^>]*>"),
            in: markup, with: " "
        )
        out = XhtmlText.decodingEntitiesLeniently(out)
        return out
            .replacingOccurrences(of: #"(?<=\S)\s+\n"#, with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Native-markup helpers

    private static func replacing(
        _ regex: NSRegularExpression?,
        in text: String,
        with replacement: String
    ) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private static func replacing(
        _ regex: NSRegularExpression?,
        in text: String,
        _ make: (NSTextCheckingResult) -> String
    ) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if match.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            out += make(match)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out += ns.substring(from: cursor)
        }
        return out
    }

    /// Rows → XHTML. `colspan` keeps columns aligned when documents merge
    /// cells; header cells render as `th` (the TTS extractor reads td/th the
    /// same, comma-joined, so speech is unaffected by the distinction).
    private static func tableXHTML(_ rows: [[DocumentTableCell]]) -> String {
        var html = "<table class=\"doc-table\">\n"
        for row in rows {
            html += "<tr>\n"
            for cell in row {
                let tag = cell.isHeader ? "th" : "td"
                let span = cell.columnSpan > 1 ? " colspan=\"\(cell.columnSpan)\"" : ""
                // Multi-line cell text keeps its line breaks.
                let content = escape(cell.text)
                    .replacingOccurrences(of: "\n", with: "<br/>")
                html += "<\(tag)\(span)>\(content)</\(tag)>\n"
            }
            html += "</tr>\n"
        }
        html += "</table>\n"
        return html
    }

    /// XML 1.0 text-node escape.
    public static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            // Strip control characters XML forbids (except tab/newline/CR).
            .unicodeScalars.filter { !$0.properties.isDeprecated && ($0.value > 0x1F || $0 == "\t" || $0 == "\n" || $0 == "\r") }
            .map(String.init)
            .joined()
    }
}
