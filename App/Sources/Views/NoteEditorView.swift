import SwiftUI
import SpeechLogic
import UIKit
import UniformTypeIdentifiers

struct NoteEditorView: View {
    let noteId: UUID

    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var titleDraft: String = ""
    @State private var didLoad = false
    @State private var showingSettings = false
    @State private var showingVoicePicker = false
    @State private var showingDeleteConfirm = false
    @State private var textSelection: Range<String.Index>?
    @State private var showingImageSource = false
    @State private var showingPhotoPicker = false
    @State private var showingImageURLPrompt = false
    @State private var showingLinkPrompt = false
    @State private var pendingLinkLabel: String = ""
    @State private var pendingLinkURL: String = ""
    @State private var imageURLDraft: String = ""
    /// Live caret / selection from MarkdownEditorView (UITextView), UTF-16
    /// offsets. The format bar reads `formattingBarSelection` (a bridged
    /// String.Index binding) so it doesn't need to know the editor is UIKit.
    @State private var selectionUTF16: Range<Int>?
    @FocusState private var editorFocused: Bool
    /// Reading mode's in-app browser for tapped markdown links (the preview
    /// now uses AttributedString links + openURL instead of per-run buttons).
    @State private var safariURL: URL?
    /// Markdown rendering mode — only meaningful when the Render Markdown
    /// setting is on; opens in preview (reading) mode, double-tap to edit.
    @State private var showPreview = true
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
    /// Debounce task for speech cache updates — running MarkdownText.plainText
    /// synchronously on every keystroke blocked the main thread for long notes.
    @State private var speechCacheTask: Task<Void, Never>?

    private var speechText: String { cachedSpeechText }

    private func updateSpeechCaches() {
        cachedSpeechText = renderMarkdown ? MarkdownText.plainText(draft) : draft
        cachedWordCount = draft.split(whereSeparator: \.isWhitespace).count
    }

