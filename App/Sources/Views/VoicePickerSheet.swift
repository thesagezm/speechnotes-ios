import SwiftUI

/// Full-screen voice picker: searchable, sectioned by accent/gender, with
/// tap-to-audition so a voice is heard before it's committed. Works for both
/// neural engines via `scope`.
struct VoicePickerSheet: View {
    enum Scope {
        case kokoro
        case kitten

        var engineKind: SpeechPlayer.EngineKind {
            self == .kitten ? .kitten : .kokoroOnnx
        }

        var title: String {
            self == .kitten ? "Kitten voice" : "Kokoro voice"
        }
    }

    let scope: Scope

    @EnvironmentObject private var player: SpeechPlayer
    @ObservedObject private var models = ModelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var descriptors: [VoiceDescriptor] {
        VoiceCatalog.descriptors(for: scope.engineKind)
    }

    private var selectedVoice: String {
        scope == .kitten ? player.kittenVoice : player.voice
    }

    private var modelReady: Bool {
        scope == .kitten ? models.kittenIsReady : models.isReady
    }

    private var filtered: [VoiceDescriptor] {
        guard !searchText.isEmpty else { return descriptors }
        let needle = searchText.lowercased()
        return descriptors.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.id.lowercased().contains(needle)
                || ($0.subtitle.lowercased().contains(needle))
        }
    }

    /// Recent selections (most recent first), intersected with known voices.
    private var recents: [VoiceDescriptor] {
        let recentIds = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        return recentIds.compactMap { id in descriptors.first { $0.id == id } }
    }

    private var recentKey: String {
        scope == .kitten ? "recentKittenVoices" : "recentKokoroVoices"
    }

    /// Section grouping preserving descriptor order.
    private var sections: [(title: String, voices: [VoiceDescriptor])] {
        var order: [String] = []
        var groups: [String: [VoiceDescriptor]] = [:]
        for descriptor in filtered {
            let key = [descriptor.accent, descriptor.gender]
                .compactMap { $0 }
                .joined(separator: " ")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(descriptor)
        }
        return order.map { ($0, groups[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !searchText.isEmpty && filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    if searchText.isEmpty, !recents.isEmpty {
                        Section("Recent") {
                            ForEach(recents) { descriptor in
                                voiceRow(descriptor)
                            }
                        }
                    }
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.voices) { descriptor in
                                voiceRow(descriptor)
                            }
                        }
                    }
                    if !modelReady {
                        Section {
                            Label(
                                "Download the model (Settings) to hear these voices.",
                                systemImage: "arrow.down.circle"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search name or codename")
            .navigationTitle(scope.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func voiceRow(_ descriptor: VoiceDescriptor) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selectedVoice == descriptor.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedVoice == descriptor.id ? Color.accentColor : Color.secondary.opacity(0.4))
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(.body.weight(selectedVoice == descriptor.id ? .semibold : .regular))
                Text(subtitleLine(descriptor))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            auditionButton(descriptor)
        }
        .contentShape(Rectangle())
        .onTapGesture { select(descriptor) }
    }

    private func subtitleLine(_ descriptor: VoiceDescriptor) -> String {
        // Codename as the secondary line — plan UI-1 keeps it visible for
        // cross-referencing with model docs.
        descriptor.subtitle + " · " + descriptor.id
    }

    @ViewBuilder
    private func auditionButton(_ descriptor: VoiceDescriptor) -> some View {
        let isAuditioningThis = player.auditioningVoice == descriptor.id
        Button {
            if isAuditioningThis {
                player.stop()
                Haptics.tap()
            } else {
                Haptics.press()
                player.audition(voice: descriptor.id)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isAuditioningThis ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                    .frame(width: 34, height: 34)
                if isAuditioningThis {
                    Image(systemName: "stop.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "waveform")
                        .font(.footnote)
                        .foregroundStyle(modelReady ? Color.accentColor : Color.secondary.opacity(0.4))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!modelReady && !isAuditioningThis)
    }

    private func select(_ descriptor: VoiceDescriptor) {
        Haptics.tap()
        if scope == .kitten {
            player.kittenVoice = descriptor.id
        } else {
            player.voice = descriptor.id
        }
        // An explicit pick during a sounding audition wins over the restore.
        player.cancelAuditionRestore()

        var recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        recent.removeAll { $0 == descriptor.id }
        recent.insert(descriptor.id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(5)), forKey: recentKey)
    }
}
