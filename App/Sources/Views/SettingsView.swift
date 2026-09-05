import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var player: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ModelManager.shared

    /// Every installed system voice, fetched once on appear and then reused —
    /// `speechSynthesisVoices()` can return a few hundred entries.
    @State private var systemVoices: [AVSpeechSynthesisVoice] = []
    @State private var showingVoicePicker = false
    @AppStorage("renderMarkdown") private var renderMarkdown = false

    /// Any neural engine is selected AND its model is ready — the system
    /// engine (and so the system voice) is not in the playback path.
    private var neuralEngineIsActive: Bool {
        (player.engineKind == .kokoroOnnx || player.engineKind == .kitten || player.engineKind == .supertonic)
            && !player.usingSystemFallback
    }

    /// The voice preference of whichever engine is selected.
    private var activeVoiceCodename: String {
        switch player.engineKind {
        case .kitten: return player.kittenVoice
        case .supertonic: return player.supertonicVoice
        default: return player.voice
        }
    }

    private var neuralModelMissing: Bool {
        switch player.engineKind {
        case .kokoroOnnx: return !models.isReady
        case .kitten: return !models.kittenIsReady
        case .supertonic: return !models.supertonicIsReady
        default: return false
        }
    }

    private var voicePickerScope: VoicePickerSheet.Scope {
        switch player.engineKind {
        case .kitten: return .kitten
        case .supertonic: return .supertonic
        default: return .kokoro
        }
    }

    private var voiceSectionHeader: String {
        switch player.engineKind {
        case .kitten: return "Kitten voice"
        case .supertonic: return "Supertonic voice"
        default: return "Kokoro voice"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Render Markdown", isOn: $renderMarkdown)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("When on, the editor gains a preview mode (eye button): headings, emphasis and links are rendered for reading, and speech reads the plain text without markdown symbols. Off keeps everything as raw text.")
                }

                Section {
                    Picker("Engine", selection: $player.engineKind) {
                        ForEach(SpeechPlayer.EngineKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)

                    if neuralModelMissing {
                        Label(
                            "Neural engine selected, but its model isn't downloaded yet — the system voice is used in the meantime.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Speech engine")
                } footer: {
                    Text("Listed worst to best. Supertonic sounds the best (10 voice styles, 31 languages). Kokoro is the solid default (28 voices). Apple's system voice beats Kitten, which is tiny and rough.")
                }

                Section {
                    Button {
                        showingVoicePicker = true
                    } label: {
                        HStack {
                            Text("Voice")
                            Spacer()
                            Text(VoiceCatalog.subtitle(
                                for: activeVoiceCodename,
                                kind: player.engineKind
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text(voiceSectionHeader)
                } footer: {
                    switch player.engineKind {
                    case .kitten:
                        Text("Tap a voice in the picker to hear a sample before committing.")
                    case .supertonic:
                        Text("10 voice styles, all fluent in 31 languages — pick the language in the voice picker. Tap a voice to hear a sample.")
                    default:
                        Text("Friendly names with codenames — e.g. Heart is af_heart, American female. Tap a voice to hear a sample.")
                    }
                }

                Section {
                    switch models.supertonicState {
                    case .notDownloaded:
                        Button {
                            models.startSupertonicDownload()
                        } label: {
                            Label("Download Supertonic model (~399 MB)", systemImage: "arrow.down.circle")
                        }
                    case .downloading(let progress):
                        ProgressView(value: progress) {
                            Text("Downloading Supertonic… \(Int(progress * 100))%")
                        }
                    case .failed(let message):
                        Label("Supertonic download failed: \(message)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                        Button("Retry") {
                            models.startSupertonicDownload()
                        }
                    case .ready:
                        Label("Supertonic model ready", systemImage: "checkmark.circle")
                        Button("Delete Supertonic model (frees ~399 MB)", role: .destructive) {
                            models.deleteSupertonicModels()
                        }
                    }
                } header: {
                    Text("Supertonic model")
                } footer: {
                    Text("Supertone supertonic-3 — flow-matching TTS with 31 languages (English, Korean, Japanese, German, French and more) and 10 voice styles. Large (~399 MB) and CPU-based; keep it as the optional multilingual engine alongside Kokoro.")
                }

                Section {
                    switch models.state {
                    case .notDownloaded:
                        Button {
                            models.startDownload()
                        } label: {
                            Label("Download Kokoro model (~341 MB)", systemImage: "arrow.down.circle")
                        }
                    case .downloading(let progress):
                        ProgressView(value: progress) {
                            Text("Downloading… \(Int(progress * 100))%")
                        }
                    case .failed(let message):
                        Label("Download failed: \(message)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                        Button("Retry") {
                            models.startDownload()
                        }
                    case .ready:
                        Label("Model ready — fully offline", systemImage: "checkmark.circle")
                        Button("Delete model (frees ~341 MB)", role: .destructive) {
                            models.deleteModels()
                        }
                    }
                } header: {
                    Text("Kokoro model")
                } footer: {
                    Text("One-time download, stored inside the app: the fp32-quality model, all 28 voices, and the tokenizer. All speech generation stays on your device.")
                }

                Section {
                    switch models.kittenState {
                    case .notDownloaded:
                        Button {
                            models.startKittenDownload()
                        } label: {
                            Label("Download Kitten model (~82 MB)", systemImage: "arrow.down.circle")
                        }
                    case .downloading(let progress):
                        ProgressView(value: progress) {
                            Text("Downloading Kitten… \(Int(progress * 100))%")
                        }
                    case .failed(let message):
                        Label("Kitten download failed: \(message)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                        Button("Retry") {
                            models.startKittenDownload()
                        }
                    case .ready:
                        Label("Kitten model ready", systemImage: "checkmark.circle")
                        Button("Delete Kitten model (frees ~82 MB)", role: .destructive) {
                            models.deleteKittenModels()
                        }
                    }
                } header: {
                    Text("Kitten model")
                } footer: {
                    Text("KittenTTS mini 0.8 — 80M parameters, 8 expressive voices. Optional; Kokoro above is the main engine.")
                }

                Section {
                    Menu {
                        systemVoiceRow(title: "Default (English)", identifier: nil)
                        ForEach(systemVoices, id: \.identifier) { voice in
                            systemVoiceRow(
                                title: systemVoiceTitle(voice),
                                identifier: voice.identifier
                            )
                        }
                    } label: {
                        HStack {
                            Text("Voice")
                            Spacer()
                            Text(selectedSystemVoiceTitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(neuralEngineIsActive)

                    if neuralEngineIsActive {
                        Label(
                            "A neural engine is active — the system voice only applies when Apple (system) is selected, or while a neural model is missing.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("System voice")
                } footer: {
                    Text("Used by Apple's built-in speech. Enhanced and premium voices sound richer; download them under Settings → Accessibility → Spoken Content → Voices.")
                }
            }
            .navigationTitle("Speech Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingVoicePicker) {
                VoicePickerSheet(scope: voicePickerScope)
                    .environmentObject(player)
            }
            .onAppear {
                guard systemVoices.isEmpty else { return }
                systemVoices = AVSpeechSynthesisVoice.speechVoices()
                    .sorted { lhs, rhs in
                        if lhs.language != rhs.language { return lhs.language < rhs.language }
                        return lhs.name < rhs.name
                    }
            }
        }
    }
}

// MARK: - Row builders

private extension SettingsView {
    @ViewBuilder
    func systemVoiceRow(title: String, identifier: String?) -> some View {
        Button {
            player.systemVoiceIdentifier = identifier
        } label: {
            if player.systemVoiceIdentifier == identifier {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Menu row title for a system voice: name, language, and quality badge
    /// for the downloaded enhanced/premium tiers.
    func systemVoiceTitle(_ voice: AVSpeechSynthesisVoice) -> String {
        var title = "\(voice.name) (\(voice.language))"
        switch voice.quality {
        case .enhanced:
            title += " · Enhanced"
        case .premium:
            title += " · Premium"
        default:
            break
        }
        return title
    }

    var selectedSystemVoiceTitle: String {
        guard let identifier = player.systemVoiceIdentifier,
              let voice = systemVoices.first(where: { $0.identifier == identifier })
        else { return "Default (English)" }
        return "\(voice.name) (\(voice.language))"
    }
}
