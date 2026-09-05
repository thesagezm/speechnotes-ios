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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MarkdownText.blocks(markdown).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Reading text scale (user-controlled in Appearance settings).
            // Muliply only Text-bearing content — code is monospaced already.
            .font(.system(size: 17 * theme.previewTextScale))
        }
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

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownText.MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            styledText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 18 : 14)
                .padding(.bottom, 6)
        case .paragraph(let text):
            runsView(MarkdownText.inlineRuns(text))
                .lineSpacing(4)
                .padding(.bottom, 14)
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
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 14)
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
            .padding(.bottom, 14)
        case .divider:
            Divider().padding(.vertical, 10)
        case .image(let alt, let url):
            imageView(url: url, alt: alt)
                .padding(.bottom, 14)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
                .padding(.bottom, 14)
        }
    }

    /// Lists render with nesting indentation and task checkboxes; completed
    /// tasks read with a strikethrough.
    private func listRows(
        _ items: [MarkdownText.ListItem],
        markerBuilder: @escaping (Int, MarkdownText.ListItem) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if item.isTask {
                        Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary)
                            .font(.callout)
                    } else {
                        Text(markerBuilder(index, item))
                            .foregroundStyle(.secondary)
                    }
                    styledText(item.text)
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                }
                .padding(.leading, CGFloat(item.level) * 16)
            }
        }
        .padding(.bottom, 14)
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                        styledText(cell).bold()
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            styledText(cell)
                        }
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }

    // MARK: - Inline runs

    /// Renders mixed text / image / link runs. Text runs go through the
    /// emphasis styler; link runs become real tappable buttons; image runs
    /// render via the NoteImageStore / AsyncImage path.
    @ViewBuilder
    private func runsView(_ runs: [MarkdownText.InlineRun]) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case .text(let s):
                    styledText(s)
                case .link(let label, let url):
                    Button {
                        guard let url = URL(string: url) else { return }
                        safariURL = url
                    } label: {
                        Text(label)
                            .foregroundColor(.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                case .image(let alt, let url):
                    imageView(url: url, alt: alt)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
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

    private func styledText(_ string: String) -> Text {
        let spans = Self.emphasisSpans(in: string)
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
    @ViewBuilder
    private func imageView(url: String, alt: String) -> some View {
        if let local = localImageURL(url) {
            CachedImage(url: local, alt: alt, zoomable: true) {
                zoomedImage = (url: local, alt: alt)
            }
            .padding(.bottom, 14)
        } else if let remote = URL(string: url) {
            CachedImage(url: remote, alt: alt, zoomable: true) {
                zoomedImage = (url: remote, alt: alt)
            }
            .padding(.bottom, 14)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }

    /// Local target → best on-disk URL (cached thumbnail when present,
    /// original otherwise); nil for remote/unknown targets.
    private func localImageURL(_ target: String) -> URL? {
        guard NoteImageStore.parseLocalTarget(target) != nil else { return nil }
        let noteId = envNoteId ?? UUID()
        return NoteImageStore.thumbnailURL(for: target, noteId: noteId)
            ?? NoteImageStore.resolveLocalURL(target, noteId: noteId)
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
/// (`URL: Identifiable` lives in StorageView.swift — one conformance only.)
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// Pinch-to-zoom image sheet for the reader. Pure SwiftUI — no
/// UIViewRepresentable, just a `MagnificationGesture` on a scroll view
/// frame.
struct ZoomableImageView: View {
    let url: URL
    let alt: String

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: url) { phase in
                if case .success(let img) = phase {
                    img
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let delta = value / lastScale
                                    lastScale = value
                                    scale = (scale * delta).clamped(to: 0.5...5)
                                }
                                .onEnded { _ in lastScale = 1.0 }
                        )
                        .gesture(
                            DragGesture()
                                .onChanged { gesture in
                                    offset = CGSize(
                                        width: lastOffset.width + gesture.translation.width,
                                        height: lastOffset.height + gesture.translation.height
                                    )
                                }
                                .onEnded { _ in lastOffset = offset }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation {
                                scale = 1
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .accessibilityLabel(alt)
    }
}

extension Comparable {
    fileprivate func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
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
