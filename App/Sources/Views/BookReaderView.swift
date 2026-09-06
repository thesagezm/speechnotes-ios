import SwiftUI
import WebKit

/// The EPUB reader: vendored epub.js in a single WKWebView (BookWebView),
/// chapter-paged scroll flow. TOC and appearance are native sheets; position
/// (chapter + scroll fraction) persists to the book's manifest so reopening
/// a book resumes where it left off. TTS rides on top of this later — the
/// chapter text pipeline hooks into the same bridge.
struct BookReaderView: View {
    let book: Book
    let store: BooksStore
    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var appTheme: AppTheme

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var chapterIndex: Int
    @State private var chapterFraction: Double
    @State private var totalChapters: Int
    @State private var toc: [BookTocEntry] = []
    @State private var showingTOC = false
    @State private var showingAppearance = false
    @State private var errorMessage: String?
    /// True once the web book reported its first relocated event — the
    /// loading veil hides the un-themed (black) webview until then.
    @State private var bookLoaded = false
    @AppStorage("bookReaderTheme") private var theme = "light"
    @AppStorage("bookReaderFontSize") private var fontSize = 100.0
    @AppStorage("readAlongEnabled") private var readAlongEnabled = true
    /// While THIS book speaks (and read-along is on) the webview surface
    /// swaps to the native ReadAlongView — the exact pattern the note editor
    /// uses, driven by the same SpeechPlayer signals.
    private var showsReadAlong: Bool {
        readAlongEnabled
            && player.readAlongActive
            && player.nowPlayingBookId == book.id.uuidString
    }
    /// The chapter whose position was last written to the manifest —
    /// relocated fires on every scroll tick; only chapter changes persist.
    @State private var persistedChapter: Int

