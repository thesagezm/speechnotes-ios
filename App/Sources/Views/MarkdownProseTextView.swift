import SwiftUI
import UIKit
import SpeechLogic

/// The preview's PROSE, rendered through native text views.
///
/// Why: SwiftUI's `.textSelection(.enabled)` gives the reader Copy and
/// nothing else — there is NO hook for adding "Read from here" to the
/// selection menu (the preview has no menu-customisation API at all). A
/// UITextView has one: the iOS 16+ edit-menu delegate, the same hook the
/// editor uses. So the prose of a rendered note is drawn by UITextView, and
/// the reader gets Copy, Look Up, Translate AND "Read from here" in one
/// native menu.
///
/// The content is IDENTICAL by construction: the blocks come from the same
/// `MarkdownText` AST the SwiftUI preview renders, and the spans carry the
/// same flags (bold / italic / code / strike / link / maths), so the
/// emphasis on screen is the emphasis the AST resolved — never a second
/// regex pass over the markdown.
///
/// What stays on the SwiftUI path (and why):
///  * block quotes — their vertical rule is drawn by the SwiftUI layout,
///    and a text view has no paragraph border;
///  * code blocks, tables, images, dividers and display maths — they are
///    not prose, and UITextView cannot lay them out;
///  * a paragraph or list item that carries an INLINE image — the picture
///    is a SwiftUI view, so the whole block stays there.
///
/// Those surfaces keep Copy (the UIMenuController fix in MarkdownEditorView
/// is what restored it) but do not offer "Read from here".
struct MarkdownProseTextView: UIViewRepresentable {

