import Foundation

/// Markdown → speech text + reading-view blocks.
///
/// One scanner (`blocks`) drives both outputs:
///  • `plainText(_:)` — syntax-stripped text for TTS and the read-along view
///    (what the engine hears == what the read-along shows, so SentenceChunker
///    offsets stay in sync).
///  • `blocks(_:)` — structured blocks for the preview; inline syntax stays
///    intact for the display layer to style.
///
/// Handles ATX/setext headings, fenced code (matched fence char/length,
/// language captured), lists with nesting ranks + task markers + lazy
/// continuation, blockquotes, tables, reference links/images, autolinks,
/// footnote-lite, thematic breaks, images, HTML comments/tags, backslash
/// escapes. Unrecognized syntax passes through untouched.
public enum MarkdownText {

    // MARK: - Public models

    public enum MarkdownBlock: Equatable {
        case heading(level: Int, text: String)
        /// Single line breaks are CONTENT here.
        case paragraph(String)
        case bulletList(items: [ListItem])
        case orderedList(items: [ListItem])
        case quote(String)
        case code(language: String?, text: String)
        case divider
        case image(alt: String, url: String)
        case table(headers: [String], rows: [[String]])
    }

    /// A list item. `level` is the nesting rank (0 = top level), computed
    /// relative to the other indents in the same list — so 2-space and
    /// 4-space nesting both work.
    public struct ListItem: Equatable, Hashable, Sendable {
        public let level: Int
        public let text: String
        public let isTask: Bool
        public let isDone: Bool
        public init(level: Int = 0, text: String, isTask: Bool = false, isDone: Bool = false) {
            self.level = level
            self.text = text
            self.isTask = isTask
            self.isDone = isDone
        }
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

