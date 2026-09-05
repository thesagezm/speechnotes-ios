import SwiftUI

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
        .miniPlayer(visible: false, onTap: nil)
        .onDisappear { wavPlayer.stop() }
    }

    // MARK: - Cached images

    /// Shows every cached note-image across all notes (thumbnails excluded),
    /// plus total bytes. Deleting removes the on-disk file + memory cache —
    /// the markdown still renders (via the speechnotes:// target) until the
    /// next save re-prunes the orphan.
    private var imagesSection: some View {
        Section {
            let targets = NoteImageStore.allTargets()
            if targets.isEmpty {
                Label(
                    "No images cached yet — insert one in a markdown note.",
                    systemImage: "photo.on.rectangle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                ForEach(targets, id: \.self) { target in
                    imageRow(target)
                }
                Button(role: .destructive) {
                    Haptics.warning()
                    clearAllImages()
                } label: {
                    Label("Clear all cached images", systemImage: "trash.slash")
                }
                .disabled(targets.isEmpty)
            }
        } header: {
            Text("Cached images")
        } footer: {
            if !targets.isEmpty {
                Text("\(targets.count) image(s) · \(ByteCountFormatter.string(fromByteCount: NoteImageStore.totalFootprint(), countStyle: .file))")
            }
        }
    }

    private func imageRow(_ target: String) -> some View {
        HStack(spacing: 12) {
            thumb(target)
            VStack(alignment: .leading, spacing: 2) {
                Text(hash(of: target))
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(fileExtension(of: target))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Haptics.press()
                NoteImageStore.remove(target: target)
                ImageCache.shared.remove(for: NoteImageStore.resolveLocalURL(target, noteId: nil) ?? URL(fileURLWithPath: target))
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            Button {
                if let local = NoteImageStore.resolveLocalURL(target, noteId: nil) {
                    sharingURL = local
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
    }

    private func thumb(_ target: String) -> some View {
        Group {
            if let local = NoteImageStore.resolveLocalURL(target, noteId: nil),
               let data = try? Data(contentsOf: local), let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
        }
    }

    private func hash(of target: String) -> String {
        guard let parsed = NoteImageStore.parseLocalTarget(target) else { return target }
        let h = parsed.hash
        return h.count > 12 ? String(h.prefix(12)) + "…" : h
    }

    private func fileExtension(of target: String) -> String {
        NoteImageStore.parseLocalTarget(target)?.ext ?? "img"
    }

    private func clearAllImages() {
        for target in NoteImageStore.allTargets() {
            NoteImageStore.remove(target: target)
            ImageCache.shared.remove(for: NoteImageStore.resolveLocalURL(target, noteId: nil) ?? URL(fileURLWithPath: target))
        }
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
            usageRow("Kokoro model", ExportsStore.directorySize(ModelManager.onnxDirectory))
            usageRow("Kitten model", ExportsStore.directorySize(ModelManager.kittenDirectory))
            usageRow("Supertonic model", ExportsStore.directorySize(ModelManager.supertonicDirectory))
            usageRow("Exported audio", ExportsStore.directorySize(ExportsStore.exportsDirectory))
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

extension URL: Identifiable {
    public var id: String { absoluteString }
}
