import SwiftUI
import PDFKit
import SpeechLogic

/// The PDF reader: PDFKit's own lazy engine at full fidelity (original
/// layout, images, fonts, zoom — the reason PDF gets a native viewer instead
/// of a text conversion). Outline sidebar comes from the PDF's outline tree;
/// position (page index + fraction) persists to the book manifest.
///
/// v1.5: TTS rides on the same machinery as the epub reader — chapters come
/// from the book's manifest (outline / heading / page-range resolved), play
/// starts at the chapter containing the current page. While the book speaks
/// (read-along toggle ON), the PDF view FOLLOWS the reading: as the sounding
/// sentence crosses into the next page the reader turns to it automatically,
/// with a brief "Page N" capsule as the turn cue (user request 2026-09-07 —
/// pages must advance themselves, not wait for a manual swipe). The mapping
/// comes from the per-page UTF-16 offsets sidecar the extraction writes;
/// without it the reader still follows at chapter granularity. PDFKit cannot
/// highlight mid-page, so pages — not words — are the follow unit.
struct BookPDFReaderView: View {
    let book: Book
    let store: BooksStore
    @EnvironmentObject private var player: SpeechPlayer

    @State private var currentPage: Int
    @State private var pageCount: Int
    @State private var pdfView: PDFView?
    @State private var outlineRows: [OutlineRow] = []
    @State private var showingOutline = false
    /// Per-page UTF-16 offsets of the PLAYING chapter's speech text, loaded
    /// from the sidecar written at extraction time.
    @State private var playingPageOffsets: [PdfPageOffset] = []
    /// Last page the follow turned to — guards against re-scrolling to the
    /// same page on every sentence tick.
    @State private var lastFollowedPage: Int?
    /// Brief "Page N" capsule shown when the follow turns the page.
    @State private var pageCue: Int?
    @State private var pageCueTask: Task<Void, Never>?
    @AppStorage("readAlongEnabled") private var readAlongEnabled = true

    init(book: Book, store: BooksStore) {
        self.book = book
        self.store = store
        let saved = book.position
        _currentPage = State(initialValue: saved?.chapterIndex ?? 0)
        _pageCount = State(initialValue: book.pageCount ?? 0)
    }

    private var thisBookIsSpeaking: Bool {
        player.nowPlayingBookId == book.id.uuidString && player.state != .idle
    }

    private var hasChapters: Bool {
        guard let chapters = book.pdfChapters else { return false }
        return !chapters.isEmpty
    }

    /// The manifest chapter containing the page on screen — where Listen
    /// starts (and what the player bar's controls act on).
    private var chapterForCurrentPage: Int? {
        guard let chapters = book.pdfChapters else { return nil }
        return chapters.firstIndex { currentPage >= $0.startPage && currentPage <= $0.endPage }
    }

