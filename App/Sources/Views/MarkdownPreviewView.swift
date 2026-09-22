import SwiftUI
import SafariServices
import SpeechLogic

/// Block-rendered markdown reading view.
///
/// Renders `MarkdownText.blocks` output: headings, nested lists with task
/// checkboxes, blockquotes, code blocks (with language label), tables,
/// thematic breaks, and paragraphs split into text / image / link runs via
/// `MarkdownText.inlineRuns`. Local `speechnotes://note-image/…` targets
/// resolve through `NoteImageStore` (thumbnails for big images); remote
/// URLs render via AsyncImage. Links open in an in-app Safari sheet.
struct MarkdownPreviewView: View {
    let markdown: String

    @State private var safariURL: URL?
    @State private var zoomedImage: (url: URL, alt: String)?
    @Environment(\.noteId) private var envNoteId
    @EnvironmentObject private var theme: AppTheme

    // MARK: - Spacing (user-tunable in Appearance → Reading View)

    /// Line spacing inside paragraphs and quotes — base × user multiplier.
    private var lineSpacing: CGFloat { ReaderSpacing.paragraphLine * theme.readerLineSpacing }
    private var quoteLineSpacing: CGFloat { ReaderSpacing.quoteLine * theme.readerLineSpacing }

    /// Vertical gap between blocks.
    private var blockGap: CGFloat { ReaderSpacing.blockGap * theme.readerBlockSpacing }

    /// Gap between list rows; clearance under/over headings.
    private var listRowSpacing: CGFloat { ReaderSpacing.listRow * theme.readerBlockSpacing }
    private var headingBottom: CGFloat { ReaderSpacing.headingBottom * theme.readerBlockSpacing }

    /// Table row height + cell padding (its own multiplier — tables need more
    /// air than prose before they stop looking cramped).
    private var tableRowSpacing: CGFloat { ReaderSpacing.tableRow * theme.readerTableSpacing }
    private var tableCellPadding: CGFloat { ReaderSpacing.tableCell * theme.readerTableSpacing }

    /// Cache so a body re-render (zoom state, theme tick, sheet state) doesn't
    /// re-parse the whole note. Recomputed only when `markdown` changes.
    @State private var parsedCache: (source: String, blocks: [MarkdownText.MarkdownBlock])?
    /// Local image target → pre-resolved on-disk URL, built off-main so the
    /// first render never does thumbnail I/O inside the view body.
    @State private var resolvedImages: [String: URL] = [:]

    private var blocks: [MarkdownText.MarkdownBlock] {
        if let cache = parsedCache, cache.source == markdown { return cache.blocks }
        return MarkdownText.blocks(markdown)
    }

    private var parsedNoteId: UUID { envNoteId ?? UUID() }

