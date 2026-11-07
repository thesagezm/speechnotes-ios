//
//  WebArticle.swift
//  SpeechLogic
//
//  Reader-mode extraction for web pages fetched by the note importer.
//

import Foundation

/// Turns a fetched web page's HTML into the prose a note wants.
///
/// Why this is not just `HtmlBookParser`: a saved *book* file is nearly all
/// content, but a live *web page* is mostly chrome around a smaller core —
/// nav bars, cookie banners, "Subscribe" buttons, related-article rails,
/// footers with forty links. The tolerant reader below would happily turn
/// all of that into paragraphs, and a note imported from a news article
/// would open with "Sign in | Sections | Watch Live │ Log In". So this pass
/// runs BEFORE the book parser:
///
/// 1. chrome blocks (`<nav>`, `<header>`, `<footer>`, `<aside>`, `<form>`,
///    `<button>`, …) and `<script>`/`<style>`/`<noscript>`/`<svg>` bodies
///    are removed by a hand-written tolerant scanner — the same
///    not-really-XML reasoning as `HtmlBookParser`: Foundation's XMLParser
///    aborts on the first `<br>`, and real pages are far sloppier than
///    saved books;
/// 2. if the page marks its content (`<article>`, `<main>`, or a
///    `role="main"` / `itemprop="articleBody"` div) AND that block holds
///    most of the page's visible text, everything outside it is dropped
///    too — the nav-stripping above cannot know that a bare link list in
///    the page body is a "Trending" rail;
/// 3. the surviving HTML goes through `HtmlBookParser` itself — one
///    tokenizer for entities, headings, paragraphs and tables, identical
///    output shape to every other document import.
///
/// Every stage degrades gracefully: no marked region → the whole cleaned
/// page; cleaned page yields nothing → the raw original. A page that
/// defeats all three was a JavaScript shell to begin with, and the caller
/// treats that as a failed fetch rather than saving a stub.
public enum WebArticle {

    // MARK: - URL detection

