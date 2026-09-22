import SwiftUI

/// Lateral playback controls for landscape: a vertical rail pinned to the
/// trailing edge, with the playback surface kept to its leading side.
///
/// Why the side (user request, and the v1.2-era plan already agreed): in
/// landscape the screen is short, so a bottom bar eats the reading height and a
/// top bar fights the navigation bar. A 78 pt rail leaves the text column tall
/// and clean, and every control stays in thumb reach either handheld or on a
/// desk.
///
/// The rail is deliberately parameterized rather than copy-pasted per surface:
/// the note editor, the EPUB reader, the PDF reader and the audiobook reader
/// all need the same five actions (voice, play/pause, stop, read-along, rate)
/// and the same vertical progress strip, differing only in what the buttons
/// call. `PlaybackRail.Action` carries those closures; `extraTrailing` covers
/// the one surface-specific button (the PDF reader's per-chapter export).
///
/// Type-checker budget (the v1.2 lesson): the rail is its own file and every
/// sub-view is a small private computed property, so adding it cannot push an
/// existing body over Swift's expression limit.
struct PlaybackRail: View {
    /// What the rail's buttons do. Every surface fills this in with its own
    /// calls — the rail itself holds no playback knowledge.
    struct Action {
        /// Voice button — opens the picker (nil hides the button).
        var onChangeVoice: (() -> Void)?
        /// Play/pause — the surface decides whether that is a note, a chapter
        /// or an audiobook.
        var onTogglePlay: () -> Void
        var onStop: (() -> Void)?
        /// Read-along toggle (nil hides the button).
        var onToggleReadAlong: (() -> Void)?
        var readAlongOn: Bool = false
        /// Live speech rate — the shared SpeechPlayer preference.
        var rate: Double
        var onRateChange: (Double) -> Void

        static func base(
            rate: Double,
            onRateChange: @escaping (Double) -> Void,
            onTogglePlay: @escaping () -> Void
        ) -> Action {
            Action(
                onChangeVoice: nil,
                onTogglePlay: onTogglePlay,
                onStop: nil,
                onToggleReadAlong: nil,
                rate: rate,
                onRateChange: onRateChange
            )
        }
    }

    let action: Action
    /// Shown under the play button — engine + voice, so the user can see what
    /// is speaking without leaving the reader.
    var voiceLabel: String = ""
    /// Progress 0…1 while speaking; nil shows nothing (the strip degrades to a
    /// hairline, matching the portrait bar's behaviour).
    var progress: Double?
    /// True while the engine is generating the first chunk — the play button
    /// shows an hourglass instead of the glyph.
    var isGenerating: Bool = false
    /// False disables play (nothing to speak / export running).
    var isPlayEnabled: Bool = true
    /// Stop/read-along show only while a session is live.
    var sessionActive: Bool = false
    /// Surface-specific trailing button (PDF per-chapter export).
    var extraTrailing: AnyView? = nil

    @EnvironmentObject private var theme: AppTheme
    @Environment(\.isLandscape) private var isLandscape

    /// Matches the portrait PlayerControlsBar's play glyph logic exactly, so
    /// the same state reads the same in both orientations.
    private var playIcon: String {
        if isGenerating { return "hourglass" }
        return sessionActive && progress != nil ? "pause.fill" : "play.fill"
    }

    var body: some View {
        HStack(spacing: 0) {
            railProgressStrip
            railControls
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    // MARK: - Progress strip

    /// Thin vertical strip on the rail's leading edge — the landscape twin of
    /// the portrait bar's capsule, filling TOP-DOWN so "further along" runs in
    /// the same direction a page fills (user request: top→bottom, not the
    /// bottom-up fill a vertical progress bar would otherwise take).
    private var railProgressStrip: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 3)
                if let progress, progress > 0 {
                    Capsule()
                        .fill(theme.accentFadeVerticalGradient)
                        .frame(width: 3, height: max(4, (proxy.size.height - 16) * progress))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 3)
        .padding(.vertical, 8)
    }

    // MARK: - Control column

    private var railControls: some View {
        VStack(spacing: 10) {
            voiceButton
            playButton

            if sessionActive {
                if let onStop = action.onStop {
                    stopButton(onStop)
                }
                if let onToggleReadAlong = action.onToggleReadAlong {
                    readAlongButton(onToggleReadAlong)
                }
                if let extraTrailing {
                    extraTrailing
                }
            }

            Spacer(minLength: 0)

            rateLabel

            // Vertical slider: lay the slider out horizontally at the slot's
            // HEIGHT, then rotate the visual 90° counter-clockwise around its
            // center (hit-testing follows the rotation). Min lands at the
            // bottom — slower down, faster up, like a mixing-desk fader.
            GeometryReader { proxy in
                Slider(
                    value: Binding(
                        get: { action.rate },
                        set: { action.onRateChange($0) }
                    ),
                    in: 0.5...2.0,
                    step: 0.05
                )
                .rotationEffect(.degrees(-90))
                .frame(width: proxy.size.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(width: 34, height: 110)
        }
        .padding(.horizontal, 2)
    }

    private var voiceButton: some View {
        Group {
            if let onChangeVoice = action.onChangeVoice {
                Button {
                    Haptics.tap()
                    onChangeVoice()
                } label: {
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change voice")
            }
        }
    }

    private var playButton: some View {
        Button {
            Haptics.tap()
            action.onTogglePlay()
        } label: {
            ZStack {
                Circle()
                    .fill(theme.accentGradient)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                if isGenerating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: playIcon)
                        .font(.body.bold())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .disabled(!isPlayEnabled)
        .accessibilityLabel(sessionActive ? "Pause" : "Play")
    }

    private func stopButton(_ onStop: @escaping () -> Void) -> some View {
        Button {
            Haptics.press()
            onStop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.red)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.red.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop playback")
    }

    private func readAlongButton(_ onToggle: @escaping () -> Void) -> some View {
        Button {
            Haptics.press()
            onToggle()
        } label: {
            Image(systemName: action.readAlongOn ? "book.pages.fill" : "book.pages")
                .font(.footnote.weight(.medium))
                .foregroundStyle(action.readAlongOn ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.readAlongOn ? "Read-along on" : "Read-along off")
    }

    private var rateLabel: some View {
        Text(String(format: "%.2f×", action.rate))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
