import SwiftUI

/// Global mini-player variant for audiobooks — same chrome and dock position
/// as `MiniPlayerBar` (GlobalMiniPlayerOverlay swaps between them; only one
/// shows at a time), fed by the app-level `AudioBookPlayer` instead of
/// `SpeechPlayer`. This is what keeps an audiobook controllable from any tab
/// after the reader is left.
struct AudioBookMiniPlayerBar: View {
    /// Invoked when the user taps the bar's body — jumps back to the book.
    var onTap: (() -> Void)?

    @EnvironmentObject private var audioBooks: AudioBookPlayer
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("miniPlayerCollapsed") private var miniPlayerCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(theme.accentFadeGradient)
                        .frame(width: max(4, proxy.size.width * audioBooks.chapterProgress))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 14)
            .padding(.top, 10)

            HStack(spacing: 14) {
                // Cover thumbnail — the VLC mini-player's anchor visual.
                if let artwork = audioBooks.artworkImage {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                        .accessibilityHidden(true)
                }

                Button {
                    Haptics.tap()
                    audioBooks.togglePlay()
                } label: {
                    Image(systemName: audioBooks.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(theme.accentGradient))
                }
                .accessibilityLabel(audioBooks.isPlaying ? "Pause" : "Play")

                Button(role: .destructive) {
                    Haptics.press()
                    audioBooks.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
                .accessibilityLabel("Stop playback")

                VStack(alignment: .leading, spacing: 2) {
                    Text(audioBooks.nowPlayingTitle ?? "Audiobook")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(audioBooks.chapterLabel ?? "Paused")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)

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

/// The minimized audiobook bubble: floating circle with a live progress ring
/// and the play state. Tap to expand back to the bar.
struct AudioBookMiniPlayerBubble: View {
    @EnvironmentObject private var audioBooks: AudioBookPlayer
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

                Circle()
                    .trim(from: 0, to: audioBooks.chapterProgress)
                    .stroke(theme.accentGradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Image(systemName: audioBooks.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand player")
    }
}
