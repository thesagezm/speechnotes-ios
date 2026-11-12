import SwiftUI
import WebKit
import SpeechLogic
import SlideDeckKit

/// The slide-deck reader: the deck is shown AS THE DECK — every slide laid
/// out as PowerPoint laid it out, never flattened to extracted text and
/// never converted to EPUB. The resolved deck (SlideDeckKit) is rendered as
/// one HTML document in a WKWebView — the Linux reader's exact pipeline
/// (`sn-ui/src/slideview/document.rs` + `script.rs`), retargeted to iOS:
/// media rides the `deck://media/<index>` scheme handler, the injected
/// script reports `slidechanged:<n>` through the `snslides` message handler,
/// and one slide is one speech chapter.
struct BookSlidesView: View {
    let book: Book
    let store: BooksStore
    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var appTheme: AppTheme
    @Environment(\.scenePhase) private var scenePhase
    /// Visual reading time — the same fold pattern as the other readers.
    @State private var readingRecorder = StatsRecorder(kind: .reading)

    @State private var slideIndex: Int
    @State private var slideCount: Int
    @State private var showingTOC = false
    @State private var errorMessage: String?
    /// The rendered deck document (nil until the parse lands — the parse is
    /// the expensive part and runs off main, like every book open).
    @State private var deckHTML: String?
    /// The parsed deck's media, served to the webview through the scheme
    /// handler (kept alive beside the HTML that references it).
    @State private var deckMedia: [DeckMedia] = []
    @State private var webView: WKWebView?
    /// True once the deck document finished loading — a slide jump issued
    /// before it is held and retried (the epub reader's pendingJump rule).
    @State private var webViewReady = false
    /// The slide whose position was last written to the manifest — the
    /// script's scroll reporting fires on every settled scroll, and only a
    /// slide CHANGE persists.
    @State private var persistedSlide: Int
    /// A slide jump requested before the deck finished parsing.
    @State private var pendingSlide: Int?
    @AppStorage("readAlongEnabled") private var readAlongEnabled = true
    /// While THIS book speaks (and read-along is on) the webview surface
    /// swaps to the native ReadAlongView — the epub reader's exact pattern.
    private var showsReadAlong: Bool {
        readAlongEnabled
            && player.readAlongActive
            && player.nowPlayingBookId == book.id.uuidString
    }

    init(book: Book, store: BooksStore) {
        self.book = book
        self.store = store
        let saved = book.position
        _slideIndex = State(initialValue: saved?.chapterIndex ?? 0)
        _persistedSlide = State(initialValue: saved?.chapterIndex ?? -1)
        _slideCount = State(initialValue: book.spineCount ?? 0)
    }

    private var chapterIsActive: Bool {
        player.nowPlayingBookId == book.id.uuidString
    }

    /// The book's CURRENT manifest entry (the backfill can refresh the TOC
    /// after the reader was handed its snapshot — the PDF reader's liveBook
    /// pattern).
    private var liveBook: Book {
        store.books.first(where: { $0.id == book.id })
            ?? store.deletedBooks.first(where: { $0.id == book.id })
            ?? book
    }

    private var toc: [BookTocEntry] {
        liveBook.toc ?? book.toc ?? []
    }

    /// Tap-to-hide chrome — PER-SURFACE storage (round 5).
    @AppStorage("immersiveBars.deck") private var immersiveBarsHidden = false
    /// Portrait bottom controls collapsed to the Notes-style pill (shared
    /// with the other book readers).
    @AppStorage("bookBarMinimized") private var bookBarMinimized = false

