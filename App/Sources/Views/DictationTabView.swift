import SwiftUI

struct DictationTabView: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var notes: NotesStore
    @State private var languageHint: String = "auto"
    @State private var savingMessage: String?
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
                        .foregroundStyle(dictation.state == .recording ? .red : .accentColor)
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
        }
    }

    @ViewBuilder
    private var engineSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.mic")
                .foregroundStyle(.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(dictation.engineKind.label)
                    .font(.subheadline.weight(.medium))
                Text("Tap the mic to start dictating. Stop to save what you said as a new note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
}
