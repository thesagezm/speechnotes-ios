import SwiftUI

/// Speech-to-text settings. Mirrors the TTS settings layout — the model
/// picker is an inline segmented-style list (like `VoicePickerSheet`), and
/// download/delete lives on a separate row per model.
struct SttSettingsView: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @ObservedObject private var models = WhisperModelManager.shared

    private var languages: [(code: String, label: String)] { DictationCoordinator.languages }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $dictation.engineKind) {
                    ForEach(DictationCoordinator.EngineKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                Text("Apple uses your device's built-in speech recognition (English-fluent, works offline once downloaded). Whisper is an offline model for tougher audio, accents, and 100+ languages.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Engine")
            }

            Section {
                if models.installedModels.isEmpty {
                    Label(
                        "No Whisper models downloaded yet — pick one below and tap Download.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                ForEach(WhisperModelManager.catalog) { model in
                    modelRow(model)
                    downloadRow(model)
                }
            } header: {
                Text("Whisper model")
            } footer: {
                Text("Tapping a model switches the active Whisper model. The Download/Delete row manages what's installed.")
            }

            Section {
                Picker("Language", selection: $dictation.languageHint) {
                    ForEach(languages, id: \.0) { code, label in
                        Text(label).tag(code)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Auto lets Whisper detect the spoken language per clip.")
            }
        }
        .navigationTitle("Speech-to-text")
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let isActive = models.activeModelId == model.id
        let isInstalled = models.isInstalled(model)
        Button {
            // Selecting a model is a passive action — just swap the
            // preference. The coordinator notices on the next record start
            // and rebuilds the engine.
            if isInstalled {
                models.activeModelId = model.id
                Haptics.tap()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : (isInstalled ? "circle" : "circle.dashed"))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.subheadline.weight(.medium))
                        if isActive {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        if model.englishOnly {
                            Text("EN")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(model.sizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if models.isInstalled(model) {
                            if let folder = WhisperModelManager.modelFolder(forId: model.id) {
                                Text(folder.lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isInstalled)
    }

    @ViewBuilder
    private func downloadRow(_ model: WhisperModel) -> some View {
        let state = models.state(for: model.id)
        switch state {
        case .notDownloaded:
            Button {
                models.startDownload(id: model.id)
                Haptics.tap()
            } label: {
                Label("Download \(model.displayName)", systemImage: "arrow.down.circle")
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress) {
                    Text("Downloading \(model.displayName)… \(Int(progress * 100))%")
                }
                HStack {
                    Button("Cancel", role: .destructive) {
                        models.cancelDownload(id: model.id)
                    }
                    .font(.footnote)
                    Spacer()
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Failed: \(message)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                HStack {
                    Button("Retry") { models.startDownload(id: model.id) }
                        .font(.footnote)
                    Spacer()
                }
            }
        case .ready:
            HStack {
                Label("Downloaded", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
                Spacer()
                Button(role: .destructive) {
                    models.delete(id: model.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .font(.footnote)
            }
        }
    }

    private func stars(_ level: Int, icon: String) -> some View {
        HStack(spacing: 1) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < level ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
