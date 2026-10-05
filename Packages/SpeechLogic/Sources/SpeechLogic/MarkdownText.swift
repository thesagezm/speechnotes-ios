import Foundation
import Markdown

/// Markdown → speech text + reading-view blocks.
///
/// The parser underneath is cmark-gfm — GitHub's own engine, via
/// apple/swift-markdown — so GFM syntax (tables, task lists, strikethrough,
/// autolinks, reference links) parses by SPEC. The hand-rolled scanner this
/// replaced drifted on exactly the constructs real notes carry (nested
/// emphasis, tables with ragged rows, `*_mixed_` markers); a spec parser
/// also gives the plugin work a real AST to hang off.
///
/// Two outputs come from the same parsed document:
///  • `plainText(_:)` — syntax-stripped text for TTS and the read-along view
///    (what the engine hears == what the read-along shows, so SentenceChunker
///    offsets stay in sync).
///  • `blocks(_:)` — structured blocks for the preview; paragraphs and
///    headings carry `StyledSpan`s so the display layer styles emphasis from
///    the AST instead of re-tokenizing with a regex (which styled inline
///    code at a FIXED Dynamic Type size — the "font thickness/spacing is not
///    uniform" report — and mangled whatever the regex misjudged).
public enum MarkdownText {

    // MARK: - Public models

    public enum MarkdownBlock: Equatable {
        case heading(level: Int, text: String, spans: [StyledSpan])
        /// Single line breaks are CONTENT here (notes semantics — a soft
        /// break is how people write lists of lines; GFM would render it as
        /// a space).
        case paragraph(text: String, spans: [StyledSpan])
        case bulletList(items: [ListItem])
        case orderedList(items: [ListItem])
        case quote(String, spans: [StyledSpan])
        case code(language: String?, text: String)
        case divider
        case image(alt: String, url: String)
        case table(headers: [[StyledSpan]], rows: [[[StyledSpan]]])
    }

    /// A list item. `level` is the nesting depth (0 = top level), straight
    /// from the AST — the old indent-rank heuristic is gone.
    public struct ListItem: Equatable, Hashable, Sendable {
        public let level: Int
        public let text: String
        public let isTask: Bool
        public let isDone: Bool
        public let spans: [StyledSpan]
        public init(level: Int = 0, text: String, isTask: Bool = false, isDone: Bool = false, spans: [StyledSpan] = []) {
            self.level = level
            self.text = text
            self.isTask = isTask
            self.isDone = isDone
            self.spans = spans
        }
    }

    /// One styled piece of inline content, straight from the GFM AST.
    /// Flags compose: a nested **_both_** arrives with `bold` AND `italic`.
    /// `linkURL`/`image…` carry the runs the display layer turns into real
    /// links and images.
    public struct StyledSpan: Equatable, Hashable, Sendable {
        public let text: String
        public var bold: Bool
        public var italic: Bool
        public var code: Bool
        public var strike: Bool
        public var linkURL: String?
        public var imageAlt: String?
        public var imageURL: String?

        public init(
            text: String,
            bold: Bool = false,
            italic: Bool = false,
            code: Bool = false,
            strike: Bool = false,
            linkURL: String? = nil,
            imageAlt: String? = nil,
            imageURL: String? = nil
        ) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
            self.strike = strike
            self.linkURL = linkURL
            self.imageAlt = imageAlt
            self.imageURL = imageURL
        }

        /// A plain, unstyled span — the fallback every consumer uses when a
        /// block carries no AST spans.
        public static func plain(_ text: String) -> StyledSpan {
            StyledSpan(text: text)
        }

