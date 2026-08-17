import SwiftUI
import SpeechLogic

struct NoteEditorView: View {
    let noteId: UUID

    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var player: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var draft: String = ""
    @State private var titleDraft: String = ""
    @State private var didLoad = false
    @State private var showingSettings = false
    @State private var showingVoicePicker = false
    @State private var showingDeleteConfirm = false
    /// Markdown reading mode — only meaningful when the Render Markdown
    /// setting is on; the editor always opens in edit mode.
    @State private var showPreview = false
    @AppStorage("renderMarkdown") private var renderMarkdown = false
    /// Whole-draft walks (markdown strip, word count) re-ran on EVERY body
    /// render — per progress tick, per slider tick — which froze long notes
    /// mid-speech. Now recomputed only when the draft (or markdown setting)
    /// actually changes.
    @State private var cachedSpeechText: String = ""
    @State private var cachedWordCount: Int = 0

    private var currentNote: Note? {
        notes.notes.first { $0.id == noteId }
    }

    /// The text handed to the engine when markdown rendering is on: syntax
    /// stripped, content intact — no more hearing "hashtag hashtag heading".
    /// With rendering off it's the raw draft. Cached — see
    /// `updateSpeechCaches`.
    private var speechText: String { cachedSpeechText }

    /// iPhone landscape = vertically compact; portrait = regular.
    private var isLandscape: Bool { verticalSizeClass == .compact }

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

    private func updateSpeechCaches() {
        cachedSpeechText = renderMarkdown ? MarkdownText.plainText(draft) : draft
        cachedWordCount = draft.split(whereSeparator: \.isWhitespace).count
    }

    /// "412 words · ~3 min listen" — live stats for the keyboard bar.
    private var draftStats: String {
        let words = draftWordCount
        guard words > 0 else { return "0 words" }
        let minutes = max(1, Int((Double(words) / 145).rounded()))
        return "\(words) words · ~\(minutes) min listen"
    }

    var body: some View { editorContent }

    // MARK: - Main content

    /// The actual view tree — extracted out of `body` so the type checker
    /// doesn't hit its expression-complexity limit on the long modifier
    /// chain (sheets, alerts, onChange, onAppear/onDisappear, etc.).
    private var editorContent: some View {
        VStack(spacing: 0) {
            titleField
            if renderMarkdown && showPreview {
                markdownPreview
            } else {
                TextEditor(text: $draft)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .onChange(of: draft) { _ in
                        scheduleDraftSync()
                        updateSpeechCaches()
                    }
            }
        }
        .safeAreaInset(edge: isLandscape ? .trailing : .bottom, spacing: 0) {
            if isLandscape {
                landscapeRail
            } else {
                controlsBar
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
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

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) { overflowMenu }
        ToolbarItemGroup(placement: .keyboard) { keyboardBar }
    }

    /// The "…" menu: markdown preview toggle, WAV export, settings, delete.
    private var overflowMenu: some View {
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

    /// Keyboard accessory bar: speak/pause + live word stats.
    private var keyboardBar: some View {
        Group {
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
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - Landscape side rail

    /// Landscape layout: controls live in a vertical rail on the trailing
    /// edge (user request — controls on the side, not the top, keeps the
    /// reading surface tall and clean). Portrait keeps the bottom bar.
    private var landscapeRail: some View {
        HStack(spacing: 10) {
            railProgressStrip
            railControls
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: 78)
        .background(.bar)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// Thin vertical progress strip on the rail's leading edge — the
    /// landscape twin of the portrait bar's progress capsule, filling
    /// bottom-up.
    @ViewBuilder
    private var railProgressStrip: some View {
        if let progress = player.progress, player.state == .speaking {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 3)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.accentColor, .purple],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 3, height: max(4, proxy.size.height * progress))
                }
            }
            .frame(width: 3)
        } else {
            Divider()
        }
    }

    private var railControls: some View {
        VStack(spacing: 10) {
            Button {
                showingVoicePicker = true
            } label: {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change voice")

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
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: playIcon)
                            .font(.body.bold())
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 46, height: 46)
            }
            .disabled(playButtonDisabled)

            if player.state == .speaking || player.state == .paused || player.state == .generating {
                Button {
                    Haptics.press()
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
            }

            Spacer(minLength: 0)

            Text(String(format: "%.2f×", player.rateMultiplier))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            // Vertical slider: lay the slider out horizontally at the slot's
            // HEIGHT, then rotate the visual 90° counter-clockwise around its
            // center (hit-testing follows the rotation). Min lands at the
            // bottom — slower down, faster up.
            GeometryReader { proxy in
                Slider(value: $player.rateMultiplier, in: 0.5...2.0, step: 0.05)
                    .rotationEffect(.degrees(-90))
                    .frame(width: proxy.size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(width: 34, height: 110)
        }
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
