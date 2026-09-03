import Foundation

/// Slash-command autocomplete for the markdown editor.
///
/// Typing `/` at the start of a line — or after a list/quote prefix like
/// `- `, `> `, `1. `, `- [x] ` — opens the menu. Fuzzy matching means `tbl`
/// finds "Table" and `chk` finds "Todo". Wrap commands bold/italicize the
/// current selection when one exists.
public enum MarkdownSlashMenu {

    public struct Command: Identifiable, Hashable {
        public enum Kind: Hashable {
            case insert
            /// Wrap the selection (or a placeholder) as `before…after`.
            case wrap(before: String, after: String)
        }

        public let id: String
        public let label: String
        public let symbol: String
        public let snippet: String
        public let placeholder: String?
        public let keywords: [String]
        public let kind: Kind

        public init(
            id: String, label: String, symbol: String,
            snippet: String, placeholder: String? = nil,
            keywords: [String] = [], kind: Kind = .insert
        ) {
            self.id = id
            self.label = label
            self.symbol = symbol
            self.snippet = snippet
            self.placeholder = placeholder
            self.keywords = keywords
            self.kind = kind
        }
    }

    public static let commands: [Command] = [
        .init(id: "h1",       label: "Heading 1",     symbol: "h.square",   snippet: "# ", placeholder: "Heading", keywords: ["title", "header"]),
        .init(id: "h2",       label: "Heading 2",     symbol: "h.square.fill", snippet: "## ", placeholder: "Heading"),
        .init(id: "h3",       label: "Heading 3",     symbol: "textformat.size.larger", snippet: "### ", placeholder: "Heading"),
        .init(id: "h4",       label: "Heading 4",     symbol: "textformat.size.smaller", snippet: "#### ", placeholder: "Heading"),
        .init(id: "bullet",   label: "Bullet list",   symbol: "list.bullet", snippet: "- ", placeholder: "item", keywords: ["unordered", "ul"]),
        .init(id: "numbered", label: "Numbered list", symbol: "list.number", snippet: "1. ", placeholder: "item", keywords: ["ordered", "ol"]),
        .init(id: "todo",     label: "Todo list",     symbol: "checklist",  snippet: "- [ ] ", placeholder: "task", keywords: ["task", "checkbox", "check", "unchecked"]),
        .init(id: "checked",  label: "Completed task", symbol: "checkmark.square", snippet: "- [x] ", placeholder: "task", keywords: ["done", "task", "checkbox", "finished"]),
        .init(id: "quote",    label: "Quote",         symbol: "text.quote", snippet: "> ", placeholder: "quote", keywords: ["blockquote", "cite"]),
        .init(id: "code",     label: "Code block",    symbol: "curlybraces", snippet: "```\n", placeholder: "code\n```", keywords: ["fence", "snippet"]),
        .init(id: "codeinline", label: "Inline code", symbol: "chevron.left.forwardslash.chevron.right", snippet: "`code`", placeholder: "code", kind: .wrap(before: "`", after: "`")),
        .init(id: "divider",  label: "Divider",       symbol: "minus",      snippet: "\n---\n", keywords: ["hr", "rule", "separator", "line"]),
        .init(id: "table",    label: "Table",         symbol: "tablecells", snippet: "| |\n| --- |\n| |", keywords: ["grid", "columns", "cols"]),
        .init(id: "link",     label: "Link",          symbol: "link",       snippet: "[", placeholder: "label](https://)", keywords: ["url", "href"]),
        .init(id: "image",    label: "Image",         symbol: "photo",      snippet: "![", placeholder: "alt](https://)", keywords: ["picture", "pic", "img", "embed"]),
        .init(id: "bold",     label: "Bold",          symbol: "bold",       snippet: "**bold**", placeholder: "bold", keywords: ["strong"], kind: .wrap(before: "**", after: "**")),
        .init(id: "italic",   label: "Italic",        symbol: "italic",     snippet: "*italic*", placeholder: "italic", keywords: ["emphasis"], kind: .wrap(before: "*", after: "*")),
        .init(id: "strike",   label: "Strikethrough", symbol: "strikethrough", snippet: "~~strike~~", placeholder: "strike", keywords: ["cross", "delete"], kind: .wrap(before: "~~", after: "~~")),
    ]

    public struct Trigger {
        public let slashIndex: String.Index
        public let cursorIndex: String.Index
        public let isValid: Bool
    }

    /// `/` that opened a command: the LAST `/` between line start and the
    /// caret, so the menu stays open while a filter (`/tbl`) is typed after
    /// it. Returns nil for mid-word slashes like `path/to/file` and for
    /// slashes outside a command context.
    public static func detect(in draft: String, caretOffset: Int) -> Trigger? {
        let utf16 = draft.utf16
        guard caretOffset > 0, caretOffset <= utf16.count else { return nil }
        let cursorUtf16 = utf16.index(utf16.startIndex, offsetBy: caretOffset)
        guard let cursor = String.Index(cursorUtf16, within: draft) else { return nil }
        let lineStart = draft.rangeOfCharacter(
            from: .newlines, options: .backwards,
            range: draft.startIndex..<cursor
        )?.upperBound ?? draft.startIndex
        guard let slash = draft[lineStart..<cursor].lastIndex(of: "/") else { return nil }
        let between = draft[lineStart..<slash]
        guard isCommandContext(between) else { return nil }
        return Trigger(slashIndex: slash, cursorIndex: cursor, isValid: true)
    }

