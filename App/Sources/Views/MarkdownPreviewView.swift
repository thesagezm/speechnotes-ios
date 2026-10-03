import SwiftUI
import SafariServices
import SpeechLogic
import UIKit

/// Block-rendered markdown reading view.
///
/// Renders `MarkdownText.blocks` output — the GFM (cmark-gfm) AST: headings,
/// nested lists with task checkboxes, blockquotes, code blocks (with
/// language label), tables, thematic breaks, and paragraphs composed from
/// the AST's own styled spans (emphasis, code, links, inline images).
/// Local `speechnotes://note-image/…` targets
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
                // The table container-width probe. `Color.clear` adopts ANY
                // proposal, so the width measured here IS the space tables
                // get. Measuring the table itself instead read back its own
                // (possibly overflowing) laid-out width and fed the column
                // math its own overflow — a feedback loop that pinned wide
                // tables at the full screen width, and in landscape that
                // pushed the trailing PlaybackRail clean off the screen
                // (the "rail missing in preview for rich notes" report).
                Color.clear
                    .frame(height: 0)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { measuredWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { measuredWidth = $0 }
                        }
                    )
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
        let realNoteId = envNoteId
        let remoteTargets = targets.filter { NoteImageStore.parseLocalTarget($0) == nil }
        Task.detached(priority: .userInitiated) {
            var map: [String: URL] = [:]
            for target in targets {
                if let url = NoteImageStore.thumbnailURL(for: target, noteId: noteId)
                    ?? NoteImageStore.resolveLocalURL(target, noteId: noteId) {
                    map[target] = url
                }
            }
            await MainActor.run { resolvedImages = map }
            // Index which web images THIS note shows — Storage's per-note
            // deletion and the recycle bin's purge both key off this. Only
            // for a real note identity (the preview's fallback UUID must not
            // litter the index).
            if let realId = realNoteId {
                let urls = remoteTargets.compactMap(URL.init(string:))
                    .filter { url in
                        guard let scheme = url.scheme?.lowercased() else { return false }
                        return scheme == "http" || scheme == "https"
                    }
                RemoteImageStore.record(urls: urls, noteId: realId)
            }
        }
    }

    private func collectImageTargets(from blocks: [MarkdownText.MarkdownBlock]) -> [String] {
        var out: [String] = []
        for block in blocks {
            switch block {
            case .image(_, let url):
                out.append(url)
            case .paragraph(_, let spans):
                out.append(contentsOf: spans.compactMap(\.imageURL))
            default: break
            }
        }
        return out.filter { NoteImageStore.parseLocalTarget($0) != nil }
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownText.MarkdownBlock) -> some View {
        switch block {
        case .heading(_, _, let spans):
            attributedText(spans)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? ReaderSpacing.headingTopLevel1 * theme.readerBlockSpacing
                                         : ReaderSpacing.headingTopLevel3Plus * theme.readerBlockSpacing)
                .padding(.bottom, headingBottom)
        case .paragraph(_, let spans):
            paragraphView(spans)
                .lineSpacing(lineSpacing)
                .padding(.bottom, blockGap)
        case .bulletList(let items):
            listRows(items, markerBuilder: { _, _ in "•" })
        case .orderedList(let items):
            listRows(items, markerBuilder: { index, _ in "\(index + 1)." })
        case .quote(_, let spans):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                    .padding(.top, 2)
                attributedText(spans)
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
                    (item.spans.isEmpty
                        ? attributedText([.plain(item.text)])
                        : attributedText(item.spans))
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                }
                .padding(.leading, CGFloat(item.level) * 16)
            }
        }
        .padding(.bottom, blockGap)
    }

    /// Tables render the way a notes app draws one: a real grid inside the
    /// available width, not a horizontally-scrolling card.
    ///
    /// What that means concretely, and why each part is here:
    ///   * **Columns share the width.** A column's floor is its longest WORD
    ///     (a word wraps; it never needs a column of its own), and whatever
    ///     is left over is split evenly. The old code split the leftover by
    ///     CONTENT WEIGHT, which gave a sentence column three times the
    ///     space a one-word column needed and pushed the table wider than
    ///     the screen.
    ///   * **A header row that reads as one.** Bold text on a tinted fill,
    ///     with a rule under it — the visual line that says "this is a
    ///     header", which bold alone does not do at a glance.
    ///   * **Hairlines between rows and columns**, plus a very light zebra
    ///     stripe on alternate rows. That combination is what makes a
    ///     wrapped multi-line cell readable when your eye has to track back
    ///     across the row; without it a three-line cell reads as floating
    ///     text.
    ///   * **Numeric columns right-align** with monospaced digits, so a
    ///     column of figures lines up on the decimal instead of jittering.
    ///   * **Horizontal scrolling only as a last resort** — when the floors
    ///     alone exceed the width, which is a genuinely wide table, not a
    ///     long sentence.
    @ViewBuilder
    private func tableView(headers: [[MarkdownText.StyledSpan]], rows: [[[MarkdownText.StyledSpan]]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        // Measure the CONTAINER width with a background-only GeometryReader:
        // `.background()` content is laid out at the size of the view it is
        // attached to and never influences that view's own size, so there is
        // no collapse and no rounding feedback loop. (Wrapping the table in a
        // foreground GeometryReader collapsed it to zero height — a
        // horizontally-scrollable table reports ~zero ideal height — and the
        // following block rendered on top of it.)
        grid(
            headers: headers,
            rows: rows,
            columnCount: columnCount
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Last container width reported by the tables' measuring reader. Shared
    /// across the note's tables (the column math depends only on width, font
    /// and content — cached per (table, font, width) — so one shared value is
    /// both correct and cheaper than per-table state).
    @State private var measuredWidth: CGFloat = 0

    /// Grid lines and fills. On top of the system background so a table reads the
    /// same in light and dark without a second branch per row — `.secondary`
    /// is semantic, so one value covers both.
    private static var ruleColor: Color { Color.secondary.opacity(0.25) }
    private static var headerFill: Color { Color.secondary.opacity(0.12) }
    private static var stripeFill: Color { Color.secondary.opacity(0.06) }

    @ViewBuilder
    private func grid(
        headers: [String],
        rows: [[String]],
        columnCount: Int
    ) -> some View {
        // Widths come from the measured container width; fall back to the
        // screen-based estimate for the very first layout pass (measuredWidth
        // is still zero then) so nothing flashes un-sized.
        let layout = cachedLayout(
            headers: headers,
            rows: rows,
            columnCount: columnCount,
            availableWidth: measuredWidth > 0 ? measuredWidth : 320
        )
        let content = tableBody(
            headers: headers,
            rows: rows,
            columnCount: columnCount,
            widths: layout.widths,
            numeric: layout.numeric,
            ruleColor: Self.ruleColor,
            headerFill: Self.headerFill,
            stripeFill: Self.stripeFill,
            horizontalPadding: layout.horizontalPadding,
            rowSpacing: tableRowSpacing
        )
        if layout.overflows {
            ScrollView(.horizontal, showsIndicators: false) { content }
        } else {
            content
        }
    }

    /// The grid itself. Split out of `grid` so the scrolling wrapper can be
    /// conditional without duplicating the layout.
    private func tableBody(
        headers: [[MarkdownText.StyledSpan]],
        rows: [[[MarkdownText.StyledSpan]]],
        columnCount: Int,
        widths: [CGFloat],
        numeric: [Bool],
        ruleColor: Color,
        headerFill: Color,
        stripeFill: Color,
        horizontalPadding: CGFloat,
        rowSpacing: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            // Header. One fill + one rule under it, so the eye reads a
            // header band rather than a bold line of text.
            tableRow(
                cells: headers.padded(to: columnCount),
                widths: widths,
                numeric: numeric,
                bold: true,
                fill: headerFill,
                ruleColor: ruleColor,
                horizontalPadding: horizontalPadding,
                rowSpacing: rowSpacing
            )
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                tableRow(
                    cells: row.padded(to: columnCount),
                    widths: widths,
                    numeric: numeric,
                    bold: false,
                    // Zebra on odd rows only — a stripe under the header
                    // would sit next to the header fill and read as one
                    // thick band.
                    fill: index % 2 == 1 ? stripeFill : .clear,
                    ruleColor: ruleColor,
                    horizontalPadding: horizontalPadding,
                    rowSpacing: rowSpacing
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(ruleColor, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// One grid row: cells separated by hairline columns. Cells top-align —
    /// a wrapped cell grows downward, never vertically centred against its
    /// neighbours, which is what makes a ragged row look wrong.
    private func tableRow(
        cells: [[MarkdownText.StyledSpan]],
        widths: [CGFloat],
        numeric: [Bool],
        bold: Bool,
        fill: Color,
        ruleColor: Color,
        horizontalPadding: CGFloat,
        rowSpacing: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<widths.count, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(ruleColor)
                        .frame(width: 0.5)
                }
                cell(
                    cells[safe: index] ?? [],
                    width: widths[index],
                    numeric: numeric[safe: index] ?? false,
                    bold: bold
                )
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, rowSpacing / 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ruleColor)
                .frame(height: 0.5)
        }
    }

    /// One cell. `fixedSize(horizontal:false, vertical:true)` is what makes a
    /// wrapped cell report its FULL height — without it SwiftUI proposes the
    /// ideal (single-line) height and every row comes out one line tall with
    /// the extra text spilling out of the cell.
    @ViewBuilder
    private func cell(_ spans: [MarkdownText.StyledSpan], width: CGFloat, numeric: Bool, bold: Bool) -> some View {
        // Traits arrive from the AST (a bold term in a cell stays bold); the
        // size never changes, so a column of cells reads as one text.
        var content = attributedText(spans.isEmpty ? [.plain("")] : spans)
        if bold {
            content = content.bold()
        }
        content
            .monospacedDigit(numeric)
            .multilineTextAlignment(numeric ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: max(1, width), alignment: numeric ? .trailing : .leading)
    }

    /// A cell's plain text — measurement and numeric-column detection read
    /// strings; the display reads spans.
    private func cellText(_ spans: [MarkdownText.StyledSpan]) -> String {
        spans.map(\.text).joined()
    }

    /// Column math for one table: the widths, which columns are figures,
    /// and whether the floors overflow the container. Nested in the view
    /// (not at file scope) because nothing outside needs it.
    private struct TableLayout {
        var widths: [CGFloat]
        var numeric: [Bool]
        /// The columns cannot fit the container at their word floors.
        var overflows: Bool
        var horizontalPadding: CGFloat
    }

    /// Equal shares over the word floors, with an honest overflow test.
    ///
    /// `minimums[i]` is the longest WORD in column i plus padding: a word is
    /// the only thing that cannot wrap, so it is the only thing that sets a
    /// hard floor. When the floors fit, whatever is left over is split
    /// evenly — that is the notes-app rule, and the reason two ordinary
    /// columns look like two ordinary columns instead of one wide one and
    /// one cramped one. When they do not fit, the table is genuinely wide
    /// and the caller pans it.
    ///
    /// Cached per (content, font, width) like the span cache: measuring a
    /// column means a boundingRect per cell, and a body re-render (theme
    /// tick, playback progress) would otherwise repeat that for every table
    /// on screen. A clear-all on overflow is fine — this is a handful of
    /// measurements, not a parse.
    private static var tableLayoutCache: [String: TableLayout] = [:]
    private static let tableLayoutCacheLimit = 64

    private func cachedLayout(
        headers: [[MarkdownText.StyledSpan]],
        rows: [[[MarkdownText.StyledSpan]]],
        columnCount: Int,
        availableWidth: CGFloat
    ) -> TableLayout {
        let key = "\(headers.map(cellText).joined(separator: "\u{1}"))\u{2}\(rows.map { $0.map(cellText).joined(separator: "\u{1}") }.joined(separator: "\u{2}"))\u{3}\(bodyFontSize)\u{4}\(availableWidth)"
        if let hit = Self.tableLayoutCache[key] { return hit }
        let layout = computeLayout(
            headers: headers,
            rows: rows,
            columnCount: columnCount,
            availableWidth: availableWidth
        )
        if Self.tableLayoutCache.count >= Self.tableLayoutCacheLimit {
            Self.tableLayoutCache.removeAll()
        }
        Self.tableLayoutCache[key] = layout
        return layout
    }

    private func computeLayout(
        headers: [[MarkdownText.StyledSpan]],
        rows: [[[MarkdownText.StyledSpan]]],
        columnCount: Int,
        availableWidth: CGFloat
    ) -> TableLayout {
        let headerTexts = headers.map(cellText)
        let rowTexts = rows.map { $0.map(cellText) }
        guard columnCount > 0 else {
            return TableLayout(widths: [], numeric: [], overflows: false, horizontalPadding: tableCellPadding)
        }
        // Rules are hairline but they take layout width, so the border and
        // the separators are part of "chrome" here — omitting them hands out
        // ~1pt more than fits and the last column clips.
        let horizontalPadding = min(tableCellPadding, 12)
        let chrome = horizontalPadding * 2 * CGFloat(columnCount) + CGFloat(columnCount - 1) * 0.5
        let usable = max(1, availableWidth - chrome)

        let columns: [[String]] = (0..<columnCount).map { index in
            [headerTexts[safe: index] ?? ""] + rowTexts.compactMap { $0[safe: index] ?? "" }
        }
        let floors: [CGFloat] = columns.map { cells in
            let longestWord = cells
                .flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
                .map { $0.boundingWidth(at: bodyFontSize) }
                .max() ?? 0
            // A cap keeps one absurd token (a base64 blob, a long URL) from
            // claiming a whole screen; the text wraps or truncates instead.
            return max(24, min(longestWord, 140))
        }
        let numeric: [Bool] = columns.map { cells in
            let values = cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !values.isEmpty else { return false }
            // Thousands separators, a leading sign and a trailing unit are
            // all figures for a reader's purposes.
            return values.allSatisfy { value in
                var stripped = value.replacingOccurrences(of: ",", with: "")
                stripped = stripped.replacingOccurrences(of: " ", with: "")
                if stripped.hasPrefix("-") || stripped.hasPrefix("+") {
                    stripped = String(stripped.dropFirst())
                }
                // Keep a decimal tail: "3.5" is numeric, "3.5 kg" is not
                // (that column is prose that happens to start with a number).
                if let dot = stripped.lastIndex(of: ".") {
                    stripped = String(stripped[stripped.index(after: dot)...])
                }
                return !stripped.isEmpty && stripped.allSatisfy(\.isNumber)
            }
        }

        let floorsTotal = floors.reduce(0, +)
        let overflows = floorsTotal > usable
        var widths: [CGFloat]
        if overflows {
            // Genuinely wide: every column gets its floor and the table pans.
            widths = floors
        } else {
            let leftover = (usable - floorsTotal) / CGFloat(columnCount)
            widths = floors.map { $0 + leftover }
        }
        return TableLayout(
            widths: widths,
            numeric: numeric,
            overflows: overflows,
            horizontalPadding: horizontalPadding
        )
    }

    // MARK: - Spans (one attributed paragraph per block)

    /// One block's spans → flowing text + the images lifted out. Traits are
    /// `inlinePresentationIntent`s, so SwiftUI renders them with the
    /// ENVIRONMENT font — the reading-size multiplier, the Dynamic Type
    /// step, the weight all carry through. The old per-span `.font(.system
    /// (.callout, design: .monospaced))` REPLACED the font wholesale, which
    /// is why inline code sat at a different size and letter spacing than
    /// the sentence around it ("font thickness/spacing not uniform").
    private func attributedText(_ spans: [MarkdownText.StyledSpan]) -> Text {
        var out = AttributedString()
        for span in spans where !span.isImage {
            var piece = AttributedString(span.text)
            var intent: InlinePresentationIntent = []
            if span.code { intent.insert(.code) }
            if span.strike { intent.insert(.strikethrough) }
            if span.italic { intent.insert(.emphasized) }
            if span.bold { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let urlString = span.linkURL, !urlString.isEmpty, let url = URL(string: urlString) {
                piece.link = url
                piece.foregroundColor = .accentColor
                piece.underlineStyle = .single
            }
            out += piece
        }
        return Text(out)
    }

    /// A paragraph: its composed text, then any inline images below it.
    @ViewBuilder
    private func paragraphView(_ spans: [MarkdownText.StyledSpan]) -> some View {
        let prose = attributedText(spans)
        let images = spans.filter(\.isImage)
        VStack(alignment: .leading, spacing: 8) {
            if spans.contains(where: { !$0.isImage }) {
                prose
            }
            ForEach(Array(images.enumerated()), id: \.offset) { _, span in
                if let alt = span.imageAlt, let url = span.imageURL, !url.isEmpty {
                    imageView(url: url, alt: alt)
                }
            }
        }
    }

    private func collectImageTargets(from spans: [MarkdownText.StyledSpan]) -> [String] {
        spans.compactMap { $0.imageURL }.filter { NoteImageStore.parseLocalTarget($0) != nil }
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

    /// Headings follow the reader's text-size multiplier like body text
    /// does. `.title`/`.title2`/... are fixed Dynamic Type steps, so the
    /// Appearance slider used to move the paragraphs and leave the
    /// headings exactly where they were — "the resizer does nothing for
    /// headers" (device report). Each step is now the Dynamic Type size ×
    /// the user's multiplier, computed once per body evaluation.
    private func headingFont(_ level: Int) -> Font {
        let scale = theme.previewTextScale
        switch level {
        case 1: return .system(size: UIFont.preferredFont(forTextStyle: .largeTitle).pointSize * scale, weight: .bold)
        case 2: return .system(size: UIFont.preferredFont(forTextStyle: .title1).pointSize * scale, weight: .semibold)
        case 3: return .system(size: UIFont.preferredFont(forTextStyle: .title2).pointSize * scale, weight: .semibold)
        case 4: return .system(size: UIFont.preferredFont(forTextStyle: .headline).pointSize * scale, weight: .semibold)
        default: return .system(size: UIFont.preferredFont(forTextStyle: .subheadline).pointSize * scale, weight: .semibold)
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

/// The empty cells a ragged table produces, and the single-owner problem
/// that comes with them.
///
/// The table body pads every row to the column count in one place, so a row
/// that legitimately has fewer cells than the header (normal for anything
/// imported from a PDF or a spreadsheet with an optional last column) cannot
/// be miscounted at a call site.
extension Array where Element == String {
    /// `count` cells, padded with empty strings.
    func padded(to count: Int) -> [String] {
        guard self.count < count else { return self }
        return self + Array(repeating: "", count: count - self.count)
    }
}

/// Element at `index`, or nil — the table rows are ragged by nature (a row
/// may have fewer cells than the header), so every column read has to
/// tolerate a short row.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Monospaced digits for a column of figures, so 1,000 and 8 line up on
/// the same digit cell instead of jittering. A no-op for prose.
private extension Text {
    func monospacedDigit(_ enabled: Bool) -> Text {
        enabled ? monospacedDigit() : self
    }
}

private extension String {
    /// Rendered width of the string at a font size, measured on ONE line so a
    /// cell that will wrap never inflates a column's floor. Used by the table
    /// layout to find the narrowest width a column can take without clipping
    /// a word.
    func boundingWidth(at fontSize: CGFloat) -> CGFloat {
        (self as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: fontSize)]
        ).width
    }
}
