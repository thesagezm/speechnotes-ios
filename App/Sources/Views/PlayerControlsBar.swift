import SwiftUI

/// Bottom-of-editor controls: voice chip, play/pause/stop, progress bar,
/// speed slider. Extracted from NoteEditorView so that player state changes
/// (progress ticks, slider drags) only re-evaluate this view — not the title
/// field, the editor, or the sheet/alert modifiers.
struct PlayerControlsBar: View {
    let speechText: String
    let note: Note?

    @EnvironmentObject private var player: SpeechPlayer

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
        VStack(spacing: 8) {
            voiceChip

            if let progress = player.progress, player.state == .speaking {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.accentColor, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, proxy.size.width * progress))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal)
            }

            HStack(spacing: 14) {
                Button {
                    Haptics.tap()
                    player.togglePlay(speechText, note: note)
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.accentColor, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
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