    /// Valid when only whitespace, earlier slashes, or block prefixes
    /// (`>`, `- `, `1. `, `[x] `) sit between line start and the `/`.
    private static func isCommandContext(_ text: Substring) -> Bool {
        var rest = String(text)
        for _ in 0..<4 {
            while let first = rest.first, first == " " || first == "\t" || first == "/" {
                rest.removeFirst()
            }
            if rest.isEmpty { return true }
            if rest.hasPrefix(">") { rest.removeFirst(); continue }
            if let m = rest.range(of: #"^[-+*][ \t]+"#, options: .regularExpression) {
                rest.removeSubrange(m); continue
            }
            if let m = rest.range(of: #"^\d{1,9}[.)][ \t]+"#, options: .regularExpression) {
                rest.removeSubrange(m); continue
            }
            if let m = rest.range(of: #"^\[[xX ]\][ \t]*"#, options: .regularExpression) {
                rest.removeSubrange(m); continue
            }
            return false
        }
        return rest.isEmpty
    }

    /// Fuzzy filter: prefix > substring > subsequence, with keyword aliases.
    public static func filter(prefix: String) -> [Command] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return commands }
        var scored: [(Command, Int)] = []
        for command in commands {
            let candidates = ([command.id, command.label] + command.keywords).map { $0.lowercased() }
            let best = candidates.reduce(0) { max($0, fuzzyScore(needle: needle, in: $1)) }
            if best > 0 { scored.append((command, best)) }
        }
        return scored
            .sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
            .map(\.0)
    }

    private static func fuzzyScore(needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        if haystack.hasPrefix(needle) { return 100 }
        if haystack.contains(needle) { return 80 }
        var index = haystack.startIndex
        var matched = 0
        var consecutive = 0
        var score = 0
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return 0 }
            consecutive = found == index ? consecutive + 1 : 1
            score += 10 + consecutive * 2
            index = haystack.index(after: found)
            matched += 1
        }
        score -= max(haystack.count - matched, 0)
        return max(score, 1)
    }

    /// Back-compatible entry point (matches the original behavior).
    public static func apply(_ command: Command, in draft: String, trigger: Trigger) -> (draft: String, caretUtf16: Int) {
        let result = apply(command, in: draft, trigger: trigger, caret: nil)
        return (result.draft, result.caretUtf16)
    }

    /// Full version: deletes `/` plus any typed prefix, and wraps the
    /// selection for wrap-style commands. `caret` is the CURRENT caret
    /// (utf-16) so the typed filter text is removed too.
    public static func apply(
        _ command: Command,
        in draft: String,
        trigger: Trigger,
        caret: Int?,
        selection: Range<Int>? = nil
    ) -> (draft: String, caretUtf16: Int, selectionUtf16: Range<Int>?) {
        var updated = draft
        let total = draft.utf16.count
        let slashStart = draft.utf16.distance(from: draft.startIndex, to: trigger.slashIndex)
        let slashEnd = draft.utf16.distance(from: draft.startIndex, to: trigger.cursorIndex)
        let deleteEnd = min(max(caret ?? slashEnd, slashEnd), total)
        let deleted = deleteEnd - slashStart

        guard let slashIndex = updated.index(utf16Offset: slashStart),
              let deleteIndex = updated.index(utf16Offset: deleteEnd),
              slashIndex <= deleteIndex else {
            return (draft, caret ?? slashEnd, nil)
        }
        updated.removeSubrange(slashIndex..<deleteIndex)

        switch command.kind {
        case .wrap(let before, let after):
            // Wrap an existing selection when it sits after the slash.
            if let selection,
               selection.lowerBound >= deleteEnd, selection.upperBound <= total,
               selection.lowerBound <= selection.upperBound {
                let start = selection.lowerBound - deleted
                let end = selection.upperBound - deleted
                // Insert the trailing marker first (later position) so the
                // leading insertion doesn't shift it.
                if let close = updated.index(utf16Offset: end) {
                    updated.insert(contentsOf: after, at: close)
                }
                if let open = updated.index(utf16Offset: start) {
                    updated.insert(contentsOf: before, at: open)
                }
                let innerStart = start + before.utf16.count
                let innerEnd = end + before.utf16.count
                return (updated, innerEnd, innerStart..<max(innerStart, innerEnd))
            }
            // No selection: before + placeholder + after, placeholder selected.
            let inner = command.placeholder ?? ""
            updated.insert(contentsOf: before + inner + after, at: slashIndex)
            let innerStart = slashStart + before.utf16.count
            return (updated, innerStart + inner.utf16.count, innerStart..<innerStart + inner.utf16.count)

        case .insert:
            let snippet = command.snippet
            updated.insert(contentsOf: snippet, at: slashIndex)
            var caretUtf16 = slashStart + snippet.utf16.count
            if let placeholder = command.placeholder {
                let marker: String? =
                    placeholder.contains("](") ? "]("
                    : (placeholder.contains("]") ? "]" : nil)
                if let marker,
                   let markerRange = updated.range(of: marker, range: slashIndex..<updated.endIndex) {
                    caretUtf16 = updated.utf16.distance(from: updated.startIndex, to: markerRange.lowerBound)
                }
            }
            return (updated, caretUtf16, nil)
        }
    }
}

extension String {
    /// UTF-16 offset → index; nil when out of bounds or mid-surrogate-pair.
    fileprivate func index(utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0, utf16Offset <= utf16.count else { return nil }
        let i = utf16.index(utf16.startIndex, offsetBy: utf16Offset)
        return String.Index(i, within: self)
    }
}
