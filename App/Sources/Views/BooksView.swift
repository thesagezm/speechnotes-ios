import SwiftUI
import UniformTypeIdentifiers

/// Books tab (v1.4.2): the ebook library. Import via the Files picker or
/// Open-In; delete via swipe/context menu. The reader view lands in the next
/// phase — rows are intentionally not tappable until it exists.
struct BooksView: View {
    @StateObject private var store = BooksStore()
    @State private var showingImporter = false
    @State private var bookToDelete: Book?

    var body: some View {
        NavigationStack {
            Group {
                if store.books.isEmpty {
                    emptyState
                } else {
                    libraryList
                }
            }
            .navigationTitle("Books")
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
            .onAppear { store.refresh() }
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
                    store.delete(book)
                    bookToDelete = nil
                }
            } message: { book in
                Text("Delete \"\(book.title)\"? The book file and its reading position are removed. Notes are not affected.")
            }
        }
    }

    // MARK: - Library

    private var libraryList: some View {
        List {
            ForEach(store.books) { book in
                BookRowView(book: book)
                    .contextMenu {
                        Button(role: .destructive) {
                            bookToDelete = book
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            bookToDelete = book
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
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
                await store.importBook(from: url)
            }
        }
    }
}
