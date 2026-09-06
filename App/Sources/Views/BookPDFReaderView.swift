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
/// starts at the chapter containing the current page, and while the book
/// speaks with read-along on, the PDF surface swaps to the native
/// ReadAlongView. PDFKit cannot highlight mid-page anyway, so read-along
/// tracks by PAGE: on return from read-along the reader jumps to the page
/// that was sounding (via the per-page offsets sidecar the extraction writes).
struct BookPDFReaderView: View {
    let book: Book
    let store: BooksStore
    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var appTheme: AppTheme

    @State private var currentPage: Int
    @State private var pageCount: Int
    @State private var pdfView: PDFView?
    @State private var outlineRows: [OutlineRow] = []
    @State private var showingOutline = false
    /// Page whose text was last sounding during read-along — applied to the
    /// PDFView when read-along ends (the surface is swapped out while active,
    /// so there is nothing to scroll under the text).
    @State private var soundingPage: Int?
    /// Per-page UTF-16 offsets of the PLAYING chapter's speech text, loaded
    /// from the sidecar written at extraction time.
    @State private var playingPageOffsets: [PdfPageOffset] = []
    @AppStorage("readAlongEnabled") private var readAlongEnabled = true

    init(book: Book, store: BooksStore) {
        self.book = book
        self.store = store
        let saved = book.position
        _currentPage = State(initialValue: saved?.chapterIndex ?? 0)
        _pageCount = State(initialValue: book.pageCount ?? 0)
    }

    private var showsReadAlong: Bool {
        readAlongEnabled
            && player.readAlongActive
            && player.nowPlayingBookId == book.id.uuidString
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
        }
        .onChange(of: player.nowPlayingBookId) { _ in
            player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
        }
        .onChange(of: showsReadAlong) { active in
            if active {
                loadPlayingChapterOffsets()
            } else {
                returnToSoundingPage()
            }
        }
        // Chapter text changes exactly when auto-advance moves to the next
        // chapter — refresh the offsets for the new unit.
        .onChange(of: player.activeSpeechText) { _ in
            if showsReadAlong {
                loadPlayingChapterOffsets()
            }
        }
        .onChange(of: player.readAlongRange?.lowerBound) { _ in
            trackSoundingPage()
        }
        .onDisappear {
            player.miniPlayerSuppressed = false
            store.updatePosition(book, chapterIndex: currentPage, chapterFraction: 0)
        }
    }

    // MARK: - Reader surface (read-along swap + PDF view)

    @ViewBuilder private var readerSurface: some View {
        if showsReadAlong {
            ReadAlongView(
                text: player.activeSpeechText ?? "",
                activeRange: player.readAlongRange,
                textScale: appTheme.previewTextScale
            )
        } else {
            BookPDFView(
                url: BooksStore.originalFileURL(book),
                startPageIndex: currentPage,
                onPageChange: handlePageChange,
                onReady: { pdfView = $0 }
            )
        }
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

    // MARK: - Read-along page tracking

    /// Loads the playing chapter's page-offset sidecar (written when the
    /// chapter's speech text was first extracted).
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
        }
    }

    /// Records which page the sounding sentence belongs to (no live scroll —
    /// the PDF view is swapped out while read-along shows the text).
    private func trackSoundingPage() {
        guard showsReadAlong, !playingPageOffsets.isEmpty,
              let start = player.readAlongRange?.lowerBound else { return }
        if let page = playingPageOffsets.last(where: { $0.utf16Offset <= start })?.page {
            soundingPage = page
        }
    }

    /// Read-along ended: land the reader on the page that was sounding.
    private func returnToSoundingPage() {
        defer {
            playingPageOffsets = []
            soundingPage = nil
        }
        guard let page = soundingPage, page != currentPage else { return }
        currentPage = page
        if let pdfView, let document = pdfView.document, let target = document.page(at: page) {
            pdfView.go(to: target)
        }
        store.updatePosition(book, chapterIndex: page, chapterFraction: 0)
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
