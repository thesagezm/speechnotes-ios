import SwiftUI

/// Speech-to-text settings: engine picker, language hint, model list with
/// download/delete (mirrors Amical's STT model manager UX).
struct SttSettingsView: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @ObservedObject private var models = WhisperModelManager.shared

    private let languages = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("ja-JP", "Japanese"),
        ("zh-CN", "Chinese"),
    ]

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: $dictation.engineKind) {
                    ForEach(DictationCoordinator.EngineKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: dictation.engineKind) { _ in
                    // Coordinator rebuilds its engine on kind change
                }
                Text("Apple uses your device's built-in speech recognition (English-fluent, works offline once downloaded). Whisper is an offline model for tougher audio, accents, and 100+ languages.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Language", selection: $models.activeModelId) {
                    ForEach(languages, id: \.0) { code, label in
                        Text(label).tag(code)
                    }
                }
            }

            Section("Whisper models") {
                if models.installedModels.isEmpty {
                    Label(
                        "No Whisper models downloaded yet — pick one below to download.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                ForEach(WhisperModelManager.catalog) { model in
                    modelRow(model)
                }
            }
        }
        .navigationTitle("Speech-to-text")
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let state = models.state(for: model.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.displayName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(model.sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
                stars(level: model.speed)
                Image(systemName: "scope").foregroundStyle(.secondary)
                stars(level: model.accuracy)
                if model.englishOnly {
                    Text("EN")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            switch state {
            case .notDownloaded:
                Button {
                    models.startDownload(id: model.id)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%")
                }
                Button("Cancel", role: .destructive) {
                    models.cancelDownload(id: model.id)
                }
                .font(.footnote)
            case .failed(let message):
                Label("Failed: \(message)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                Button("Retry") { models.startDownload(id: model.id) }
                    .font(.footnote)
            case .ready:
                Label("Downloaded", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
                HStack {
                    Button {
                        models.activeModelId = model.id
                    } label: {
                        Label(
                            models.activeModelId == model.id ? "Active" : "Use this model",
                            systemImage: models.activeModelId == model.id ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    Spacer()
                    Button(role: .destructive) {
                        models.delete(id: model.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    private func stars(level: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < level ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
