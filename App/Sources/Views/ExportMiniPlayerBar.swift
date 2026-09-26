import SwiftUI

/// Global mini-player variant for exported WAV files — the same chrome and
/// dock position as the other bars (GlobalMiniPlayerOverlay swaps between
/// them; only one shows at a time). This is what makes a pre-rendered export
/// behave like a download: play it from Storage, leave the screen, keep the
/// transport in reach everywhere (user request, round 5).
struct ExportMiniPlayerBar: View {
    var onTap: (() -> Void)? = nil

    @EnvironmentObject private var wav: WavPlayer
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("miniPlayerCollapsed") private var miniPlayerCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(theme.accentFadeGradient)
                        .frame(width: max(4, proxy.size.width * (wav.progress ?? 0)))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 14)
            .padding(.top, 10)

            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                    .accessibilityHidden(true)

                Button {
                    Haptics.tap()
                    wav.togglePlay()
                } label: {
                    Image(systemName: wav.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(theme.accentGradient))
                }
                .accessibilityLabel(wav.isPaused ? "Play" : "Pause")

                Button(role: .destructive) {
                    Haptics.press()
                    wav.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
                .accessibilityLabel("Stop playback")

                VStack(alignment: .leading, spacing: 2) {
                    Text(wav.nowPlayingTitle ?? "Export")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(Self.clock(wav.currentTime)) / \(Self.clock(wav.duration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

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

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The minimized export bubble: floating circle with a live progress ring.
/// Tap to expand back to the bar — mirrors the audiobook bubble.
struct ExportMiniPlayerBubble: View {
    @EnvironmentObject private var wav: WavPlayer
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
                    .trim(from: 0, to: wav.progress ?? 0)
                    .stroke(theme.accentGradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Image(systemName: wav.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand player")
    }
}
