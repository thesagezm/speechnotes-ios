import SwiftUI

/// Compact player bar pinned above the tab bar while speech is active.
/// Play/pause, stop, live progress, the speaking note's title and current
/// voice; tapping the bar navigates back to the note (when a handler exists).
struct MiniPlayerBar: View {
    /// Invoked when the user taps the bar's body (not its buttons). The
    /// notes list passes a jump-to-note closure; Logs passes none.
    var onTap: (() -> Void)?

    @EnvironmentObject private var player: SpeechPlayer

    private var playIcon: String {
        switch player.state {
        case .generating: return "hourglass"
        case .speaking: return "pause.fill"
        case .paused, .idle: return "play.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                .frame(height: 3)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            HStack(spacing: 14) {
                Button {
                    Haptics.tap()
                    player.togglePlay("")
                } label: {
                    Image(systemName: playIcon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle().fill(
                                LinearGradient(
                                    colors: [.accentColor, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )
                }
                .disabled(player.state == .generating)

                Button(role: .destructive) {
                    Haptics.press()
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.nowPlayingTitle ?? "Speaking")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(player.currentVoiceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)

                if player.state == .generating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Pins a `MiniPlayerBar` above the tab bar whenever speech is active.
/// `visible` lets screens with their own controls (the editor) opt out;
/// `onTap` handles body taps (the notes list jumps to the playing note).
struct MiniPlayerModifier: ViewModifier {
    @EnvironmentObject private var player: SpeechPlayer
    var visible: Bool = true
    var onTap: (() -> Void)?

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.showMiniPlayer && visible {
                MiniPlayerBar(onTap: onTap)
            }
        }
    }
}

extension View {
    /// Shows the persistent mini-player while speech is active.
    func miniPlayer(visible: Bool = true, onTap: (() -> Void)? = nil) -> some View {
        modifier(MiniPlayerModifier(visible: visible, onTap: onTap))
    }
}
