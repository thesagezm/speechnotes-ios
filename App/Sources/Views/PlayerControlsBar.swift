import SwiftUI

/// Bottom-of-editor controls: voice chip, play/pause/stop, progress bar,
/// speed slider. Extracted from NoteEditorView so that player state changes
/// (progress ticks, slider drags) only re-evaluate this view — not the title
/// field, the editor, or the sheet/alert modifiers.
struct PlayerControlsBar: View {
    let speechText: String
    let note: Note?
    /// Called at the top of every play/pause tap, BEFORE speechText is read —
    /// the editor flushes its (debounced) speech-text cache here so the
    /// engine hears edits made in the last 300ms. Additive optional so other
    /// call sites (if any ever appear) keep working.
    var onBeforeToggle: (() -> Void)? = nil

    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var theme: AppTheme
    /// Mirrors NoteEditorView's read-along switch — shared via AppStorage.
    @AppStorage("readAlongEnabled") private var readAlongEnabled = true
    /// Collapsed to the slim pill — frees editor space while playing.
    @AppStorage("editorBarMinimized") private var editorBarMinimized = false

    private var playIcon: String {
        switch player.state {
        case .generating: return "hourglass"
        case .speaking: return "pause.fill"
        case .paused, .idle: return "play.fill"
        }
    }

    private var playButtonDisabled: Bool {
        player.isExporting
            || player.state == .idle
                && speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if editorBarMinimized {
            minimizedPill
        } else {
            expandedBar
        }
    }

    /// Collapsed editor playback bar: one slim translucent pill — frees the
    /// lower half of the editor while still showing play state and progress.
    private var minimizedPill: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                onBeforeToggle?()
                player.togglePlay(speechText, note: note)
            } label: {
                Image(systemName: playIcon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
            }
            .disabled(playButtonDisabled)

            if let progress = player.progress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if player.state == .generating {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 0)

            Button {
                Haptics.tap()
                editorBarMinimized = false
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .accessibilityLabel("Expand playback controls")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var expandedBar: some View {
        VStack(spacing: 8) {
            voiceChip

            if let progress = player.progress, player.state == .speaking {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25))
                        Capsule()
                            .fill(theme.accentFadeGradient)
                            .frame(width: max(4, proxy.size.width * progress))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal)
            }

            HStack(spacing: 14) {
                Button {
                    Haptics.tap()
                    onBeforeToggle?()
                    player.togglePlay(speechText, note: note)
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.accentGradient)
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                        if player.state == .generating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: playIcon)
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                }
                .disabled(playButtonDisabled)

                if player.state == .speaking || player.state == .paused || player.state == .generating {
                    // Live read-along toggle: sentence-highlighted reader
                    // replaces the editor while this note is speaking.
                    Button {
                        Haptics.press()
                        readAlongEnabled.toggle()
                    } label: {
                        Image(systemName: readAlongEnabled ? "book.pages.fill" : "book.pages")
                            .font(.body.weight(.medium))
                            .foregroundStyle(readAlongEnabled ? Color.accentColor : .secondary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .accessibilityLabel(readAlongEnabled ? "Read-along on" : "Read-along off")

                    Button {
                        Haptics.press()
                        player.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.red)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.red.opacity(0.12)))
                    }
                }

                Slider(value: $player.rateMultiplier, in: 0.5...2.0, step: 0.05)
                    .frame(height: 44)

                Text(String(format: "%.2f×", player.rateMultiplier))
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)

                Button {
                    Haptics.tap()
                    editorBarMinimized = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .accessibilityLabel("Minimize playback controls")
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// Current engine + voice, one tap from the picker.
    private var voiceChip: some View {
        Button {
            NotificationCenter.default.post(name: .requestVoicePicker, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2.fill")
                    .font(.caption)
                Text(player.currentVoiceDescription)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    /// Posted by PlayerControlsBar when the user taps the voice chip. The
    /// editor listens and presents the picker — keeps player-state-driven
    /// controls from holding a reference to the whole editor.
    static let requestVoicePicker = Notification.Name("PlayerControlsBar.requestVoicePicker")
}
