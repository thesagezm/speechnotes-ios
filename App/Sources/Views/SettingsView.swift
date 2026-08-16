import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var player: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ModelManager.shared

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

                    if player.engineKind == .kokoro && !models.isReady {
                        Label(
                            "Kokoro selected, but its model isn't downloaded yet — the system voice is used in the meantime.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    switch models.state {
                    case .notDownloaded:
                        Button {
                            models.startDownload()
                        } label: {
                            Label("Download Kokoro model (~342 MB)", systemImage: "arrow.down.circle")
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
                        Button("Delete model (frees ~342 MB)", role: .destructive) {
                            models.deleteModels()
                        }
                    }
                } header: {
                    Text("Kokoro model")
                } footer: {
                    Text("One-time download, stored inside the app. All speech generation stays on your device.")
                }

                Section {
                    ForEach(ModelManager.knownVoices, id: \.self) { voice in
                        Button {
                            player.voice = voice
                        } label: {
                            HStack {
                                Text(voice)
                                Spacer()
                                if player.voice == voice {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Kokoro voice")
                } footer: {
                    Text("Naming: a = American, b = British · f = female, m = male — e.g. am_eric is American male Eric.")
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
        }
    }
}
