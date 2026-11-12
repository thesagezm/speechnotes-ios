import Foundation

/// One book format. Slide decks are their own format (`original.pptx` /
/// `original.odp` is kept and the deck reader opens it) — the manifest
/// spells them with the file's OWN extension ("pptx", "odp", …), which is
/// what the Linux app's `is_slides()` reads, so a deck imported on one
/// platform opens as a deck on the other. Everything the enum encodes is
/// therefore the manifest's `format` string; the old raw-Value spellings
/// ("epub", "pdf", "audio") are unchanged.
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

    /// The deck extensions this app treats as decks (not EPUB normalizations).
    /// Legacy `.ppt` (a compound file, not a zip) is not in the set: the deck
    /// reader cannot open it and the import reports that honestly.
    public static let deckExtensions: Set<String> = ["pptx", "ppsx", "potx", "odp"]

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
            if Self.deckExtensions.contains(raw.lowercased()) {
                self = .slides(raw.lowercased())
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
        }
    }

    /// The extension the book's `original.<ext>` file carries.
    public var fileExtension: String {
        switch self {
        case .epub: return "epub"
        case .pdf: return "pdf"
        case .audio: return "audio"
        case .slides(let ext): return ext
        }
    }

    public var isSlides: Bool {
        if case .slides = self { return true }
        return false
    }
}
