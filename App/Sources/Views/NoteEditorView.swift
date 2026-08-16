import SwiftUI

struct NoteEditorView: View {
    let noteId: UUID

    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var player: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var didLoad = false
    @State private var showingSettings = false
    @State private var showingVoicePicker = false
    @State private var showingDeleteConfirm = false

    private var currentNote: Note? {
        notes.notes.first { $0.id == noteId }
    }

    /// True while a note is being spoken — the editable TextEditor is swapped
    /// for the read-along view so the draft can't change under the highlighter.
    /// Stop (or finishing) returns to the normal editor with the same draft.
    private var isReadAlongActive: Bool {
        player.state == .speaking || player.state == .paused
    }

    private static let whitespace = CharacterSet.whitespacesAndNewlines

    /// Shifts `player.spokenRange` — UTF-16 offsets into the *trimmed* text
    /// the engine was given — into draft coordinates: re-add the length of
    /// the draft's leading whitespace (every whitespace scalar is one UTF-16
    /// unit), then clamp to the draft's UTF-16 length.
    private var draftSpokenRange: Range<Int>? {
        guard let spoken = player.spokenRange else { return nil }
        let leading = draft.unicodeScalars.prefix { Self.whitespace.contains($0) }.count
        let length = draft.utf16.count
        let lower = min(max(spoken.lowerBound + leading, 0), length)
        let upper = min(max(spoken.upperBound + leading, lower), length)
        guard upper > lower else { return nil }
        return lower..<upper
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

    private var draftWordCount: Int {
        draft.split(whereSeparator: \.isWhitespace).count
    }

    /// "412 words · ~3 min listen" — live stats for the keyboard bar.
    private var draftStats: String {
        let words = draftWordCount
        guard words > 0 else { return "0 words" }
        let minutes = max(1, Int((Double(words) / 145).rounded()))
        return "\(words) words · ~\(minutes) min listen"
    }

    var body: some View {
        VStack(spacing: 0) {
            if isReadAlongActive {
                ReadAlongTextView(text: draft, spokenRange: draftSpokenRange)
            } else {
                TextEditor(text: $draft)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .onChange(of: draft) { _ in scheduleDraftSync() }
            }

            controlsBar
        }
        .navigationTitle(currentNote?.title ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .tint(.red)
            }
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
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    Haptics.tap()
                    player.togglePlay(draft, note: currentNote)
                } label: {
                    Label(
                        player.state == .speaking ? "Pause" : "Speak",
                        systemImage: playIcon
                    )
                }
                .disabled(playButtonDisabled)

                Spacer()

                Text(draftStats)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete note", role: .destructive) {
                player.stop()
                notes.delete(noteId: noteId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerSheet(scope: player.engineKind == .kitten ? .kitten : .kokoro)
                .environmentObject(player)
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
            draftSyncTask?.cancel()
            draftSyncTask = nil
            saveDraft()
            notes.flushNow()
        }
        .onChange(of: player.shareURL) { newValue in
            if newValue != nil { Haptics.success() }
        }
    }

    // MARK: - Export

    private var canExport: Bool {
        !player.usingSystemFallback
            && player.engineKind != .system
            && !player.isExporting
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var exportButton: some View {
        Button {
            Haptics.tap()
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

    // MARK: - Controls

    private var controlsBar: some View {
        VStack(spacing: 8) {
            voiceChip

            if let progress = player.progress, player.state == .speaking {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.accentColor, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, proxy.size.width * progress))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal)
            }

            HStack(spacing: 14) {
                Button {
                    Haptics.tap()
                    player.togglePlay(draft, note: currentNote)
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.accentColor, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                        if player.state == .generating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: playIcon)
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                }
                .disabled(playButtonDisabled)

                if player.state == .speaking || player.state == .paused || player.state == .generating {
                    Button {
                        Haptics.press()
                        player.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.red)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.red.opacity(0.12)))
                    }
                }

                Slider(value: $player.rateMultiplier, in: 0.5...2.0, step: 0.05)
                    .frame(height: 44)

                Text(String(format: "%.2f×", player.rateMultiplier))
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// Current engine + voice, one tap from the picker.
    private var voiceChip: some View {
        Button {
            showingVoicePicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2.fill")
                    .font(.caption)
                Text(player.currentVoiceDescription)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func saveDraft() {
        guard var note = currentNote, note.text != draft else { return }
        note.text = draft
        notes.update(note)
    }

    /// Pushing the draft into the store re-sorts and re-renders the whole
    /// notes list; doing that per keystroke was a big part of the editor lag.
    /// The sync (and the debounced disk write behind it) lands shortly after
    /// typing pauses, and immediately when the editor goes away.
    @State private var draftSyncTask: Task<Void, Never>?

    private func scheduleDraftSync() {
        draftSyncTask?.cancel()
        draftSyncTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            saveDraft()
        }
    }
}
