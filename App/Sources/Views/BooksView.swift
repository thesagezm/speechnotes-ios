import SwiftUI
import UniformTypeIdentifiers

/// Books tab (v1.4.2): the ebook library. Import via the Files picker or
/// Open-In; delete via context menu; tap opens the format's reader (epub.js
/// webview for EPUB, PDFKit for PDF).
///
/// v1.5: Apple-Books-style cover GRID with search (title/author), and the
/// mini-player's tap lands here while a book speaks — pushing the playing
/// book's reader.
struct BooksView: View {
    @StateObject private var store = BooksStore()
    @EnvironmentObject private var player: SpeechPlayer
    @State private var showingImporter = false
    @State private var bookToDelete: Book?
    @State private var searchText = ""
    /// Pushed reader — set by the mini-player's book jump.
    @State private var path: [Book] = []

    /// Search over title/author; empty query = the whole shelf.
    private var visibleBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.books }
        return store.books.filter { book in
            book.title.localizedCaseInsensitiveContains(query)
                || (book.author ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.books.isEmpty {
                    emptyState
                } else {
                    libraryGrid
                }
            }
            .navigationTitle("Books")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Title or author"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showingImporter = true
                    } label: {
                        Label("Import book", systemImage: "plus")
                    }
                    .disabled(store.isImporting)
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.epub, .pdf],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
            .navigationDestination(for: Book.self) { book in
                switch book.format {
                case .epub: BookReaderView(book: book, store: store)
                case .pdf: BookPDFReaderView(book: book, store: store)
                }
            }
            .onAppear {
                store.refresh()
                consumePendingBookJump()
            }
            .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToBook)) { notification in
                guard let idString = notification.object as? String else { return }
                consumeBookJump(idString)
            }
            .refreshable { store.refresh() }
            .overlay {
                if store.isImporting {
                    importingOverlay
                }
            }
            .alert(
                "Couldn't import book",
                isPresented: Binding(
                    get: { store.importError != nil },
                    set: { if !$0 { store.importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.importError ?? "Unknown error.")
            }
            .alert(
                "Delete book?",
                isPresented: Binding(
                    get: { bookToDelete != nil },
                    set: { if !$0 { bookToDelete = nil } }
                ),
                presenting: bookToDelete
            ) { book in
                Button("Delete", role: .destructive) {
                    Haptics.press()
                    // Deleting a book that is speaking would leave a ghost
                    // session narrating a removed file — stop it first.
                    if BookPlaybackController.shared.isBookActive(book) {
                        player.stop()
                    }
                    store.delete(book)
                    bookToDelete = nil
                }
            } message: { book in
                Text("Delete \"\(book.title)\"? The book file and its reading position are removed. Notes are not affected.")
            }
        }
    }

    // MARK: - Library

    private var libraryGrid: some View {
        ScrollView {
            if visibleBooks.isEmpty {
                noResults
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 16)],
                    spacing: 20
                ) {
                    ForEach(visibleBooks) { book in
                        NavigationLink(value: book) {
                            BookGridCard(book: book)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                bookToDelete = book
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No books match \"\(searchText)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No books yet")
                .font(.headline)
            Text("Import an EPUB or PDF to start reading and listening.\nYou can also open files into Speechnotes from the Files app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                showingImporter = true
            } label: {
                Label("Import a book", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                Text("Importing book…")
                    .font(.subheadline)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Import

    /// The mini-player tap races the tab switch: the notification can fire
    /// before this view installs its listener, so the overlay ALSO parks the
    /// book id on the player and onAppear consumes it here.
    private func consumePendingBookJump() {
        guard let pending = player.pendingBookJumpId else { return }
        player.pendingBookJumpId = nil
        consumeBookJump(pending)
    }

    private func consumeBookJump(_ idString: String) {
        guard let id = UUID(uuidString: idString),
              let book = store.books.first(where: { $0.id == id }) else { return }
        // Replace the path wholesale: the reader must be ON TOP when the
        // user lands, not one more card deep in an old stack.
        path = [book]
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            store.importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                // Security scope must live as long as the copy inside
                // importBook, so it is held across the await here (the
                // established ImportService pattern).
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let imported = await store.importBook(from: url) {
                    ToastCenter.shared.show("Imported \"\(imported.title.prefix(32))\"")
                }
            }
        }
    }
}

/// One cover card in the grid: cover, title, meta line. Same data discipline
/// as BookRowView — renders without touching the disk (cover loads via its
/// own .task).
private struct BookGridCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCoverView(book: book, height: 150)
            Text(book.title)
                .font(.caption.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            Text(metaLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaLine: String {
        var parts = [book.authorOrFormat]
        switch book.format {
        case .epub:
            if let chapters = book.spineCount {
                parts.append("\(chapters) ch")
            }
        case .pdf:
            if let chapters = book.pdfChapters, !chapters.isEmpty {
                parts.append("\(chapters.count) ch")
            } else if let pages = book.pageCount {
                parts.append("\(pages) p")
            }
        }
        return parts.joined(separator: " · ")
    }
}
