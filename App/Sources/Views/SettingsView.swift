import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var player: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ModelManager.shared

    /// Every installed system voice, fetched once on appear and then reused —
    /// `speechSynthesisVoices()` can return a few hundred entries.
    @State private var systemVoices: [AVSpeechSynthesisVoice] = []

    /// Kokoro voice groups, derived once (voice prefix a* = American,
    /// b* = British).
    private static let americanVoices = ModelManager.knownVoices.filter { $0.hasPrefix("a") }
    private static let britishVoices = ModelManager.knownVoices.filter { $0.hasPrefix("b") }

    /// Any neural engine is selected AND its model is ready — the system
    /// engine (and so the system voice) is not in the playback path.
    private var neuralEngineIsActive: Bool {
        player.engineKind == .kokoroOnnx && !player.usingSystemFallback
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Speech engine") {
                    Picker("Engine", selection: $player.engineKind) {
                        ForEach(SpeechPlayer.EngineKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)

                    if player.engineKind == .kokoroOnnx && !models.isReady {
                        Label(
                            "Neural engine selected, but its model isn't downloaded yet — the system voice is used in the meantime.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Menu {
                        Section("American (a*)") {
                            ForEach(Self.americanVoices, id: \.self) { voice in
                                kokoroVoiceRow(voice)
                            }
                        }
                        Section("British (b*)") {
                            ForEach(Self.britishVoices, id: \.self) { voice in
                                kokoroVoiceRow(voice)
                            }
                        }
                    } label: {
                        dropdownRow(title: "Voice", value: player.voice)
                    }
                } header: {
                    Text("Kokoro voice")
                } footer: {
                    Text("Naming: a = American, b = British · f = female, m = male — e.g. am_eric is American male Eric.")
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
                        dropdownRow(title: "Voice", value: selectedSystemVoiceTitle)
                    }
                    .disabled(neuralEngineIsActive)

                    if neuralEngineIsActive {
                        Label(
                            "A Kokoro engine is active — the system voice only applies when Apple (system) is selected, or while a neural model is missing.",
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
                    switch models.state {
                    case .notDownloaded:
                        Button {
                            models.startDownload()
                        } label: {
                            Label("Download Kokoro model (~101 MB)", systemImage: "arrow.down.circle")
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
                        Button("Delete model (frees ~101 MB)", role: .destructive) {
                            models.deleteModels()
                        }
                    }
                } header: {
                    Text("Kokoro model")
                } footer: {
                    Text("One-time download, stored inside the app: the quantized model, all 28 voices, and the tokenizer. All speech generation stays on your device.")
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
    func kokoroVoiceRow(_ voice: String) -> some View {
        Button {
            player.voice = voice
        } label: {
            if player.voice == voice {
                Label(voice, systemImage: "checkmark")
            } else {
                Text(voice)
            }
        }
    }

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

    /// Compact dropdown-style control row: label, current value, chevron.
    func dropdownRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
    }
}
