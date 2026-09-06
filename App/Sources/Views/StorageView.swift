import SwiftUI
import SpeechLogic

/// Storage tab: every exported WAV (playable in-app, shareable, deletable)
/// plus a storage-usage breakdown.
struct StorageView: View {
    @StateObject private var exports = ExportsStore()
    @StateObject private var wavPlayer = WavPlayer()
    @EnvironmentObject private var player: SpeechPlayer
    @State private var sharingURL: URL?

    var body: some View {
        NavigationStack {
            List {
                imagesSection
                exportsSection
                usageSection
            }
            .navigationTitle("Storage")
            .refreshable { exports.refresh() }
            .onAppear { exports.refresh() }
            .sheet(item: $sharingURL) { url in
                ShareSheet(items: [url])
            }
        }
        .onDisappear { wavPlayer.stop() }
    }

    // MARK: - Cached images

    /// One browsable cached image — either a note's own attached image
    /// (Documents/note-images/) or a file the preview downloaded from the
    /// internet (Caches/remote-images/).
    private struct CachedImageEntry: Identifiable {
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

    /// Every cached image across both stores. Computed once per body
    /// evaluation so header / grid / footer stay consistent.
    private var cachedImages: [CachedImageEntry] {
        var entries: [CachedImageEntry] = []
        for target in NoteImageStore.allTargets() {
            entries.append(CachedImageEntry(source: .note(target: target)))
        }
        for entry in RemoteImageStore.allEntries() {
            entries.append(CachedImageEntry(source: .web(entry)))
        }
        return entries
    }

    private var totalImageBytes: Int64 {
        cachedImages.reduce(0) { $0 + $1.bytes }
    }

    /// Browsable gallery: every cached image (notes + web) as tappable
    /// thumbnails — tap opens the full pinch-to-zoom viewer, long-press
    /// offers share/delete, and the footer counts both stores together.
    private var imagesSection: some View {
        Section {
            if cachedImages.isEmpty {
                Label(
                    "No images cached yet — insert one in a markdown note.",
                    systemImage: "photo.on.rectangle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(cachedImages) { entry in
                        galleryCell(entry)
                    }
                }
                .padding(.vertical, 4)
                Button(role: .destructive) {
                    Haptics.warning()
                    clearAllImages()
                } label: {
                    Label("Clear all cached images", systemImage: "trash.slash")
                }
            }
        } header: {
            Text("Cached images")
        } footer: {
            if !cachedImages.isEmpty {
                Text("\(cachedImages.count) image(s) · \(ByteCountFormatter.string(fromByteCount: totalImageBytes, countStyle: .file)) — attached and web previews")
            }
        }
        .sheet(item: $zoomedImage) { entry in
            ZoomableImageView(url: entry.fileURL, alt: entry.label)
        }
    }

    @State private var zoomedImage: CachedImageEntry?

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
    }

    private func clearAllImages() {
        for target in NoteImageStore.allTargets() {
            NoteImageStore.remove(target: target)
        }
        RemoteImageStore.removeAll()
        ImageCache.shared.removeAll()
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
                ForEach(exports.exports) { item in
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
            }
        } header: {
            Text("Exported audio")
        } footer: {
            if !exports.exports.isEmpty {
                Text("\(exports.exports.count) file(s) · \(ByteCountFormatter.string(fromByteCount: exports.totalBytes, countStyle: .file))")
            }
        }
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

    // MARK: - Usage breakdown

    private var usageSection: some View {
        Section {
            usageRow("Notes (notes.json)", NotesStoreSizeReader.notesBytes)
            usageRow("Kokoro models (fp32 + fp16)", ExportsStore.directorySize(ModelManager.onnxDirectory))
            usageRow("Supertonic model", ExportsStore.directorySize(ModelManager.supertonicDirectory))
            usageRow("Exported audio", ExportsStore.directorySize(ExportsStore.exportsDirectory))
            usageRow(
                "Cached images",
                NoteImageStore.totalFootprint() + RemoteImageStore.totalFootprint()
            )
        } header: {
            Text("Storage used")
        } footer: {
            Text("Delete voice models in Settings → Storage. Everything is stored on-device; nothing is uploaded.")
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
}

/// Tiny helper so the view body doesn't do file IO inline.
private enum NotesStoreSizeReader {
    static var notesBytes: Int64 {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notes.json")
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// One grid thumbnail. Loads + decodes its image once per cell via `.task`
/// (off the main actor) instead of inline in body — the grid re-renders on
/// every storage refresh and would otherwise re-read every file each time.
private struct GalleryThumb: View {
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

extension URL: Identifiable {
    public var id: String { absoluteString }
}
