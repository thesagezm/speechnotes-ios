import SwiftUI

struct StorageSettingsView: View {
    @StateObject private var exports = ExportsStore()
    @StateObject private var wavPlayer = WavPlayer()
    @State private var showingClearConfirm = false
    @State private var sharingURL: URL?

    var body: some View {
        Form {
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
            } footer: {
                if !exports.exports.isEmpty {
                    Text("\(exports.exports.count) file(s) · \(ByteCountFormatter.string(fromByteCount: exports.totalBytes, countStyle: .file))")
                }
            }

            Section {
                usageRow("Notes (notes.json)", NotesStoreSizeReader.notesBytes)
                usageRow("Kokoro model", ExportsStore.directorySize(ModelManager.onnxDirectory))
                usageRow("Kitten model", ExportsStore.directorySize(ModelManager.kittenDirectory))
                usageRow("Supertonic model", ExportsStore.directorySize(ModelManager.supertonicDirectory))
                usageRow("Exported audio", ExportsStore.directorySize(ExportsStore.exportsDirectory))
                usageRow("Whisper models", ExportsStore.directorySize(WhisperModelManager.modelsDirectory))
            } header: {
                Text("Usage")
            }

            Section {
                Button("Clear temporary files") {
                    showingClearConfirm = true
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Storage")
        .refreshable { exports.refresh() }
        .onAppear { exports.refresh() }
        .alert("Clear temporary files?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                let bytes = ExportsStore.clearTemporaryFiles()
                print("Freed \(bytes) bytes")
            }
        } message: {
            Text("Remove cached WAVs generated inside the app. Exported files in Documents remain.")
        }
        .sheet(item: $sharingURL) { url in
            ShareSheet(items: [url])
        }
    }

    private func exportRow(_ item: ExportedAudio) -> some View {
        Button {
            Haptics.tap()
            wavPlayer.toggle(item.url)
        } label: {
            HStack(spacing: 12) {
                let isThis = wavPlayer.playingURL == item.url
                ZStack {
                    Circle().fill(isThis ? Color.accentColor : Color.secondary.opacity(0.15))
                    Image(systemName: isThis && !wavPlayer.isPaused ? "pause.fill" : "play.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(isThis ? .white : .secondary)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.medium))
                    Text(metaLine(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }

    private func metaLine(for item: ExportedAudio) -> String {
        var parts = [item.createdAt.formatted(date: .abbreviated, time: .shortened), item.sizeLabel]
        if let duration = item.duration {
            parts.append(String(format: "%.0f:%02.0f", duration / 60, duration.truncatingRemainder(dividingBy: 60)))
        }
        return parts.joined(separator: " · ")
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

private enum NotesStoreSizeReader {
    static var notesBytes: Int64 {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notes.json")
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
