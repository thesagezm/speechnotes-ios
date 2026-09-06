import SwiftUI
import AVFoundation

struct SpeechSettingsView: View {
    @EnvironmentObject private var player: SpeechPlayer
    @ObservedObject private var models = ModelManager.shared
    @State private var systemVoices: [AVSpeechSynthesisVoice] = []
    @State private var showingVoicePicker = false
    @AppStorage("renderMarkdown") private var renderMarkdown = false

    private var neuralEngineIsActive: Bool {
        (player.engineKind == .kokoroOnnx || player.engineKind == .kokoroSmall || player.engineKind == .supertonic)
            && !player.usingSystemFallback
    }

    private var activeVoiceCodename: String {
        switch player.engineKind {
        case .supertonic: return player.supertonicVoice
        default: return player.voice
        }
    }

    private var neuralModelMissing: Bool {
        switch player.engineKind {
        case .kokoroOnnx: return !models.isReady
        case .kokoroSmall: return !models.smallIsReady
        case .supertonic: return !models.supertonicIsReady
        default: return false
        }
    }

    private var voicePickerScope: VoicePickerSheet.Scope {
        switch player.engineKind {
        case .kokoroSmall: return .kokoroSmall
        case .supertonic: return .supertonic
        default: return .kokoro
        }
    }

    private var voiceSectionHeader: String {
        switch player.engineKind {
        case .kokoroSmall, .kokoroOnnx: return "Kokoro voice"
        case .supertonic: return "Supertonic voice"
        default: return "Kokoro voice"
        }
    }

    var body: some View {
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
                Text("Listed worst to best. Supertonic sounds the best (10 voice styles, 31 languages). Kokoro uint8 (~177 MB) is the lightweight tier; Kokoro fp32 is the solid default. All use the same 28 voices.")
            }

            Section {
                Button {
                    showingVoicePicker = true
                } label: {
                    HStack {
                        Text("Voice")
                        Spacer()
                        Text(VoiceCatalog.subtitle(for: activeVoiceCodename, kind: player.engineKind))
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
                case .supertonic:
                    Text("10 voice styles, all fluent in 31 languages — pick the language in the voice picker. Tap a voice to hear a sample.")
                default:
                    Text("Friendly names with codenames — e.g. Heart is af_heart, American female. Tap a voice to hear a sample.")
                }
            }

            Section {
                Menu {
                    systemVoiceRow(title: "Default (English)", identifier: nil)
                    ForEach(systemVoices, id: \.identifier) { voice in
                        systemVoiceRow(title: systemVoiceTitle(voice), identifier: voice.identifier)
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

            Section {
                switch models.supertonicState {
                case .notDownloaded:
                    Button { models.startSupertonicDownload() } label: {
                        Label("Download Supertonic model (~399 MB)", systemImage: "arrow.down.circle")
                    }
                case .downloading(let progress):
                    ProgressView(value: progress) { Text("Downloading Supertonic… \(Int(progress*100))%") }
                case .failed(let message):
                    Label("Supertonic download failed: \(message)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                    Button("Retry") { models.startSupertonicDownload() }
                case .ready:
                    Label("Supertonic model ready", systemImage: "checkmark.circle")
                    Button("Delete Supertonic model (frees ~399 MB)", role: .destructive) { models.deleteSupertonicModels() }
                }
            } header: { Text("Supertonic model") } footer: {
                Text("Supertone supertonic-3 — flow-matching TTS with 31 languages and 10 voice styles. Large (~399 MB) and CPU-based; keep it as the optional multilingual engine alongside Kokoro.")
            }

            Section {
                switch models.state {
                case .notDownloaded:
                    Button { models.startDownload() } label: { Label("Download Kokoro model (~341 MB)", systemImage: "arrow.down.circle") }
                case .downloading(let progress):
                    ProgressView(value: progress) { Text("Downloading… \(Int(progress*100))%") }
                case .failed(let message):
                    Label("Download failed: \(message)", systemImage: "exclamationmark.triangle").font(.footnote)
                    Button("Retry") { models.startDownload() }
                case .ready:
                    Label("Model ready — fully offline", systemImage: "checkmark.circle")
                    Button("Delete model (frees ~341 MB)", role: .destructive) { models.deleteModels() }
                }
            } header: { Text("Kokoro model") } footer: {
                Text("One-time download, stored inside the app: the fp32-quality model, all 28 voices, and the tokenizer. All speech generation stays on your device.")
            }

            Section {
                switch models.smallState {
                case .notDownloaded:
                    Button { models.startSmallDownload() } label: { Label("Download Kokoro small model (~177 MB)", systemImage: "arrow.down.circle") }
                case .downloading(let progress):
                    ProgressView(value: progress) { Text("Downloading Kokoro small… \(Int(progress*100))%") }
                case .failed(let message):
                    Label("Download failed: \(message)", systemImage: "exclamationmark.triangle").font(.footnote)
                    Button("Retry") { models.startSmallDownload() }
                case .ready:
                    Label("Small model ready — fully offline", systemImage: "checkmark.circle")
                    Button("Delete small model (frees ~177 MB)", role: .destructive) { models.deleteSmallModel() }
                }
            } header: { Text("Kokoro small model") } footer: {
                Text("The uint8 build of the same Kokoro graph — half the footprint of fp32 with a small quality step down. Shares the 28-voice catalog, tokenizer and voice bank with the model above.")
            }
        }
        .navigationTitle("Speech Settings")
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerSheet(scope: voicePickerScope).environmentObject(player)
        }
        .onAppear {
            guard systemVoices.isEmpty else { return }
            systemVoices = AVSpeechSynthesisVoice.speechVoices()
                .sorted { $0.language != $1.language ? $0.language < $1.language : $0.name < $1.name }
        }
    }

    private func systemVoiceRow(title: String, identifier: String?) -> some View {
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

    private func systemVoiceTitle(_ voice: AVSpeechSynthesisVoice) -> String {
        var title = "\(voice.name) (\(voice.language))"
        switch voice.quality {
        case .enhanced: title += " · Enhanced"
        case .premium: title += " · Premium"
        default: break
        }
        return title
    }

    private var selectedSystemVoiceTitle: String {
        guard let id = player.systemVoiceIdentifier, let v = systemVoices.first(where: { $0.identifier == id }) else { return "Default (English)" }
        return "\(v.name) (\(v.language))"
    }
}