    /// The URL in a piece of shared text, if the text IS a web address.
    ///
    /// Deliberately strict: the text must be ONE token — a share sheet's
    /// "copy link" lands a bare URL on the pasteboard, and anything with
    /// spaces or newlines around it is prose the user meant to keep verbatim
    /// (a note titled "read https://… later" should stay a note, not become
    /// a fetch). Scheme-less forms (`example.com/story`) are accepted when
    /// they end in a plausible TLD, so a link typed without `https://` still
    /// imports; version strings like `v1.7.4` fail the TLD test and stay
    /// text.
    public static func url(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
            return url
        }
        guard trimmed.count <= 2000, bareDomainMatch(trimmed) else { return nil }
        guard let url = URL(string: "https://" + trimmed), url.scheme != nil else { return nil }
        return url
    }

    /// `example.com`, `www.site.co.uk/story.html`, `sub.domain.org/x?a=1` —
    /// but not `v1.7.4` (the last dotted label must be ≥2 letters) and not
    /// an address with a port (scheme-less plus `:8080` reads like a typo).
    private static func bareDomainMatch(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return bareDomainRegex.firstMatch(in: text, range: range) != nil
    }

    private static let bareDomainRegex = try! NSRegularExpression(
        pattern: "^[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}([/?#]\\S*)?$",
        options: [.caseInsensitive]
    )

    // MARK: - Extraction

    /// Cap on the DECODED source handed to the cleaner, in characters. The
    /// cleaner builds a character array of its input (~8× the string's
    /// bytes), and the LiveContainer process jetsams as one — a pathological
    /// 8 MB page must not become a 100 MB spike. 1.5M characters of HTML is
    /// ~3 MB of markup, far past any article; the note-side output is
    /// capped separately at a million.
    private static let maxSourceChars = 1_500_000

    /// Reader text for fetched HTML. Returns the page title (from `<title>`
    /// or the Open Graph metas) and the prose, or nil when the page carries
    /// no extractable text at all.
    public static func extract(html data: Data) -> (title: String?, text: String)? {
        let raw = String(HtmlBookParser.decode(data).prefix(maxSourceChars))
        let (cleaned, regions) = clean(raw)

        // Candidates in preference order: the page's own marked content
        // region(s), then the whole cleaned page, then — for pages whose
        // markup defeats the cleaner (an unclosed `<form>` around the body,
        // say) — the raw original. First candidate that yields text wins.
        var candidates: [String] = preferredRegions(in: cleaned, regions: regions)
        candidates.append(cleaned)
        candidates.append(raw)

        for candidate in candidates {
            guard let chapters = try? HtmlBookParser.parse(html: Data(candidate.utf8)) else {
                continue
            }
            // The same flatten the file importer applies: headings stay as
            // lines, paragraphs and table rows joined with blank lines.
            let lines = chapters.flatMap { chapter -> [String] in
                var out: [String] = []
                if let title = chapter.title { out.append(title) }
                out.append(contentsOf: chapter.textLines)
                return out
            }
            let body = lines.joined(separator: "\n\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            // Title from the ORIGINAL page — the marked region often starts
            // below `<head>`, and `<title>` beats a stripped `<header>`'s
            // nothing. The truncated source carries `<head>` by definition
            // (it is the first kilobyte), so it doubles as the metadata
            // input without a second full decode.
            let title = HtmlBookParser.metadata(html: Data(raw.utf8)).title
            return (title, body)
        }
        return nil
    }

    // MARK: - The tolerant cleaner

    /// Tags whose whole body is page chrome — never article prose. The
    /// first five are machine output (their text would be noise even in a
    /// "footer" reading); the rest are the structural chrome the reader
    /// tokenizer has no semantics for.
    private static let junkBlocks: Set<String> = [
        "script", "style", "noscript", "template", "svg", "iframe",
        "nav", "header", "footer", "aside", "form", "button", "select", "dialog",
    ]

    /// A removed block larger than this is a parsing artifact, not a footer
    /// — an unclosed `<form>` wrapping the whole body is real-page common.
    /// Past the bound the block is force-closed so one bad tag cannot
    /// swallow the article.
    private static let maxJunkBlockSize = 250_000

    /// One tolerant pass over the page. Removes junk blocks AND reports the
    /// kept content regions (`<article>`, `<main>`, `role="main"` divs) as
    /// substrings of the cleaned text, so the region preference in
    /// `extract` never has to re-scan.
    ///
    /// Emission rules: kept tags are re-emitted verbatim (the book parser
    /// needs the structure); junk blocks are dropped whole and replaced by
    /// a newline so word-joins never happen across a removed block. Same-name
    /// nesting is depth-counted, self-closing and void forms carry no body,
    /// and inner unclosed tags are closed implicitly at the first matching
    /// close — real-page tolerance, not XML strictness.
    private static func clean(_ html: String) -> (text: String, regions: [String]) {
        let source = Array(html)
        var out: [Character] = []
        out.reserveCapacity(source.count)
        var regions: [Range<Int>] = []

        struct Open {
            let name: String
            let sourceStart: Int // where the open tag began, SOURCE coordinates
            let bodyStart: Int   // cleaned-coordinate index where the body begins
            let remove: Bool     // junk block: suppress everything until it closes
            let region: Bool     // content marker: report the body when it closes
        }
        var stack: [Open] = []
        var removalDepth = 0
        var index = 0

        while index < source.count {
            // Force-close a junk block that has run past the artifact bound.
            // Only one remove block can be open at a time (a junk tag only
            // opens a removal at depth 0), so everything above it on the
            // stack is inside it.
            if removalDepth > 0, let pos = stack.lastIndex(where: { $0.remove }),
               index - stack[pos].sourceStart > maxJunkBlockSize {
                stack.removeSubrange(pos...)
                removalDepth -= 1
                out.append("\n")
            }
            // Comments and declarations (`<!-- … -->`, `<!DOCTYPE html>`)
            // never reach the tag reader — emitted literally they would
            // become visible text, exactly the failure mode the chrome
            // removal exists to prevent.
            if source[index] == "<", index + 1 < source.count, source[index + 1] == "!" {
                if index + 3 < source.count,
                   source[index + 2] == "-", source[index + 3] == "-" {
                    var cursor = index + 4
                    while cursor + 2 < source.count,
                          !(source[cursor] == "-" && source[cursor + 1] == "-"
                              && source[cursor + 2] == ">") {
                        cursor += 1
                    }
                    index = min(source.count, cursor + 3)
                } else {
                    var cursor = index
                    while cursor < source.count, source[cursor] != ">" { cursor += 1 }
                    index = min(source.count, cursor + 1)
                }
                continue
            }
            guard source[index] == "<", let token = readTag(source, at: index) else {
                if removalDepth == 0 { out.append(source[index]) }
                index += 1
                continue
            }

            if !token.isClosing {
                let isJunk = removalDepth == 0 && junkBlocks.contains(token.name)
                let hasBody = !token.isSelfClosing && !voidElements.contains(token.name)
                if isJunk { removalDepth += 1 }
                if removalDepth == 0 {
                    out.append(contentsOf: source[token.start..<token.end])
                }
                if hasBody {
                    stack.append(Open(
                        name: token.name,
                        sourceStart: token.start,
                        bodyStart: out.count,
                        remove: isJunk,
                        region: removalDepth == 0 && !isJunk && isRegionRoot(token.name, token.attributes)
                    ))
                }
                index = token.end
                continue
            }

            // Closing tag: pop to the topmost matching open (implicit closes
            // for anything unclosed above it).
            guard let pos = stack.lastIndex(where: { $0.name == token.name }) else {
                // Stray close — kept pages pass it through; the book parser
                // tolerates unmatched closes.
                if removalDepth == 0 {
                    out.append(contentsOf: source[token.start..<token.end])
                }
                index = token.end
                continue
            }
            let entry = stack[pos]
            if entry.remove {
                removalDepth -= 1
                out.append("\n")
            } else {
                let bodyEnd = out.count
                if entry.region, entry.bodyStart < bodyEnd {
                    regions.append(entry.bodyStart..<bodyEnd)
                }
                if removalDepth == 0 {
                    out.append(contentsOf: source[token.start..<token.end])
                }
            }
            stack.removeSubrange(pos...)
            index = token.end
        }

        return (String(out), regions.map { String(out[$0]) })
    }

    /// Content markers whose body is worth isolating: the semantic pair plus
    /// the two div conventions (`role="main"`, `itemprop="articleBody"`).
    private static func isRegionRoot(_ name: String, _ attributes: [String: String]) -> Bool {
        if name == "article" || name == "main" { return true }
        if name == "div" {
            return attributes["role"]?.lowercased() == "main"
                || attributes["itemprop"]?.lowercased() == "articlebody"
        }
        return false
    }

    /// Elements that carry no body even unclosed.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// The cleaned page's marked regions, most substantial first, and only
    /// those that actually hold most of the page's text — a teaser in a
    /// small `<article>` must not replace the full page (blog indexes mark
    /// each teaser as its own article). The 40% floor with a 200-char
    /// absolute minimum is the balance: real article bodies are the bulk of
    /// a page once chrome is gone; anything thinner is a listing.
    private static func preferredRegions(in cleaned: String, regions: [String]) -> [String] {
        guard !cleaned.isEmpty, !regions.isEmpty else { return [] }
        let whole = textWeight(of: cleaned)
        guard whole >= 400 else { return [] }   // tiny page: nothing to narrow
        let floor = max(200, whole * 2 / 5)
        var scored: [(text: String, weight: Int)] = []
        for region in regions {
            let weight = textWeight(of: region)
            guard weight >= floor else { continue }
            scored.append((region, weight))
        }
        return scored.sorted { $0.weight > $1.weight }.map { $0.text }
    }

    /// Visible-text weight: tags dropped, whitespace collapsed. Used only
    /// for comparisons between regions of the same page, so entity size and
    /// attribute loss are irrelevant.
    private static func textWeight(of html: String) -> Int {
        let stripped = html.replacingOccurrences(
            of: "<[^>]*>", with: " ", options: .regularExpression)
        return stripped.filter { !$0.isWhitespace }.count
    }

    // MARK: - Tag tokenizer

    private struct TagToken {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        /// Source index of the tag's `<`.
        let start: Int
        /// Source index just past the tag's `>` (or the end of input).
        let end: Int
        let attributes: [String: String]
    }

    /// Reads one tag at `start` (which must hold `<`). Attributes are
    /// consumed quote-aware so `alt="a > b"` cannot end the tag early —
    /// the same rule (and the same load-bearing bare-`<p>` break) as
    /// `HtmlReader.readTag`, without that reader's text-state machinery.
    /// Returns nil when `<` does not begin a tag (`<3`), so the caller can
    /// emit the character literally.
    private static func readTag(_ source: [Character], at start: Int) -> TagToken? {
        guard start + 1 < source.count else { return nil }
        var index = start + 1
        var isClosing = false
        if source[index] == "/" {
            isClosing = true
            index += 1
        }
        var name = ""
        while index < source.count, isNameChar(source[index]) {
            name.append(Character(source[index].lowercased()))
            index += 1
        }
        guard !name.isEmpty else { return nil }

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
                // Bare `<p>`: on '>' with nothing left to consume.
                break
            }
        }
        // `end` is just past '>'; at EOF it is the input end.
        let end = index < source.count ? index + 1 : source.count

        // Self-closing: a `/` immediately (modulo whitespace) before the '>'.
        var isSelfClosing = false
        if !isClosing {
            var back = index - 1
            while back > start, source[back].isWhitespace { back -= 1 }
            isSelfClosing = back > start && source[back] == "/"
        }

        return TagToken(
            name: name,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing,
            start: start,
            end: end,
            attributes: attributes
        )
    }

    private static func isNameChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "-" || char == "_" || char == ":"
    }
}
