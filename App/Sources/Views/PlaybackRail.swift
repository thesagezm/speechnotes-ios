import SwiftUI

/// Lateral playback controls for landscape: a panel pinned to the trailing
/// edge, with the playback surface kept to its leading side.
///
/// Why the side (user request, and the v1.2-era plan already agreed): in
/// landscape the screen is short, so a bottom bar eats the reading height and a
/// top bar fights the navigation bar. The rail is deliberately parameterized
/// rather than copy-pasted per surface: the note editor, the EPUB reader and
/// the PDF reader all need the same five actions (voice, play/pause, stop,
/// read-along, rate) and the same progress readout, differing only in what the
/// buttons call. `PlaybackRail.Action` carries those closures; `extraTrailing`
/// covers the one surface-specific button (the PDF reader's per-chapter
/// export).
///
/// Round-5 redesign (user: "poorly done and unprofessional" at 78 pt): the
/// narrow column with its rotated fader was rebuilt as a PROPER PANEL that
/// mirrors the portrait PlayerControlsBar feature-for-feature — voice chip
/// with the live voice description, progress capsule with percentage, the
/// same 52 pt play button, read-along/stop/(export) controls, and a NORMAL
/// horizontal rate slider (there is width for one now; the rotated fader is
/// gone). Every control the portrait bar has, the rail has.
///
/// Type-checker budget (the v1.2 lesson): the rail is its own file and every
/// sub-view is a small private computed property, so adding it cannot push an
/// existing body over Swift's expression limit.
struct PlaybackRail: View {
    /// The documented rail width — every layout partner reserves this
    /// (ReadAlongView's trailing inset, the HStacks that host the rail).
    static let idealWidth: CGFloat = 170

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
    /// Shown in the voice chip — engine + voice, so the user can see what is
    /// speaking without leaving the reader.
    var voiceLabel: String = ""
    /// Progress 0…1 while speaking; nil shows nothing (the strip degrades to
    /// a hairline, matching the portrait bar's behaviour).
    var progress: Double?
    /// True while the engine is generating the first chunk — the play button
    /// shows an hourglass instead of the glyph.
    var isGenerating: Bool = false
    /// False disables play (nothing to speak / export running).
    var isPlayEnabled: Bool = true
    /// Stop/read-along show only while a session is live.
    var sessionActive: Bool = false
    /// Surface-specific extra button (PDF per-chapter export).
    var extraTrailing: AnyView? = nil

    @EnvironmentObject private var theme: AppTheme

    /// Matches the portrait PlayerControlsBar's play glyph logic exactly, so
    /// the same state reads the same in both orientations.
    private var playIcon: String {
        if isGenerating { return "hourglass" }
        return sessionActive && progress != nil ? "pause.fill" : "play.fill"
    }

    var body: some View {
        VStack(spacing: 12) {
            progressStrip
            voiceChip
            Spacer(minLength: 0)
            playButton
            if sessionActive {
                controlsRow
            }
            Spacer(minLength: 0)
            rateSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.idealWidth)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    // MARK: - Progress

    /// Horizontal capsule across the panel's top — the landscape twin of the
    /// portrait bar's progress capsule, with the live percentage beside it.
    private var progressStrip: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    if let progress, progress > 0 {
                        Capsule()
                            .fill(theme.accentFadeGradient)
                            .frame(width: max(4, proxy.size.width * progress))
                    }
                }
            }
            .frame(height: 4)
            if let progress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Voice chip

    /// Same chip as the portrait bar: engine + voice, one tap to the picker.
    private var voiceChip: some View {
        Group {
            if let onChangeVoice = action.onChangeVoice {
                Button {
                    Haptics.tap()
                    onChangeVoice()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.caption)
                        Text(voiceLabel)
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
                .accessibilityLabel("Change voice")
            }
        }
    }

    // MARK: - Transport

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
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .disabled(!isPlayEnabled)
        .accessibilityLabel(sessionActive ? "Pause" : "Play")
    }

    /// Read-along, stop and the surface's extra button — the same trio row
    /// the portrait bar shows while a session is live.
    private var controlsRow: some View {
        HStack(spacing: 14) {
            if let onToggleReadAlong = action.onToggleReadAlong {
                Button {
                    Haptics.press()
                    onToggleReadAlong()
                } label: {
                    Image(systemName: action.readAlongOn ? "book.pages.fill" : "book.pages")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(action.readAlongOn ? Color.accentColor : .secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.readAlongOn ? "Read-along on" : "Read-along off")
            }

            if let onStop = action.onStop {
                Button {
                    Haptics.press()
                    onStop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop playback")
            }

            if let extraTrailing {
                extraTrailing
            }
        }
    }

    // MARK: - Rate

    /// Horizontal rate slider — the portrait bar's exact control. (The old
    /// rail rotated a slider 90° into a 34×110 slot: it fought the thumb,
    /// looked improvised, and there was never a reason to given the panel's
    /// width.)
    private var rateSection: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { action.rate },
                    set: { action.onRateChange($0) }
                ),
                in: 0.5...2.0,
                step: 0.05
            )
            .frame(height: 44)
            .accessibilityLabel("Speech rate")
            .accessibilityValue(String(format: "%.2f times", action.rate))
            Text(String(format: "%.2f×", action.rate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