    /// Debounce speech cache updates: MarkdownText.plainText runs a full
    /// regex parse over the whole draft; doing that synchronously per
    /// keystroke blocked the main thread for long notes. Now we wait until
    /// ~300ms after typing stops, run the parse off-main, and hop back to
    /// update the cached values.
    private func scheduleSpeechCacheUpdate() {
        speechCacheTask?.cancel()
        let draftCopy = draft
        let render = renderMarkdown
        speechCacheTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let plainText = await Task.detached(priority: .userInitiated) {
                render ? MarkdownText.plainText(draftCopy) : draftCopy
            }.value
            let words = await Task.detached(priority: .userInitiated) {
                draftCopy.split(whereSeparator: \.isWhitespace).count
            }.value
            await MainActor.run {
                guard !Task.isCancelled else { return }
                cachedSpeechText = plainText
                cachedWordCount = words
            }
        }
    }

    /// UITextView reports caret changes as UTF-16 offsets; the markdown
    /// formatting bar's API takes a `Range<String.Index>?`. This binding does
    /// the conversion so the bar can read and write selection uniformly.
    private var formattingBarSelection: Binding<Range<String.Index>?> {
        Binding(
            get: {
                guard let r = selectionUTF16 else { return nil }
                guard r.lowerBound >= 0, r.upperBound <= draft.utf16.count,
                      r.lowerBound <= r.upperBound else { return nil }
                guard let lo = String.Index(draft.utf16.index(draft.utf16.startIndex, offsetBy: r.lowerBound), within: draft),
                      let hi = String.Index(draft.utf16.index(draft.utf16.startIndex, offsetBy: r.upperBound), within: draft) else { return nil }
                return lo..<hi
            },
            set: { newValue in
                if let r = newValue {
                    let lo = draft.utf16.distance(from: draft.utf16.startIndex, to: r.lowerBound)
                    let hi = draft.utf16.distance(from: draft.utf16.startIndex, to: r.upperBound)
                    selectionUTF16 = lo..<hi
                } else {
                    selectionUTF16 = nil
                }
            }
        )
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

    /// Play/pause icon for the keyboard toolbar — mirrors PlayerControlsBar.
    private var keyboardPlayIcon: String {
        switch player.state {
        case .generating: return "hourglass"
        case .speaking: return "pause.fill"
        case .paused, .idle: return "play.fill"
        }
    }

    /// Disabled state for the keyboard Speak button.
    private var keyboardPlayDisabled: Bool {
        player.isExporting
            || player.state == .idle
                && speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            titleField
            if renderMarkdown && showPreview {
                markdownPreview
            } else {
                editBody
            }
            PlayerControlsBar(speechText: speechText, note: currentNote)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .onReceive(NotificationCenter.default.publisher(for: .requestVoicePicker)) {
            showingVoicePicker = true
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete note", role: .destructive) {
                player.stop()
                notes.delete(noteId: noteId)
                NoteImageStore.removeAllImages(for: noteId)
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
        .confirmationDialog("Insert image", isPresented: $showingImageSource, titleVisibility: .visible) {
            Button("Choose from Photos") { showingPhotoPicker = true }
            Button("Paste from Clipboard") { pasteImageFromClipboard() }
            Button("From URL…") { showingImageURLPrompt = true }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingPhotoPicker) {
            ImagePicker { data, ext in
                Task { @MainActor in
                    let fragment = await MarkdownImageInserter(noteId: noteId).store(data: data, ext: ext, alt: "image")
                    if let fragment { insertAtCaret(fragment) }
                }
            }
        }
        .alert("Insert from URL", isPresented: $showingImageURLPrompt) {
            TextField("https://…", text: $imageURLDraft)
            Button("Insert") {
                guard let url = URL(string: imageURLDraft) else { return }
                Task { @MainActor in
                    let fragment = await MarkdownImageInserter(noteId: noteId).storeFromURL(url, alt: "image")
                    insertAtCaret(fragment)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll download the image once and store it locally.")
        }
        .alert("Insert link", isPresented: $showingLinkPrompt) {
            TextField("Label", text: $pendingLinkLabel)
            TextField("https://…", text: $pendingLinkURL)
            Button("Insert") {
                insertAtCaret("[\(pendingLinkLabel)](\(pendingLinkURL))")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll make the label tappable in the reading view.")
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
            speechCacheTask?.cancel()
            speechCacheTask = nil
            saveDraft()
            notes.flushNow()
        }
        .onChange(of: player.shareURL) { newValue in
            if newValue != nil { Haptics.success() }
        }
        .onChange(of: renderMarkdown) { _ in
            // Reading the setting directly recomputes the full-text regex —
            // fine on an explicit user toggle (this used to run per keystroke).
            scheduleSpeechCacheUpdate()
            if renderMarkdown { showPreview = true }
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
        ZStack(alignment: .topTrailing) {
            MarkdownPreviewView(markdown: draft)
                .onTapGesture(count: 2) {
                    Haptics.tap()
                    showPreview = false
                }
                // Single tap in preview: no-op — we don't want readers
                // accidentally switching to edit mode while scrolling.
                .onTapGesture(count: 1) {}
            // Reading-mode indicator with pencil affordance at the corner so
            // the editor hint is discoverable without a double-tap mystery.
            Image(systemName: "pencil.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .opacity(0.4)
                .padding(10)
                .onTapGesture {
                    Haptics.tap()
                    showPreview = false
                }
                .accessibilityLabel("Switch to edit")
                .accessibilityHint("Double-tap to switch to edit mode")
        }
        .environmentObject(theme)
        .environment(\.noteId, noteId)
        .environment(\.openURL, OpenURLAction { url in
            safariURL = url
            return .handled
        })
        .sheet(item: $safariURL) { url in
            SafariSheet(url: url)
                .ignoresSafeArea()
        }
    }

    /// Edit branch extracted from `body` so SwiftUI's type checker doesn't
    /// time out on the long modifier chain.
    @ViewBuilder
    private var editBody: some View {
        MarkdownEditorView(
            text: $draft,
            selection: $selectionUTF16,
            onCaretMoved: { },
            focusState: $editorFocused,
            textScale: theme.previewTextScale
        )
        .font(.body)
        .padding(.horizontal, 12)
        .onChange(of: draft) { _ in
            scheduleDraftSync()
            scheduleSpeechCacheUpdate()
        }
        if renderMarkdown {
            MarkdownFormattingBar(
                draft: $draft,
                selection: formattingBarSelection,
                insertImage: { showingImageSource = true },
                insertLink: { label, url in
                    pendingLinkLabel = label
                    pendingLinkURL = url
                    showingLinkPrompt = true
                }
            )
        }
    }

    /// Toolbar extracted for the same reason as `editBody`.
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
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
                    // Flush any pending draft changes so the exported text is
                    // what the user just wrote, not whatever the 400 ms
                    // debounce last committed.
                    updateSpeechCaches()
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
                // Snapshot first; the cached copy can lag by one edit cycle.
                scheduleSpeechCacheUpdate()
                player.togglePlay(speechText, note: currentNote)
            } label: {
                Label(
                    player.state == .speaking ? "Pause" : "Speak",
                    systemImage: keyboardPlayIcon
                )
            }
            .disabled(keyboardPlayDisabled)

            Spacer()

            Text(draftStats)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    /// Controls are rendered by PlayerControlsBar — extracted so player
    /// state changes don't re-evaluate the title field, editor, or sheets.
    private var controlsBar: some View {
        PlayerControlsBar(speechText: speechText, note: currentNote)
    }

    private func saveDraft() {
        guard var note = currentNote else { return }
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        guard note.text != draft || note.explicitTitle != newTitle else { return }
        note.text = draft
        note.explicitTitle = newTitle
        notes.update(note)
        // Drop cached images the markdown no longer references.
        NoteImageStore.prune(noteId: noteId, markdown: draft)
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
            // plainText() is a full-document regex pass — keep it with the
            // debounce instead of running it per keystroke.
            scheduleSpeechCacheUpdate()
        }
    }

    /// Insert `fragment` at the current caret (replaces any selection).
    /// Used by the formatting bar / image picker / link prompt.
    private func insertAtCaret(_ fragment: String) {
        let utf16: Range<Int> = selectionUTF16 ?? (draft.utf16.count..<draft.utf16.count)
        guard utf16.lowerBound >= 0, utf16.upperBound <= draft.utf16.count,
              utf16.lowerBound <= utf16.upperBound else { return }
        guard let lo = String.Index(draft.utf16.index(draft.utf16.startIndex, offsetBy: utf16.lowerBound), within: draft),
              let hi = String.Index(draft.utf16.index(draft.utf16.startIndex, offsetBy: utf16.upperBound), within: draft) else { return }
        let range: Range<String.Index> = lo..<hi
        var updated = draft
        updated.replaceSubrange(range, with: fragment)
        let insertEndUtf16 = updated.utf16.distance(from: updated.startIndex, to: range.lowerBound) + fragment.utf16.count
        draft = updated
        if let idx = updated.utf16.index(updated.utf16.startIndex, offsetBy: insertEndUtf16, limitedBy: updated.utf16.endIndex).flatMap({ String.Index($0, within: updated) }) {
            let caret = updated.utf16.distance(from: updated.utf16.startIndex, to: idx)
            selectionUTF16 = caret..<caret
        }
        scheduleDraftSync()
        scheduleSpeechCacheUpdate()
        Haptics.tap()
    }

    /// Try to paste an image from the clipboard. Supports both PNG (most
    /// common) and any NSItemProvider variant that carries image data.
    private func pasteImageFromClipboard() {
        let pb = UIPasteboard.general
        guard pb.hasImages, let image = pb.image else {
            Haptics.warning()
            return
        }
        guard let data = image.pngData() else { return }
        Task { @MainActor in
            let fragment = await MarkdownImageInserter(noteId: noteId).store(data: data, ext: "png", alt: "image")
            if let fragment { insertAtCaret(fragment) }
        }
    }
}
