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
    @Environment(\.scenePhase) private var scenePhase
    /// Visual reading time — same fold pattern as the epub reader.
    @State private var readingRecorder = StatsRecorder(kind: .reading)

    @State private var currentPage: Int
    @State private var pageCount: Int
    @State private var pdfView: PDFView?
    @State private var outlineRows: [OutlineRow] = []
    @State private var showingOutline = false
    /// True until the reader's document lands — the open itself is the
    /// expensive part and runs off main (see BookPDFView), so the surface
    /// says so instead of sitting blank.
    @State private var pdfLoading = true
    /// Collapsed outline row ids (round 6: the TOC is a drop-down tree —
    /// entries with children get a chevron and fold their subtree).
    @State private var collapsedOutlineRows: Set<Int> = []
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

    /// Tap-to-hide chrome — PER-SURFACE storage (round 5): each reader hides
    /// and shows its own title bar; the old app-wide key stranded hidden
    /// bars across surfaces.
    @AppStorage("immersiveBars.pdf") private var immersiveBarsHidden = false

    /// Reader + playback, arranged per orientation — same guided-rotation
    /// shape as the EPUB reader: one GeometryReader, one content identity, an
    /// explicit transition between the two arrangements.
    @ViewBuilder
    private var readerLayout: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack(alignment: .bottom) {
                if landscape, hasChapters {
                    // Round 6: the bottom page-number band is GONE in
                    // landscape — it covered the page it named (user
                    // request). The toolbar and the TOC carry navigation;
                    // the rail carries playback.
                    HStack(spacing: 0) {
                        readerSurface
                        railPlayerBar
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
    /// per-chapter export button the portrait bar carries. The page stepper
    /// rides the rail (v1.7.2): the portrait pageBar has the chevrons, the
    /// landscape layout has no bottom band, and prev/next were missing here.
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
                onRateChange: { player.rateMultiplier = $0 },
                onStepBack: { goToPage(currentPage - 1) },
                onStepForward: { goToPage(currentPage + 1) },
                stepLabel: pageCount > 0 ? "Page \(currentPage + 1)/\(pageCount)" : nil,
                stepBackEnabled: currentPage > 0,
                stepForwardEnabled: pageCount == 0 || currentPage < pageCount - 1
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
            readingRecorder.begin(subjectId: book.id.uuidString)
            // The reader has its own player bar — the global mini-player
            // yields while THIS book is the one speaking (editor pattern).
            player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
        }
        .onChange(of: player.nowPlayingBookId) { _ in
            player.miniPlayerSuppressed = player.nowPlayingBookId == book.id.uuidString
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: readingRecorder.begin(subjectId: book.id.uuidString)
            default: readingRecorder.end()
            }
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
            readingRecorder.end()
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
            GeometryReader { geo in
                ZStack {
                    BookPDFView(
                        url: BooksStore.originalFileURL(book),
                        fitWidth: geo.size.width,
                        startPageIndex: currentPage,
                        onPageChange: handlePageChange,
                        onReady: {
                            pdfView = $0
                            // A fresh surface identity is loading again (the
                            // read-along swap remakes this view on return).
                            pdfLoading = true
                        },
                        onDocumentLoaded: { pdfLoading = false },
                        onOutlineLoaded: { outlineRows = $0 }
                    )
                    if pdfLoading {
                        ProgressView()
                    }
                }
            }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Contents (outline + chapter fallback)

    /// The row the reader should open scrolled to and highlight — the last
    /// entry at or before the visible page (readest's activeHref equivalent,
    /// keyed by page because PDF destinations are the only address we have).
    private var currentOutlineRowID: Int? {
        guard !outlineRows.isEmpty else { return nil }
        let beforeOrAt = outlineRows.prefix { $0.pageIndex <= currentPage }
        guard let last = beforeOrAt.last else { return outlineRows.first?.id }
        return last.id
    }

    /// True when the row has direct children (depth + 1) before the next
    /// sibling — drives the drop-down chevron.
    private func outlineHasChildren(_ id: Int) -> Bool {
        guard let index = outlineRows.firstIndex(where: { $0.id == id }) else { return false }
        let depth = outlineRows[index].depth
        var cursor = index + 1
        while cursor < outlineRows.count, outlineRows[cursor].depth > depth {
            if outlineRows[cursor].depth == depth + 1 { return true }
            cursor += 1
        }
        return false
    }

    /// The outline minus every subtree under a collapsed row. A stack of
    /// collapsed depths: a row is hidden while it sits strictly deeper than
    /// any still-collapsed ancestor.
    private var visibleOutlineRows: [OutlineRow] {
        var collapsedDepths: [Int] = []
        var out: [OutlineRow] = []
        for row in outlineRows {
            while let top = collapsedDepths.last, row.depth <= top {
                collapsedDepths.removeLast()
            }
            if let top = collapsedDepths.last, row.depth > top {
                continue // under a collapsed ancestor
            }
            out.append(row)
            if collapsedOutlineRows.contains(row.id) {
                collapsedDepths.append(row.depth)
            }
        }
        return out
    }

    /// The manifest chapter the visible page sits in — the fallback list's
    /// highlight (and the same data TTS speaks).
    private var currentChapterID: Int? {
        guard let chapters = book.pdfChapters else { return nil }
        return chapters.firstIndex { currentPage >= $0.startPage && currentPage <= $0.endPage }
    }

    /// The Contents sheet: the PDF's own outline as a DROP-DOWN TREE —
    /// entries with children carry a chevron and fold their subtree (user
    /// request; every desktop reader shows outlines this way). All levels
    /// start expanded; depth indentation + page numbers + current highlight
    /// stay. For PDFs without an outline, the resolved TTS chapter list
    /// takes its place — never a dead button.
    private var outlineSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Group {
                    if !outlineRows.isEmpty {
                        List(visibleOutlineRows) { row in
                            HStack(spacing: 6) {
                                Button {
                                    Haptics.tap()
                                    showingOutline = false
                                    goToPage(row.pageIndex)
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
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if outlineHasChildren(row.id) {
                                    Button {
                                        Haptics.tap()
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if collapsedOutlineRows.contains(row.id) {
                                                collapsedOutlineRows.remove(row.id)
                                            } else {
                                                collapsedOutlineRows.insert(row.id)
                                            }
                                        }
                                    } label: {
                                        Image(systemName: collapsedOutlineRows.contains(row.id) ? "chevron.right" : "chevron.down")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 26, height: 26)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(collapsedOutlineRows.contains(row.id) ? "Expand section" : "Collapse section")
                                }
                            }
                        }
                    } else if let chapters = book.pdfChapters, !chapters.isEmpty {
                        List(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                            Button {
                                Haptics.tap()
                                showingOutline = false
                                goToPage(chapter.startPage)
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

    /// Navigates by PAGE INDEX, not by the outline's PDFDestination. The
    /// outline rows were flattened on the background pass that opened the
    /// document, and rows carry only the resolved page index (a destination
    /// kept across documents silently does nothing in PDFKit — the round-5
    /// "TOC taps don't go to the page, in-book links do" report). The page
    /// index is instance-independent; resolving it in the reader's own
    /// document always lands.
    private func goToPage(_ index: Int) {
        guard let pdfView, let document = pdfView.document,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else {
            Log.shared.info("PDFContents: cannot jump — page \(index + 1) of \(book.pageCount ?? 0) not resolvable")
            return
        }
        pdfView.go(to: page)
        currentPage = index
        store.updatePosition(book, chapterIndex: index, chapterFraction: 0)
        // A go(to:) issued while the Contents sheet is still animating away
        // can be dropped by PDFKit (the landscape half of the round-6
        // report). Re-issue once the transition has settled — a no-op if the
        // first jump landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak pdfView] in
            guard let pdfView, pdfView.window != nil, pdfView.currentPage != page else { return }
            pdfView.go(to: page)
        }
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

/// One flattened outline row, fileprivate so the representable below can
/// build and carry rows from its background pass. Navigation is by PAGE
/// INDEX only: a `PDFDestination` kept here would belong to whatever
/// document instance produced it, and a destination from another document
/// silently does nothing in PDFKit (the round-5 lesson) — the index is
/// instance-independent and always lands.
fileprivate struct OutlineRow: Identifiable {
    let id: Int
    let label: String
    let depth: Int
    /// 0-based page the entry points at, resolved at flatten time so rows
    /// can show their page number and highlight the current one.
    let pageIndex: Int
}

/// PDFKit bridge. THE OPEN RUNS OFF MAIN: `PDFDocument(url:)` is lazy about
/// page *content*, but the container parse itself — cross-reference table,
/// page tree, outline destinations — is synchronous, and on the big scanned
/// textbooks this library carries (hundreds of MB) it stalled the main
/// thread long enough to read as a terminal freeze (the round-7 report:
/// open an audiobook, then open a big PDF → force quit; round 7 detached
/// the outline walk but left THIS open on main, and the freeze survived).
/// makeUIView now returns a responsive empty surface and kicks off ONE
/// background pass that opens the document and flattens the outline on the
/// same thread; the results land on main together. While it runs the
/// reader shows a spinner — the app stays interactive no matter how long
/// PDFKit takes with the file.
private struct BookPDFView: UIViewRepresentable {
    let url: URL
    /// The surface's current width (from the reader's GeometryReader) — the
    /// width-fit scale is derived from it, and a change (rotation, the
    /// landscape rail appearing) re-fits.
    let fitWidth: CGFloat
    let startPageIndex: Int
    var onPageChange: (Int, Int) -> Void
    var onReady: (PDFView) -> Void
    /// Fires when the open pass ends (document or not) — the reader hides
    /// its loading state.
    var onDocumentLoaded: () -> Void
    /// The outline flattened during the same background pass that opened
    /// the document — rows for the Contents sheet, or [] when the PDF has
    /// no resolvable outline.
    var onOutlineLoaded: ([OutlineRow]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        context.coordinator.fitWidth = fitWidth
        context.coordinator.attach(pdfView)
        context.coordinator.load(
            url: url,
            startPageIndex: startPageIndex,
            onLoaded: onDocumentLoaded,
            onOutline: onOutlineLoaded
        )
        DispatchQueue.main.async { [onReady] in
            onReady(pdfView)
        }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        // A background open that landed before this view joined the
        // hierarchy is applied now (see Coordinator.load).
        context.coordinator.applyOpened(startPageIndex: startPageIndex)
        // Width re-fit: the surface's slot changed (rotation, landscape
        // rail) — recompute the scale against the new width. Guarded by a
        // width delta so ordinary state-driven updates don't touch the
        // scale, and a manual zoom survives until the surface itself
        // changes shape.
        let coordinator = context.coordinator
        if abs(fitWidth - coordinator.fitWidth) > 0.5 {
            coordinator.fitWidth = fitWidth
            if pdfView.document != nil {
                Self.applyWidthFit(pdfView, width: fitWidth)
            }
        }
    }

    /// Opens `url` and flattens its outline tree depth-first — ON ONE
    /// THREAD, end to end. The old shape had two defects at once: the open
    /// ran on main (makeUIView) and a SECOND document instance was opened
    /// on a detached task for the outline walk, so a big textbook paid the
    /// container parse twice concurrently. Walking the single instance
    /// before it reaches the view keeps every PDFKit touch single-threaded
    /// (PDFDocument is documented thread-safe, but PDFPage is not — the
    /// walk stops before the view's main-thread rendering begins). Walks
    /// via numberOfChildren/child(at:) — this SDK's PDFOutline has no
    /// `children` array (CI-caught). Entries whose destination does not
    /// resolve to a page are skipped: every row must be navigable.
    ///
    /// The document and the outline are two independent results. A PDF with
    /// no outline (every scanned book, most page-scan dumps) returns
    /// `(document, [])` — returning nil here was the "book opens blank" bug:
    /// the caller's `guard let opened` then skipped `pdfView.document =
    /// …` for exactly those files, leaving a white page while TTS (which
    /// opens its own PDFDocument) kept working.
    fileprivate static func openWithOutline(url: URL) -> (document: PDFDocument, rows: [OutlineRow])? {
        guard let document = PDFDocument(url: url) else { return nil }
        var rows: [OutlineRow] = []
        guard document.pageCount > 0, let root = document.outlineRoot else {
            return (document, rows)
        }
        func walk(_ outline: PDFOutline, depth: Int) {
            if let dest = outline.destination, let page = dest.page {
                let index = document.index(for: page)
                if index >= 0, index < document.pageCount {
                    rows.append(OutlineRow(
                        id: rows.count,
                        label: outline.label ?? "Untitled",
                        depth: depth,
                        pageIndex: index
                    ))
                }
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
        return (document, rows)
    }

    /// Width-fit: the page's width fills the surface — what every reader
    /// defaults to on a phone. PDFKit's own autoScales fits the WHOLE page
    /// instead, which on a portrait screen leaves dead margins down both
    /// sides (the user's report). autoScales goes OFF so PDFKit stops
    /// re-fitting the whole page on every layout, and pinch-zoom still
    /// works on top of the chosen scale; a surface width change re-fits
    /// (see updateUIView).
    fileprivate static func applyWidthFit(_ pdfView: PDFView, width: CGFloat) {
        guard width > 0,
              let document = pdfView.document,
              document.pageCount > 0,
              let first = document.page(at: 0) else { return }
        let pageWidth = first.bounds(for: .cropBox).width
        guard pageWidth > 0 else { return }
        let scale = width / pageWidth
        pdfView.minScaleFactor = scale * 0.5
        pdfView.maxScaleFactor = scale * 6
        pdfView.scaleFactor = scale
        pdfView.autoScales = false
    }

    final class Coordinator {
        var onPageChange: (Int, Int) -> Void
        /// The surface width the current scale was fitted against (set by
        /// makeUIView, refreshed by updateUIView).
        var fitWidth: CGFloat = 0
        private var observer: NSObjectProtocol?
        private weak var pdfView: PDFView?
        private var loadTask: Task<Void, Never>?

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

        /// One background pass: open + outline walk, then a single
        /// main-actor delivery. The main turn is uninterruptible (assign →
        /// go(to:) → callbacks with no await between), so no runloop turn
        /// can deliver a page-changed notification for page 0 between the
        /// document landing and the saved page being applied — the saved
        /// position can't be overwritten by the initial report.
        ///
        /// The delivery does NOT require the view to be in a window: a
        /// background open on a large scanned book lands AFTER SwiftUI has
        /// called makeUIView but BEFORE the view joins the hierarchy, and the
        /// old `pdfView.window != nil` guard threw that result away — the
        /// surface stayed white forever while TTS (which opens its own
        /// PDFDocument) kept working. That is the "PDFs don't display" report:
        /// the big TOC-less page dumps are exactly the ones slow enough to
        /// lose that race. `applyOpened` re-applies the result if the first
        /// delivery arrived too early.
        func load(
            url: URL,
            startPageIndex: Int,
            onLoaded: @escaping () -> Void,
            onOutline: @escaping ([OutlineRow]) -> Void
        ) {
            loadTask?.cancel()
            loadTask = Task.detached(priority: .userInitiated) { [weak self] in
                let opened = BookPDFView.openWithOutline(url: url)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    // The loading state clears whatever happened — a document
                    // that never lands must not leave the spinner up forever.
                    onLoaded()
                    guard let self else { return }
                    self.opened = opened
                    self.applyOpened(startPageIndex: startPageIndex)
                    onOutline(opened?.rows ?? [])
                }
            }
        }

        /// The open result, kept so a delivery that arrived before the view
        /// joined the hierarchy can be re-applied.
        fileprivate var opened: (document: PDFDocument, rows: [OutlineRow])?

        /// Puts the opened document in the view (once) and applies the saved
        /// page. No-ops when there is nothing to show, or the document is
        /// already in place.
        func applyOpened(startPageIndex: Int) {
            guard let opened,
                  let pdfView,
                  pdfView.document !== opened.document else { return }
            pdfView.document = opened.document
            // Width-fit BEFORE the saved-page jump, so go(to:) lands on a page
            // already at its final scale.
            BookPDFView.applyWidthFit(pdfView, width: fitWidth)
            if startPageIndex > 0,
               startPageIndex < opened.document.pageCount,
               let page = opened.document.page(at: startPageIndex) {
                pdfView.go(to: page)
            }
            self.opened = nil
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
            loadTask?.cancel()
        }
    }
}