    var body: some View {
        VStack(spacing: 0) {
            readerSurface
            pageBar
            if hasChapters {
                playerBar
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !outlineRows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showingOutline = true
                    } label: {
                        Label("Outline", systemImage: "sidebar.leading")
                    }
                }
            }
        }
        .sheet(isPresented: $showingOutline) {
            outlineSheet
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
        .onAppear {
            store.markOpened(book)
            outlineRows = Self.flattenOutline(book: book)
            // The reader has its own player bar — the global mini-player
            // yields while THIS book is the one speaking (editor pattern).
            player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
            // Arriving while the book already speaks (mini-player jump):
            // pick up the offsets so page-follow engages immediately.
            if thisBookIsSpeaking {
                loadPlayingChapterOffsets()
            }
        }
        .onChange(of: player.nowPlayingBookId) { _ in
            player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
        }
        // Playback starting/stopping while the reader is open — load or drop
        // the offsets so page-follow tracks the live chapter.
        .onChange(of: player.state) { _ in
            if thisBookIsSpeaking {
                loadPlayingChapterOffsets()
            } else {
                playingPageOffsets = []
                lastFollowedPage = nil
                pageCue = nil
            }
        }
        // Chapter text changes exactly when auto-advance moves to the next
        // chapter — refresh the offsets for the new unit.
        .onChange(of: player.activeSpeechText) { _ in
            if thisBookIsSpeaking {
                loadPlayingChapterOffsets()
            }
        }
        .onChange(of: player.readAlongRange?.lowerBound) { _ in
            followSoundingPage()
        }
        .onDisappear {
            player.miniPlayerSuppressed = false
            store.updatePosition(book, chapterIndex: currentPage, chapterFraction: 0)
        }
    }

    // MARK: - Reader surface (PDF view + page-turn cue)

    private var readerSurface: some View {
        BookPDFView(
            url: BooksStore.originalFileURL(book),
            startPageIndex: currentPage,
            onPageChange: handlePageChange,
            onReady: { pdfView = $0 }
        )
        .overlay(alignment: .top) {
            if let pageCue {
                Text("Page \(pageCue + 1)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: pageCue)
    }

    private var playerBar: some View {
        BookPlayerBar(
            book: book,
            chapterIndex: chapterForCurrentPage ?? 0,
            player: player,
            onToggle: {
                Task {
                    await BookPlaybackController.shared.togglePlay(
                        book: book,
                        chapterIndex: chapterForCurrentPage ?? 0
                    )
                }
            },
            onExport: {
                Task {
                    await BookPlaybackController.shared.exportChapter(
                        book: book,
                        chapterIndex: chapterForCurrentPage ?? 0
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

    // MARK: - Page bar

    private var pageBar: some View {
        HStack {
            Spacer()
            Text(pageCount > 0 ? "Page \(currentPage + 1) of \(pageCount)" : "PDF")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Outline

    private struct OutlineRow: Identifiable {
        let id: Int
        let label: String
        let depth: Int
        let destination: PDFDestination
    }

    /// Flattens the PDF outline tree depth-first. Runs once per open; big
    /// outlines are rare and cheap compared to the document itself. Walks
    /// via numberOfChildren/child(at:) — this SDK's PDFOutline has no
    /// `children` array (CI-caught).
    private static func flattenOutline(book: Book) -> [OutlineRow] {
        guard let root = PDFDocument(url: BooksStore.originalFileURL(book))?.outlineRoot else { return [] }
        var rows: [OutlineRow] = []
        func walk(_ outline: PDFOutline, depth: Int) {
            if let dest = outline.destination {
                rows.append(OutlineRow(
                    id: rows.count,
                    label: outline.label ?? "Untitled",
                    depth: depth,
                    destination: dest
                ))
            }
            for index in 0..<outline.numberOfChildren {
                if let child = outline.child(at: index) {
                    walk(child, depth: depth + 1)
                }
            }
        }
        for index in 0..<root.numberOfChildren {
            if let child = root.child(at: index) {
                walk(child, depth: 0)
            }
        }
        return rows
    }

    private var outlineSheet: some View {
        NavigationStack {
            List(outlineRows) { row in
                Button {
                    Haptics.tap()
                    showingOutline = false
                    pdfView?.go(to: row.destination)
                } label: {
                    Text(row.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, CGFloat(row.depth) * 14)
                }
            }
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingOutline = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func handlePageChange(pageIndex: Int, pageCount: Int) {
        currentPage = pageIndex
        if pageCount > 0 { self.pageCount = pageCount }
        store.updatePosition(book, chapterIndex: pageIndex, chapterFraction: 0)
    }

    // MARK: - Page follow

    /// Loads the playing chapter's page-offset sidecar (written when the
    /// chapter's speech text was first extracted). Idempotent — playback
    /// start, resume, and chapter auto-advance all call it.
    private func loadPlayingChapterOffsets() {
        let controller = BookPlaybackController.shared
        guard controller.isBookActive(book) else { return }
        let url = BooksStore.speechTextOffsetsURL(book, chapterIndex: controller.activeChapterIndex)
        Task {
            let offsets = await Task.detached(priority: .utility) { () -> [PdfPageOffset] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return (try? JSONDecoder().decode([PdfPageOffset].self, from: data)) ?? []
            }.value
            playingPageOffsets = offsets
            // The chapter may have STARTED on a page we're not showing (e.g.
            // the follow engaged mid-chapter after a mini-player jump) — turn
            // to the chapter's first sounding page right away.
            if lastFollowedPage == nil, let start = offsets.first {
                turnToSoundingPage(start.page)
            }
        }
    }

    /// The sounding sentence crossed a page boundary (or follow just
    /// engaged): turn the PDF view to the sounding page — with the brief
    /// "Page N" cue — while the read-along toggle is on.
    private func followSoundingPage() {
        guard readAlongEnabled, thisBookIsSpeaking, !playingPageOffsets.isEmpty,
              let start = player.readAlongRange?.lowerBound else { return }
        guard let page = playingPageOffsets.last(where: { $0.utf16Offset <= start })?.page else { return }
        turnToSoundingPage(page)
    }

    private func turnToSoundingPage(_ page: Int) {
        guard page != lastFollowedPage else { return }
        let turned = page != currentPage
        lastFollowedPage = page
        if turned {
            if let pdfView, let document = pdfView.document, page < document.pageCount,
               let target = document.page(at: page) {
                pdfView.go(to: target)
            }
            showPageCue(page)
        }
    }

    private func showPageCue(_ page: Int) {
        pageCue = page
        pageCueTask?.cancel()
        pageCueTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            pageCue = nil
        }
    }
}

/// PDFKit bridge. PDFDocument(url:) is lazy — page content loads as the user
/// scrolls, which is exactly why whole-document extraction stays out of the
/// book path.
private struct BookPDFView: UIViewRepresentable {
    let url: URL
    let startPageIndex: Int
    var onPageChange: (Int, Int) -> Void
    var onReady: (PDFView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
        context.coordinator.attach(pdfView)

        if startPageIndex > 0,
           let document = pdfView.document,
           startPageIndex < document.pageCount,
           let page = document.page(at: startPageIndex) {
            pdfView.go(to: page)
        }

        DispatchQueue.main.async { [onReady] in
            onReady(pdfView)
        }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
    }

    final class Coordinator {
        var onPageChange: (Int, Int) -> Void
        private var observer: NSObjectProtocol?
        private weak var pdfView: PDFView?

        init(onPageChange: @escaping (Int, Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func attach(_ pdfView: PDFView) {
            self.pdfView = pdfView
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                self?.report()
            }
        }

        private func report() {
            guard let pdfView, let document = pdfView.document else { return }
            let index = pdfView.currentPage.map { document.index(for: $0) } ?? 0
            onPageChange(index, document.pageCount)
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