    // MARK: - Regex cache (the old code recompiled every pattern per line)

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
    /// block scan as the preview. Task items read "To do: …" / "Done: …",
    /// tables read row-wise, code is kept verbatim.
    public static func plainText(_ markdown: String) -> String {
        let refs = linkReferences(in: markdown)
        let parsed = blocks(markdown, references: refs)
        return parsed
            .compactMap { block -> String? in
                let text = speechText(for: block, references: refs)
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n\n")
    }

    private static func speechText(for block: MarkdownBlock, references refs: [String: LinkReference]) -> String {
        switch block {
        case .heading(_, let text), .paragraph(let text):
            return speechInline(text, references: refs)
        case .bulletList(let items), .orderedList(let items):
            return items.map { item -> String in
                let body = speechInline(item.text, references: refs)
                if item.isTask { return (item.isDone ? "Done: " : "To do: ") + body }
                return body
            }.joined(separator: "\n")
        case .quote(let text):
            return speechInline(text, references: refs)
        case .code(_, let text):
            return text
        case .divider:
            return ""
        case .image(let alt, _):
            return speechInline(alt, references: refs)
        case .table(let headers, let rows):
            var lines = [headers.map { speechInline($0, references: refs) }.joined(separator: ", ")]
            for row in rows {
                lines.append(row.map { speechInline($0, references: refs) }.joined(separator: ", "))
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Strips inline syntax from one chunk of text. Escape-protected so
    /// `\*never italic\*` survives emphasis stripping.
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

        // 4. Links → label (inline and reference forms).
        line = replaceMatches(in: line, pattern: #"(?<!!)\[([^\]]+)\](?:\([^)]*\)|\[([^\]]*)\])"#) { m, ns in
            let label = ns.substring(with: m.range(at: 1))
            let ref = m.range(at: 2)
            if ref.location != NSNotFound {
                let key = ns.substring(with: ref)
                let resolved = references[(key.isEmpty ? label : key).lowercased()] != nil
                return resolved ? label : ns.substring(with: m.range)
            }
            return label
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

    // MARK: - Blocks (reading view)

    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        blocks(markdown, references: linkReferences(in: markdown))
    }

    public static func blocks(_ markdown: String, references refs: [String: LinkReference]) -> [MarkdownBlock] {
        let lines = normalize(markdown).components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        struct PendingItem { var indent: Int; var text: String; var isTask = false; var isDone = false }
        var bullets: [PendingItem] = []
        var ordered: [PendingItem] = []
        var codeLines: [String] = []
        var codeLanguage: String? = nil
        var fence: (char: Character, length: Int)? = nil
        var inHTMLComment = false

        func finalized(_ item: PendingItem, among siblings: [PendingItem]) -> ListItem {
            let distinct = Set(siblings.map(\.indent)).sorted()
            return ListItem(
                level: distinct.firstIndex(of: item.indent) ?? 0,
                text: item.text, isTask: item.isTask, isDone: item.isDone
            )
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
            if let (alt, url) = standaloneImage(joined, references: refs) {
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
            if !bullets.isEmpty {
                result.append(.bulletList(items: bullets.map { finalized($0, among: bullets) }))
                bullets = []
            }
            if !ordered.isEmpty {
                result.append(.orderedList(items: ordered.map { finalized($0, among: ordered) }))
                ordered = []
            }
        }
        func flushCode() {
            result.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
            codeLines = []
            codeLanguage = nil
        }
        func flushAll() { flushParagraph(); flushQuote(); flushLists() }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            i += 1
            let trimmedRaw = raw.trimmingCharacters(in: .whitespaces)

            // ---- Fences (matched char + length) ----
            if let f = fence {
                if let info = fenceInfo(trimmedRaw), info.char == f.char,
                   info.length >= f.length, info.canClose {
                    fence = nil
                    flushCode()
                } else {
                    codeLines.append(raw)
                }
                continue
            }
            if let info = fenceInfo(trimmedRaw) {
                flushAll()
                fence = (char: info.char, length: info.length)
                codeLanguage = language(from: info.info)
                continue
            }

            // ---- HTML comments (single and multi-line) ----
            var line = raw
            if inHTMLComment {
                if let close = line.range(of: "-->") {
                    inHTMLComment = false
                    line = String(line[close.upperBound...])
                } else {
                    continue
                }
            }
            if let open = line.range(of: "<!--") {
                if let close = line.range(of: "-->", range: open.upperBound..<line.endIndex) {
                    line = String(line[..<open.lowerBound]) + String(line[close.upperBound...])
                } else {
                    inHTMLComment = true
                    line = String(line[..<open.lowerBound])
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // ---- Setext underline (paragraph directly above becomes heading) ----
            if !paragraph.isEmpty, isSetextUnderline(trimmed) {
                flushQuote(); flushLists()
                result.append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2,
                                       text: paragraph.joined(separator: "\n")))
                paragraph = []
                continue
            }

            // ---- Thematic break ----
            if isThematicBreak(trimmed) {
                flushAll()
                result.append(.divider)
                continue
            }

            // ---- Footnote definition (reads as a paragraph) / link refs (dropped) ----
            if let footnote = footnoteBody(trimmed) {
                flushAll()
                paragraph.append(footnote)
                continue
            }
            if isLinkReferenceDefinition(trimmed) {
                flushAll()
                continue
            }

            // ---- ATX heading (closing #'s stripped) ----
            if let heading = headingInfo(trimmed) {
                flushAll()
                result.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            // ---- Table: this line is the header, next line the delimiter row ----
            if trimmed.contains("|"), i < lines.count,
               isTableDelimiterRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                flushParagraph(); flushQuote(); flushLists()
                let headers = tableCells(trimmed)
                i += 1 // skip delimiter row
                var rows: [[String]] = []
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    if row.isEmpty || !row.contains("|") { break }
                    rows.append(tableCells(row))
                    i += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }

            // ---- Blockquote ----
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushLists()
                var content = trimmed
                while content.hasPrefix(">") {
                    content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                quote.append(content)
                continue
            }

            // ---- Lists ----
            let indent = leadingSpaces(raw)
            if let item = bulletItem(trimmed) {
                flushParagraph(); flushQuote()
                if !ordered.isEmpty { flushLists() }
                bullets.append(PendingItem(indent: indent, text: item.text, isTask: item.isTask, isDone: item.isDone))
                continue
            }
            if let item = orderedItem(trimmed) {
                flushParagraph(); flushQuote()
                if !bullets.isEmpty { flushLists() }
                ordered.append(PendingItem(indent: indent, text: item.text, isTask: item.isTask, isDone: item.isDone))
                continue
            }

            // ---- Lazy continuation (CommonMark): indented text extends the
            // last list item; plain text continues an open quote. ----
            if paragraph.isEmpty {
                if !bullets.isEmpty, indent > bullets[bullets.count - 1].indent {
                    bullets[bullets.count - 1].text += "\n" + trimmed
                    continue
                }
                if !ordered.isEmpty, indent > ordered[ordered.count - 1].indent {
                    ordered[ordered.count - 1].text += "\n" + trimmed
                    continue
                }
                if !quote.isEmpty {
                    quote.append(trimmed)
                    continue
                }
            }

            // ---- Paragraph ----
            flushQuote(); flushLists()
            paragraph.append(trimmed)
        }

        if fence != nil { flushCode() }
        flushAll()
        return result
    }

    // MARK: - Inline runs (preview)

    /// Splits a line into text / image / link runs, resolving reference
    /// links via `references` when provided. E.g. "See ![x](a.png) and
    /// [docs](https://d.com)" → text, image, text, link, text.
    public static func inlineRuns(_ line: String, references: [String: LinkReference] = [:]) -> [InlineRun] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let imageRx = rx(#"!\[([^\]]*)\](?:\(([^)]*)\)|\[([^\]]*)\])"#) else { return [.text(line)] }
        let matches = imageRx.matches(in: line, options: [], range: full)
        guard !matches.isEmpty else { return linkRuns(in: line, references: references) }
        return splitRuns(in: line, matches: matches, ns: ns, make: { match, ns -> [InlineRun] in
            let alt = ns.substring(with: match.range(at: 1))
            var url = ""
            if match.range(at: 2).location != NSNotFound {
                url = cleanURL(ns.substring(with: match.range(at: 2)))
            } else if match.range(at: 3).location != NSNotFound {
                let ref = ns.substring(with: match.range(at: 3))
                url = references[(ref.isEmpty ? alt : ref).lowercased()]?.url ?? ""
            }
            return url.isEmpty
                ? [.text(ns.substring(with: match.range))]
                : [.image(alt: alt, url: url)]
        }, textSegment: { linkRuns(in: $0, references: references) })
    }

    private static func linkRuns(in text: String, references: [String: LinkReference]) -> [InlineRun] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let autoRx = rx(#"<((?:https?://|mailto:)[^>\s]+)>"#) {
            let autos = autoRx.matches(in: text, options: [], range: full)
            if !autos.isEmpty {
                return splitRuns(in: text, matches: autos, ns: ns, make: { match, ns -> [InlineRun] in
                    let url = ns.substring(with: match.range(at: 1))
                    return [.link(label: url, url: url)]
                }, textSegment: { bracketLinkRuns($0, references) })
            }
        }
        return bracketLinkRuns(text, references)
    }

    private static func bracketLinkRuns(_ text: String, _ references: [String: LinkReference]) -> [InlineRun] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let bracketRx = rx(#"\[([^\]]+)\](?:\(([^)]*)\)|\[([^\]]*)\])"#) else { return [.text(text)] }
        let matches = bracketRx.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return [.text(text)] }
        return splitRuns(in: text, matches: matches, ns: ns) { match, ns -> [InlineRun] in
            let label = ns.substring(with: match.range(at: 1))
            var url = ""
            if match.range(at: 2).location != NSNotFound {
                url = cleanURL(ns.substring(with: match.range(at: 2)))
            } else if match.range(at: 3).location != NSNotFound {
                let ref = ns.substring(with: match.range(at: 3))
                url = references[(ref.isEmpty ? label : ref).lowercased()]?.url ?? ""
            }
            return url.isEmpty
                ? [.text(ns.substring(with: match.range))]
                : [.link(label: label, url: url)]
        }
    }

    /// Shared splitter: emits `textSegment(...)` between matches, `make(...)`
    /// for each match (in order).
    private static func splitRuns(
        in text: String,
        matches: [NSTextCheckingResult],
        ns: NSString,
        make: (NSTextCheckingResult, NSString) -> [InlineRun],
        textSegment: (String) -> [InlineRun] = { [.text($0)] }
    ) -> [InlineRun] {
        var runs: [InlineRun] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !before.isEmpty { runs.append(contentsOf: textSegment(before)) }
            }
            if match.range.length > 0 {
                runs.append(contentsOf: make(match, ns))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty { runs.append(contentsOf: textSegment(tail)) }
        }
        return runs
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

    /// Paragraph that is JUST an image token → (alt, url).
    private static func standaloneImage(_ joined: String, references: [String: LinkReference]) -> (alt: String, url: String)? {
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        let runs = inlineRuns(trimmed, references: references)
        guard runs.count == 1, case .image(let alt, let url) = runs[0] else { return nil }
        return (alt, url)
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

    // MARK: - Line-level helpers

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

    private static func language(from info: String) -> String? {
        let trimmed = info.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.components(separatedBy: " ").first
    }

    private static func headingInfo(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var rest = Substring(line)
        var marks = 0
        while rest.first == "#" {
            rest = rest.dropFirst()
            marks += 1
        }
        guard (1...6).contains(marks), rest.first == " " || rest.first == "\t" else { return nil }
        var text = String(rest).trimmingCharacters(in: .whitespaces)
        // ATX closing sequence: "# Heading #" → "Heading".
        if let closing = rx(#"[ \t]+#+[ \t]*$"#),
           let m = closing.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            text = (text as NSString).substring(with: NSRange(location: 0, length: m.range.location))
                .trimmingCharacters(in: .whitespaces)
        }
        return (marks, text)
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        guard let first = line.first, first == "=" || first == "-" else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let characters = Array(line)
        let first = characters[0]
        guard first == "-" || first == "*" || first == "_" else { return false }
        var runs = 0
        for character in characters {
            if character == first { runs += 1 }
            else if character != " " && character != "\t" { return false }
        }
        return runs >= 3
    }

    private static func footnoteBody(_ line: String) -> String? {
        guard let rx = rx(#"^\[\^[^\]]+\]:[ \t]*(.*)$"#),
              let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        return (line as NSString).substring(with: m.range(at: 1))
    }

    private static func isLinkReferenceDefinition(_ line: String) -> Bool {
        guard let rx = rx(#"^\[[^\]^][^\]]*\]:"#
        ) else { return false }
        return rx.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Delimiter row: cells of `---`/`:--`/`--:`/`:-:`, at least one pipe.
    private static func isTableDelimiterRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func taskMarker(_ text: String) -> (isTask: Bool, isDone: Bool, remainder: String) {
        let chars = Array(text)
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return (false, false, text) }
        let mark = chars[1]
        if mark == " " { return (true, false, String(chars[3...]).trimmingCharacters(in: .whitespaces)) }
        if mark == "x" || mark == "X" { return (true, true, String(chars[3...]).trimmingCharacters(in: .whitespaces)) }
        return (false, false, text)
    }

    private static func bulletItem(_ line: String) -> (text: String, isTask: Bool, isDone: Bool)? {
        guard let first = line.first, first == "-" || first == "*" || first == "+" else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let text = String(rest).trimmingCharacters(in: .whitespaces)
        let task = taskMarker(text)
        return (task.remainder, task.isTask, task.isDone)
    }

    private static func orderedItem(_ line: String) -> (text: String, isTask: Bool, isDone: Bool)? {
        guard let rx = rx(#"^\d{1,9}[.)][ \t]+"#),
              let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        let text = (line as NSString).substring(from: m.range.length)
            .trimmingCharacters(in: .whitespaces)
        let task = taskMarker(text)
        return (task.remainder, task.isTask, task.isDone)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }
}
