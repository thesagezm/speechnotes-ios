import SwiftUI
import SpeechLogic

struct NoteEditorView: View {
    let noteId: UUID

    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var player: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var titleDraft: String = ""
    @State private var didLoad = false
    @State private var showingSettings = false
    @State private var showingVoicePicker = false
    @State private var showingDeleteConfirm = false
    @State private var keyboardRefreshTrigger = 0
    @FocusState private var editorFocused: Bool
    /// Markdown reading mode — only meaningful when the Render Markdown
    /// setting is on; the editor always opens in edit mode.
    @State private var showPreview = false
    @AppStorage("renderMarkdown") private var renderMarkdown = false

    private var currentNote: Note? {
        notes.notes.first { $0.id == noteId }
    }

    /// The text handed to the engine when markdown rendering is on: syntax
    /// stripped, content intact — no more hearing "hashtag hashtag heading".
    /// With rendering off it's the raw draft. Cached instead of recomputed
    /// per render: body re-renders fire per progress/slider tick and the
    /// whole-draft regex walk froze long notes mid-speech.
    @State private var cachedSpeechText: String = ""
    @State private var cachedWordCount: Int = 0

    private var speechText: String { cachedSpeechText }

    private func updateSpeechCaches() {
        cachedSpeechText = renderMarkdown ? MarkdownText.plainText(draft) : draft
        cachedWordCount = draft.split(whereSeparator: \.isWhitespace).count
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

    private var voicePickerScope: VoicePickerSheet.Scope {
        switch player.engineKind {
        case .kitten: return .kitten
        case .supertonic: return .supertonic
        default: return .kokoro
        }
    }

    private var draftWordCount: Int { cachedWordCount }

    /// "412 words · ~3 min listen" — live stats for the keyboard bar.
    private var draftStats: String {
        let words = draftWordCount
        guard words > 0 else { return "0 words" }
        let minutes = max(1, Int((Double(words) / 145).rounded()))
        return "\(words) words · ~\(minutes) min listen"
    }

    var body: some View {
        VStack(spacing: 0) {
            titleField
            if renderMarkdown && showPreview {
                markdownPreview
            } else {
                TextEditor(text: $draft)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .focused($editorFocused)
                    .onChange(of: draft) { _ in
                        scheduleDraftSync()
                        updateSpeechCaches()
                    }
                    .onChange(of: keyboardRefreshTrigger) { _ in
                        // Sheet dismissed — re-claim focus so the controls
                        // bar collapses back below the keyboard instead of
                        // staying glued above the dismiss position.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            editorFocused = true
                        }
                    }
            }

            controlsBar
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                EditorMicButton(
                    keyboardRefreshTrigger: $keyboardRefreshTrigger
                ) { text in
                    if !draft.isEmpty, !draft.hasSuffix(" "), !draft.hasSuffix("\n") {
                        draft += " "
                    }
                    draft += text
                    scheduleDraftSync()
                    updateSpeechCaches()
                    Haptics.success()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if renderMarkdown {
                        Button {
                            Haptics.tap()
                            showPreview.toggle()
                            if !showPreview { saveDraft() }
                        } label: {
                            Label(
                                showPreview ? "Edit note" : "Preview markdown",
                                systemImage: showPreview ? "pencil.circle" : "eye.circle"
                            )
                        }
                    }
                    Button {
                        Haptics.tap()
                        player.export(speechText)
                    } label: {
                        if case .running(let progress) = player.exportState {
                            Label("Exporting… \(Int(progress * 100))%", systemImage: "square.and.arrow.up")
                        } else {
                            Label("Export WAV", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(!canExport)
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Speech settings", systemImage: "speaker.wave.2")
                    }
                    if player.hasResumeOption(for: noteId, text: speechText) {
                        Button {
                            Haptics.tap()
                            player.restartFromBeginning(speechText, note: currentNote)
                        } label: {
                            Label("Restart from beginning", systemImage: "gobackward")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete note", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    Haptics.tap()
                    player.togglePlay(speechText, note: currentNote)
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
            VoicePickerSheet(scope: voicePickerScope)
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
            titleDraft = currentNote?.explicitTitle ?? ""
            didLoad = true
            updateSpeechCaches()
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
        .onChange(of: renderMarkdown) { _ in updateSpeechCaches() }
    }

    // MARK: - Export helpers

    private var canExport: Bool {
        !player.usingSystemFallback
            && player.engineKind != .system
            && !player.isExporting
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    // MARK: - Title field

    /// Editable note title; blank falls back to the first-line-derived title.
    @ViewBuilder
    private var titleField: some View {
        Group {
            if renderMarkdown && showPreview {
                Text(titleDraft.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Untitled note" : titleDraft)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Title", text: $titleDraft)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .submitLabel(.done)
                    .onChange(of: titleDraft) { _ in scheduleDraftSync() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Markdown preview

    /// Reading mode for markdown notes: block-rendered layout via
    /// MarkdownPreviewView; tap anywhere to return to editing.
    private var markdownPreview: some View {
        MarkdownPreviewView(markdown: draft)
            .onTapGesture {
                // Tap to edit — readers expect the whole surface to be a toggle.
                Haptics.tap()
                showPreview = false
            }
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
                    player.togglePlay(speechText, note: currentNote)
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
        guard var note = currentNote else { return }
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        guard note.text != draft || note.explicitTitle != newTitle else { return }
        note.text = draft
        note.explicitTitle = newTitle
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
