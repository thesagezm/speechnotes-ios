import SwiftUI

/// Selection-aware formatting bar pinned above the keyboard while editing a
/// markdown note. Buttons mutate `draft` and the selection range around the
/// caret. Layouts reflect what real users want at the touch of a button:
/// bold / italic / strikethrough, H1-H2, bullet / ordered list, blockquote,
/// code (inline + fenced), divider, link, image. The bar is hidden when the
/// preview is showing (preview has its own touch targets).
///
/// `selection` is the *live* SwiftUI selection binding from `TextEditor` —
/// every action reads it, mutates `draft`, and writes the post-edit range
/// back so the caret lands sensibly.
struct MarkdownFormattingBar: View {
    @Binding var draft: String
    @Binding var selection: Range<String.Index>?
    /// Inserter for picking an image from the photo library / paste board /
    /// by URL — routes through NoteImageStore so the markdown contains a
    /// `speechnotes://` target instead of base64.
    let insertImage: () -> Void
    /// Inserter for a link — the editor passes the chosen label + URL in.
    let insertLink: (String, String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                group {
                    button(symbol: "bold") { wrap(prefix: "**", suffix: "**", placeholder: "bold") }
                    button(symbol: "italic") { wrap(prefix: "*", suffix: "*", placeholder: "italic") }
                    button(symbol: "strikethrough") { wrap(prefix: "~~", suffix: "~~", placeholder: "strike") }
                }
                divider
                group {
                    button(symbol: "h1") { applyHeading(level: 1) }
                    button(symbol: "h2") { applyHeading(level: 2) }
                }
                divider
                group {
                    button(symbol: "list.bullet") { applyList(marker: "- ") }
                    button(symbol: "list.number") { applyList(marker: "1. ") }
                    button(symbol: "text.quote") { applyBlockquote() }
                }
                divider
                group {
                    button(symbol: "chevron.left.forwardslash.chevron.right") { applyInlineCode() }
                    button(symbol: "curlybraces") { applyFencedCode() }
                    button(symbol: "minus") { applyDivider() }
                }
                divider
                group {
                    button(symbol: "link") { linkFlow() }
                    button(symbol: "photo") { insertImage() }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
    }

    private var divider: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }

    private func button(symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Range editing helpers

    /// Current selection, clamped to the draft's bounds. Returns nil when
    /// the editor hasn't reported a range yet.
    private var currentRange: Range<String.Index>? {
        guard let r = selection, r.lowerBound >= draft.startIndex,
              r.upperBound <= draft.endIndex else { return nil }
        return r
    }

    /// Replace `range` with `replacement` and place the caret at the end of
    /// the inserted text.
    fileprivate func mutate(_ range: Range<String.Index>, with replacement: String) {
        var updated = draft
        updated.replaceSubrange(range, with: replacement)
        let insertEndUtf16 = updated.utf16.distance(from: updated.startIndex, to: range.lowerBound) + replacement.utf16.count
        draft = updated
        if let idx = updated.utf16.index(updated.utf16.startIndex, offsetBy: insertEndUtf16, limitedBy: updated.utf16.endIndex).flatMap({ String.Index($0, within: updated) }) {
            selection = idx..<idx
        }
    }

    /// Wrap the current selection (or insert a placeholder when there's
    /// none) with prefix/suffix markers.
    fileprivate func wrap(prefix: String, suffix: String, placeholder: String) {
        guard let range = currentRange
                ?? Range(NSRange(location: draft.utf16.count, length: 0), in: draft)
        else { return }
        let ns = NSString(string: draft)
        let selected = ns.substring(with: NSRange(range, in: draft))
        let body = selected.isEmpty ? placeholder : selected
        mutate(range, with: "\(prefix)\(body)\(suffix)")
    }

    fileprivate func applyHeading(level: Int) {
        guard let range = currentRange
                ?? Range(NSRange(location: draft.utf16.count, length: 0), in: draft)
        else { return }
        let lineStart = draft.rangeOfCharacter(
            from: .newlines, options: .backwards,
            range: draft.startIndex..<range.lowerBound
        )?.upperBound ?? draft.startIndex
        let marker = String(repeating: "#", count: level) + " "
        mutate(lineStart..<lineStart, with: marker)
    }

    fileprivate func applyList(marker: String) {
        if let range = currentRange {
            let ns = draft as NSString
            let selected = ns.substring(with: NSRange(range, in: draft))
            let lines = selected.components(separatedBy: "\n")
            let allPrefixed = lines.allSatisfy { $0.hasPrefix(marker) }
            let mutated = lines.map { line -> String in
                if allPrefixed { return String(line.dropFirst(marker.count)) }
                return marker + line
            }.joined(separator: "\n")
            mutate(range, with: mutated)
        } else if let r = Range(NSRange(location: draft.utf16.count, length: 0), in: draft) {
            toggleMarkerOnLine(r.lowerBound, marker: marker)
        }
    }

    fileprivate func toggleMarkerOnLine(_ idx: String.Index, marker: String) {
        let lineStart = draft.rangeOfCharacter(
            from: .newlines, options: .backwards,
            range: draft.startIndex..<idx
        )?.upperBound ?? draft.startIndex
        let lineEnd: String.Index = draft.rangeOfCharacter(
            from: .newlines, options: [],
            range: idx..<draft.endIndex
        ) ?? draft.endIndex
        let line = String(draft[lineStart..<lineEnd])
        let replacement = line.hasPrefix(marker)
            ? String(line.dropFirst(marker.count))
            : marker + line
        mutate(lineStart..<lineEnd, with: replacement)
    }

    fileprivate func applyBlockquote() { applyList(marker: "> ") }
    fileprivate func applyInlineCode() { wrap(prefix: "`", suffix: "`", placeholder: "code") }
    fileprivate func applyFencedCode() {
        guard let range = currentRange
                ?? Range(NSRange(location: draft.utf16.count, length: 0), in: draft)
        else { return }
        let ns = NSString(string: draft)
        let selected = ns.substring(with: NSRange(range, in: draft))
        let body = selected.isEmpty ? "code" : selected
        mutate(range, with: "\n```\n\(body)\n```\n")
    }
    fileprivate func applyDivider() {
        guard let range = currentRange else { return }
        mutate(range, with: "\n---\n")
    }
    fileprivate func linkFlow() {
        if let range = currentRange {
            let ns = NSString(string: draft)
            let selected = ns.substring(with: NSRange(range, in: draft))
            insertLink(selected.isEmpty ? "label" : selected, "")
        } else {
            insertLink("label", "")
        }
    }
}