    /// Reader surface + playback controls, arranged per orientation — the
    /// same guided-rotation shape as the EPUB/PDF readers: one
    /// GeometryReader, one content identity, an explicit transition.
    @ViewBuilder
    private var readerLayout: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack(alignment: .bottom) {
                if landscape {
                    HStack(spacing: 0) {
                        readerSurface
                            .layoutPriority(-1)
                        railPlayerBar
                            .layoutPriority(1)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    readerSurface
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            VStack(spacing: 0) {
                                if !bookBarMinimized {
                                    slideBar
                                }
                                playerBar
                            }
                        }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: landscape)
        }
    }

    /// Trailing rail for landscape — the book twin of the note editor's rail.
    private var railPlayerBar: some View {
        PlaybackRail(
            action: PlaybackRail.Action(
                onChangeVoice: nil,
                onTogglePlay: {
                    Task {
                        await BookPlaybackController.shared.togglePlay(
                            book: book,
                            chapterIndex: slideIndex
                        )
                    }
                },
                onStop: { player.stop() },
                onToggleReadAlong: { readAlongEnabled.toggle() },
                readAlongOn: readAlongEnabled,
                rate: player.rateMultiplier,
                onRateChange: { player.rateMultiplier = $0 },
                onStepBack: { goSlide(slideIndex - 1) },
                onStepForward: { goSlide(slideIndex + 1) },
                stepLabel: slideCount > 0 ? "Slide \(slideIndex + 1)/\(slideCount)" : nil,
                stepBackEnabled: slideIndex > 0,
                stepForwardEnabled: slideCount == 0 || slideIndex < slideCount - 1
            ),
            voiceLabel: player.currentVoiceDescription,
            progress: player.progress,
            isGenerating: chapterIsActive && player.state == .generating,
            isPlayEnabled: true,
            sessionActive: chapterIsActive
                && (player.state == .speaking || player.state == .paused || player.state == .generating),
            isSpeaking: chapterIsActive && player.state == .speaking
        )
    }

    var body: some View {
        readerLayout
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(immersiveBarsHidden ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        showingTOC = true
                    } label: {
                        Label("Slides", systemImage: "sidebar.leading")
                    }
                }
            }
            .sheet(isPresented: $showingTOC) {
                tocSheet
            }
            .sheet(isPresented: exportShareBinding) {
                if let url = player.shareURL {
                    ShareSheet(items: [url])
                }
            }
            .alert(
                "Couldn't open deck",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error.")
            }
            .keepScreenAwake(.pdfReader)
            .onAppear {
                store.markOpened(book)
                readingRecorder.begin(subjectId: book.id.uuidString)
                player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
            }
            .onChange(of: player.nowPlayingBookId) { _ in
                player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    readingRecorder.begin(subjectId: book.id.uuidString)
                case .background:
                    readingRecorder.end()
                default:
                    readingRecorder.end()
                }
            }
            .onDisappear {
                player.miniPlayerSuppressed = false
                readingRecorder.end()
            }
            .task {
                await loadDeck()
            }
    }

    // MARK: - Deck load

    /// Parses the deck OFF the main actor and renders the whole-deck HTML
    /// once. A deck that cannot be parsed says so — it never falls back to
    /// an EPUB flattening, which is the thing this reader exists to prevent.
    private func loadDeck() async {
        guard deckHTML == nil else { return }
        let archiveURL = BooksStore.originalFileURL(book)
        let ext = book.format.fileExtension
        let rendered: (html: String, media: [DeckMedia])? = await Task.detached(priority: .userInitiated) { () -> (String, [DeckMedia])? in
            guard let data = try? Data(contentsOf: archiveURL, options: .mappedIfSafe) else { return nil }
            do {
                let deck = try DeckParser.parse(data)
                return (DeckHTML.deckHTML(deck), deck.media)
            } catch SlideError.encrypted {
                return nil
            } catch {
                Log.shared.error("BookSlides: \(ext) deck of \(book.title) failed to render: \(error)")
                return nil
            }
        }.value
        guard let rendered else {
            errorMessage = book.importError ?? "This \(ext.uppercased()) could not be opened as a slide deck."
            return
        }
        deckHTML = rendered.html
        deckMedia = rendered.media
        slideCount = max(slideCount, book.spineCount ?? 0)
    }

    // MARK: - Reader surface (read-along swap + deck webview + veil)

    private var readerSurface: some View {
        Group {
            if showsReadAlong {
                ReadAlongView(
                    text: player.activeSpeechText ?? "",
                    activeRange: player.readAlongRange,
                    textScale: appTheme.previewTextScale,
                    onTapParagraph: { offset in
                        Haptics.tap()
                        player.playFrom(
                            player.activeSpeechText ?? "",
                            at: offset,
                            book: SpeechPlayer.BookPlaybackRef(
                                id: book.id.uuidString,
                                title: book.title,
                                chapterIndex: slideIndex
                            )
                        )
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.tap()
                    immersiveBarsHidden.toggle()
                }
            } else if let html = deckHTML {
                DeckWebView(
                    html: html,
                    media: deckMedia,
                    startSlide: slideIndex,
                    onSlideChanged: handleSlideChanged,
                    onReady: { webView = $0; applyPendingSlide() },
                    onChromeTap: {
                        Haptics.tap()
                        immersiveBarsHidden.toggle()
                    }
                )
            } else if errorMessage == nil {
                openingVeil
            }
        }
    }

    private var openingVeil: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Opening deck…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// The deck scrolled (or stepped) to another slide: the position records
    /// like a chapter's, debounced to actual CHANGES (the script reports on
    /// every settled scroll).
    private func handleSlideChanged(_ index: Int) {
        guard index >= 0 else { return }
        slideIndex = index
        if index != persistedSlide {
            persistedSlide = index
            store.updatePosition(book, chapterIndex: index, chapterFraction: 0)
        }
    }

    private func applyPendingSlide() {
        webViewReady = true
        if let pending = pendingSlide {
            pendingSlide = nil
            goSlide(pending)
        } else if slideIndex > 0 {
            goSlide(slideIndex)
        }
    }

    private func goSlide(_ index: Int) {
        guard index >= 0, slideCount == 0 || index < slideCount else { return }
        guard webViewReady, let webView else {
            // The webview is still loading the document: hold the jump and
            // run it when the deck lands (the epub reader's pendingJump).
            pendingSlide = index
            slideIndex = index
            return
        }
        slideIndex = index
        webView.evaluateJavaScript("__snslides.show(\(index))", completionHandler: nil)
    }

    // MARK: - Bars and sheets

    private var slideBar: some View {
        HStack(spacing: 16) {
            Button {
                Haptics.tap()
                goSlide(slideIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(slideIndex <= 0)

            Spacer()
            Text(slideLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()

            Button {
                Haptics.tap()
                goSlide(slideIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(slideCount > 0 && slideIndex >= slideCount - 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var slideLabel: String {
        slideCount > 0 ? "Slide \(slideIndex + 1) of \(slideCount)" : "Slide \(slideIndex + 1)"
    }

    private var playerBar: some View {
        BookPlayerBar(
            book: book,
            chapterIndex: slideIndex,
            player: player,
            onToggle: {
                Task {
                    await BookPlaybackController.shared.togglePlay(
                        book: book,
                        chapterIndex: slideIndex
                    )
                }
            },
            onExport: {
                Task {
                    await BookPlaybackController.shared.exportChapter(
                        book: book,
                        chapterIndex: slideIndex
                    )
                }
            },
            onStepBack: { goSlide(slideIndex - 1) },
            onStepForward: { goSlide(slideIndex + 1) },
            stepBackEnabled: slideIndex > 0,
            stepForwardEnabled: slideCount == 0 || slideIndex < slideCount - 1
        )
    }

    private var tocSheet: some View {
        NavigationStack {
            List(Array(toc.enumerated()), id: \.offset) { row in
                Button {
                    Haptics.tap()
                    showingTOC = false
                    goSlide(row.element.spineIndex ?? row.offset)
                } label: {
                    HStack {
                        Text(row.element.label)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        Spacer()
                        if row.offset == slideIndex {
                            Image(systemName: "speaker.wave.2")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Slides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingTOC = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var exportShareBinding: Binding<Bool> {
        Binding(
            get: { player.shareURL != nil },
            set: { if !$0 { player.shareURL = nil } }
        )
    }
}

// MARK: - Deck webview

/// One WKWebView carrying the whole-deck document. Media rides the
/// `deck://media/<index>` scheme handler; the injected script reports
/// `slidechanged:<n>` (scroll) and `chromeTap` (tap-to-hide-chrome) through
/// the `snslides` message handler.
private struct DeckWebView: UIViewRepresentable {
    let html: String
    let media: [DeckMedia]
    let startSlide: Int
    let onSlideChanged: (Int) -> Void
    let onReady: (WKWebView) -> Void
    let onChromeTap: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "snslides")
        config.setURLSchemeHandler(DeckMediaSchemeHandler(media: media), forURLScheme: DeckHTML.mediaScheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.callbacks = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(callbacks: self)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var callbacks: DeckWebView
        private var reportedReady = false

        init(callbacks: DeckWebView) {
            self.callbacks = callbacks
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "snslides", let body = message.body as? String else { return }
            // The delegate callback is not MainActor — bridge into one, like
            // BookWebView's coordinator does, so the view-state closures run
            // on the main actor.
            Task { @MainActor [weak self] in
                self?.handleMessage(body)
            }
        }

        @MainActor private func handleMessage(_ body: String) {
            if body.hasPrefix("slidechanged:") {
                let index = Int(body.dropFirst("slidechanged:".count)) ?? -1
                callbacks.onSlideChanged(index)
            } else if body.hasPrefix("chromeTap") {
                callbacks.onChromeTap()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !reportedReady else { return }
            reportedReady = true
            // Fit the whole slide first — the reader chrome decides the
            // mode later; the script recomputes on every resize.
            webView.evaluateJavaScript("__snslides.setFit('page', 1)", completionHandler: nil)
            webView.evaluateJavaScript("__snslides.show(\(callbacks.startSlide))", completionHandler: nil)
            callbacks.onReady(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.shared.error("BookSlides: webview failed: \(error.localizedDescription)")
        }
    }
}

/// Serves the deck's own images to the webview: `deck://media/<index>/<name>`
/// (and the `…/fill` spelling a picture FILL uses) resolves to the parsed
/// deck's media entry at `<index>`.
private final class DeckMediaSchemeHandler: NSObject, WKURLSchemeHandler {
    private let media: [DeckMedia]

    init(media: [DeckMedia]) {
        self.media = media
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        // deck://media/<index>/<name>
        let parts = url?.path.split(separator: "/").map(String.init) ?? []
        guard parts.first.flatMap(Int.init) != nil, !parts.isEmpty,
              let index = Int(parts[0]), index >= 0, index < media.count else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let entry = media[index]
        let data = Data(entry.data)
        let response = URLResponse(
            url: url ?? URL(string: "\(DeckHTML.mediaScheme)://media/\(index)")!,
            mimeType: entry.contentType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
