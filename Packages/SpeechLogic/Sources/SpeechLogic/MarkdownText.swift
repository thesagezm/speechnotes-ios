import Foundation

/// Markdown → plain text for speech and read-along display.
///
/// When "Render Markdown" is on, the engine should not hear "hashtag
/// hashtag heading" and the read-along view should not show `**bold**`.
/// This converter strips syntax while KEEPING the content and paragraph
/// structure, so `SentenceChunker` offsets map cleanly onto the same string
/// the read-along view displays.
///
/// Deliberately pragmatic (CommonMark-ish, not exhaustive): headings,
/// emphasis/strong/strikethrough markers, inline code backticks, fenced and
/// indented code blocks (content kept), links → label, images → alt text,
/// blockquote markers, list bullets (text kept), thematic breaks. Anything
/// unrecognized passes through untouched — malformed markdown just reads as
/// itself.
public enum MarkdownText {

    public static func plainText(_ markdown: String) -> String {
        var outLines: [String] = []
        var inFence = false

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks: ``` / ~~~ toggles; content kept verbatim.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence {
                    inFence = true
                } else {
                    inFence = false
                }
                outLines.append("")
                continue
            }
            if inFence {
                outLines.append(rawLine)
                continue
            }

            var line = trimmed

            // Thematic breaks (---, ***, ___ alone) vanish.
            if isThematicBreak(line) {
                outLines.append("")
                continue
            }

            // Headings: drop the leading #'s.
            if let heading = stripHeading(line) {
                line = heading
            }

            // Blockquote markers (possibly nested, possibly lazy).
            while line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            // List bullets: "- ", "* ", "+ " → keep text on its own line;
            // "3. " → keep text (the number is noise for speech).
            line = stripListMarker(line)

            // Inline transformations.
            line = stripImages(line)
            line = stripLinks(line)
            line = stripEmphasisAndCode(line)

            outLines.append(line)
        }

        // Collapse the runs of blank lines our removals can leave behind,
        // preserving single paragraph breaks.
        var paragraphs: [String] = []
        var current: [String] = []
        for line in outLines {
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: "\n"))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - Block structure (reading view)

    /// One block of a markdown document, for reading-view layout.
    public enum MarkdownBlock: Equatable {
        case heading(level: Int, text: String)
        /// May contain "\n" — single line breaks are CONTENT here.
        case paragraph(String)
        case bulletList(items: [String])
        case orderedList(items: [String])
        case quote(String)
        case code(String)
        case divider
        /// Standalone image (paragraph that contained only an image token).
        case image(alt: String, url: String)
    }

    /// An inline run inside a paragraph/heading/list item. Lets the preview
    /// render text + images together with arbitrary order — e.g.
    /// "Look ![logo](x.png) here" splits into [.text("Look "), .image("logo", "x.png"), .text(" here")].
    public enum InlineRun: Equatable {
        case text(String)
        case image(alt: String, url: String)
    }

    /// Inline parse for a single line/paragraph, splitting text and image
    /// tokens so the preview can render mixed content. Other markdown syntax
    /// (bold/italic/code/links) is left as raw text for Foundation's
    /// AttributedString to style — image runs are the only structural token
    /// we need to lift out for native rendering.
    public static func inlineRuns(_ line: String) -> [InlineRun] {
        guard let regex = try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\([^)]+\)"#) else {
            return [.text(line)]
        }
        let nsLine = line as NSString
        let matches = regex.matches(
            in: line, options: [],
            range: NSRange(location: 0, length: nsLine.length)
        )
        if matches.isEmpty { return [.text(line)] }

        var runs: [InlineRun] = []
        var cursor = 0
        let full = NSRange(location: 0, length: nsLine.length)
        for match in matches {
            // Text before the image.
            if match.range.location > cursor {
                let textRange = NSRange(location: cursor, length: match.range.location - cursor)
                let before = nsLine.substring(with: textRange)
                if !before.isEmpty { runs.append(.text(before)) }
            }
            // Image token: ![alt](url) — extract alt and url.
            if let (alt, url) = parseImage(nsLine.substring(with: match.range)) {
                runs.append(.image(alt: alt, url: url))
            } else {
                runs.append(.text(nsLine.substring(with: match.range)))
            }
            cursor = match.range.location + match.range.length
        }
        // Trailing text.
        if cursor < full.length {
            let tail = nsLine.substring(from: cursor)
            if !tail.isEmpty { runs.append(.text(tail)) }
        }
        return runs
    }

    /// Parses a single image token "![alt](url)". Returns (alt, url) or nil
    /// on malformed input. URL strings inside parens may not contain ')'.
    private static func parseImage(_ token: String) -> (alt: String, url: String)? {
        guard token.hasPrefix("![") else { return nil }
        let afterBang = token.dropFirst(2)
        guard let altEnd = afterBang.firstIndex(of: "]") else { return nil }
        let alt = String(afterBang[..<altEnd])
        var rest = afterBang[afterBang.index(after: altEnd)...]
        guard rest.hasPrefix("(") else { return nil }
        rest = rest.dropFirst()
        guard rest.hasSuffix(")") else { return nil }
        let url = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
        return (alt, url)
    }

    /// Extract every link target in `markdown` (without rendering). Used by
    /// the editor's link-edit popover and by the preview's long-press
    /// handler.
    public static func linkTargets(in markdown: String) -> [(label: String, url: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) else {
            return []
        }
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        var results: [(String, String, Range<String.Index>)] = []
        regex.enumerateMatches(in: markdown, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            let label = ns.substring(with: match.range(at: 1))
            let url = ns.substring(with: match.range(at: 2))
            if let swiftRange = Range(match.range, in: markdown) {
                results.append((label, url, swiftRange))
            }
        }
        return results
    }

    /// Extract every image token in `markdown` as (alt, url, range). Same
    /// shape as `linkTargets(in:)` for the editing layer.
    public static func imageTokens(in markdown: String) -> [(alt: String, url: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]+\)"#) else {
            return []
        }
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        var results: [(String, String, Range<String.Index>)] = []
        regex.enumerateMatches(in: markdown, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 1,
                  let (alt, url) = parseImage(ns.substring(with: match.range)),
                  let swiftRange = Range(match.range, in: markdown) else { return }
            results.append((alt, url, swiftRange))
        }
        return results
    }

    /// Block structure for the reading view. Same scanning rules as
    /// `plainText` (fences, headings, thematic breaks, > quotes, -/*/+/ and
    /// "1." list markers) but inline syntax is left intact for the display
    /// layer to style. Consecutive non-blank lines form ONE paragraph joined
    /// by "\n" — line breaks stay visible.
    ///
    /// Standalone-image paragraphs become `.image` blocks; otherwise a
    /// paragraph with inline images stays as `.paragraph(text)` and the
    /// preview calls `inlineRuns` to split text vs image.
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var codeLines: [String] = []
        var inFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
            if let (alt, url) = standaloneImage(joined) {
                result.append(.image(alt: alt, url: url))
            } else {
                result.append(.paragraph(joined))
            }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { result.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushLists() {
            if !bullets.isEmpty { result.append(.bulletList(items: bullets)) }
            bullets = []
            if !ordered.isEmpty { result.append(.orderedList(items: ordered)) }
            ordered = []
        }
        func flushAll() { flushParagraph(); flushQuote(); flushLists() }

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence {
                    flushAll()
                    inFence = true
                } else {
                    inFence = false
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                }
                continue
            }
            if inFence {
                codeLines.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if isThematicBreak(trimmed) {
                flushAll()
                result.append(.divider)
                continue
            }
            if let heading = stripHeading(trimmed), let level = headingLevel(trimmed) {
                flushAll()
                result.append(.heading(level: level, text: heading))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushLists()
                var line = trimmed
                while line.hasPrefix(">") {
                    line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                quote.append(line)
                continue
            }
            if let item = bulletItem(trimmed) {
                flushParagraph(); flushQuote()
                if !ordered.isEmpty { flushLists() }
                bullets.append(item)
                continue
            }
            if let item = orderedItem(trimmed) {
                flushParagraph(); flushQuote()
                if !bullets.isEmpty { flushLists() }
                ordered.append(item)
                continue
            }
            flushQuote(); flushLists()
            paragraph.append(trimmed)
        }
        if inFence { result.append(.code(codeLines.joined(separator: "\n"))) }
        flushAll()
        return result
    }

    /// If `joined` is JUST an image token (with optional whitespace), returns
    /// (alt, url). Lets the preview render stand-alone images as a block.
    private static func standaloneImage(_ joined: String) -> (alt: String, url: String)? {
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
        let runs = inlineRuns(trimmed)
        // Sole run must be an image with no surrounding text.
        guard runs.count == 1, case .image(let alt, let url) = runs[0] else {
            return nil
        }
        return (alt, url)
    }

    /// Heading level (count of leading #'s), 1–6, else nil.
    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var count = 0
        for character in line {
            guard character == "#" else { break }
            count += 1
        }
        return (1...6).contains(count) ? count : nil
    }

    /// "- text" / "* text" / "+ text" → "text"; nil when not a bullet item.
    private static func bulletItem(_ line: String) -> String? {
        guard let first = line.first, first == "-" || first == "*" || first == "+",
              line.dropFirst().first == " " else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// "3. text" / "3) text" → "text"; nil when not an ordered item.
    private static func orderedItem(_ line: String) -> String? {
        guard let match = line.range(of: #"^\d{1,9}[.)]\s+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[match.upperBound...])
    }

    // MARK: - Block-level helpers

    private static func isThematicBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let characters = Array(line)
        let first = characters[0]
        guard first == "-" || first == "*" || first == "_" else { return false }
        var runs = 0
        for character in characters {
            if character == first {
                runs += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return runs >= 3
    }

    private static func stripHeading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        var rest = Substring(line)
        var marks = 0
        while rest.first == "#" {
            rest = rest.dropFirst()
            marks += 1
        }
        guard marks <= 6, rest.first == " " || rest.first == "\t" else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private static func stripListMarker(_ line: String) -> String {
        // Bullet lists.
        if let first = line.first, first == "-" || first == "*" || first == "+" {
            let rest = line.dropFirst()
            if rest.first == " " {
                return String(rest).trimmingCharacters(in: .whitespaces)
            }
        }
        // Ordered lists: digits, optional separator, space.
        if let match = line.range(of: #"^\d{1,9}[.)]\s+"#, options: .regularExpression) {
            return String(line[match.upperBound...])
        }
        return line
    }

    // MARK: - Inline helpers

    private static func stripImages(_ line: String) -> String {
        // Drop image tokens AND their trailing space (so "Hello ![x](y) world"
        // collapses to "Hello world" not "Hello  world").
        let noImages = replacePatterns(line, pattern: #"!\[[^\]]*\]\([^)]*\) ?"#, with: "")
        return noImages
    }

    private static func stripLinks(_ line: String) -> String {
        replacePatterns(line, pattern: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
    }

    /// Removes **bold**, __bold__, *italic*, _italic_, ~~strike~~ and
    /// `code` markers. Opening markers can't be followed by whitespace
    /// (CommonMark rule) which incidentally protects arithmetic like
    /// `2 * 3 * 4`; underscores also require word boundaries so snake_case
    /// identifiers survive. Nested emphasis needs repeated passes — loop
    /// until stable, bounded.
    private static func stripEmphasisAndCode(_ line: String) -> String {
        var current = line
        for _ in 0..<4 {
            let next = replacePatterns(
                replacePatterns(
                    replacePatterns(
                        replacePatterns(
                            replacePatterns(
                                current, pattern: #"`([^`]+)`"#, with: "$1"
                            ),
                            pattern: #"\*\*([^*]+)\*\*"#, with: "$1"
                        ),
                        pattern: #"__([^_]+)__"#, with: "$1"
                    ),
                    pattern: #"(?<![*\w])\*([^*\s][^*]*)\*(?!\*)"#, with: "$1"
                ),
                pattern: #"(?<![\w_])_([^_\s][^_]*)_(?![\w_])"#, with: "$1"
            )
            let strike = replacePatterns(next, pattern: #"~~([^~]+)~~"#, with: "$1")
            if strike == current { return strike }
            current = strike
        }
        return current
    }

    private static func replacePatterns(_ input: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }
}
