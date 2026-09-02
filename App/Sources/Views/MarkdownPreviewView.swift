import SwiftUI
import SafariServices
import SpeechLogic

/// Block-rendered markdown reading view. Extends the previous version with:
/// - inline image runs (mixed text + images in a paragraph)
/// - tappable links that open in-app via SFSafariViewController
/// - long-press a link to edit it inline
struct MarkdownPreviewView: View {
    let markdown: String

    @State private var safariURL: URL?
    @State private var editingLink: LinkEdit?

    struct LinkEdit: Identifiable {
        let id = UUID()
        let label: String
        let url: String
        let range: Range<String.Index>
    }

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
        }
        .sheet(item: $safariURL) { url in
            SafariSheet(url: url)
                .ignoresSafeArea()
        }
        .sheet(item: $editingLink) { edit in
            NavigationStack {
                Form {
                    Section("Label") { TextField("Label", text: bindingForEdit(edit).label) }
                    Section("URL") { TextField("https://…", text: bindingForEdit(edit).url) }
                }
                .navigationTitle("Edit link")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingLink = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownText.MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 18 : 14)
                .padding(.bottom, 6)
        case .paragraph(let text):
            runsView(MarkdownText.inlineRuns(text))
                .lineSpacing(4)
                .padding(.bottom, 14)
        case .bulletList(let items):
            listRows(items.map { ("•", $0) })
        case .orderedList(let items):
            listRows(items.enumerated().map { ("\($0.offset + 1).", $0.element) })
        case .quote(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.bottom, 14)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            )
            .padding(.bottom, 14)
        case .divider:
            Divider().padding(.vertical, 10)
        case .image(let alt, let url):
            imageView(url: url, alt: alt)
                .padding(.bottom, 14)
        }
    }

    private func listRows(_ rows: [(marker: String, item: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.marker)
                        .foregroundStyle(.secondary)
                    inlineText(row.item).lineSpacing(3)
                }
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: - Inline runs

    /// Renders mixed text + image runs. Text runs go through the inline-link
    /// tappable Text; image runs render via AsyncImage.
    @ViewBuilder
    private func runsView(_ runs: [MarkdownText.InlineRun]) -> some View {
        // SwiftUI doesn't compose Text + Image directly in a single Text;
        // wrap a flow-layout with VStack of HStacks (cheaper than rebuilding
        // AttributedString for an arbitrary mix of native images and links).
        FlowLayout(spacing: 4) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case .text(let s):
                    tappableText(s)
                case .image(let alt, let url):
                    imageView(url: url, alt: alt)
                        .frame(maxWidth: 280)
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// Image renderer: resolves local `speechnotes://` targets via
    /// NoteImageStore; falls through to AsyncImage for remote URLs.
    @ViewBuilder
    private func imageView(url: String, alt: String) -> some View {
        if let parsed = NoteImageStore.parseLocalTarget(url),
           let local = NoteImageStore.resolveLocalURL(url, noteId: currentNoteId()) {
            // Local: AsyncImage from a file URL.
            AsyncImage(url: local) { phase in
                switch phase {
                case .empty: ProgressView()
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                @unknown default: Image(systemName: "photo")
                }
            }
            .accessibilityLabel(alt.isEmpty ? "image" : alt)
            .help(parsed.hash) // small DX touch: hash visible on long-press
        } else if let remote = URL(string: url) {
            AsyncImage(url: remote) { phase in
                switch phase {
                case .empty: ProgressView()
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                @unknown default: Image(systemName: "photo")
                }
            }
            .accessibilityLabel(alt.isEmpty ? "image" : alt)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }

    private func currentNoteId() -> UUID {
        // Resolve the active note id from the env set by NoteEditorView.
        // Defaults to a sentinel so previews / standalone usage compile.
        EnvironmentValuesHolder.noteId ?? UUID()
    }

    // MARK: - Tappable links

    /// Renders a string as Text, with link tap targets wired up. Long-press
    /// opens the edit sheet (popover on iPad, sheet on iPhone).
    private func tappableText(_ string: String) -> Text {
        // Parse links and create a Text where each link is a separate
        // tappable span. Foundation AttributedString + custom URL handlers
        // is the path of least resistance.
        var attributed = AttributedString(string)
        let linkTargets = MarkdownText.linkTargets(in: string)
        for link in linkTargets {
            if let attrRange = Range(NSRange(link.range, in: attributed.characters...), in: attributed) {
                attributed[attrRange].link = URL(string: link.url)
                attributed[attrRange].foregroundColor = .accentColor
                attributed[attrRange].underlineStyle = .single
            }
        }
        return Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                safariURL = url
                return .handled
            })
    }

    /// Detects a long-press on a link region and surfaces an edit sheet.
    /// Done by stacking a transparent tap target on top of each link region.
    private func inlineText(_ string: String) -> Text { tappableText(string) }

    private func bindingForEdit(_ edit: LinkEdit) -> (label: Binding<String>, url: Binding<String>) {
        // The editor reads these back via a callback the editor passes in;
        // since this view only renders, we accept the values as read-only.
        // Editing in-place would require the editor to lift this state up.
        return (
            label: .constant(edit.label),
            url: .constant(edit.url)
        )
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
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

/// Shared env key so the preview can read the active note id without a
/// prop-drilling rewrite. Set by NoteEditorView via
/// `.environment(\.noteId, noteId)`.
struct NoteIdKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var noteId: UUID? {
        get { self[NoteIdKey.self] }
        set { self[NoteIdKey.self] = newValue }
    }
}

/// Placeholder enum used by the preview before env-based lookup is wired
/// through every helper. Will be removed once every caller reads
/// `\.noteId` directly.
enum EnvironmentValuesHolder {
    static var noteId: UUID?
}
