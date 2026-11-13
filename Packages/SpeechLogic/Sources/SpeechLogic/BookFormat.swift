import Foundation

/// One book format. Slide decks are their own format (`original.pptx` /
/// `original.odp` is kept and the deck reader opens it) — the manifest
/// spells them with the file's OWN extension ("pptx", "odp", …), which is
/// what the Linux app's `is_slides()` reads, so a deck imported on one
/// platform opens as a deck on the other. Everything the enum encodes is
/// therefore the manifest's `format` string; the old raw-Value spellings
/// ("epub", "pdf", "audio") are unchanged.
///
/// The headless documents (the Mobipocket/Kindle family, FictionBook, RTF,
/// HTML, plain text — the Linux `DocFamily` set plus Markdown) are their own
/// family the same way: the manifest's format string is the file's own
/// extension, `original.<ext>` is kept WHOLE, and the reader serves the
/// parse (`doc/chapter-N.html` + images) straight into the webview — the
/// Linux app's exact pipeline (`bookdoc.rs` + `ServedBookDoc`), which never
/// becomes an EPUB. Office formats (docx/doc/odt) are NOT in the family:
/// they still normalize to EPUB at import, so their manifest spelling stays
/// "epub" and the decode set below never sees them.
///
/// Lives in the logic package because it IS the cross-platform contract:
/// the manifest is written by Linux and read here (and the other way
/// round), and the round-trip ("pptx" decodes, re-encodes as "pptx") is
/// pinned by BookFormatManifestTests in CI.
public enum BookFormat: Hashable, Codable, Sendable {
    case epub
    case pdf
    /// A finished audiobook file (M4B / M4A / MP4 with a chpl atom, or MP3 with
    /// ID3 CHAP frames). The audio already exists — Speechnotes plays it and
    /// keeps the chapter list for navigation and lock-screen controls, instead
    /// of synthesizing anything.
    case audio
    /// A slide deck: `original.<ext>` is kept whole and the deck reader
    /// renders the slides. `ext` is the deck's own lowercase extension
    /// ("pptx", "ppsx", "potx", "odp") — the manifest's format string.
    case slides(String)
    /// A headless document: `original.<ext>` is kept whole, the import
    /// persists the parse (`doc/chapter-N.html`, images, cover) and the
    /// reader serves those pages directly. `ext` is the file's own lowercase
    /// extension — the manifest's format string, matching what the Linux
    /// app's import_document stamps.
    case document(String)

    /// The deck extensions this app treats as decks (not EPUB normalizations).
    /// Legacy `.ppt` (a compound file, not a zip) is not in the set: the deck
    /// reader cannot open it and the import reports that honestly.
    public static let deckExtensions: Set<String> = ["pptx", "ppsx", "potx", "odp"]

    /// The extensions that decode as `.document` — the Linux DocFamily set
    /// plus the two Markdown spellings iOS reads. Read by the import path's
    /// format routing (one table, the same one-list discipline the Linux
    /// `DocFamily::from_extension` keeps).
    public static let documentExtensions: Set<String> = [
        "mobi", "azw", "azw3", "prc", "pdb",
        "fb2",
        "rtf",
        "html", "htm", "htmlz",
        "txt", "text",
        "md", "markdown",
    ]

    private enum Raw: String {
        case epub, pdf, audio
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "epub": self = .epub
        case "pdf": self = .pdf
        case "audio": self = .audio
        default:
            let lower = raw.lowercased()
            if Self.deckExtensions.contains(lower) {
                self = .slides(lower)
            } else if Self.documentExtensions.contains(lower) {
                self = .document(lower)
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "unknown book format \(raw)"
                    )
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .epub: try container.encode(Raw.epub.rawValue)
        case .pdf: try container.encode(Raw.pdf.rawValue)
        case .audio: try container.encode(Raw.audio.rawValue)
        case .slides(let ext): try container.encode(ext)
        case .document(let ext): try container.encode(ext)
        }
    }

    /// The extension the book's `original.<ext>` file carries.
    public var fileExtension: String {
        switch self {
        case .epub: return "epub"
        case .pdf: return "pdf"
        case .audio: return "audio"
        case .slides(let ext): return ext
        case .document(let ext): return ext
        }
    }

    public var isSlides: Bool {
        if case .slides = self { return true }
        return false
    }

    /// True for the headless document family — the formats the reader
    /// serves from the persisted parse instead of an EPUB archive.
    public var isDocument: Bool {
        if case .document = self { return true }
        return false
    }
}
