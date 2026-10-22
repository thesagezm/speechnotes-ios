import SwiftUI
import SpeechLogic

/// Settings → Storage (v1.4.2): everything the old Storage tab had — the
/// storage-usage breakdown, exported WAVs, the cached-image gallery — plus
/// the download-cache cleanup under Maintenance. The Storage TAB became the
/// Books library, so this screen is now the only home for that content.
struct StorageSettingsView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var exports = ExportsStore()
    /// Shared so the global mini-player and this screen observe ONE playhead.
    @ObservedObject private var wavPlayer = WavPlayer.shared
    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var audioBooks: AudioBookPlayer
    @EnvironmentObject private var notes: NotesStore
    /// The app-level shelf (injected at the app root) — the Books library
    /// usage row expands into THIS list, so deleting here and on the Books
    /// tab mutate the same store and the shelf updates live.
    @EnvironmentObject private var books: BooksStore
    @State private var sharingURL: URL?
    @State private var zoomedImage: CachedImageEntry?
    @State private var showingAllImages = false
    @State private var showingAllExports = false
    @State private var showingClearConfirm = false
    /// Expanded "Books library" sublist — the per-book sizes + delete list.
    @State private var showingBooksList = false
    @State private var bookToDelete: Book?
    /// Per-book directory sizes (manifest + original + cover + caches),
    /// computed once off-main alongside the usage breakdown.
    @State private var bookSizes: [UUID: Int64] = [:]
    /// Backs the PDF extractor picker; persisted to UserDefaults on change.
    /// ~4 rows of an 84 pt adaptive grid before "See all" appears.
    private let imagePreviewLimit = 16
    private let exportPreviewLimit = 5

    // Usage-breakdown bytes — computed ONCE off-main in .task, not on every
    // body evaluation (the old synchronous directory walks re-enumerated
    // thousands of files per render).
    @State private var usage: UsageBreakdown?

    struct UsageBreakdown {
        let notesBytes: Int64
        let booksBytes: Int64
        let onnxBytes: Int64
        let supertonicBytes: Int64
        let exportsBytes: Int64
        let imageBytes: Int64
    }

    /// One note's slice of the web-image cache (round 5: per-note deletion —
    /// "deleting cache for specific notes only, not every image").
    struct NoteImageUsage: Identifiable {
        let noteId: UUID
        let title: String
        let count: Int
        let bytes: Int64
        var id: UUID { noteId }
    }
    @State private var perNoteImages: [NoteImageUsage] = []

    var body: some View {
        Form {
            usageSection
            filesAppSection
            exportsSection
            imagesSection
            if !perNoteImages.isEmpty {
                perNoteImagesSection
            }
            maintenanceSection
        }
        .navigationTitle("Storage")
        .refreshable { exports.refresh() }
        .onAppear {
            exports.refresh()
            wavPlayer.miniPlayerSuppressed = true
        }
        .task { await loadUsage() }
        .sheet(item: $sharingURL) { url in
            ShareSheet(items: [url])
        }
        .onDisappear {
            wavPlayer.miniPlayerSuppressed = false
            wavPlayer.stop()
        }
        .alert("Clear temporary files?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                let bytes = ExportsStore.clearTemporaryFiles()
                LogStore.shared.info("Cleared \(bytes) bytes of temporary files")
            }
        } message: {
            Text("Remove cached WAVs and partial downloads. Exported files and books remain.")
        }
    }

    private func loadUsage() async {
        let noteTitles = Dictionary(uniqueKeysWithValues: notes.notes.map { ($0.id, $0.title) })
        // Snapshot the shelf on main before the detached walk — the store's
        // @Published array is main-actor state.
        let shelf = books.books
        let (breakdown, images, perNote, sizes): (UsageBreakdown, [CachedImageEntry], [NoteImageUsage], [UUID: Int64]) = await Task.detached(priority: .utility) {
            let usage = UsageBreakdown(
                notesBytes: NotesStoreSizeReader.notesBytes,
                booksBytes: BooksStore.directorySize(),
                onnxBytes: ExportsStore.directorySize(ModelManager.onnxDirectory),
                supertonicBytes: ExportsStore.directorySize(ModelManager.supertonicDirectory),
                exportsBytes: ExportsStore.directorySize(ExportsStore.exportsDirectory),
                imageBytes: NoteImageStore.totalFootprint() + RemoteImageStore.totalFootprint()
            )
            var entries: [CachedImageEntry] = []
            for target in NoteImageStore.allTargets() {
                entries.append(CachedImageEntry(source: .note(target: target)))
            }
            for entry in RemoteImageStore.allEntries() {
                entries.append(CachedImageEntry(source: .web(entry)))
            }
            // Per-note usage from the preview's note→URL index, restricted to
            // notes that still exist (purged notes' entries are swept by
            // their purge path).
            var perNote: [NoteImageUsage] = []
            for (idString, urls) in RemoteImageStore.indexedNotes() {
                guard let id = UUID(uuidString: idString), let title = noteTitles[id] else { continue }
                var bytes: Int64 = 0
                var count = 0
                for string in urls {
                    guard let url = URL(string: string) else { continue }
                    let size = Int64((try? RemoteImageStore.fileURL(for: url).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    guard size > 0 else { continue } // not actually cached
                    bytes += size
                    count += 1
                }
                guard count > 0 else { continue }
                perNote.append(NoteImageUsage(noteId: id, title: title, count: count, bytes: bytes))
            }
            perNote.sort { $0.bytes > $1.bytes }
            // One directory walk per book: manifest + original + cover +
            // per-chapter speech-text cache. The Books row's sublist shows
            // these so a 700 MB audiobook is findable and deletable.
            var sizes: [UUID: Int64] = [:]
            for book in shelf {
                sizes[book.id] = ExportsStore.directorySize(BooksStore.bookDirectory(book.id))
            }
            return (usage, entries, perNote, sizes)
        }.value
        await MainActor.run {
            self.usage = breakdown
            self.cachedImages = images
            self.perNoteImages = perNote
            self.bookSizes = sizes
        }
    }

    // MARK: - Usage breakdown

    private var usageSection: some View {
        Section {
            if let usage {
                usageRow("Notes (notes.json)", usage.notesBytes)
                // The Books row is a dropdown into the shelf itself: every
                // book, its real on-disk size, and a menu with Delete +
                // Send with BookDrop — the reason this list exists is that
                // one 700 MB audiobook hides inside a single "Books library"
                // number with no way to find or drop it.
                DisclosureGroup(isExpanded: $showingBooksList) {
                    if books.books.isEmpty {
                        Text("No books on the shelf.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(books.books) { book in
                            bookUsageRow(book)
                        }
                        if books.books.count > 1 {
                            Button {
                                Haptics.tap()
                                sendBooksToBookDrop(books.books)
                            } label: {
                                Label("Send all with BookDrop", systemImage: "wifi")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Books library")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: usage.booksBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                // Attached HERE, not on the Form: a view carries one alert,
                // and the Form's clear-temporary-files alert already owns the
                // body-level slot.
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
                        // Same guard the Books shelf uses: a playing book must
                        // stop before its file leaves, or a ghost session keeps
                        // sounding from a de-shelved book.
                        if BookPlaybackController.shared.isBookActive(book) {
                            player.stop()
                        }
                        if book.format == .audio {
                            audioBooks.stopIfPlaying(book)
                            NotificationCenter.default.post(name: .audioBookStopped, object: book.id)
                        }
                        books.delete(book)
                        bookSizes.removeValue(forKey: book.id)
                        bookToDelete = nil
                        Task { await loadUsage() }
                    }
                } message: { book in
                    Text("Move \"\(book.title)\" to the recycle bin? The file stays recoverable for \(Book.recycleRetentionDays) days (Books → … → Recently Deleted). Notes are not affected.")
                }
                usageRow("Kokoro models (fp32 + compact)", usage.onnxBytes)
                usageRow("Supertonic model", usage.supertonicBytes)
                usageRow("Exported audio", usage.exportsBytes)
                usageRow("Cached images", usage.imageBytes)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Storage used")
        } footer: {
            Text("Delete voice models in Settings → Speech Settings. Everything is stored on-device; nothing is uploaded. Tap \"Books library\" to list every book with its size — swipe a book to delete it or send it with BookDrop.")
        }
    }

    /// One book inside the expanded Books library group: title, real
    /// directory size, swipe-to-delete (soft, into the recycle bin) and a
    /// menu carrying the same two actions for anyone who doesn't swipe.
    private func bookUsageRow(_ book: Book) -> some View {
        HStack(spacing: 10) {
            BookCoverView(book: book, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(book.authorOrFormat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(ByteCountFormatter.string(
                fromByteCount: bookSizes[book.id] ?? 0,
                countStyle: .file
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                bookToDelete = book
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                sendBooksToBookDrop([book])
            } label: {
                Label("BookDrop", systemImage: "wifi")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                sendBooksToBookDrop([book])
            } label: {
                Label("Send", systemImage: "wifi")
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button {
                sendBooksToBookDrop([book])
            } label: {
                Label("Send with BookDrop", systemImage: "wifi")
            }
            Button(role: .destructive) {
                bookToDelete = book
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func usageRow(_ label: String, _ bytes: Int64) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    // MARK: - BookDrop hand-offs

    /// Opens the app-level BookDrop send sheet prefilled with these books.
    private func sendBooksToBookDrop(_ list: [Book]) {
        NotificationCenter.default.post(
            name: .bookDropSendRequest,
            object: BookDropRequest(payload: .book, bookIDs: list.map(\.id))
        )
    }

    /// …and the same for exported WAVs (Storage is where they live, so
    /// this is the natural place to push one or all of them).
    private func sendExportsToBookDrop(_ urls: [URL]) {
        NotificationCenter.default.post(
            name: .bookDropSendRequest,
            object: BookDropRequest(payload: .export, exportURLs: urls)
        )
    }

    // MARK: - Exported audio

    private var exportsSection: some View {
        Section {
            if exports.exports.isEmpty {
                Label(
                    "No exports yet — use 'Export WAV' in a note's … menu.",
                    systemImage: "waveform"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                ForEach(visibleExports) { item in
                    exportRow(item)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                wavPlayer.stop()
                                exports.delete(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                sendExportsToBookDrop([item.url])
                            } label: {
                                Label("BookDrop", systemImage: "wifi")
                            }
                            .tint(.indigo)
                            Button {
                                sharingURL = item.url
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.teal)
                        }
                        .contextMenu {
                            Button {
                                sendExportsToBookDrop([item.url])
                            } label: {
                                Label("Send with BookDrop", systemImage: "wifi")
                            }
                            Button {
                                sharingURL = item.url
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                wavPlayer.stop()
                                exports.delete(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                // Whole-list hand-off: every WAV in one BookDrop session.
                if exports.exports.count > 1 {
                    Button {
                        Haptics.tap()
                        sendExportsToBookDrop(exports.exports.map(\.url))
                    } label: {
                        Label("Send all with BookDrop", systemImage: "wifi")
                            .font(.subheadline.weight(.medium))
                    }
                }
                // The playing export gets the full transport right where it
                // was started — the "download the note in advance and play
                // it as I read" surface (round 5). Elsewhere the global
                // mini-player carries it.
                if let url = wavPlayer.playingURL,
                   let item = exports.exports.first(where: { $0.url == url }) {
                    exportTransport(item)
                }
                if exports.exports.count > exportPreviewLimit {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingAllExports.toggle()
                        }
                    } label: {
                        Label(
                            showingAllExports ? "Show fewer" : "See all \(exports.exports.count) recordings",
                            systemImage: showingAllExports ? "chevron.up" : "chevron.down"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
        } header: {
            Text("Exported audio")
        } footer: {
            if !exports.exports.isEmpty {
                Text("\(exports.exports.count) file(s) · \(ByteCountFormatter.string(fromByteCount: exports.totalBytes, countStyle: .file))")
            }
        }
    }

    /// Scrub slider, ±15 s skips and speed for the export currently playing.
    private func exportTransport(_ item: ExportedAudio) -> some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { wavPlayer.progress ?? 0 },
                    set: { wavPlayer.seek(toFraction: $0) }
                )
            )
            HStack {
                Text(timeLabel(wavPlayer.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeLabel(wavPlayer.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                Button {
                    Haptics.tap()
                    wavPlayer.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 22))
                }
                .accessibilityLabel("Back 15 seconds")

                Button {
                    Haptics.tap()
                    wavPlayer.togglePlay()
                } label: {
                    Image(systemName: wavPlayer.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 36))
                }
                .accessibilityLabel(wavPlayer.isPaused ? "Play" : "Pause")

                Button {
                    Haptics.tap()
                    wavPlayer.skip(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 22))
                }
                .accessibilityLabel("Forward 15 seconds")

                Spacer(minLength: 0)

                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                        Button {
                            Haptics.tap()
                            wavPlayer.rate = value
                        } label: {
                            if abs(wavPlayer.rate - value) < 0.001 {
                                Label(String(format: "%.2f×", value), systemImage: "checkmark")
                            } else {
                                Text(String(format: "%.2f×", value))
                            }
                        }
                    }
                } label: {
                    Text(String(format: "%.2f×", wavPlayer.rate))
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("Playback speed")
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var visibleExports: [ExportedAudio] {
        showingAllExports ? exports.exports : Array(exports.exports.prefix(exportPreviewLimit))
    }

    private func exportRow(_ item: ExportedAudio) -> some View {
        Button {
            Haptics.tap()
            player.stop()
            wavPlayer.toggle(item.url)
        } label: {
            HStack(spacing: 12) {
                playBadge(for: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(metaLine(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func playBadge(for item: ExportedAudio) -> some View {
        let isThis = wavPlayer.playingURL == item.url
        return ZStack {
            Circle()
                .fill(isThis ? Color.accentColor : Color.secondary.opacity(0.15))
            Image(systemName: isThis && !wavPlayer.isPaused ? "pause.fill" : "play.fill")
                .font(.footnote.bold())
                .foregroundStyle(isThis ? .white : .secondary)
        }
        .frame(width: 36, height: 36)
    }

    private func metaLine(for item: ExportedAudio) -> String {
        var parts = [item.createdAt.formatted(date: .abbreviated, time: .shortened), item.sizeLabel]
        if let duration = item.duration {
            parts.append(String(format: "%.0f:%02.0f", duration / 60, duration.truncatingRemainder(dividingBy: 60)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Cached images

    /// One browsable cached image — either a note's own attached image
    /// (Documents/note-images/) or a file the preview downloaded from the
    /// internet (Caches/remote-images/).
    struct CachedImageEntry: Identifiable {
        enum Source {
            case note(target: String)
            case web(RemoteImageStore.Entry)
        }

        let source: Source

        var id: String {
            switch source {
            case .note(let target): return "note-" + target
            case .web(let entry): return "web-" + entry.id
            }
        }
        var fileURL: URL {
            switch source {
            case .note(let target):
                return NoteImageStore.resolveLocalURL(target, noteId: nil)
                    ?? URL(fileURLWithPath: target)
            case .web(let entry): return entry.fileURL
            }
        }
        /// Key under which the preview cached the decoded image in memory,
        /// so deleting the entry also evicts the NSCache copy.
        var memoryKey: URL {
            switch source {
            case .note(let target):
                return NoteImageStore.resolveLocalURL(target, noteId: nil)
                    ?? URL(fileURLWithPath: target)
            case .web(let entry): return entry.url
            }
        }
        var bytes: Int64 {
            switch source {
            case .note(let target):
                return Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            case .web(let entry): return entry.bytes
            }
        }
        var isFromWeb: Bool {
            if case .web = source { return true }
            return false
        }
        var label: String {
            switch source {
            case .note(let target):
                guard let parsed = NoteImageStore.parseLocalTarget(target) else { return target }
                let h = parsed.hash
                return h.count > 12 ? String(h.prefix(12)) + "…" : h
            case .web(let entry):
                return entry.url.host ?? entry.url.absoluteString
            }
        }
    }

    /// Every cached image across both stores, loaded once off-main in the
    /// same task as the usage breakdown. The old computed property enumerated
    /// both stores — including per-entry `resourceValues` file-size stats —
    /// synchronously on every body evaluation.
    @State private var cachedImages: [CachedImageEntry]?

    private var totalImageBytes: Int64 {
        cachedImages?.reduce(0) { $0 + $1.bytes } ?? 0
    }

    private var imagesSection: some View {
        Section {
            if let cachedImages, cachedImages.isEmpty {
                Label(
                    "No images cached yet — insert one in a markdown note.",
                    systemImage: "photo.on.rectangle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if let cachedImages {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(visibleCachedImages) { entry in
                        galleryCell(entry)
                    }
                }
                .padding(.vertical, 4)
                if cachedImages.count > imagePreviewLimit {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingAllImages.toggle()
                        }
                    } label: {
                        Label(
                            showingAllImages ? "Show fewer" : "See all \(cachedImages.count) images",
                            systemImage: showingAllImages ? "chevron.up" : "chevron.down"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                }
                Button(role: .destructive) {
                    Haptics.warning()
                    clearAllImages()
                } label: {
                    Label("Clear web-downloaded images", systemImage: "trash.slash")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Cached images")
        } footer: {
            if let cachedImages, !cachedImages.isEmpty {
                Text("\(cachedImages.count) image(s) · \(ByteCountFormatter.string(fromByteCount: totalImageBytes, countStyle: .file)) — attached and web previews")
            }
        }
        .sheet(item: $zoomedImage) { entry in
            ZoomableImageView(url: entry.fileURL, alt: entry.label)
        }
    }

    private var visibleCachedImages: [CachedImageEntry] {
        guard let cachedImages else { return [] }
        return showingAllImages ? cachedImages : Array(cachedImages.prefix(imagePreviewLimit))
    }

    private func galleryCell(_ entry: CachedImageEntry) -> some View {
        Button {
            Haptics.tap()
            zoomedImage = entry
        } label: {
            ZStack(alignment: .topTrailing) {
                GalleryThumb(fileURL: entry.fileURL)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if entry.isFromWeb {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                sharingURL = entry.fileURL
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                deleteImage(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func deleteImage(_ entry: CachedImageEntry) {
        Haptics.press()
        switch entry.source {
        case .note(let target):
            NoteImageStore.remove(target: target)
        case .web(let webEntry):
            RemoteImageStore.remove(webEntry)
        }
        ImageCache.shared.remove(for: entry.memoryKey)
        Task { await loadUsage() }
    }

    // MARK: - Per-note cached images

    private var perNoteImagesSection: some View {
        Section {
            ForEach(perNoteImages) { item in
                HStack {
                    Image(systemName: "note.text")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(item.count) web image(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteNoteImages(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Per-note cached images")
        } footer: {
            Text("Web images each note has cached. Deleting one note's images keeps every other note's — an image two notes share stays until both are cleared. Purging a note from the recycle bin removes its images automatically.")
        }
    }

    private func deleteNoteImages(_ item: NoteImageUsage) {
        Haptics.press()
        Task.detached(priority: .utility) {
            let bytes = RemoteImageStore.removeImages(for: item.noteId)
            await MainActor.run {
                LogStore.shared.info("Deleted \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of cached images for “\(item.title)”")
                Task { await loadUsage() }
            }
        }
    }

    /// Clears only the WEB image cache. Note-attached images are content,
    /// not cache — wiping them would break the markdown that references
    /// them — so they are managed per-note (prune on edit, delete with the
    /// note) and never by a bulk "clear".
    private func clearAllImages() {
        RemoteImageStore.removeAll()
        ImageCache.shared.removeAll()
    }

    // MARK: - Files app

    /// The app's Documents folder is exposed in the Files app ("On My iPhone
    /// → Speechnotes"). This is the shortcut into it — `shareddocuments://`
    /// is the scheme Files itself registers for "this app's documents"; when
    /// it is refused nothing happens rather than failing loudly, and the
    /// folder is still reachable by browsing.
    private var filesAppSection: some View {
        Section {
            Button {
                guard let url = URL(string: "shareddocuments://") else { return }
                openURL(url)
            } label: {
                Label("Open in Files", systemImage: "folder")
            }
        } header: {
            Text("Files app")
        } footer: {
            Text("Notes, books and exports live in this app's folder under \"On My iPhone → Speechnotes\". Files edited there are picked up here.")
        }
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        Section {
            Button(role: .destructive) {
                showingClearConfirm = true
            } label: {
                Label("Clear temporary files", systemImage: "sparkles")
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Removes partial downloads and cache leftovers. Books, notes, exports and models are not touched.")
        }
    }
}

/// Tiny helper so the view body doesn't do file IO inline.
enum NotesStoreSizeReader {
    static var notesBytes: Int64 {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notes.json")
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// One grid thumbnail. Loads + decodes its image once per cell via `.task`
/// (off the main actor) instead of inline in body — the grid re-renders on
/// every storage refresh and would otherwise re-read every file each time.
struct GalleryThumb: View {
    let fileURL: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.08))
            }
        }
        .task(id: fileURL) {
            guard image == nil else { return }
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return UIImage(data: data)
            }.value
        }
    }
}

/// Load-bearing app-wide conformance: NoteEditorView and MarkdownPreviewView
/// present share/zoom sheets via `.sheet(item:)` on plain URLs. It used to
/// live in StorageView.swift — it moved here when the Storage tab became the
/// Books library. Keep exactly ONE of these in the app.
extension URL: Identifiable {
    public var id: String { absoluteString }
}
