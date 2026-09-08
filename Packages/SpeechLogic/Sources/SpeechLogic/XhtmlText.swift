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

    /// HTML named character references beyond XML's five predefined ones.
    /// XMLParser is STRICT XML: the first `&nbsp;` in a real-world book
    /// aborts the parse, which silently TRUNCATES the chapter at that point
    /// (and the truncation used to be cached forever). The pre-parse pass
    /// below maps the common named set to Unicode so the parser never sees
    /// them; unknown names are stripped (losing a glyph beats losing the
    /// rest of the chapter).
    public static let namedEntities: [String: String] = [
        "nbsp": "\u{00A0}", "iexcl": "¡", "cent": "¢", "pound": "£", "curren": "¤",
        "yen": "¥", "brvbar": "¦", "sect": "§", "uml": "¨", "copy": "©",
        "ordf": "ª", "laquo": "«", "not": "¬", "shy": "\u{00AD}", "reg": "®",
        "macr": "¯", "deg": "°", "plusmn": "±", "sup2": "²", "sup3": "³",
        "acute": "´", "micro": "µ", "para": "¶", "middot": "·", "cedil": "¸",
        "sup1": "¹", "ordm": "º", "raquo": "»", "frac14": "¼", "frac12": "½",
        "frac34": "¾", "iquest": "¿", "times": "×", "divide": "÷",
        "mdash": "—", "ndash": "–", "hellip": "…", "ldquo": "\u{201C}",
        "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "sbquo": "‚", "bdquo": "„", "lsaquo": "‹", "rsaquo": "›",
        "bull": "•", "dagger": "†", "Dagger": "‡", "permil": "‰",
        "prime": "′", "Prime": "″", "euro": "€", "trade": "™",
        "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "aring": "å",
        "aelig": "æ", "ccedil": "ç", "eacute": "é", "egrave": "è", "ecirc": "ê",
        "euml": "ë", "iacute": "í", "igrave": "ì", "icirc": "î", "ntilde": "ñ",
        "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "oslash": "ø",
        "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü", "szlig": "ß",
        "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š",
        "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}",
        "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}",
    ]

    /// XML's five predefined entities. These are legal to the strict parser
    /// and MUST pass through this pre-pass VERBATIM — mapping `&lt;` to a
    /// literal `<` here would hand the parser broken markup (the very
    /// failure this pass exists to prevent), and stripping them (the old
    /// behavior) deleted every "&" in every book ("AT&amp;T" → "ATT").
    /// XMLParser resolves them in foundCharacters.
    private static let xmlPredefined: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// Rewrites `&name;` references the XML parser would reject. Numeric
    /// references (`&#8212;`, `&#x2014;`) and the five XML entities are
    /// standard XML and pass through untouched.
    public static func replacingNamedEntities(_ xhtml: String) -> String {
        guard xhtml.contains("&") else { return xhtml }
        var out = ""
        out.reserveCapacity(xhtml.count)
        var i = xhtml.startIndex
        while i < xhtml.endIndex {
            let c = xhtml[i]
            if c == "&" {
                // Entity-shaped token: a letters/digits run closed by ';'
                // (cap 32 — real names are far shorter). XML-predefined →
                // verbatim; known HTML name → Unicode; UNKNOWN → strip the
                // token, because a strict parser treats ANY undefined entity
                // as fatal and one `&weirdname;` would otherwise truncate
                // the rest of the chapter.
                var j = xhtml.index(after: i)
                var name = ""
                var closed = false
                while j < xhtml.endIndex, name.count < 32 {
                    let cj = xhtml[j]
                    if cj == ";" { closed = true; break }
                    guard cj.isLetter || cj.isNumber else { break }
                    name.append(cj)
                    j = xhtml.index(after: j)
                }
                if closed {
                    if xmlPredefined.contains(name) {
                        out += "&\(name);"
                    } else {
                        out += namedEntities[name] ?? ""
                    }
                    i = xhtml.index(after: j)
                    continue
                }
            }
            out.append(c)
            i = xhtml.index(after: i)
        }
        return out
    }

    /// Extracts speech text from serialized XHTML. Returns "" for input with
    /// no extractable text (a cover-only spine item, for instance).
    public static func plainText(from xhtml: Data) -> String {
        extract(from: xhtml).text
    }

    /// Full-fidelity extraction: the plain text PLUS whether the parser ran
    /// to completion. Callers that CACHE the result (the chapter speech-text
    /// cache) must refuse when `parseCompleted` is false — caching a
    /// truncated extraction would poison every future play/resume.
    public static func extract(from xhtml: Data) -> (text: String, parseCompleted: Bool) {
        // Named-entity pre-pass needs UTF-8 text; for anything else let the
        // parser handle its own declared encoding (a Latin-1 book with named
        // entities stays broken, but bytes are never mangled).
        let prepared: Data
        if let text = String(data: xhtml, encoding: .utf8) {
            prepared = Data(replacingNamedEntities(text).utf8)
        } else {
            prepared = xhtml
        }
        let delegate = Delegate()
        let parser = XMLParser(data: prepared)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let completed = parser.parse()
        return (delegate.paragraphText, completed)
    }

    /// Convenience for test authors and callers holding a String.
    public static func plainText(from xhtml: String) -> String {
        plainText(from: Data(replacingNamedEntities(xhtml).utf8))
    }

    /// epub:type values that mark footnote-family asides (otherwise read
    /// aloud inline — a footnote body landing mid-sentence).
    private static let footnoteTypes: Set<String> = [
        "footnote", "endnote", "rearnote", "marginnote", "note", "footnotes", "endnotes"
    ]

    static func isFootnoteAside(_ attributes: [String: String]) -> Bool {
        let type = attributes["epub:type"] ?? attributes["type"] ?? ""
        return type.split(separator: " ").contains { footnoteTypes.contains(String($0)) }
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
        /// `aside` elements (epub:type footnote/endnote/…) read inline
        /// otherwise: a footnote BODY interrupts the sentence mid-flow and a
        /// `sup` noteref digit reads as a random number. Scrub both; `rt`
        /// (ruby annotation) likewise — the base text carries the meaning.
        ///
        /// Scrub state is a stack of EVERY open element, not a depth counter:
        /// a plain (non-footnote) `</aside>` or a nested `</sup>` inside a
        /// footnote must not end the footnote's scrub — only the close of the
        /// element that STARTED the scrub may. (The old single counter was
        /// decremented by any aside/sup/rt close, which leaked or lost
        /// footnote content depending on nesting order.)
        private struct OpenElement { let name: String; let scrubs: Bool }
        private var openElements: [OpenElement] = []
        private var scrubCount = 0
        /// Void (self-closing) elements: didEndElement never fires for them,
        /// so they must never be pushed onto the stack.
        private static let voidElements: Set<String> = [
            "br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source", "track", "wbr"
        ]
        /// Inside `<td>/<th>` a `<br>` means "same cell, new line" — the
        /// cells are comma-joined for speech, so a br must NOT flush a
        /// paragraph (it split table rows mid-sentence).
        private var cellDepth = 0

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
            if name == "aside" {
                if XhtmlText.isFootnoteAside(attributeDict) {
                    openElements.append(.init(name: name, scrubs: true))
                    scrubCount += 1
                    return
                }
            } else if name == "sup" || name == "rt" {
                openElements.append(.init(name: name, scrubs: true))
                scrubCount += 1
                return
            }
            if !Self.voidElements.contains(name) {
                openElements.append(.init(name: name, scrubs: false))
            }
            guard skipDepth == 0, scrubCount == 0 else { return }
            if name == "td" || name == "th" {
                cellDepth += 1
                // Table cells read as one running line, comma-joined — a
                // paragraph break per cell would be unbearably choppy.
                let text = buffer
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { buffer = text + ", " }
            } else if name == "br" {
                if cellDepth > 0 {
                    // Table cells read as one running line, comma-joined — a
                    // br inside a cell is "same cell, next line", not a
                    // paragraph break (it used to split rows mid-sentence).
                    buffer += ", "
                } else {
                    flush()
                }
            } else if Self.blockTags.contains(name) {
                flush()
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
            guard skipDepth == 0, scrubCount == 0 else { return }
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
            // Pop the stack, searching from the END for the matching open
            // element name — <a><b></b></a> is fine but a malformed
            // <a><sup></sup> (no inner `</a>`) must still resolve. Only the
            // element that STARTED the scrub can clear it; any nested close
            // leaves the scrub in force.
            if let idx = openElements.lastIndex(where: { $0.name == name }) {
                let popped = openElements[idx]
                if popped.scrubs { scrubCount = max(0, scrubCount - 1) }
                openElements.remove(at: idx)
            }
            if scrubCount > 0 { return }
            if name == "td" || name == "th" {
                cellDepth = max(0, cellDepth - 1)
            }
            guard skipDepth == 0 else { return }
            if Self.blockTags.contains(name) || (name == "br" && cellDepth == 0) {
                flush()
            }
        }
    }
}
