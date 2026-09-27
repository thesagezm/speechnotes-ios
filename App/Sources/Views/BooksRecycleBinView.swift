import SwiftUI

/// Recently Deleted — the books recycle bin. Pushed onto the Books tab's
/// navigation stack, the twin of the notes bin: recover, delete-permanently,
/// empty-all. A mis-tap on a 3 GB audiobook is recoverable for
/// `Book.recycleRetentionDays` before the file is really removed.
struct BooksRecycleBinView: View {
    @EnvironmentObject private var store: BooksStore
    @EnvironmentObject private var audioBooks: AudioBookPlayer
    @State private var showingEmptyConfirm = false

    var body: some View {
        Group {
            if store.deletedBooks.isEmpty {
                ContentUnavailableView(
                    "Recycle bin is empty",
                    systemImage: "trash.slash",
                    description: Text("Deleted books stay here for \(Book.recycleRetentionDays) days before they're removed for good.")
                )
            } else {
                binList
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !store.deletedBooks.isEmpty {
                    Button("Empty", role: .destructive) { showingEmptyConfirm = true }
                }
            }
        }
        .confirmationDialog(
            "Permanently delete all \(store.deletedBooks.count) books?",
            isPresented: $showingEmptyConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                for book in store.deletedBooks where audioBooks.activeBookID == book.id {
                    audioBooks.stop()
                    NotificationCenter.default.post(name: .audioBookStopped, object: book.id)
                }
                store.emptyRecycleBin()
                Haptics.press()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var binList: some View {
        List {
            ForEach(store.deletedBooks) { book in
                binRow(book)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            store.recover(book)
                            Haptics.success()
                        } label: {
                            Label("Recover", systemName: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            purge(book)
                        } label: {
                            Label("Delete Now", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func purge(_ book: Book) {
        // A playing audiobook must not keep sounding from a removed file.
        if audioBooks.activeBookID == book.id {
            audioBooks.stop()
            NotificationCenter.default.post(name: .audioBookStopped, object: book.id)
        }
        store.purge(book)
        Haptics.press()
    }

    private func binRow(_ book: Book) -> some View {
        HStack(spacing: 12) {
            BookCoverView(book: book, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(book.format.rawValue.uppercased()) · removed \(daysAgo(book.deletedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func daysAgo(_ date: Date?) -> String {
        guard let date else { return "just now" }
        let days = max(0, Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0)
        return days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
