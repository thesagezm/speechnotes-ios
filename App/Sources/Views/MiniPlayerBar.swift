import SwiftUI

/// Compact player bar pinned above the tab bar while speech is active.
/// Play/pause, stop, live progress, the speaking note's title and current
/// voice; tapping the bar navigates back to the note (when a handler exists).
struct MiniPlayerBar: View {
    /// Invoked when the user taps the bar's body (not its buttons). The
    /// notes list passes a jump-to-note closure; Logs passes none.
    var onTap: (() -> Void)?

    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("miniPlayerCollapsed") private var miniPlayerCollapsed = false

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
                            .fill(theme.accentFadeGradient)
                            .frame(width: max(4, proxy.size.width * progress))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 14)
                .padding(.top, 10)
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
                        .background(Circle().fill(theme.accentGradient))
                }
                .disabled(player.state == .generating)
                .accessibilityLabel(player.state == .speaking ? "Pause" : "Play")

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
                .accessibilityLabel("Stop playback")

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

                Menu {
                    Button { player.setSleepTimer(.minutes(5)) }
                        label: { Label("5 minutes", systemImage: "moon") }
                    Button { player.setSleepTimer(.minutes(15)) }
                        label: { Label("15 minutes", systemImage: "moon") }
                    Button { player.setSleepTimer(.minutes(30)) }
                        label: { Label("30 minutes", systemImage: "moon") }
                    Button { player.setSleepTimer(.minutes(60)) }
                        label: { Label("1 hour", systemImage: "moon") }
                    Divider()
                    if player.nowPlayingBookId != nil {
                        Button { player.setSleepTimer(.endOfChapter) }
                            label: { Label("End of chapter", systemImage: "book.closed") }
                    }
                    if player.sleepTimer != .off {
                        Button(role: .destructive) { player.setSleepTimer(.off) }
                            label: { Label("Cancel sleep timer", systemImage: "moon.zzz") }
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "moon")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(player.sleepTimer == .off ? .secondary : Color.accentColor)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                        if player.sleepTimer != .off {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                                .offset(x: -1, y: 1)
                        }
                    }
                }
                .accessibilityLabel(player.sleepTimer == .off ? "Sleep timer off" : "Sleep timer: \(player.sleepTimer)")

                // Minimize to the floating bubble.
                Button {
                    Haptics.tap()
                    miniPlayerCollapsed = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .accessibilityLabel("Minimize player")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
    }
}

/// The minimized mini-player: a floating bubble with a live progress ring
/// and play/pause. Tap to expand back to the bar.
struct MiniPlayerBubble: View {
    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("miniPlayerCollapsed") private var miniPlayerCollapsed = false

    var body: some View {
        Button {
            Haptics.tap()
            miniPlayerCollapsed = false
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 3)

                // Progress ring.
                Circle()
                    .trim(from: 0, to: player.progress ?? 0)
                    .stroke(theme.accentGradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                if player.state == .generating {
                    ProgressView()
                        .tint(.accentColor)
                } else {
                    Image(systemName: player.state == .speaking ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand player")
    }
}

/// NO-OP kept for compatibility with older call sites — the mini-player is
/// attached once at the root by `globalMiniPlayer()` (see
/// GlobalMiniPlayerOverlay.swift). Per-screen insets rode push/pop
/// transitions and could end up stuck mid-screen.
extension View {
    /// Deprecated — do nothing. Remove remaining call sites at leisure.
    func miniPlayer(visible: Bool = true, onTap: (() -> Void)? = nil) -> some View {
        self
    }
}
