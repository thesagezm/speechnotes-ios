import Foundation

/// One dispatch table for the headless book formats: everything that is
/// not EPUB/PDF/audio/decks but becomes a book through this pipeline.
///
/// The office formats (docx/odt/pptx/odp/doc) normalize to EPUB at import —
/// `DocumentEpubConverter` emits a real EPUB the reader, the TOC and the TTS
/// spine pipeline already speak, so downstream nothing ever knows the
/// difference. The headless family (mobipocket, FictionBook, RTF,
/// HTML/HTMLZ, plain text/Markdown) instead keeps the file whole and the
/// import persists the parse — `DocumentPages` writes the standalone
/// chapter pages and images the reader's scheme handler serves directly
/// (the Linux app's native pipeline); `BookFormat.documentExtensions` is
/// the set the import routes to `.document`.
///
/// Both families share this one parse dispatch (the office parsers' switches
/// used to be inlined at each call site — `BooksStore.importBook` and
/// `ImportService.importText` each grew a copy; the five headless readers
/// would have made that five copies, so the dispatch lives here once and
/// every caller asks this type).
///
/// Each parser reduces its format to `DocumentParseResult` (chapters +
/// images + cover); the caller decides whether the converter packages it
/// into an EPUB (office) or the page writer serves it as-is (headless).
public enum DocumentBook {

    /// Every extension this pipeline normalizes to EPUB, lowercase, without
    /// the dot. One list — the file pickers, the LocalSend receiver and the
    /// Open-In registration all read it, so they cannot drift apart.
    public static let supportedExtensions: Set<String> = [
        // Office (v1.7.2)
        "docx", "doc", "odt", "pptx", "odp",
        // Mobipocket / Kindle
        "mobi", "azw", "azw3", "prc", "pdb",
        // FictionBook
        "fb2",
        // RTF
        "rtf",
        // Web
        "html", "htm", "htmlz",
        // Plain text / Markdown
        "txt", "text", "md", "markdown",
    ]

    /// Extensions whose real type has no `UTType` of its own, so the file
    /// pickers must name them as imported UTTypes instead of resolving them.
    /// (`.mobi`/`.fb2`/`.rtf` DO have system types; these do not.)
    public static let exoticExtensions: Set<String> = [
        "azw3", "azw", "prc", "pdb", "htmlz", "html", "htm", "md", "markdown", "text",
    ]

    /// True when a file with this extension can become a book. Cheap — the
    /// file pickers and the drop targets call it per file.
    public static func canNormalize(_ fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    /// Parses `data` as the document `fileExtension` names it.
    ///
    /// Throws the parser's own error on a malformed file; the caller decides
    /// how much of that the user sees. Run OFF the main thread — a 50 MB
    /// `.azw3` spends real seconds in here.
    public static func parse(fileExtension: String, data: Data) throws -> DocumentParseResult {
        switch fileExtension.lowercased() {
        // MARK: Office (existing parsers, unchanged)
        case "docx":
            return try DocxParser.parseFull(archive: data)
        case "odt":
            return try OdtParser.parseFull(archive: data)
        case "pptx":
            return try PptxParser.parseFull(archive: data)
        case "odp":
            return try OdpParser.parseFull(archive: data)
        case "doc":
            // Legacy Word has no headings and no media — plain text out of the
            // binary, then the headless chunker.
            return DocumentParseResult(
                chapters: DocumentEpubConverter.chunk(
                    paragraphs: textParagraphs(
                        try LegacyDocParser.extractText(archive: data)
                    )
                )
            )

        // MARK: Mobipocket
        case "mobi", "azw", "azw3", "prc", "pdb":
            let book = try MobiParser.parse(book: data)
            // The book's own markup IS the chapter: italics, headings and
            // the recindex illustrations survive into the EPUB. Chapters
            // without markup (the headless fallback) keep the paragraph
            // blocks that read as one paragraph each. This is the same
            // model readest/Koodo/Anx use — the foliate-js family renders
            // each mobi section as its own HTML file; here each chapter is
            // one EPUB XHTML file.
            //
            // The publisher's contents page is consumed INSIDE the parser
            // now (MobiParser.chapters: the real-format index read cuts the
            // chapters at the index's own offsets and titles them with the
            // publisher's labels), so the emitted EPUB's nav IS the
            // publisher's TOC. The old CNCX re-split here is gone with it:
            // it re-cut the chapters' STRIPPED markup at raw-stream offsets,
            // coordinates that no longer exist once prepare() collapsed the
            // pagebreaks — a cut that could only land mid-paragraph.
            let resolved = book.chapters
            return DocumentParseResult(
                chapters: resolved.map { chapter in
                    chapter.html.isEmpty
                        ? DocumentChapter(
                            title: chapter.title,
                            blocks: chapter.paragraphs.map { .paragraph($0) }
                        )
                        : DocumentChapter(
                            title: chapter.title,
                            blocks: [.html(chapter.html)]
                        )
                },
                images: book.inlineImages.map { image in
                    DocumentImage(data: image.data, mime: image.mime, alt: "Illustration")
                },
                cover: book.cover.map {
                    DocumentImage(
                        data: $0,
                        mime: $0.starts(with: [0x89]) ? "image/png" : "image/jpeg",
                        alt: "Cover"
                    )
                }
            )

        // MARK: FictionBook
        case "fb2":
            return try Fb2Parser.parseFull(archive: data)

        // MARK: RTF
        case "rtf":
            return try RtfParser.parseFull(archive: data)

        // MARK: Web
        case "html", "htm":
            return DocumentParseResult(chapters: try HtmlBookParser.parse(html: data))
        case "htmlz":
            return try HtmlBookParser.parseFull(archive: data)

        // MARK: Plain text / Markdown
        case "txt", "text", "md", "markdown":
            return DocumentParseResult(
                chapters: try PlainTextBookParser.parse(archive: data)
            )

        default:
            throw DocumentParseError.malformed(
                "'\(fileExtension)' is not a document this reader supports"
            )
        }
    }

    /// The document's OWN title and author, where its format carries them, so
    /// the shelf shows a book's metadata instead of its filename. nil for the
    /// formats with no metadata of their own (the office parsers get theirs
    /// from the EPUB the converter writes).
    public static func metadata(
        fileExtension: String,
        data: Data
    ) -> (title: String?, author: String?)? {
        switch fileExtension.lowercased() {
        case "mobi", "azw", "azw3", "prc", "pdb":
            guard let book = try? MobiParser.parse(book: data) else { return nil }
            return (book.title, book.author)
        case "fb2":
            let meta = Fb2Parser.metadata(archive: data)
            return (meta.title, meta.author)
        case "rtf":
            guard let meta = RtfParser.metadata(archive: data) else { return nil }
            return (meta.title, meta.author)
        case "html", "htm":
            return HtmlBookParser.metadata(html: data)
        case "htmlz":
            guard let entries = try? ZipReader.entries(in: data),
                  let opfName = entries.first(where: { $0.name.lowercased().hasSuffix(".opf") })?.name,
                  let opfData = try? ZipReader.readEntry(opfName, in: data) else { return nil }
            return HtmlBookParser.metadataFromOPF(opfData)
        default:
            return nil
        }
    }

    /// Splits raw text into paragraphs the way every headless format does.
    static func textParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
