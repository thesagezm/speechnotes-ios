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

    /// Tap-to-hide chrome — shared app-wide (ImmersiveBars.swift).
    @AppStorage("immersiveBarsEnabled") private var immersiveBarsHidden = false

    /// Reader + playback, arranged per orientation — same guided-rotation
    /// shape as the EPUB reader: one GeometryReader, one content identity, an
    /// explicit transition between the two arrangements.
    @ViewBuilder
    private var readerLayout: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack(alignment: .bottom) {
                if landscape, hasChapters {
                    // The page bar returns to the bottom in landscape too
                    // ("steppers stay bottom") — it overlays the lower edge
                    // of the page surface.
                    ZStack(alignment: .bottom) {
                        HStack(spacing: 0) {
                            readerSurface
                            railPlayerBar
                        }
                        pageBar
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    VStack(spacing: 0) {
                        readerSurface
                        pageBar
                        if hasChapters {
                            playerBar
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: landscape)
        }
    }

    /// Trailing rail for landscape — PDF twin of the editor's rail, plus the
    /// per-chapter export button the portrait bar carries.
    private var railPlayerBar: some View {
        PlaybackRail(
            action: PlaybackRail.Action(
                onChangeVoice: nil,
                onTogglePlay: {
                    Task {
                        await BookPlaybackController.shared.togglePlay(
                            book: book,
                            chapterIndex: chapterForCurrentPage ?? 0
                        )
                    }
                },
                onStop: { player.stop() },
                onToggleReadAlong: { readAlongEnabled.toggle() },
                readAlongOn: readAlongEnabled,
                rate: player.rateMultiplier,
                onRateChange: { player.rateMultiplier = $0 }
            ),
            voiceLabel: player.currentVoiceDescription,
            progress: player.progress,
            isGenerating: chapterIsActive && player.state == .generating,
            isPlayEnabled: true,
            sessionActive: chapterIsActive
                && (player.state == .speaking || player.state == .paused || player.state == .generating),
            extraTrailing: AnyView(
                Button {
                    Haptics.tap()
                    Task {
                        await BookPlaybackController.shared.exportChapter(
                            book: book,
                            chapterIndex: chapterForCurrentPage ?? 0
                        )
                    }
                } label: {
                    if player.isExporting {
                        ProgressView()
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                }
                .buttonStyle(.plain)
                .disabled(player.isExporting)
                .accessibilityLabel("Export chapter audio")
            )
        )
    }

    private var chapterIsActive: Bool {
        player.nowPlayingBookId == book.id.uuidString
    }

    var body: some View {
        // Landscape: PDF pages keep the leading width, playback moves to a
        // trailing rail (per-chapter export rides along as the rail's extra
        // button). The page bar stays at the bottom in both orientations.
        readerLayout
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
        // Tap the page to hide/show the title + toolbar (immersive reading).
        .toolbar(immersiveBarsHidden ? .hidden : .visible, for: .navigationBar)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            immersiveBarsHidden.toggle()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingOutline = true
                } label: {
                    Label("Contents", systemImage: "sidebar.leading")
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
            Button {
                Haptics.tap()
                showingOutline = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("Contents")
            Spacer()
            Text(pageCount > 0 ? "Page \(currentPage + 1) of \(pageCount)" : "PDF")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            // Symmetric ghost of the Contents button keeps the page count
            // genuinely centered.
            Image(systemName: "list.bullet")
                .font(.body)
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Contents (outline + chapter fallback)

    private struct OutlineRow: Identifiable {
        let id: Int
        let label: String
        let depth: Int
        let destination: PDFDestination
        /// 0-based page the entry points at, resolved at flatten time so
        /// rows can show their page number and highlight the current one.
        let pageIndex: Int
    }

    /// Flattens the PDF outline tree depth-first. Runs once per open; big
    /// outlines are rare and cheap compared to the document itself. Walks
    /// via numberOfChildren/child(at:) — this SDK's PDFOutline has no
    /// `children` array (CI-caught). Entries whose destination does not
    /// resolve to a page are skipped: every row must be navigable.
    private static func flattenOutline(book: Book) -> [OutlineRow] {
        guard let document = PDFDocument(url: BooksStore.originalFileURL(book)),
              let root = document.outlineRoot else { return [] }
        var rows: [OutlineRow] = []
        func walk(_ outline: PDFOutline, depth: Int) {
            if let dest = outline.destination, let page = dest.page {
                rows.append(OutlineRow(
                    id: rows.count,
                    label: outline.label ?? "Untitled",
                    depth: depth,
                    destination: dest,
                    pageIndex: document.index(for: page)
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

    /// The row the reader should open scrolled to and highlight — the last
    /// entry at or before the visible page (readest's activeHref equivalent,
    /// keyed by page because PDF destinations are the only address we have).
    private var currentOutlineRowID: Int? {
        guard !outlineRows.isEmpty else { return nil }
        let beforeOrAt = outlineRows.prefix { $0.pageIndex <= currentPage }
        guard let last = beforeOrAt.last else { return outlineRows.first?.id }
        return last.id
    }

    /// The manifest chapter the visible page sits in — the fallback list's
    /// highlight (and the same data TTS speaks).
    private var currentChapterID: Int? {
        guard let chapters = book.pdfChapters else { return nil }
        return chapters.firstIndex { currentPage >= $0.startPage && currentPage <= $0.endPage }
    }

    /// The Contents sheet: the PDF's own outline with depth indentation and
    /// page numbers (what readest/anx-reader show), highlighted and
    /// auto-scrolled to the current position; for PDFs without an outline,
    /// the resolved TTS chapter list takes its place — never a dead button.
    private var outlineSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Group {
                    if !outlineRows.isEmpty {
                        List(outlineRows) { row in
                            Button {
                                Haptics.tap()
                                showingOutline = false
                                pdfView?.go(to: row.destination)
                            } label: {
                                HStack {
                                    Text(row.label)
                                        .font(.subheadline)
                                        .fontWeight(row.id == currentOutlineRowID ? .semibold : .regular)
                                        .foregroundStyle(row.id == currentOutlineRowID ? Color.accentColor : .primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Text("\(row.pageIndex + 1)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, CGFloat(row.depth) * 14)
                            }
                        }
                    } else if let chapters = book.pdfChapters, !chapters.isEmpty {
                        List(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                            Button {
                                Haptics.tap()
                                showingOutline = false
                                if let pdfView, let document = pdfView.document,
                                   let page = document.page(at: chapter.startPage) {
                                    pdfView.go(to: page)
                                }
                            } label: {
                                HStack {
                                    Text(chapter.label)
                                        .font(.subheadline)
                                        .fontWeight(index == currentChapterID ? .semibold : .regular)
                                        .foregroundStyle(index == currentChapterID ? Color.accentColor : .primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(chapter.endPage > chapter.startPage
                                         ? "pp. \(chapter.startPage + 1)–\(chapter.endPage + 1)"
                                         : "p. \(chapter.startPage + 1)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        List {
                            Text("This PDF has no outline or chapters.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onAppear {
                    // Open scrolled to where the reader is (readest centers
                    // the active row; the anchor picks whichever is closer).
                    if let id = currentOutlineRowID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .navigationTitle("Contents")
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
