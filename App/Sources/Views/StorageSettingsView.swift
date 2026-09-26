import SwiftUI
import SpeechLogic

/// Settings → Storage (v1.4.2): everything the old Storage tab had — the
/// storage-usage breakdown, exported WAVs, the cached-image gallery — plus
/// the download-cache cleanup under Maintenance. The Storage TAB became the
/// Books library, so this screen is now the only home for that content.
struct StorageSettingsView: View {
    @StateObject private var exports = ExportsStore()
    @StateObject private var wavPlayer = WavPlayer()
    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var notes: NotesStore
    @State private var sharingURL: URL?
    @State private var zoomedImage: CachedImageEntry?
    @State private var showingAllImages = false
    @State private var showingAllExports = false
    @State private var showingClearConfirm = false
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
            exportsSection
            imagesSection
            if !perNoteImages.isEmpty {
                perNoteImagesSection
            }
            maintenanceSection
        }
        .navigationTitle("Storage")
        .refreshable { exports.refresh() }
        .onAppear { exports.refresh() }
        .task { await loadUsage() }
        .sheet(item: $sharingURL) { url in
            ShareSheet(items: [url])
        }
        .onDisappear { wavPlayer.stop() }
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
        let (breakdown, images, perNote): (UsageBreakdown, [CachedImageEntry], [NoteImageUsage]) = await Task.detached(priority: .utility) {
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
            return (usage, entries, perNote)
        }.value
        await MainActor.run {
            self.usage = breakdown
            self.cachedImages = images
            self.perNoteImages = perNote
        }
    }

    // MARK: - Usage breakdown

    private var usageSection: some View {
        Section {
            if let usage {
                usageRow("Notes (notes.json)", usage.notesBytes)
                usageRow("Books library", usage.booksBytes)
                usageRow("Kokoro models (fp32 + uint8)", usage.onnxBytes)
                usageRow("Supertonic model", usage.supertonicBytes)
                usageRow("Exported audio", usage.exportsBytes)
                usageRow("Cached images", usage.imageBytes)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Storage used")
        } footer: {
            Text("Delete voice models in Settings → Speech Settings. Everything is stored on-device; nothing is uploaded.")
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
                                sharingURL = item.url
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.indigo)
                        }
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
