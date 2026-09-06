import Foundation

/// Plain speech text from a spine item's XHTML — the source of truth for
/// reading books aloud. Deliberately NATIVE (XMLParser), not webview
/// extraction: playback must keep working with the reader closed (the
/// auto-advance to the next chapter happens with no webview alive at all).
///
/// Block elements (p, h1-h6, li, blockquote, …) become `\n\n`-separated
/// paragraphs — SentenceChunker already treats those as boundaries — inline
/// markup flows through as text, images contribute their alt text, and
/// head/style/script content is dropped entirely.
public enum XhtmlText {

    /// Extracts speech text from serialized XHTML. Returns "" for input with
    /// no extractable text (a cover-only spine item, for instance).
    public static func plainText(from xhtml: Data) -> String {
        let delegate = Delegate()
        let parser = XMLParser(data: xhtml)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.paragraphText
    }

    /// Convenience for test authors and callers holding a String.
    public static func plainText(from xhtml: String) -> String {
        plainText(from: Data(xhtml.utf8))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private static let blockTags: Set<String> = [
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote",
            "div", "tr", "dd", "dt", "figcaption", "pre", "section", "article"
        ]
        private static let skipTags: Set<String> = ["head", "style", "script"]

        private var paragraphs: [String] = []
        private var buffer = ""
        private var skipDepth = 0

        var paragraphText: String {
            flush()
            return paragraphs.joined(separator: "\n\n")
        }

        private func flush() {
            // Collapse the whitespace runs pretty-printed XHTML is full of.
            let text = buffer
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { paragraphs.append(text) }
            buffer = ""
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.split(separator: ":", maxSplits: 1).last.map(String.init) ?? elementName
            if Self.skipTags.contains(name) {
                skipDepth += 1
                return
            }
            guard skipDepth == 0 else { return }
            if Self.blockTags.contains(name) {
                flush()
            } else if name == "br" {
                flush()
            } else if name == "td" || name == "th" {
                // Table cells read as one running line, comma-joined — a
                // paragraph break per cell would be unbearably choppy.
                let text = buffer
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { buffer = text + ", " }
            } else if name == "img" {
                // Always emit a word boundary — an alt-less image must not
                // glue the surrounding words together ("Beforeafter").
                if let alt = attributeDict["alt"], !alt.isEmpty {
                    buffer += " (image: \(alt)) "
                } else {
                    buffer += " "
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = elementName.split(separator: ":", maxSplits: 1).last.map(String.init) ?? elementName
            if Self.skipTags.contains(name) {
                skipDepth = max(0, skipDepth - 1)
                return
            }
            guard skipDepth == 0 else { return }
            if Self.blockTags.contains(name) || name == "br" {
                flush()
            }
        }
    }
}
