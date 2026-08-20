import SwiftUI
import UniformTypeIdentifiers

struct DictationTabView: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var notes: NotesStore
    @State private var languageHint: String = "auto"
    @State private var savingMessage: String?
    @State private var importingAudio = false
    @State private var importingError: String?
    @State private var isImporting = false
    @State private var lastSavedNoteId: UUID?

    private let languages = [
        ("auto", "Auto"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("ja-JP", "Japanese"),
        ("zh-CN", "Chinese"),
    ]

    private static var audioTypes: [UTType] {
        var types: [UTType] = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
        if let aac = UTType("public.aac-audio") { types.append(aac) }
        if let flac = UTType("org.xiph.flac") { types.append(flac) }
        if let caf = UTType("com.apple.coreaudio-format") { types.append(caf) }
        return types
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                engineSummary

                Picker("Language", selection: $languageHint) {
                    ForEach(languages, id: \.0) { code, label in
                        Text(label).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.08))
                    ScrollView {
                        Text(dictation.partialText.isEmpty ? placeholderText : dictation.partialText)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding(.horizontal)

                HStack(spacing: 12) {
                    Text(String(format: "%.1fs", dictation.elapsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        dictation.stopRecording()
                        saveTranscript()
                    } label: {
                        Label("Save as note", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(dictation.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    if dictation.state == .recording {
                        dictation.stopRecording()
                        saveTranscript()
                    } else {
                        dictation.startRecording(language: languageHint == "auto" ? nil : languageHint)
                    }
                } label: {
                    Image(systemName: dictation.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 84))
                        .foregroundStyle(dictation.state == .recording ? .red : Color.accentColor)
                }
                .padding(.bottom, 36)
            }
            .navigationTitle("Speech to text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        SttSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .fileImporter(
                isPresented: $importingAudio,
                allowedContentTypes: Self.audioTypes,
                allowsMultipleSelection: false
            ) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { await importAudio(at: url) }
                    case .failure(let error):
                        importingError = error.localizedDescription
                    }
                }
            }
            .onOpenURL { url in
                guard isAudio(url) else { return }
                Task { @MainActor in await importAudio(at: url) }
            }
            .alert(
                "Saved as new note",
                isPresented: Binding(
                    get: { savingMessage != nil },
                    set: { if !$0 { savingMessage = nil } }
                )
            ) {
                Button("OK") { savingMessage = nil }
            } message: {
                Text(savingMessage ?? "")
            }
            .alert(
                "Audio import failed",
                isPresented: Binding(
                    get: { importingError != nil },
                    set: { if !$0 { importingError = nil } }
                )
            ) {
                Button("OK") { importingError = nil }
            } message: {
                Text(importingError ?? "")
            }
            .overlay {
                if isImporting {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView(value: dictation.importProgress ?? 0.0)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(width: 220)
                            Text(dictation.importProgressLabel.isEmpty ? "Transcribing audio…" : dictation.importProgressLabel)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                        .padding(24)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.55)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var engineSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.mic")
                        .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(dictation.engineKind.label)
                    .font(.subheadline.weight(.medium))
                Text("Dictate with the mic, or import an audio file to transcribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                importingAudio = true
            } label: {
                Label("Import audio", systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(isImporting || dictation.state == .recording)
        }
        .padding(.horizontal)
    }

    private var placeholderText: String {
        switch dictation.state {
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        default: return "Tap the mic to start. Your words will appear here as you speak."
        }
    }

    private func saveTranscript() {
        let text = dictation.consumeFinal()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let note = notes.createNote()
        var updated = note
        updated.text = text
        notes.update(updated)
        lastSavedNoteId = note.id
        savingMessage = "Saved \(text.count) characters as a new note."
        Haptics.success()
    }

    private func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["wav", "mp3", "m4a", "aac", "flac", "caf", "aif", "aiff"].contains(ext) { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return Self.audioTypes.contains { type.conforms(to: $0) }
        }
        return false
    }

    private func importAudio(at url: URL) async {
        isImporting = true
        defer { isImporting = false }
        let lang = languageHint == "auto" ? nil : languageHint
        do {
            let text = try await dictation.transcribeAudioFile(at: url, language: lang)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                importingError = "No speech detected in \(url.lastPathComponent)."
                return
            }
            let note = notes.createNote()
            var updated = note
            updated.explicitTitle = url.deletingPathExtension().lastPathComponent
            updated.text = text
            notes.update(updated)
            lastSavedNoteId = note.id
            savingMessage = "Imported \(url.lastPathComponent) (\(text.count) chars)."
            Haptics.success()
        } catch {
            importingError = error.localizedDescription
            Haptics.warning()
        }
    }
}
