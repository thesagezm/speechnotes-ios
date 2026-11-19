import SwiftUI
import AVFoundation

/// Speech settings — Android SpeechSettingsScreen parity: an engine radio
/// list with factual subtitles, one Voice section, per-engine quality dials
/// shown only while that engine is active, and ONE "Models" section holding
/// every download (sorted smallest-first, largest last). The old screen's
/// per-model sections each repeated a Download/Retry/Delete button plus a
/// footer essay; footers are gone — the nav-bar info button carries the
/// consolidated engine facts instead.
struct SpeechSettingsView: View {
    @EnvironmentObject private var player: SpeechPlayer
    @ObservedObject private var models = ModelManager.shared
    @State private var systemVoices: [AVSpeechSynthesisVoice] = []
    @State private var showingVoicePicker = false
    @State private var showingInfo = false
    /// Supertonic's quality-vs-speed dial — read per chunk by the engine
    /// (`SupertonicEngine.RenderQuality`), so a change applies from the
    /// next chunk with no restart.
    @AppStorage("supertonicRenderQuality") private var supertonicRenderQuality = "high"
    /// The Phase-5 CoreML EP experiment dial. Default OFF: the flag is read
    /// by SpeechPlayer's supertonic branch when it builds the engine, and
    /// onChange forces the rebuild that swaps the session set. The
    /// Benchmark Mode tiers carry their own variant selection — this flag
    /// only governs normal playback.
    @AppStorage("supertonicUseCoreML") private var supertonicUseCoreML = false

    /// Kokoro's tier dial, stored under the same `kokoroTier` key
    /// `SpeechPlayer.kokoroWantsBigModel` reads. It MUST be @AppStorage, not
    /// a Binding over the player's computed property: that property reads
    /// UserDefaults without publishing anything, so the picker's checkmark
    /// never moved until something else re-rendered the section (2026-10-25
    /// device feedback). @AppStorage observes the defaults store directly.
    @AppStorage("kokoroTier") private var kokoroTier = "high"

    private var kokoroQuality: Binding<String> {
        Binding(
            get: { kokoroTier == "compact" ? "compact" : "high" },
            set: { newValue in
                kokoroTier = newValue == "compact" ? "compact" : "high"
                // Re-drive the engine through the same rebuild a kind switch
                // uses, so the tier change applies NOW (a rebuild is
                // idempotent when the tier did not actually change).
                player.rebuildKokoroTier()
            }
        )
    }

    private var neuralEngineIsActive: Bool {
        (player.engineKind == .kokoro || player.engineKind == .nanoEdge || player.engineKind == .phonon || player.engineKind == .supertonic)
            && !player.usingSystemFallback
    }

    private var activeVoiceCodename: String {
        switch player.engineKind {
        case .supertonic: return player.supertonicVoice
        case .phonon: return player.phononVoice
        case .nanoEdge: return player.nanoEdgeVoice
        default: return player.voice
        }
    }

    private var neuralModelMissing: Bool {
        switch player.engineKind {
        case .kokoro: return !models.isReady && !models.smallIsReady
        case .nanoEdge: return !models.nanoIsReady
        case .phonon: return !models.phononIsReady
        case .supertonic: return !models.supertonicIsReady
        default: return false
        }
    }

    private var voicePickerScope: VoicePickerSheet.Scope {
        switch player.engineKind {
        case .supertonic: return .supertonic
        case .phonon: return .phonon
        case .nanoEdge: return .nanoEdge
        default: return .kokoro
        }
    }