    init(book: Book, store: BooksStore) {
        self.book = book
        self.store = store
        let saved = book.position
        _chapterIndex = State(initialValue: saved?.chapterIndex ?? 0)
        _chapterFraction = State(initialValue: saved?.chapterFraction ?? 0)
        _persistedChapter = State(initialValue: saved?.chapterIndex ?? -1)
        _totalChapters = State(initialValue: book.spineCount ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            readerSurface
            chapterBar
            playerBar
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.tap()
                    showingTOC = true
                } label: {
                    Label("Contents", systemImage: "sidebar.leading")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingAppearance = true
                } label: {
                    Label("Appearance", systemImage: "textformat.size")
                }
            }
        }
        .sheet(isPresented: $showingTOC) {
            tocSheet
        }
        .sheet(isPresented: $showingAppearance) {
            appearanceSheet
        }
        .sheet(isPresented: exportShareBinding) {
            if let url = player.shareURL {
                ShareSheet(items: [url])
            }
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: {
                    if case .failed = player.exportState { return true }
                    return false
                },
                set: { if !$0 { player.dismissExportError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .alert(
            "Couldn't open book",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error.")
        }
        .onAppear {
            store.markOpened(book)
            // The reader shows its own player bar — the global mini-player
            // yields while THIS book is the one speaking (editor pattern).
            player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
        }
        .onChange(of: player.nowPlayingBookId) { _ in
            player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
        }
        .onDisappear {
            player.miniPlayerSuppressed = false
            persistPosition()
            // Tear the web book down so its parsed spine doesn't linger.
            webView?.evaluateJavaScript("readerDestroy()", completionHandler: nil)
        }
    }

    // MARK: - Reader surface (read-along swap + webview + veil)

    /// While this book speaks with read-along on, the webview surface swaps
    /// to the native ReadAlongView (the editor's exact pattern).
    private var readerSurface: some View {
        Group {
            if showsReadAlong {
                ReadAlongView(
                    text: player.activeSpeechText ?? "",
                    activeRange: player.readAlongRange,
                    textScale: appTheme.previewTextScale
                )
            } else {
                webSurface
            }
        }
    }

    private var webSurface: some View {
        BookWebView(
            book: book,
            startChapter: chapterIndex,
            startTheme: theme,
            startFontSize: Int(fontSize),
            onRelocated: handleRelocated,
            onTOC: { toc = $0 },
            onError: { errorMessage = $0 },
            onWebViewReady: { webView = $0 }
        )
        .overlay {
            if !bookLoaded {
                openingVeil
            }
        }
    }

    private var openingVeil: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Opening book…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(veilColor)
    }

    private var veilColor: Color {
        switch theme {
        case "dark": return .black
        case "sepia": return Color(red: 0.96, green: 0.94, blue: 0.89)
        default: return Color(.systemBackground)
        }
    }

    private var playerBar: some View {
        BookPlayerBar(
            book: book,
            chapterIndex: chapterIndex,
            player: player,
            onToggle: {
                Task {
                    await BookPlaybackController.shared.togglePlay(
                        book: book,
                        chapterIndex: chapterIndex
                    )
                }
            },
            onExport: {
                Task {
                    await BookPlaybackController.shared.exportChapter(
                        book: book,
                        chapterIndex: chapterIndex
                    )
                }
            }
        )
    }

    /// Per-chapter WAV export lands in player.shareURL; the sheet shows the
    /// system share panel once it's there (note-export pattern).
    private var exportShareBinding: Binding<Bool> {
        Binding(
            get: { player.shareURL != nil },
            set: { if !$0 { player.shareURL = nil } }
        )
    }

    private var exportErrorMessage: String? {
        if case .failed(let message) = player.exportState { return message }
        return nil
    }

    // MARK: - Chapter bar

    private var chapterBar: some View {
        HStack(spacing: 16) {
            Button {
                Haptics.tap()
                goChapter(chapterIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(chapterIndex <= 0)

            Spacer()
            Text(chapterLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()

            Button {
                Haptics.tap()
                goChapter(chapterIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(totalChapters > 0 && chapterIndex >= totalChapters - 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var chapterLabel: String {
        if totalChapters > 0 {
            return "Chapter \(chapterIndex + 1) of \(totalChapters) · \(Int((chapterFraction * 100).rounded()))%"
        }
        return "\(Int((chapterFraction * 100).rounded()))%"
    }

    // MARK: - TOC sheet

    private var tocSheet: some View {
        NavigationStack {
            // Keyed by index, not href: real books point several TOC rows at
            // the same spine file (pg1342's first two entries do).
            List(Array(toc.enumerated()), id: \.offset) { _, entry in
                Button {
                    Haptics.tap()
                    showingTOC = false
                    goToHref(entry.href)
                } label: {
                    Text(entry.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingTOC = false }
                }
            }
            .overlay {
                if toc.isEmpty {
                    ContentUnavailableView(
                        "No table of contents",
                        systemImage: "list.bullet.rectangle",
                        description: Text("This book doesn't provide one; use the chapter arrows below.")
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Appearance sheet

    private var appearanceSheet: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: $theme) {
                        Text("Light").tag("light")
                        Text("Sepia").tag("sepia")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    LabeledContent("Text size", value: "\(Int(fontSize))%")
                    Slider(value: $fontSize, in: 70...200, step: 10)
                } footer: {
                    Text("Applies to the book pages. The read-along view follows the app's Reading View text size instead.")
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingAppearance = false }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { applyAppearance() }
        .onChange(of: theme) { _ in applyAppearance() }
        .onChange(of: fontSize) { _ in applyAppearance() }
    }

    // MARK: - Actions & plumbing

    private func handleRelocated(index: Int, fraction: Double, total: Int) {
        chapterIndex = max(0, index)
        chapterFraction = fraction
        if total > 0 { totalChapters = total }
        if !bookLoaded { bookLoaded = true }
        if index != persistedChapter {
            persistPosition()
        }
    }

    private func persistPosition() {
        persistedChapter = chapterIndex
        store.updatePosition(book, chapterIndex: chapterIndex, chapterFraction: chapterFraction)
    }

    private func goChapter(_ index: Int) {
        webView?.evaluateJavaScript("readerGoChapter(\(index))", completionHandler: nil)
    }

    private func goToHref(_ href: String) {
        // JSON-encode the href: it comes from book content, never trust it
        // as a raw JS literal.
        guard let encoded = try? String(
            data: JSONEncoder().encode(href),
            encoding: .utf8
        ) else { return }
        webView?.evaluateJavaScript("readerGoToHref(\(encoded))", completionHandler: nil)
    }

    private func applyAppearance() {
        applyAppearanceDebounced()
    }

    /// Slider drags fire onChange per 10% step — each one used to push two
    /// evaluateJavaScript calls straight into the webview. 150 ms after the
    /// drag settles is visually indistinguishable and keeps the bridge quiet.
    @State private var appearanceTask: Task<Void, Never>?

    private func applyAppearanceDebounced() {
        appearanceTask?.cancel()
        let size = Int(fontSize)
        let themeName = theme
        appearanceTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            webView?.evaluateJavaScript("readerFontSize(\(size))", completionHandler: nil)
            webView?.evaluateJavaScript("readerTheme(\"\(themeName)\")", completionHandler: nil)
        }
    }
}
