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

    /// Any neural engine is selected AND its model is ready — the system
    /// engine (and so the system voice) is not in the playback path.
    private var neuralEngineIsActive: Bool {
        (player.engineKind == .kokoroOnnx || player.engineKind == .kitten)
            && !player.usingSystemFallback
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: $player.engineKind) {
                        ForEach(SpeechPlayer.EngineKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)

                    if (player.engineKind == .kokoroOnnx && !models.isReady)
                        || (player.engineKind == .kitten && !models.kittenIsReady) {
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
                    Text("Kokoro is the main engine (28 voices). Kitten is a smaller experimental pack (8 voices).")
                }

                Section {
                    Button {
                        showingVoicePicker = true
                    } label: {
                        HStack {
                            Text("Voice")
                            Spacer()
                            Text(VoiceCatalog.subtitle(
                                for: player.engineKind == .kitten ? player.kittenVoice : player.voice,
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
                    Text(player.engineKind == .kitten ? "Kitten voice" : "Kokoro voice")
                } footer: {
                    if player.engineKind == .kitten {
                        Text("Tap a voice in the picker to hear a sample before committing.")
                    } else {
                        Text("Friendly names with codenames — e.g. Heart is af_heart, American female. Tap a voice to hear a sample.")
                    }
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
                    switch models.state {
                    case .notDownloaded:
                        Button {
                            models.startDownload()
                        } label: {
                            Label("Download Kokoro model (~192 MB)", systemImage: "arrow.down.circle")
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
                        Button("Delete model (frees ~192 MB)", role: .destructive) {
                            models.deleteModels()
                        }
                    }
                } header: {
                    Text("Kokoro model")
                } footer: {
                    Text("One-time download, stored inside the app: the uint8 quality model, all 28 voices, and the tokenizer. All speech generation stays on your device.")
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
                VoicePickerSheet(scope: player.engineKind == .kitten ? .kitten : .kokoro)
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
