import Foundation

/// Slash-command autocomplete for the markdown editor.
///
/// Typing `/` at the start of a line opens a menu of markdown snippets.
/// Picking one expands the slash-prefix to the snippet and replaces the
/// selection with the result. Commands map to the same operations the
/// formatting bar exposes — slash is just keyboard-equivalent of the bar.
///
/// Detection: only trigger on a `/` immediately preceded by a newline (or
/// at the start of the draft). Inline `/` inside words (e.g. `path/to/file`)
/// never opens the menu.
public enum MarkdownSlashMenu {

    public struct Command: Identifiable, Hashable {
        public let id: String
        public let label: String
        public let symbol: String
        public let snippet: String
        public let placeholder: String?

        public init(id: String, label: String, symbol: String, snippet: String, placeholder: String? = nil) {
            self.id = id
            self.label = label
            self.symbol = symbol
            self.snippet = snippet
            self.placeholder = placeholder
        }
    }

    public static let commands: [Command] = [
        .init(id: "h1",       label: "Heading 1",         symbol: "h.square",           snippet: "# ",                placeholder: "Heading"),
        .init(id: "h2",       label: "Heading 2",         symbol: "h.square.fill",      snippet: "## ",               placeholder: "Heading"),
        .init(id: "h3",       label: "Heading 3",         symbol: "h.square.filled",    snippet: "### ",              placeholder: "Heading"),
        .init(id: "bullet",   label: "Bullet list",       symbol: "list.bullet",        snippet: "- ",                placeholder: "item"),
        .init(id: "numbered", label: "Numbered list",     symbol: "list.number",        snippet: "1. ",               placeholder: "item"),
        .init(id: "todo",     label: "Todo list",         symbol: "checklist",          snippet: "- [ ] ",             placeholder: "task"),
        .init(id: "quote",    label: "Quote",             symbol: "text.quote",         snippet: "> ",                placeholder: "quote"),
        .init(id: "code",     label: "Code block",        symbol: "curlybraces",        snippet: "```\n",             placeholder: "code\n```"),
        .init(id: "divider",  label: "Divider",           symbol: "minus",              snippet: "\n---\n",           placeholder: nil),
        .init(id: "link",     label: "Link",              symbol: "link",               snippet: "[",                 placeholder: "label](https://)"),
        .init(id: "image",    label: "Image",             symbol: "photo",              snippet: "![",                placeholder: "alt](https://)"),
        .init(id: "bold",     label: "Bold",              symbol: "bold",               snippet: "**",                placeholder: "bold**"),
        .init(id: "italic",   label: "Italic",            symbol: "italic",             snippet: "*",                 placeholder: "italic*"),
    ]

    /// Where in `draft` the `/` token starts, plus the prefix that
    /// triggered it (so the caller knows what to delete on dismissal).
    public struct Trigger {
        /// Index of the `/` in `draft`.
        public let slashIndex: String.Index
        /// Index immediately AFTER the `/` — what the user has typed.
        public let cursorIndex: String.Index
        /// Whether the trigger condition was met (start of draft or after
        /// newline). Filters out inline `/` like `path/to/file`.
        public let isValid: Bool
    }

    /// Detect whether the current caret position follows a `/` at the start
    /// of a line.
    public static func detect(in draft: String, caretOffset: Int) -> Trigger? {
        let utf16 = draft.utf16
        guard caretOffset > 0, caretOffset <= utf16.count else { return nil }
        // Convert caret offset back to a String.Index.
        let cursorUtf16 = utf16.index(utf16.startIndex, offsetBy: caretOffset)
        guard let cursor = String.Index(cursorUtf16, within: draft) else { return nil }
        let prev = draft.index(before: cursor)
        guard draft[prev] == "/" else { return nil }
        // Find the start of the line containing the `/`.
        let lineStart = draft.rangeOfCharacter(
            from: .newlines, options: .backwards,
            range: draft.startIndex..<prev
        )?.upperBound ?? draft.startIndex
        let triggerIndex = lineStart == prev ? prev : prev
        let isValid = lineStart == prev  // `/` is the first char on the line
        return Trigger(slashIndex: triggerIndex, cursorIndex: cursor, isValid: isValid)
    }

    /// Filter the commands by the prefix the user has typed after `/`.
    public static func filter(prefix: String) -> [Command] {
        guard !prefix.isEmpty else { return commands }
        let needle = prefix.lowercased()
        return commands.filter {
            $0.id.lowercased().hasPrefix(needle) || $0.label.lowercased().contains(needle)
        }
    }

    /// Apply `command` to `draft` at `trigger`:
    ///   1. delete the `/<typed-prefix>` range
    ///   2. insert the snippet
    ///   3. place the caret just before the placeholder marker (if any)
    ///
    /// Returns the updated draft and the new caret offset (utf-16). The
    /// caller is responsible for committing both to its state.
    public static func apply(_ command: Command, in draft: String, trigger: Trigger) -> (draft: String, caretUtf16: Int) {
        var updated = draft
        updated.removeSubrange(trigger.slashIndex..<trigger.cursorIndex)
        let insertAt = trigger.slashIndex
        let snippet = command.snippet
        updated.insert(contentsOf: snippet, at: insertAt)

        // Place caret immediately after the snippet, then walk back to the
        // end of `placeholder` so the user lands inside it.
        let insertEndUtf16 = updated.utf16.distance(from: updated.startIndex, to: insertAt) + snippet.utf16.count
        var caretUtf16 = insertEndUtf16
        if let placeholder = command.placeholder {
            // Place caret at the start of the placeholder marker.
            if let range = placeholder.range(of: "](") ?? placeholder.range(of: "]"),
               let placeholderStart = updated.range(of: placeholder, range: insertAt..<updated.endIndex) {
                caretUtf16 = updated.utf16.distance(from: updated.startIndex, to: placeholderStart.lowerBound)
            }
        }
        return (updated, caretUtf16)
    }
}