    /// The prose blocks, in reading order. One group = one text view.
    let blocks: [MarkdownText.MarkdownBlock]
    /// The note's SPEECH text — what the engine will read. "Read from here"
    /// maps the selection onto it (see `SelectionOffsetMapper`).
    let speechText: String
    /// The reading-view metrics (fonts, spacing, colours) — the same
    /// numbers the SwiftUI preview uses, so the two agree.
    let style: MarkdownProseStyle
    /// The accent colour, resolved from the environment (links, maths and
    /// task checkboxes).
    let accent: UIColor
    /// The reader picked "Read from here" — the argument is a UTF-16 offset
    /// into `speechText`.
    var onReadFromHere: ((Int) -> Void)? = nil
    /// A link in the prose was tapped.
    var onOpenURL: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        // The preview's own padding (the VStack's 16pt) is the gutter; a
        // text view adds its own by default, which would double it.
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        // The container must NOT follow the view's own width: SwiftUI asks
        // for the height BEFORE the view has its final frame, so a
        // container that tracks the view would be measured at the PREVIOUS
        // width (or zero) and the last line would be clipped. The width is
        // set explicitly in `sizeThatFits` instead — the proposal SwiftUI
        // hands over IS the width the view will get.
        tv.textContainer.widthTracksTextView = false
        tv.adjustsFontForContentSizeCategory = false
        tv.dataDetectorTypes = []
        let document = Self.buildDocument(blocks: blocks, style: style, accent: accent)
        context.coordinator.document = document
        context.coordinator.lastBlocks = blocks
        context.coordinator.lastStyle = style
        context.coordinator.lastAccent = accent
        tv.attributedText = document.attributed
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // The coordinator holds the CURRENT view: the edit-menu hook asks it
        // whether playback may start, and that answer depends on live state
        // (the speech text, the callbacks) the coordinator cannot see.
        context.coordinator.parent = self
        // Rebuild only when the CONTENT, the metrics or the accent changed —
        // the body re-renders on every theme tick, and rebuilding the
        // attributed string each time is wasted work.
        if context.coordinator.lastBlocks != blocks
            || context.coordinator.lastStyle != style
            || context.coordinator.lastAccent != accent {
            let document = Self.buildDocument(blocks: blocks, style: style, accent: accent)
            context.coordinator.document = document
            context.coordinator.lastBlocks = blocks
            context.coordinator.lastStyle = style
            context.coordinator.lastAccent = accent
            uiView.attributedText = document.attributed
        }
    }

    /// The text view reports its own height — SwiftUI asks, the layout
    /// manager answers. The text container is sized explicitly first: the
    /// view's own width is still the PREVIOUS one when SwiftUI asks, and a
    /// height measured for the wrong line length clips the last line.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let container = uiView.textContainer
        // Measure with an unbounded height: the container's height would
        // otherwise clip the layout and the last line would be missing from
        // the measurement.
        container.size = CGSize(width: width, height: 100_000)
        let used = uiView.layoutManager.usedRect(for: container)
        // One point of slack: the layout manager's used rect and the view's
        // own line breaking can disagree by a fraction of a point, and a
        // clipped descender is visible.
        let height = max(ceil(used.height) + 1, 1)
        // Then shrink the container back to the text's own height: a text
        // view whose container is 100,000 points tall reports a 100,000
        // point content size, and that leaks into the selection and the
        // scroll geometry.
        container.size = CGSize(width: width, height: height)
        return CGSize(width: width, height: height)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownProseTextView
        var document = ProseDocument.empty
        var lastBlocks: [MarkdownText.MarkdownBlock] = []
        var lastStyle: MarkdownProseStyle = MarkdownProseStyle()
        /// The accent the current document was built with — the theme can
        /// change it under the preview, and the links/maths are tinted.
        var lastAccent: UIColor = .label

        init(_ parent: MarkdownProseTextView) { self.parent = parent }

        /// "Read from here" rides the SAME native edit menu as Copy — the
        /// item is APPENDED to the system's suggested actions, never
        /// replacing them.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let onRead = parent.onReadFromHere,
                  let offset = speechOffset(forUTF16: range.location) else {
                return UIMenu(title: "", children: suggestedActions)
            }
            let action = UIAction(
                title: String(localized: "Read from here"),
                image: UIImage(systemName: "play.circle")
            ) { _ in
                onRead(offset)
            }
            return UIMenu(title: "", children: suggestedActions + [action])
        }

        /// A link in the prose was tapped — the preview opens it in its own
        /// Safari sheet, exactly like the SwiftUI-rendered links.
        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            if interaction == .invokeDefaultAction {
                parent.onOpenURL?(url)
                return false
            }
            return true
        }

        /// The selection's offset in the SPEECH text: the block it sits in
        /// is located in the speech text, and the offset inside the block
        /// is added to it.
        private func speechOffset(forUTF16 offset: Int) -> Int? {
            guard let entry = document.block(atUTF16: offset) else { return nil }
            let intra = offset - entry.range.location
            return SelectionOffsetMapper.speechOffset(
                blockText: entry.spoken,
                blockOffset: max(0, min(intra, entry.spoken.utf16.count)),
                speechText: parent.speechText
            )
        }
    }

    // MARK: - Building the document

    /// The built prose: the attributed string plus the map from the
    /// rendered characters back to the blocks they came from.
    struct ProseDocument {
        let attributed: NSAttributedString
        /// One entry per rendered block: the range it occupies and the text
        /// the ENGINE reads for it (maths as words, not glyphs).
        let blocks: [(range: NSRange, spoken: String)]

        static let empty = ProseDocument(attributed: NSAttributedString(), blocks: [])

        /// The block a UTF-16 offset falls in. An offset at the very end of
        /// the last block belongs to that block (the caret sits after its
        /// last character).
        func block(atUTF16 offset: Int) -> (range: NSRange, spoken: String)? {
            for entry in blocks {
                if NSLocationInRange(offset, entry.range) { return entry }
            }
            if let last = blocks.last,
               offset == last.range.location + last.range.length {
                return last
            }
            return nil
        }
    }

    /// One rendered paragraph: its marker (a list bullet, a task box), the
    /// spans, the base font, the colour and the paragraph style.
    private struct Paragraph {
        var prefix: String = ""
        var prefixColor: UIColor = .secondaryLabel
        var spans: [MarkdownText.StyledSpan] = []
        var font: UIFont
        var color: UIColor = .label
        var style: NSMutableParagraphStyle
    }

    static func buildDocument(
        blocks: [MarkdownText.MarkdownBlock],
        style: MarkdownProseStyle,
        accent: UIColor
    ) -> ProseDocument {
        let result = NSMutableAttributedString()
        var entries: [(range: NSRange, spoken: String)] = []
        for block in blocks {
            for paragraph in paragraphs(for: block, style: style, accent: accent) {
                let start = result.length
                // The marker rides the paragraph's own style, so the hanging
                // indent and the tab stop apply to it too.
                if !paragraph.prefix.isEmpty {
                    result.append(NSAttributedString(
                        string: paragraph.prefix,
                        attributes: [
                            .font: paragraph.font,
                            .foregroundColor: paragraph.prefixColor,
                            .paragraphStyle: paragraph.style
                        ]
                    ))
                }
                appendSpans(
                    paragraph.spans,
                    to: result,
                    baseFont: paragraph.font,
                    color: paragraph.color,
                    accent: accent
                )
                let range = NSRange(location: start, length: result.length - start)
                entries.append((range: range, spoken: spokenText(for: paragraph)))
            }
        }
        return ProseDocument(attributed: result, blocks: entries)
    }

    /// The paragraphs of one block. A list contributes one paragraph per
    /// item; every other block contributes one.
    private static func paragraphs(
        for block: MarkdownText.MarkdownBlock,
        style: MarkdownProseStyle,
        accent: UIColor
    ) -> [Paragraph] {
        let bodyFont = UIFont.systemFont(ofSize: style.bodyFontSize)
        switch block {
        case .heading(let level, _, let spans):
            var paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacingBefore = level <= 2 ? style.headingTopLevel1 : style.headingTopLevel3Plus
            paragraphStyle.paragraphSpacing = style.headingBottom
            return [Paragraph(
                spans: spans,
                font: headingFont(level: level, style: style),
                style: paragraphStyle
            )]
        case .paragraph(_, let spans):
            var paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = style.blockGap
            paragraphStyle.lineSpacing = style.lineSpacing
            return [Paragraph(spans: spans, font: bodyFont, style: paragraphStyle)]
        case .bulletList(let items):
            return listParagraphs(
                items: items,
                markers: items.indices.map { _ in "•\t" },
                style: style,
                accent: accent
            )
        case .orderedList(let items):
            return listParagraphs(
                items: items,
                markers: items.indices.map { "\($0 + 1).\t" },
                style: style,
                accent: accent
            )
        default:
            return []
        }
    }

    /// One paragraph per list item. The marker hangs in the margin: the
    /// first line starts at the item's indent, the wrapped lines at the
    /// marker's column — the SwiftUI list's exact shape.
    private static func listParagraphs(
        items: [MarkdownText.ListItem],
        markers: [String],
        style: MarkdownProseStyle,
        accent: UIColor
    ) -> [Paragraph] {
        let bodyFont = UIFont.systemFont(ofSize: style.bodyFontSize)
        return items.enumerated().map { index, item in
            var paragraphStyle = NSMutableParagraphStyle()
            let indent = CGFloat(item.level) * 16
            paragraphStyle.firstLineHeadIndent = indent
            paragraphStyle.headIndent = indent + 20
            paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
            paragraphStyle.lineSpacing = style.lineSpacing
            // Between rows the list's own gap; after the LAST row the
            // block gap the SwiftUI list carries as its bottom padding.
            paragraphStyle.paragraphSpacing = index == items.count - 1 ? style.blockGap : style.listRowSpacing
            let marker = index < markers.count ? markers[index] : "•\t"
            let prefix: String
            var prefixColor = UIColor.secondaryLabel
            if item.isTask {
                prefix = (item.isDone ? "☑\t" : "☐\t")
                prefixColor = accent
            } else {
                prefix = marker
            }
            return Paragraph(
                prefix: prefix,
                prefixColor: prefixColor,
                spans: item.spans.isEmpty ? [.plain(item.text)] : item.spans,
                font: bodyFont,
                color: item.isDone ? .secondaryLabel : .label,
                style: paragraphStyle
            )
        }
    }

    /// One styled span → attributed text. The flags come from the AST, so
    /// the emphasis is the SAME emphasis the SwiftUI preview shows.
    private static func appendSpans(
        _ spans: [MarkdownText.StyledSpan],
        to result: NSMutableAttributedString,
        baseFont: UIFont,
        color: UIColor,
        accent: UIColor
    ) {
        for span in spans {
            if span.math != nil {
                // A formula is typeset in the maths face and tinted — what
                // tells the reader "this is a formula", not a stray Greek
                // letter in the prose.
                let font = UIFont.systemFont(ofSize: baseFont.pointSize * 1.02, design: .serif)
                result.append(NSAttributedString(string: span.text, attributes: [
                    .font: font,
                    .foregroundColor: accent
                ]))
                continue
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: spanFont(for: span, base: baseFont),
                .foregroundColor: color
            ]
            if span.strike {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let urlString = span.linkURL, let url = URL(string: urlString) {
                attributes[.link] = url
                attributes[.foregroundColor] = accent
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: span.text, attributes: attributes))
        }
    }

    /// The font of one span: the block's font, plus the span's own bold /
    /// italic. A code span is monospaced at the CALL OUT size — the SwiftUI
    /// preview's rule, so inline code keeps its own scale.
    private static func spanFont(for span: MarkdownText.StyledSpan, base: UIFont) -> UIFont {
        if span.code {
            return UIFont.monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
                weight: span.bold ? .bold : .regular
            )
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if span.bold { traits.insert(.traitBold) }
        if span.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty,
              let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    /// The block's text as the ENGINE reads it (maths as words). The
    /// mapping onto the speech text needs this form — the reader sees "β",
    /// the voice says "beta".
    private static func spokenText(for paragraph: Paragraph) -> String {
        paragraph.spans.map(\.spoken).joined()
    }

    /// Headings follow the reader's text-size multiplier like body text
    /// does — the same table the SwiftUI preview uses.
    static func headingFont(level: Int, style: MarkdownProseStyle) -> UIFont {
        let scale = style.headingScale
        switch level {
        case 1:
            return UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .largeTitle).pointSize * scale,
                weight: .bold
            )
        case 2:
            return UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .title1).pointSize * scale,
                weight: .semibold
            )
        case 3:
            return UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize * scale,
                weight: .semibold
            )
        case 4:
            return UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize * scale,
                weight: .semibold
            )
        default:
            return UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize * scale,
                weight: .semibold
            )
        }
    }
}

/// The reading-view metrics the prose text view draws with — the same
/// numbers `MarkdownPreviewView` uses for the SwiftUI blocks, so the two
/// agree on sizes and spacing.
struct MarkdownProseStyle: Equatable {
    /// The body size (Dynamic Type × the reader's text-size setting).
    var bodyFontSize: CGFloat = 17
    /// The heading scale (the reader's text-size setting).
    var headingScale: CGFloat = 1
    /// Line spacing inside paragraphs.
    var lineSpacing: CGFloat = 6
    /// The gap between blocks.
    var blockGap: CGFloat = 16
    /// The gap between list rows.
    var listRowSpacing: CGFloat = 9
    /// The clearance under a heading.
    var headingBottom: CGFloat = 9
    /// The clearance above a level 1-2 heading.
    var headingTopLevel1: CGFloat = 20
    /// The clearance above a level 3+ heading.
    var headingTopLevel3Plus: CGFloat = 16
}
