import SwiftUI

struct NoteEditorView: View {
    let noteId: UUID

    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var player: SpeechPlayer
    @State private var draft: String = ""
    @State private var didLoad = false
    @State private var showingSettings = false

    private var currentNote: Note? {
        notes.notes.first { $0.id == noteId }
    }

    private var playIcon: String {
        switch player.state {
        case .generating: return "hourglass"
        case .speaking: return "pause.fill"
        case .paused, .idle: return "play.fill"
        }
    }

    private var playButtonDisabled: Bool {
        player.isExporting
            || player.state == .idle
                && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.body)
                .padding(.horizontal, 8)
                .onChange(of: draft) { _ in saveDraft() }

            if let progress = player.progress, player.state == .speaking {
                ProgressView(value: progress)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            controlsBar
        }
        .navigationTitle(currentNote?.title ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                exportButton
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: shareSheetBinding) {
            if let url = player.shareURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Export failed", isPresented: exportErrorBinding) {
            Button("OK") { player.dismissExportError() }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .onAppear {
            guard !didLoad else { return }
            draft = currentNote?.text ?? ""
            didLoad = true
        }
        .onDisappear {
            saveDraft()
        }
    }

    // MARK: - Export

    private var canExport: Bool {
        !player.usingSystemFallback
            && player.engineKind == .kokoro
            && !player.isExporting
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var exportButton: some View {
        Button {
            player.export(draft)
        } label: {
            Group {
                if case .running(let progress) = player.exportState {
                    ProgressView(value: progress)
                        .frame(width: 28)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .disabled(!canExport)
    }

    private var exportErrorMessage: String? {
        if case .failed(let message) = player.exportState { return message }
        return nil
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { player.dismissExportError() } }
        )
    }

    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { player.shareURL != nil },
            set: { if !$0 { player.shareURL = nil } }
        )
    }

    private var controlsBar: some View {
        HStack(spacing: 16) {
            Button {
                player.togglePlay(draft)
            } label: {
                Group {
                    if player.state == .generating {
                        ProgressView()
                    } else {
                        Image(systemName: playIcon)
                    }
                }
                .font(.title2)
                .frame(width: 44, height: 44)
            }
            .disabled(playButtonDisabled)

            if player.state == .speaking || player.state == .paused || player.state == .generating {
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .tint(.red)
            }

            Slider(value: $player.rateMultiplier, in: 0.5...2.0, step: 0.05)

            Text(String(format: "%.2f×", player.rateMultiplier))
                .font(.callout.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func saveDraft() {
        guard var note = currentNote, note.text != draft else { return }
        note.text = draft
        notes.update(note)
    }
}

/// UIActivityViewController bridge for sharing exported WAV files.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
