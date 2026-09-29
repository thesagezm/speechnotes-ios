import Foundation

/// One chapter of a parsed office document: an optional heading title and
/// the paragraphs under it. The common currency of the normalize-to-EPUB
/// pipeline (DOCX/ODT today, PPTX/ODP/DOC next) — every parser reduces its
/// format to this, and one converter turns it into a real EPUB the existing
/// reader, TOC and TTS chapter pipeline already understand.
public struct DocumentChapter: Equatable {
    public var title: String?
    public var paragraphs: [String]

    public init(title: String?, paragraphs: [String]) {
        self.title = title
        self.paragraphs = paragraphs
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

// MARK: - DOCX

/// WordprocessingML (DOCX) parser — text + heading structure from
/// word/document.xml. Images, tables (as sequential paragraphs) and
/// footnotes are out of scope: the output feeds the reader and the TTS
/// chapter pipeline, which want clean prose.
public enum DocxParser {
    public static func parse(archive: Data) throws -> [DocumentChapter] {
        let documentXML: Data
        do {
            documentXML = try ZipReader.readEntry("word/document.xml", in: archive)
        } catch let ZipReader.ZipError.entryNotFound(name) {
            throw DocumentParseError.missingEntry(name)
        }
        let delegate = DocxDelegate()
        let parser = XMLParser(data: documentXML)
        parser.delegate = delegate
        guard parser.parse() else {
            throw DocumentParseError.malformed(parser.error?.localizedDescription ?? "XML error")
        }
        return chapterize(delegate.paragraphs)
    }
}

private final class DocxDelegate: NSObject, XMLParserDelegate {
    struct Paragraph {
        var text: String = ""
        var headingLevel: Int = 0 // 0 = body text, 1...6
    }

    private(set) var paragraphs: [Paragraph] = []
    private var current: Paragraph?
    private var inText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch Self.local(elementName) {
        case "p":
            current = Paragraph()
        case "pStyle":
            // Style IDs are stable across Word UI languages: "Heading1"…,
            // "Title". Level 1/2 opens a chapter in chapterize(); deeper
            // headings stay body paragraphs with the heading text inline.
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
            current?.text += " "
        case "br":
            current?.text += "\n"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText, var paragraph = current else { return }
        paragraph.text += string
        current = paragraph
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
            if var paragraph = current {
                // Collapse run-split whitespace: runs often break mid-word
                // with no characters lost, but tab/br inserts may leave
                // doubled spaces.
                paragraph.text = paragraph.text
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !paragraph.text.isEmpty {
                    paragraphs.append(paragraph)
                }
            }
            current = nil
            inText = false
        default:
            break
        }
    }

    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

// MARK: - ODT

/// OpenDocument Text parser — text:h / text:p out of content.xml.
public enum OdtParser {
    public static func parse(archive: Data) throws -> [DocumentChapter] {
        let contentXML: Data
        do {
            contentXML = try ZipReader.readEntry("content.xml", in: archive)
        } catch let ZipReader.ZipError.entryNotFound(name) {
            throw DocumentParseError.missingEntry(name)
        }
        let delegate = OdtDelegate()
        let parser = XMLParser(data: contentXML)
        parser.delegate = delegate
        guard parser.parse() else {
            throw DocumentParseError.malformed(parser.error?.localizedDescription ?? "XML error")
        }
        return chapterize(delegate.paragraphs)
    }
}

private final class OdtDelegate: NSObject, XMLParserDelegate {
    private(set) var paragraphs: [DocxDelegate.Paragraph] = []
    private var current: DocxDelegate.Paragraph?
    private var inside = false

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
            current = DocxDelegate.Paragraph()
            let level = Int(attributeDict["text:outline-level"] ?? "1") ?? 1
            current?.headingLevel = min(max(level, 1), 6)
        case "p":
            inside = true
            current = DocxDelegate.Paragraph()
        case "tab":
            current?.text += " "
        case "line-break":
            current?.text += "\n"
        case "s":
            // text:s is a run of literal spaces (c attribute, default 1).
            let count = Int(attributeDict["text:c"] ?? "1") ?? 1
            current?.text += String(repeating: " ", count: count)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inside, var paragraph = current else { return }
        paragraph.text += string
        current = paragraph
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch DocxDelegate.local(elementName) {
        case "h", "p":
            if var paragraph = current {
                paragraph.text = paragraph.text
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !paragraph.text.isEmpty {
                    paragraphs.append(paragraph)
                }
            }
            current = nil
            inside = false
        default:
            break
        }
    }
}

// MARK: - Chapterization (shared)

/// Splits a heading-annotated paragraph stream into chapters: a level 1-2
/// heading opens a chapter; deeper headings only open one when nothing is
/// open yet (documents whose only structure is h3+). Headless documents (a
/// contract, a lecture note) chunk into ~150-paragraph chapters so the
/// reader's one-chapter-at-a-time memory bound still holds.
private func chapterize(_ paragraphs: [DocxDelegate.Paragraph]) -> [DocumentChapter] {
    var chapters: [DocumentChapter] = []
    var currentTitle: String?
    var currentParagraphs: [String] = []

    func flush() {
        if !currentParagraphs.isEmpty || currentTitle != nil {
            chapters.append(DocumentChapter(title: currentTitle, paragraphs: currentParagraphs))
        }
        currentTitle = nil
        currentParagraphs = []
    }

    for paragraph in paragraphs {
        let opensChapter = paragraph.headingLevel > 0
            && (paragraph.headingLevel <= 2 || currentTitle == nil)
        if opensChapter {
            flush()
            currentTitle = paragraph.text
        } else {
            currentParagraphs.append(paragraph.text)
            if currentParagraphs.count >= 150 {
                // Carry the section title onto the continuation chapter so
                // the TOC doesn't show "Chapter N" mid-section.
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
public enum DocumentEpubConverter {
    public static func epubData(
        chapters: [DocumentChapter],
        title: String,
        author: String?,
        identifier: String = UUID().uuidString
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
            files.append((name: "OEBPS/\(href)", data: Data(chapterXHTML(chapter, index: index + 1).utf8)))
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

    private static func chapterXHTML(_ chapter: DocumentChapter, index: Int) -> String {
        var body = ""
        if let title = chapter.title {
            body += "<h1>\(escape(title))</h1>\n"
        }
        for paragraph in chapter.paragraphs {
            body += "<p>\(escape(paragraph))</p>\n"
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
          <head><meta charset="utf-8"/><title>Chapter \(index)</title></head>
          <body>
            \(body)
          </body>
        </html>
        """
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