    /// Body font follows Dynamic Type (pre-bisect behavior) scaled by the
    /// user's reading-size setting — not a hard-coded 17pt.
    private var bodyFontSize: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).pointSize * theme.previewTextScale
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Reading text scale (user-controlled in Appearance settings).
            // Muliply only Text-bearing content — code is monospaced already.
            .font(.system(size: bodyFontSize))
        }
        // The note should not drift once you open it: vertical bounce is off
        // entirely (user request — "once I open [a note] it's too easy to
        // move, make it static"). Scrolling still works; a short note sits
        // fixed at rest and a long one stops dead at its ends instead of
        // rubber-banding past them. The pre-v1.6.0 `.basedOnSize` compromise
        // still let a note drift, so it's gone.
        .scrollBounceBehavior(.basedOnSize, axes: [])
        .onAppear { refreshCaches() }
        .onChange(of: markdown) { _ in refreshCaches() }
        .sheet(item: $safariURL) { url in
            SafariSheet(url: url)
                .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(
            get: { zoomedImage != nil },
            set: { if !$0 { zoomedImage = nil } }
        )) {
            if let image = zoomedImage {
                ZoomableImageView(url: image.url, alt: image.alt)
                    .ignoresSafeArea()
            }
        }
    }

    /// Parse + resolve images once per markdown change. Parsing happens
    /// synchronously (needed for this render) but only when the source
    /// changed; thumbnail/stat resolution goes off the main thread.
    private func refreshCaches() {
        if parsedCache?.source != markdown {
            parsedCache = (markdown, MarkdownText.blocks(markdown))
        }
        let targets = collectImageTargets(from: parsedCache?.blocks ?? [])
        let noteId = parsedNoteId
        Task.detached(priority: .userInitiated) {
            var map: [String: URL] = [:]
            for target in targets {
                if let url = NoteImageStore.thumbnailURL(for: target, noteId: noteId)
                    ?? NoteImageStore.resolveLocalURL(target, noteId: noteId) {
                    map[target] = url
                }
            }
            await MainActor.run { resolvedImages = map }
        }
    }

    private func collectImageTargets(from blocks: [MarkdownText.MarkdownBlock]) -> [String] {
        var out: [String] = []
        for block in blocks {
            switch block {
            case .image(_, let url):
                out.append(url)
            case .paragraph(let text):
                for run in MarkdownText.inlineRuns(text) {
                    if case .image(_, let url) = run { out.append(url) }
                }
            default: break
            }
        }
        return out.filter { NoteImageStore.parseLocalTarget($0) != nil }
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownText.MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            styledText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? ReaderSpacing.headingTopLevel1 * theme.readerBlockSpacing
                                         : ReaderSpacing.headingTopLevel3Plus * theme.readerBlockSpacing)
                .padding(.bottom, headingBottom)
        case .paragraph(let text):
            runsView(MarkdownText.inlineRuns(text))
                .lineSpacing(lineSpacing)
                .padding(.bottom, blockGap)
        case .bulletList(let items):
            listRows(items, markerBuilder: { _, _ in "•" })
        case .orderedList(let items):
            listRows(items, markerBuilder: { index, _ in "\(index + 1)." })
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                    .padding(.top, 2)
                styledText(text)
                    .foregroundStyle(.secondary)
                    .lineSpacing(quoteLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, blockGap)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
            .padding(.bottom, blockGap)
        case .divider:
            Divider().padding(.vertical, 10)
        case .image(let alt, let url):
            imageView(url: url, alt: alt)
                .padding(.bottom, blockGap)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
                .padding(.bottom, blockGap)
        }
    }

    /// Lists render with nesting indentation and task checkboxes; completed
    /// tasks read with a strikethrough.
    private func listRows(
        _ items: [MarkdownText.ListItem],
        markerBuilder: @escaping (Int, MarkdownText.ListItem) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: listRowSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if item.isTask {
                        Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.isDone ? Color.accentColor : .secondary)
                            .font(.callout)
                    } else {
                        Text(markerBuilder(index, item))
                            .foregroundStyle(.secondary)
                    }
                    styledText(item.text)
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                }
                .padding(.leading, CGFloat(item.level) * 16)
            }
        }
        .padding(.bottom, blockGap)
    }

    /// Tables. The old `Grid` gave every column the width of its WIDEST cell,
    /// so one long sentence stretched the whole table sideways and pushed the
    /// other columns off screen — and because the grid lived in a horizontal
    /// ScrollView the reader had to pan to find them. What a reader expects is
    /// a table that wraps: long cells break across lines, columns share the
    /// width fairly, and the table only scrolls sideways when even a fair
    /// share cannot fit (a genuinely wide table, not a long sentence).
    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        // Measure the CONTAINER width with a background-only GeometryReader:
        // `.background()` content is laid out at the size of the view it is
        // attached to and never influences that view's own size, so there is
        // no collapse and no rounding feedback loop. (Wrapping the table in a
        // foreground GeometryReader collapsed it to zero height — a
        // horizontally-scrollable table reports ~zero ideal height — and the
        // following block rendered on top of it.)
        tableGrid(headers: headers, rows: rows, columnCount: columnCount)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measuredWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { newValue in measuredWidth = newValue }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Last container width reported by the tables' measuring reader. Shared
    /// across the note's tables (the column math depends only on width, font
    /// and content — cached per (table, font, width) — so one shared value is
    /// both correct and cheaper than per-table state).
    @State private var measuredWidth: CGFloat = 0

    @ViewBuilder
    private func tableGrid(
        headers: [String],
        rows: [[String]],
        columnCount: Int
    ) -> some View {
        // Widths come from the measured container width; fall back to the
        // screen-based estimate for the very first layout pass (measuredWidth
        // is still zero then) so nothing flashes un-sized.
        let widths = cachedTableWidths(
            headers: headers,
            rows: rows,
            columnCount: columnCount,
            availableWidth: measuredWidth > 0 ? measuredWidth : (UIScreen.main.bounds.width - 32)
        )
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: tableRowSpacing) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { index in
                        styledText(headers[safe: index] ?? "")
                            .bold()
                            .frame(width: widths[safe: index], alignment: .leading)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { index in
                            styledText(row[safe: index] ?? "")
                                .frame(width: widths[safe: index], alignment: .leading)
                        }
                    }
                }
            }
            .padding(tableCellPadding)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }

    /// (headers + rows joined, font size, available width) → column widths.
    /// Bounded like the span cache; a clear-all on overflow is fine because
    /// rebuilding a table's width list is a handful of boundingRect calls,
    /// not a parse.
    ///
    /// The budget: a column gets its longest-word floor plus an equal share of
    /// what is left. When the table genuinely cannot fit (a wide table), the
    /// columns simply exceed the viewport and the horizontal ScrollView pans —
    /// that case is rare by design (a long SENTENCE wraps; only a long WORD
    /// pushes a column wide). The old code measured with UIScreen.main, which
    /// is wrong in landscape and inside the reader's insets; it now uses the
    /// container width passed in by the caller's GeometryReader.
    private static var tableWidthCache: [String: [CGFloat]] = [:]
    private static let tableWidthCacheLimit = 64

    private func cachedTableWidths(
        headers: [String],
        rows: [[String]],
        columnCount: Int,
        availableWidth: CGFloat
    ) -> [CGFloat] {
        let key = "\(headers.joined(separator: "\u{1}"))\u{2}\(rows.map { $0.joined(separator: "\u{1}") }.joined(separator: "\u{2}"))\u{3}\(bodyFontSize)\u{4}\(availableWidth)"
        if let hit = Self.tableWidthCache[key] { return hit }
        let minimums = (0..<columnCount).map { index -> CGFloat in
            let cells = [headers[safe: index] ?? ""] + rows.compactMap { $0[safe: index] ?? "" }
            let longestWord = cells
                .flatMap { $0.split(separator: " ").map(String.init) }
                .map { $0.boundingWidth(at: bodyFontSize) }
                .max() ?? 0
            return min(longestWord + 2, 160)
        }
        // Joplin-style distribution: the leftover is shared by CONTENT
        // WEIGHT, not equally. Equal shares give a one-word status chip as
        // much room as a sentence-long description, which is what made the
        // old layout look cramped. Weight = average cell text length per
        // column, so prose columns grow and code columns stay tight.
        let chrome = 16 /*table cell padding both sides*/ + CGFloat(minimums.count + 1) * 8
        let available = max(0, availableWidth - chrome)
        let weights: [Double] = (0..<columnCount).map { index in
            let cells = [headers[safe: index] ?? ""] + rows.compactMap { $0[safe: index] ?? "" }
            let longest = cells.map { $0.count }.max() ?? 1
            return Double(max(1, longest))
        }
        let totalWeight = weights.reduce(0, +)
        let widths: [CGFloat] = (0..<columnCount).map { index in
            guard totalWeight > 0 else { return available / CGFloat(max(1, columnCount)) }
            let share = available * CGFloat(weights[index] / totalWeight)
            // Never below the word floor — a long word must not be clipped.
            return max(minimums[index], minimums[index] + share * 0.85)
        }
        if Self.tableWidthCache.count >= Self.tableWidthCacheLimit {
            Self.tableWidthCache.removeAll()
        }
        Self.tableWidthCache[key] = widths
        return widths
    }

    // MARK: - Inline runs

    /// Paragraphs render as ONE composed Text so words wrap naturally across
    /// runs (the old FlowLayout forced run-level wrapping, overflowing to the
    /// edge). Links become real AttributedString links opened via the
    /// environment's openURL; inline images stand alone below the paragraph.
    @ViewBuilder
    private func runsView(_ runs: [MarkdownText.InlineRun]) -> some View {
        if let composed = composedText(runs) {
            composed
        }
        ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
            if case .image(let alt, let url) = run {
                imageView(url: url, alt: alt)
            }
        }
    }

    private func composedText(_ runs: [MarkdownText.InlineRun]) -> Text? {
        var composed: Text?
        for run in runs {
            let piece: Text
            switch run {
            case .text(let s):
                piece = styledText(s)
            case .link(let label, let urlString):
                var attrs = AttributedString(label)
                attrs.foregroundColor = .accentColor
                attrs.underlineStyle = .single
                if let url = URL(string: urlString) { attrs.link = url }
                piece = Text(attrs)
            case .image:
                continue
            }
            composed = composed.map { $0 + piece } ?? piece
        }
        return composed
    }

    // MARK: - Emphasis styling

    /// Styles **bold**, *italic*, `code` and ~~strike~~ spans within a text
    /// run, returning one composed Text. (Links are lifted out earlier as
    /// separate runs, so no link handling is needed here.)
    /// One-pass tokenizer over inline markers. Unmatched markers stay
    /// literal, so stray asterisks in prose survive; underscore rules carry
    /// word-boundary guards so snake_case identifiers are not styled.
    private static let emphasisRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"`([^`]+)`"#
                + #"|\*\*\*([^*]+)\*\*\*"#
                + #"|\*\*([^*]+)\*\*"#
                + #"|__([^_]+)__"#
                + #"|~~([^~]+)~~"#
                + #"|(?<![*\w])\*([^*\s][^*]*)\*(?!\*)"#
                + #"|(?<![\w_])_([^_\s][^_]*)_(?![\w_])"#
        )
    }()

    private enum SpanStyle { case plain, bold, italic, boldItalic, code, strike }
    private struct Span { let text: String; let style: SpanStyle }

    /// Per-source-string span cache. The emphasis regex used to run once per
    /// run per body evaluation, and body evaluations fire on every playback
    /// progress tick (the player is a root environment object) — a table- or
    /// paragraph-heavy note re-ran a full regex pass over its visible text
    /// several times a second for output that never changed. Bounded to the
    /// most recent 512 distinct strings so a long scroll can't grow it
    /// without limit.
    private static var spanCache: [String: [Span]] = [:]
    private static let spanCacheLimit = 512

    private static func cachedSpans(in string: String) -> [Span] {
        if let hit = spanCache[string] { return hit }
        let spans = emphasisSpans(in: string)
        if spanCache.count >= spanCacheLimit {
            // Cheap eviction — drop the whole map rather than track LRU
            // order; rebuilding 512 short strings is microseconds.
            spanCache.removeAll()
        }
        spanCache[string] = spans
        return spans
    }

    private func styledText(_ string: String) -> Text {
        let spans = Self.cachedSpans(in: string)
        guard !spans.isEmpty else { return Text(string) }
        var composed = Text("")
        for span in spans {
            let piece = Text(span.text)
            switch span.style {
            case .plain: composed = composed + piece
            case .bold: composed = composed + piece.bold()
            case .italic: composed = composed + piece.italic()
            case .boldItalic: composed = composed + piece.bold().italic()
            case .code: composed = composed + piece.font(.system(.callout, design: .monospaced))
            case .strike: composed = composed + piece.strikethrough()
            }
        }
        return composed
    }

    private static func emphasisSpans(in string: String) -> [Span] {
        guard let regex = Self.emphasisRegex else { return [] }
        let ns = string as NSString
        var spans: [Span] = []
        var cursor = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                spans.append(Span(text: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), style: .plain))
            }
            let content: (String, SpanStyle)
            if match.range(at: 1).location != NSNotFound {
                content = (ns.substring(with: match.range(at: 1)), .code)
            } else if match.range(at: 2).location != NSNotFound {
                content = (ns.substring(with: match.range(at: 2)), .boldItalic)
            } else if match.range(at: 3).location != NSNotFound {
                content = (ns.substring(with: match.range(at: 3)), .bold)
            } else if match.range(at: 4).location != NSNotFound {
                content = (ns.substring(with: match.range(at: 4)), .bold)
            } else if match.range(at: 5).location != NSNotFound {
                content = (ns.substring(with: match.range(at: 5)), .strike)
            } else if match.range(at: 6).location != NSNotFound {
                content = (ns.substring(with: match.range(at: 6)), .italic)
            } else if match.range(at: 7).location != NSNotFound {
                content = (ns.substring(with: match.range(at: 7)), .italic)
            } else {
                content = (ns.substring(with: match.range), .plain)
            }
            spans.append(Span(text: content.0, style: content.1))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            spans.append(Span(text: ns.substring(from: cursor), style: .plain))
        }
        return spans
    }

    // MARK: - Images

    /// Image renderer: thumbnail-first resolution (never re-downloads a
    /// cached `speechnotes://` image), remote fallback, tap to zoom.
    /// We resolve the URL *before* creating the image view so the zoom
    /// sheet doesn't need to re-derive it from the alt text.
    /// Images render at full available width (Joplin parity): the thumbnail
    /// is generated at 1200px long edge, and we use `.aspectRatioFit` +
    /// explicit maxWidth so the image fills the screen horizontally.
    @ViewBuilder
    private func imageView(url: String, alt: String) -> some View {
        if let local = localImageURL(url) {
            CachedImage(url: local, alt: alt, zoomable: true) {
                zoomedImage = (url: local, alt: alt)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
        } else if let remote = URL(string: url) {
            CachedImage(url: remote, alt: alt, zoomable: true) {
                zoomedImage = (url: remote, alt: alt)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }

    /// Local target → pre-resolved on-disk URL (populated off-main by
    /// refreshCaches); nil for remote/unknown targets.
    private func localImageURL(_ target: String) -> URL? {
        guard NoteImageStore.parseLocalTarget(target) != nil else { return nil }
        return resolvedImages[target]
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        case 4: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

/// Thin wrapper around SFSafariViewController so SwiftUI can show it via
/// `.sheet(item:)`. No toolbar chrome — we want a minimal in-app browser.
/// (`URL: Identifiable` lives in StorageSettingsView.swift — one conformance only.)
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// Environment key so the preview can resolve note-scoped image caches.
/// Set by NoteEditorView via `.environment(\.noteId, noteId)`.
struct NoteIdKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var noteId: UUID? {
        get { self[NoteIdKey.self] }
        set { self[NoteIdKey.self] = newValue }
    }
}

private extension Array {
    /// Element at `index`, or nil — used for ragged table rows, where a row
    /// may legitimately have fewer cells than the header.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    /// Rendered width of the string at a font size. Used by the table layout
    /// to find the narrowest width a column can take without clipping a word.
    func boundingWidth(at fontSize: CGFloat) -> CGFloat {
        (self as NSString).boundingRect(
            with: CGSize(width: .greatestFiniteMagnitude, height: fontSize * 2),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.systemFont(ofSize: fontSize)],
            context: nil
        ).width
    }
}
