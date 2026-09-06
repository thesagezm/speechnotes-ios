import SwiftUI
import PDFKit

/// The PDF reader: PDFKit's own lazy engine at full fidelity (original
/// layout, images, fonts, zoom — the reason PDF gets a native viewer instead
/// of a text conversion). Outline sidebar comes from the PDF's outline tree;
/// position (page index + fraction) persists to the book manifest.
struct BookPDFReaderView: View {
    let book: Book
    let store: BooksStore

    @State private var currentPage: Int
    @State private var pageCount: Int
    @State private var pdfView: PDFView?
    @State private var outlineRows: [OutlineRow] = []
    @State private var showingOutline = false

    init(book: Book, store: BooksStore) {
        self.book = book
        self.store = store
        let saved = book.position
        _currentPage = State(initialValue: saved?.chapterIndex ?? 0)
        _pageCount = State(initialValue: book.pageCount ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            BookPDFView(
                url: BooksStore.originalFileURL(book),
                startPageIndex: currentPage,
                onPageChange: handlePageChange,
                onReady: { pdfView = $0 }
            )
            pageBar
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
        .onAppear {
            store.markOpened(book)
            outlineRows = Self.flattenOutline(book: book)
        }
        .onDisappear {
            store.updatePosition(book, chapterIndex: currentPage, chapterFraction: 0)
        }
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