    var body: some View {
        Form {
            engineSection
            voiceSection

            // Kokoro's tier choice (fp32/int8) — shown while the one Kokoro
            // engine is active.
            if player.engineKind == .kokoro {
                kokoroQualitySection
            }

            if player.engineKind == .supertonic {
                supertonicQualitySection
                coreMLSection
            }

            modelsSection
        }
        .navigationTitle("Speech Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("About the engines")
            }
        }
        .sheet(isPresented: $showingInfo) {
            SpeechInfoSheet()
        }
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerSheet(scope: voicePickerScope).environmentObject(player)
        }
        .onAppear {
            guard systemVoices.isEmpty else { return }
            systemVoices = AVSpeechSynthesisVoice.speechVoices()
                .sorted { $0.language != $1.language ? $0.language < $1.language : $0.name < $1.name }
        }
    }

    // MARK: - Engine

    /// Engine radio list. Rows carry the name plus its factual subtitle in
    /// the smaller secondary font (2026-11-19 device feedback: quality
    /// rankings go stale, "on-device neural" said nothing — rows state only
    /// languages, voice counts and sizes).
    private var engineSection: some View {
        Section("Speech engine") {
            Picker("Engine", selection: $player.engineKind) {
                ForEach(SpeechPlayer.EngineKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.label)
                        Text(kind.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(kind)
                }
            }
            .pickerStyle(.inline)

            if neuralModelMissing {
                Label(
                    "Selected engine's model isn't downloaded yet — the system voice is used in the meantime.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Voice

    /// Both voice pickers in ONE section: the neural engine's voice on top,
    /// the Apple system voice beneath it (dimmed while a neural engine owns
    /// playback). The old screen gave the system voice its own section with
    /// a footer essay.
    private var voiceSection: some View {
        Section("Voice") {
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

            Menu {
                systemVoiceRow(title: "Default (English)", identifier: nil)
                ForEach(systemVoices, id: \.identifier) { voice in
                    systemVoiceRow(title: systemVoiceTitle(voice), identifier: voice.identifier)
                }
            } label: {
                HStack {
                    Text("System voice")
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
                    "A neural engine is active — the system voice applies only when Apple (system) is selected, or while a model is missing.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Quality dials

    private var kokoroQualitySection: some View {
        Section("Kokoro quality") {
            Picker("Kokoro quality", selection: kokoroQuality) {
                qualityRow(title: "High", subtitle: "Full precision · ~341 MB").tag("high")
                qualityRow(title: "Compact", subtitle: "int8-quantized · ~92 MB · same 28 voices").tag("compact")
            }
            .pickerStyle(.inline)
        }
    }

    private var supertonicQualitySection: some View {
        Section("Supertonic quality") {
            Picker("Supertonic quality", selection: $supertonicRenderQuality) {
                qualityRow(title: "High", subtitle: "8 denoising steps on every chunk").tag("high")
                qualityRow(title: "Balanced", subtitle: "6 steps — close to High at ~¾ of the render time").tag("balanced")
                qualityRow(title: "Automatic", subtitle: "4 steps, only while the phone runs critically hot").tag("automatic")
                qualityRow(title: "Fast", subtitle: "Always 4 steps — quickest, audible artifacts").tag("fast")
            }
            .pickerStyle(.inline)
        }
    }

    /// Two-line picker row: option name + its factual detail underneath.
    private func qualityRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var coreMLSection: some View {
        Section {
            Toggle("Render with Core ML (experimental)", isOn: $supertonicUseCoreML)
                .onChange(of: supertonicUseCoreML) { _ in
                    player.rebuildSupertonicEngineVariant()
                }
        }
    }

    // MARK: - Models

    /// Every download in ONE section, smallest first / largest last
    /// (2026-11-19 device feedback): one row per model — name + size, state
    /// as the secondary line, and a single trailing button replacing the old
    /// per-model section of full-width Download/Retry/Delete rows.
    private var modelsSection: some View {
        Section("Models") {
            modelRow(name: "Kokoro (small)", size: "~92 MB",
                     state: models.smallState,
                     start: { models.startSmallDownload() },
                     remove: { models.deleteSmallModel() })
            modelRow(name: "Nano Edge", size: "~157 MB",
                     state: models.nanoEdgeState,
                     start: { models.startNanoEdgeDownload() },
                     remove: { models.deleteNanoEdgeModels() })
            modelRow(name: "Phonon", size: "~192 MB",
                     state: models.phononState,
                     start: { models.startPhononDownload() },
                     remove: { models.deletePhononModels() })
            modelRow(name: "Kokoro", size: "~341 MB",
                     state: models.state,
                     start: { models.startDownload() },
                     remove: { models.deleteModels() })
            modelRow(name: "Supertonic", size: "~399 MB",
                     state: models.supertonicState,
                     start: { models.startSupertonicDownload() },
                     remove: { models.deleteSupertonicModels() })
        }
    }

    /// One model download row: name + size on top, download state beneath,
    /// Download / progress / Retry / Delete trailing. A `.bordered` style on
    /// the trailing buttons keeps the tap scoped to the button — a plain
    /// Button inside a Form row makes the WHOLE row the hit target.
    @ViewBuilder
    private func modelRow(name: String, size: String,
                          state: ModelManager.State,
                          start: @escaping () -> Void,
                          remove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) · \(size)")
                Text(stateText(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            switch state {
            case .notDownloaded:
                Button("Download", action: start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 72)
            case .failed:
                Button("Retry", action: start)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .ready:
                Button("Delete", role: .destructive, action: remove)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func stateText(_ state: ModelManager.State) -> String {
        switch state {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let progress): return "Downloading… \(Int(progress * 100))%"
        case .failed(let message): return "Failed — \(message)"
        case .ready: return "Ready — fully offline"
        }
    }

    // MARK: - System voice rows

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

/// The nav-bar info button's sheet: the engine and model facts the old
/// footer essays carried, stated once and verifiably — no quality rankings.
private struct SpeechInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                engineInfo("Apple system voice",
                           "Uses the voices installed in iOS — enhanced and premium tiers sound richer. Download more under Settings → Accessibility → Spoken Content → Voices.")
                engineInfo("Kokoro",
                           "One fp32 graph with all 28 American and British voices plus the tokenizer, stored inside the app. The High/Compact quality choice is the model tier; Compact is the int8 build at about a quarter of the size. Fully offline.")
                engineInfo("Nano Edge",
                           "Kokoro's text encoder with its waveform decoder replaced by a distilled 1.75M-parameter one. Trained on Kokoro's own voice banks, so Heart sounds like Heart — the same 28 English voices at about a quarter of the fp32 footprint, with native speed control.")
                engineInfo("Phonon",
                           "Gradium Phonon — a 31M-parameter English streaming TTS: two fp32 graphs, a tokenizer and 27 voices. English only; the speed slider has no effect here (the model has no speed input).")
                engineInfo("Supertonic",
                           "Supertone supertonic-3 — flow-matching TTS with 31 languages and 10 voice styles; pick the language in the voice picker. ~399 MB and CPU-based. The quality dial trades render time against denoising steps and applies from the next chunk; exports always render full quality.")
                engineInfo("Core ML experiment (Supertonic)",
                           "Routes Supertonic's four ONNX sessions through Apple's Core ML execution provider (Apple Neural Engine / GPU where they fit) instead of pure CPU. Off by default — numerically identical in the lab; the on-device speed, battery and heat comparison is still pending. Toggling it rebuilds the engine; playing speech stops at the next sentence boundary. Benchmark Mode measures Core ML vs CPU back-to-back.")
            }
            .navigationTitle("About the engines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func engineInfo(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