        public var isImage: Bool { imageURL != nil }
    }

    /// Inline run for the preview: text, native images, tappable links.
    public enum InlineRun: Equatable {
        case text(String)
        case image(alt: String, url: String)
        case link(label: String, url: String)
    }

    /// `[label]: url "title"` definition, used to resolve reference links.
    public struct LinkReference: Equatable, Hashable {
        public let label: String
        public let url: String
        public let title: String?
    }

    // MARK: - Regex cache (speech-stripping and the editing layer still
    // work on RAW text; the AST is the display parser)

    private static let regexLock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func rx(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        regexLock.lock(); defer { regexLock.unlock() }
        if let cached = regexCache[key] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache[key] = compiled
        return compiled
    }

    private static func replacePatterns(
        _ input: String, pattern: String, with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = rx(pattern, options: options) else { return input }
        let ns = input as NSString
        return regex.stringByReplacingMatches(
            in: input, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: template
        )
    }

    private static func replaceMatches(
        in input: String, pattern: String,
        handler: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = rx(pattern) else { return input }
        let ns = input as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard match.range.location >= cursor else { continue }
            if match.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            out += handler(match, ns)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return out
    }

    private static func normalize(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Speech text

    /// Markdown → plain text for speech + read-along. Derived from the same
    /// parsed document as the preview. Task items read "To do: …" /
    /// "Done: …", tables read row-wise, code is kept verbatim.
    ///
    /// The result passes through `SpeechSanitizer.clean` last: a note carries
    /// whatever a paste or an import brought in — soft hyphens from a copied
    /// PDF line, zero-width joiners, control bytes — and the engines fail on
    /// exactly those. Cleaning here rather than at the engine boundary keeps
    /// the read-along rendering equal to what is spoken.
    public static func plainText(_ markdown: String) -> String {
        // Speakability: an UNRESOLVED reference link stays literal in the
        // AST (`[label][missing]`), and the engine reading bracket soup was
        // the v1.5 report — speak the label instead. Resolved links are
        // already clean (the AST carries their text).
        let refs = Set(linkReferences(in: markdown).keys)
        var spokenBlocks = blocks(markdown)
        spokenBlocks = spokenBlocks.map { block in
            guard case .paragraph(let text, let spans) = block else { return block }
            let stripped = unresolvedReferences(text, defined: refs)
            return stripped == text ? block : .paragraph(text: stripped, spans: spans)
        }
        let spoken = spokenBlocks
            .compactMap { block -> String? in
                let text = speechText(for: block)
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n\n")
        return SpeechSanitizer.clean(spoken)
    }

    /// `[label][key]` → `label` for every reference whose key is not
    /// defined. A bare `[word]` stays literal (CommonMark leaves unresolved
    /// shortcut references alone, and stripping every bracket would eat the
    /// deliberate ones).
    private static func unresolvedReferences(_ text: String, defined: Set<String>) -> String {
        guard text.contains("][") else { return text }
        return replaceMatches(in: text, pattern: #"(?<!!)\[([^\]]+)\]\[([^\]]*)\]"#) { match, ns in
            let label = ns.substring(with: match.range(at: 1))
            let key = ns.substring(with: match.range(at: 2)).lowercased()
            let lookup = key.isEmpty ? label.lowercased() : key
            return defined.contains(lookup) ? ns.substring(with: match.range) : label
        }
    }

    private static func speechText(for block: MarkdownBlock) -> String {
        // The AST already resolved every inline construct (escapes, links,
        // emphasis) — the span text is what a reader sees, so it is what the
        // engine says. No re-stripping: speechInline on resolved text would
        // eat the LITERAL markers GFM deliberately kept (an escaped `\*`).
        func plain(_ spans: [StyledSpan]) -> String {
            spans.map(\.text).joined()
        }
        switch block {
        case .heading(_, let text, _), .paragraph(let text, _):
            return text
        case .bulletList(let items), .orderedList(let items):
            return items.map { item -> String in
                if item.isTask { return (item.isDone ? "Done: " : "To do: ") + item.text }
                return item.text
            }.joined(separator: "\n")
        case .quote(let text, _):
            return text
        case .code(_, let text):
            return text
        case .divider:
            return ""
        case .image(let alt, _):
            return alt
        case .table(let headers, let rows):
            func cell(_ spans: [StyledSpan]) -> String { spans.map(\.text).joined() }
            var lines = [headers.map(cell).joined(separator: ", ")]
            for row in rows {
                lines.append(row.map(cell).joined(separator: ", "))
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Strips inline syntax from one chunk of RAW text (the editing path —
    /// speech while the draft is unrendered). AST-derived text is already
    /// stripped, so this is only ever fed raw drafts and table cells.
    /// Escape-protected so `\*never italic\*` survives emphasis stripping.
    public static func speechInline(_ text: String, references: [String: LinkReference] = [:]) -> String {
        guard !text.isEmpty else { return text }

        // 1. Protect backslash escapes so `\*` never looks like emphasis.
        var (line, stash) = protectEscapes(text)

        // 2. Footnote markers are silent.
        line = replacePatterns(line, pattern: #"\[\^[^\]]+\]"#, with: "")

        // 3. Images → alt text (inline and reference forms).
        line = replaceMatches(in: line, pattern: #"!\[([^\]]*)\](?:\([^)]*\)|\[([^\]]*)\])"#) { m, ns in
            ns.substring(with: m.range(at: 1))
        }

        // 4. Links → label (inline and reference forms). An UNRESOLVED
        // reference link also speaks its label — the raw `[label][key]`
        // form reads as bracket soup and made the spoken text drift from
        // what a reader expects (v1.5 speakability fix).
        line = replaceMatches(in: line, pattern: #"(?<!!)\[([^\]]+)\](?:\([^)]*\)|\[([^\]]*)\])"#) { m, ns in
            ns.substring(with: m.range(at: 1))
        }

        // 5. Autolinks → bare URL.
        line = replacePatterns(line, pattern: #"<((?:https?://|mailto:)[^>\s]+)>"#, with: "$1")
        line = replacePatterns(line, pattern: #"<([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})>"#, with: "$1")

        // 6. Code spans → content.
        line = replacePatterns(line, pattern: #"`([^`]+)`"#, with: "$1")

        // 7. Emphasis markers (loop until stable, bounded).
        for _ in 0..<6 {
            var next = line
            for rule in emphasisRules {
                next = replacePatterns(next, pattern: rule.pattern, with: rule.template)
            }
            if next == line { break }
            line = next
        }

        // 8. HTML: <br> becomes a line break; other tags vanish.
        line = replacePatterns(line, pattern: #"<br\s*/?>"#, with: "\n", options: [.caseInsensitive])
        line = replacePatterns(line, pattern: #"</?[A-Za-z][^>]*>"#, with: "")

        // 9. Restore escapes.
        return restoreEscapes(line, stash: stash)
    }

    private static let emphasisRules: [(pattern: String, template: String)] = [
        (#"\*\*\*([^*]+)\*\*\*"#, "$1"),
        (#"\*\*([^*]+)\*\*"#, "$1"),
        (#"__([^_]+)__"#, "$1"),
        (#"(?<![*\w])\*([^*\s][^*]*)\*(?!\*)"#, "$1"),
        (#"(?<![\w_])_([^_\s][^_]*)_(?![\w_])"#, "$1"),
        (#"~~([^~]+)~~"#, "$1"),
    ]

    private static let asciiPunctuation: Set<Character> =
        Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// `\X` → invisible sentinel + index, so escaped markers can't be
    /// mistaken for syntax by later passes. Sentinels are restored after.
    private static func protectEscapes(_ line: String) -> (line: String, stash: [String]) {
        guard line.contains("\\") else { return (line, []) }
        var stash: [String] = []
        var out = ""
        out.reserveCapacity(line.count)
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\\" {
                let next = line.index(after: index)
                if next < line.endIndex, asciiPunctuation.contains(line[next]) {
                    stash.append(String(line[next]))
                    out += "\u{1}"
                    out += String(stash.count - 1)
                    index = line.index(after: next)
                    continue
                }
            }
            out.append(character)
            index = line.index(after: index)
        }
        return (out, stash)
    }

    private static func restoreEscapes(_ line: String, stash: [String]) -> String {
        guard !stash.isEmpty, line.contains("\u{1}") else { return line }
        var out = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\u{1}" {
                var digits = ""
                var scan = line.index(after: index)
                while scan < line.endIndex, line[scan].isASCII, line[scan].isNumber {
                    digits.append(line[scan])
                    scan = line.index(after: scan)
                }
                if let n = Int(digits), n < stash.count {
                    out += stash[n]
                    index = scan
                    continue
                }
            }
            out.append(line[index])
            index = line.index(after: index)
        }
        return out
    }

    // MARK: - Blocks (reading view) — the GFM AST

    /// Parses `markdown` with cmark-gfm and maps the AST onto the reading
    /// view's block model.
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        // The AST parser handles \r\n itself; normalize anyway so the
        // plain-text joiners here never meet a stray \r.
        let document = Document(parsing: normalize(markdown))
        var result: [MarkdownBlock] = []
        for child in document.children {
            appendBlock(child, to: &result)
        }
        return result
    }

    private static func appendBlock(_ node: any Markup, to result: inout [MarkdownBlock]) {
        switch node {
        case let heading as Heading:
            let spans = spans(of: heading.children)
            result.append(.heading(
                level: heading.level,
                text: spans.map(\.text).joined(),
                spans: spans
            ))

        case let paragraph as Paragraph:
            let spans = spans(of: paragraph.children)
            // A paragraph that is exactly one image renders as an image
            // block — the alt text is not body copy.
            let images = spans.filter(\.isImage)
            if images.count == 1, spans.count == 1,
               let alt = images[0].imageAlt, let url = images[0].imageURL {
                result.append(.image(alt: alt, url: url))
            } else if !spans.isEmpty {
                result.append(.paragraph(text: spans.map(\.text).joined(), spans: spans))
            }

        case let list as OrderedList:
            result.append(.orderedList(items: listItems(of: list)))

        case let list as UnorderedList:
            result.append(.bulletList(items: listItems(of: list)))

        case let quote as BlockQuote:
            // One source paragraph per line, WITH its spans — bold inside a
            // blockquote stays bold on screen (the sample notes are full of
            // emphasized blockquote leads).
            var lines: [String] = []
            var quoteSpans: [StyledSpan] = []
            flattenQuote(quote, into: &lines, spans: &quoteSpans)
            if !lines.isEmpty {
                result.append(.quote(lines.joined(separator: "\n"), spans: quoteSpans))
            }

        case let code as CodeBlock:
            // The fence's own trailing newline is structure, not content.
            var body = code.code
            if body.hasSuffix("\n") { body.removeLast() }
            result.append(.code(language: code.language, text: body))

        case is ThematicBreak:
            result.append(.divider)

        case is Table:
            if let parsed = tableSpans(from: node) {
                result.append(.table(headers: parsed.headers, rows: parsed.rows))
            }

        case is HTMLBlock:
            // Raw HTML has no reading in a notes app — skipped, the same
            // call the old scanner made for comments.
            break

        default:
            // Anything unmodelled (definitions, directives) contributes its
            // plain text as a paragraph rather than vanishing.
            let text = plainInlineText(of: node.children)
            if !text.isEmpty {
                result.append(.paragraph(text: text, spans: [.plain(text)]))
            }
        }
    }

    private struct ParsedTable {
        var headers: [[StyledSpan]]
        var rows: [[[StyledSpan]]]
    }

    /// One span list per cell — each cell is a header or body CELL, and its
    /// own emphasis (a bold term in a table) rides along.
    private static func tableSpans(from node: any Markup) -> ParsedTable? {
        guard let table = node as? Table else { return nil }
        let head = table.head.children.compactMap { $0 as? Table.Cell }
            .map { spans(of: $0.children) }
        let rows: [[[StyledSpan]]] = table.body.children.compactMap { row in
            guard let row = row as? Table.Row else { return nil }
            return row.children.compactMap { $0 as? Table.Cell }
                .map { spans(of: $0.children) }
        }
        guard !head.isEmpty else { return nil }
        return ParsedTable(headers: head, rows: rows)
    }

    /// One `ListItem` per AST item, nested lists flattened to deeper levels
    /// (the preview indents by `level`). A task marker is the item's first
    /// inline child when the item is a GFM task.
    private static func listItems(of list: any Markup) -> [ListItem] {
        var items: [ListItem] = []
        for child in list.children {
            // `Markdown.ListItem`: the AST node (our own `ListItem` wins the
            // unqualified name inside this file).
            guard let item = child as? Markdown.ListItem else { continue }
            flattenListItem(item, level: 0, into: &items)
        }
        return items
    }

    private static func flattenListItem(_ item: Markdown.ListItem, level: Int, into items: inout [ListItem]) {
        // The GFM checkbox is a property of the list item itself in this
        // parser — no marker node to strip from the paragraph.
        let isTask = item.checkbox != nil
        let isDone = item.checkbox == .checked

        var textParts: [String] = []
        var itemSpans: [StyledSpan] = []

        func flush() {
            let text = textParts.joined()
            if !text.isEmpty || isTask {
                items.append(ListItem(
                    level: level, text: text,
                    isTask: isTask, isDone: isDone, spans: itemSpans
                ))
            }
            textParts = []
            itemSpans = []
        }

        for child in item.children {
            switch child {
            case let paragraph as Paragraph:
                let childSpans = spans(of: paragraph.children)
                if !textParts.isEmpty { textParts.append("\n") }
                textParts.append(childSpans.map(\.text).joined())
                itemSpans.append(contentsOf: childSpans)
            case let subList as UnorderedList:
                flush()
                flattenSubList(subList, level: level + 1, into: &items)
            case let subList as OrderedList:
                flush()
                flattenSubList(subList, level: level + 1, into: &items)
            case let code as CodeBlock:
                if !textParts.isEmpty { textParts.append("\n") }
                textParts.append(code.code)
            default:
                let text = plainInlineText(of: child.children)
                if !text.isEmpty {
                    if !textParts.isEmpty { textParts.append("\n") }
                    textParts.append(text)
                }
            }
        }
        flush()
    }

    private static func flattenSubList(_ list: any Markup, level: Int, into items: inout [ListItem]) {
        for child in list.children {
            guard let item = child as? Markdown.ListItem else { continue }
            flattenListItem(item, level: level, into: &items)
        }
    }

    private static func flattenQuote(_ quote: BlockQuote, into lines: inout [String], spans out: inout [StyledSpan]) {
        for child in quote.children {
            switch child {
            case let paragraph as Paragraph:
                let paragraphSpans = spans(of: paragraph.children)
                let text = paragraphSpans.map(\.text).joined()
                if !text.isEmpty {
                    if !lines.isEmpty { out.append(StyledSpan(text: "\n")) }
                    lines.append(text)
                    out.append(contentsOf: paragraphSpans)
                }
            case let nested as BlockQuote:
                flattenQuote(nested, into: &lines, spans: &out)
            case let code as CodeBlock:
                lines.append(code.code)
            default:
                let text = plainInlineText(of: child.children)
                if !text.isEmpty { lines.append(text) }
            }
        }
    }

    // MARK: - Inline spans (the AST walk)

    /// The inline children of one block, as styled spans. Containers recurse
    /// with their flags set; breaks become newlines; an image becomes an
    /// image span the display layer lifts out.
    private static func spans<S: Sequence>(of children: S) -> [StyledSpan] where S.Element == any Markup {
        var out: [StyledSpan] = []
        collectSpans(children, bold: false, italic: false, strike: false, into: &out)
        return out.compactMap { span in
            // Drop empty text spans except images (an empty alt is legal).
            span.isImage || !span.text.isEmpty ? span : nil
        }
    }

    private static func collectSpans<S: Sequence>(
        _ children: S,
        bold: Bool,
        italic: Bool,
        strike: Bool,
        into out: inout [StyledSpan]
    ) where S.Element == any Markup {
        for child in children {
            switch child {
            case let text as Text:
                out.append(StyledSpan(
                    text: text.string, bold: bold, italic: italic,
                    code: false, strike: strike
                ))

            case let strong as Strong:
                collectSpans(strong.children, bold: true, italic: italic, strike: strike, into: &out)

            case let emphasis as Emphasis:
                collectSpans(emphasis.children, bold: bold, italic: true, strike: strike, into: &out)

            case let code as InlineCode:
                out.append(StyledSpan(
                    text: code.code, bold: bold, italic: italic,
                    code: true, strike: strike
                ))

            case let strikeNode as Strikethrough:
                collectSpans(strikeNode.children, bold: bold, italic: italic, strike: true, into: &out)

            case let link as Markdown.Link:
                let inner = spans(of: link.children)
                if inner.count == 1, !inner[0].isImage {
                    var span = inner[0]
                    span.linkURL = link.destination ?? ""
                    out.append(span)
                } else {
                    out.append(StyledSpan(
                        text: inner.map(\.text).joined(),
                        bold: bold, italic: italic, code: false,
                        strike: strike, linkURL: link.destination ?? ""
                    ))
                }

            case let image as Markdown.Image:
                let alt = plainInlineText(of: image.children)
                out.append(StyledSpan(
                    text: alt,
                    bold: bold, italic: italic, code: false, strike: strike,
                    imageAlt: alt, imageURL: image.source ?? ""
                ))

            case let soft as SoftBreak:
                // Notes semantics: the author pressed return, so a line
                // break it is (GFM would render a space).
                out.append(StyledSpan(text: "\n"))

            case let hard as LineBreak:
                out.append(StyledSpan(text: "\n"))

            case is InlineHTML:
                // Raw inline tags have no display — skipped, as before.
                break

            default:
                // Unknown inline container: descend with current flags so
                // nothing inside is lost.
                collectSpans(child.children, bold: bold, italic: italic, strike: strike, into: &out)
            }
        }
    }

    /// The plain text of inline children — for contexts that want one string
    /// (table cells, image alt, fallbacks).
    private static func plainInlineText<S: Sequence>(of children: S) -> String where S.Element == any Markup {
        spans(of: children).map(\.text).joined()
    }

    // MARK: - Inline runs (preview) — same AST, the InlineRun shape

    /// Splits a line into text / image / link runs via the AST. E.g. "See
    /// ![x](a.png) and [docs](https://d.com)" → text, image, text, link,
    /// text.
    public static func inlineRuns(_ line: String, references: [String: LinkReference] = [:]) -> [InlineRun] {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let spans = spans(of: Array(Document(parsing: line).children))
        let runs = runs(from: spans)
        return runs.isEmpty ? [.text(line)] : runs
    }

    /// Runs straight from spans the caller already holds — paragraph blocks
    /// carry theirs from the document parse. Re-parsing the paragraph's PLAIN
    /// text (the old preview path) cannot recover images: flattening replaced
    /// the `![…](…)` marker with the alt text, so an inline image vanished
    /// from every paragraph that was not exactly one image.
    public static func runs(from spans: [StyledSpan]) -> [InlineRun] {
        var runs: [InlineRun] = []
        for span in spans {
            if let alt = span.imageAlt, let url = span.imageURL {
                if !url.isEmpty { runs.append(.image(alt: alt, url: url)) }
                else if !span.text.isEmpty { runs.append(.text(span.text)) }
            } else if let url = span.linkURL, !url.isEmpty {
                runs.append(.link(label: span.text, url: url))
            } else if !span.text.isEmpty {
                runs.append(.text(span.text))
            }
        }
        return runs
    }

    // MARK: - Reference definitions

    /// Scans the document for `[label]: url "title"` lines (fence-aware,
    /// footnote `[^…]` labels excluded). Keys are lowercased labels.
    public static func linkReferences(in markdown: String) -> [String: LinkReference] {
        var map: [String: LinkReference] = [:]
        guard let rx = rx(#"^[ \t]{0,3}\[([^\]^][^\]]*)\]:[ \t]*(?:<([^<>]+)>|(\S+))(?:[ \t]+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\)))?[ \t]*$"#) else { return map }
        var fenceChar: Character? = nil
        for rawLine in normalize(markdown).components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let info = fenceInfo(line) {
                if fenceChar == nil { fenceChar = info.char }
                else if info.char == fenceChar, info.canClose { fenceChar = nil }
                continue
            }
            guard fenceChar == nil,
                  let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            else { continue }
            let ns = line as NSString
            func group(_ index: Int) -> String? {
                let r = m.range(at: index)
                return r.location != NSNotFound && r.length > 0 ? ns.substring(with: r) : nil
            }
            let label = ns.substring(with: m.range(at: 1))
            let url = group(2) ?? group(3) ?? ""
            guard !url.isEmpty else { continue }
            map[label.lowercased()] = LinkReference(label: label, url: url, title: group(4) ?? group(5) ?? group(6))
        }
        return map
    }

    // MARK: - Token scanners (editing layer)

    /// Every link (inline, reference, resolved) as (label, url, range-in-markdown).
    public static func linkTargets(in markdown: String) -> [(label: String, url: String, range: Range<String.Index>)] {
        var results: [(String, String, Range<String.Index>)] = []
        guard let rx = rx(#"(?<!!)\[([^\]]+)\](?:\(([^)]*)\)|\[([^\]]*)\])"#) else { return [] }
        let refs = linkReferences(in: markdown)
        let ns = markdown as NSString
        rx.enumerateMatches(in: markdown, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let label = ns.substring(with: match.range(at: 1))
            var url = ""
            if match.range(at: 2).location != NSNotFound {
                url = cleanURL(ns.substring(with: match.range(at: 2)))
            } else if match.range(at: 3).location != NSNotFound {
                let ref = ns.substring(with: match.range(at: 3))
                url = refs[(ref.isEmpty ? label : ref).lowercased()]?.url ?? ""
            }
            guard !url.isEmpty, let swiftRange = Range(match.range, in: markdown) else { return }
            results.append((label, url, swiftRange))
        }
        return results
    }

    /// Every image token (inline and reference, resolved) as (alt, url, range).
    public static func imageTokens(in markdown: String) -> [(alt: String, url: String, range: Range<String.Index>)] {
        var results: [(String, String, Range<String.Index>)] = []
        guard let rx = rx(#"!\[([^\]]*)\](?:\(([^)]*)\)|\[([^\]]*)\])"#) else { return [] }
        let refs = linkReferences(in: markdown)
        let ns = markdown as NSString
        rx.enumerateMatches(in: markdown, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let alt = ns.substring(with: match.range(at: 1))
            var url = ""
            if match.range(at: 2).location != NSNotFound {
                url = cleanURL(ns.substring(with: match.range(at: 2)))
            } else if match.range(at: 3).location != NSNotFound {
                let ref = ns.substring(with: match.range(at: 3))
                url = refs[(ref.isEmpty ? alt : ref).lowercased()]?.url ?? ""
            }
            guard !url.isEmpty, let swiftRange = Range(match.range, in: markdown) else { return }
            results.append((alt, url, swiftRange))
        }
        return results
    }

    // MARK: - Line-level helpers (the editing layer's fence scan)

    private static func fenceInfo(_ line: String) -> (char: Character, length: Int, info: String, canClose: Bool)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        var count = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == first {
            count += 1
            idx = line.index(after: idx)
        }
        guard count >= 3 else { return nil }
        let rest = String(line[idx...])
        let info = rest.trimmingCharacters(in: .whitespaces)
        return (first, count, info, canClose: info.isEmpty)
    }

    /// `raw` is the `(...)` part of a link/image: trims whitespace, drops a
    /// trailing `"title"`, unwraps `<…>`.
    private static func cleanURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespaces)
        if let quote = url.firstIndex(of: "\"") {
            url = String(url[..<quote]).trimmingCharacters(in: .whitespaces)
        }
        if url.hasPrefix("<"), url.hasSuffix(">"), url.count >= 2 {
            url = String(url.dropFirst().dropLast())
        }
        return url
    }
}
