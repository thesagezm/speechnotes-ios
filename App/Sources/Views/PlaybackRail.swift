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
    /// Round 6: 150 (user liked the panel, asked for it slightly smaller).
    static let idealWidth: CGFloat = 150

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
        /// Landscape prev/next for the surface's unit (chapter or page) —
        /// portrait carries these in its bottom chapter/page bar, landscape
        /// has no bottom band (round 6 removed it), so the rail is the one
        /// place they can live. nil hides the stepper.
        var onStepBack: (() -> Void)? = nil
        var onStepForward: (() -> Void)? = nil
        var stepLabel: String? = nil
        var stepBackEnabled: Bool = true
        var stepForwardEnabled: Bool = true

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

    /// Collapsed to a slim strip — the landscape twin of the portrait bar's
    /// `editorBarMinimized` pill (user request, round 6: minimize the rail
    /// the way the bottom bar minimizes). One app-wide preference: the rail
    /// is the same control on every surface.
    @AppStorage("landscapeRailMinimized") private var minimized = false

    /// Matches the portrait PlayerControlsBar's play glyph logic exactly, so
    /// the same state reads the same in both orientations.
    private var playIcon: String {
        if isGenerating { return "hourglass" }
        return sessionActive && progress != nil ? "pause.fill" : "play.fill"
    }

    var body: some View {
        if minimized {
            minimizedCapsule
        } else {
            fullPanel
        }
    }

    /// The full panel: three pinned zones; the middle one centers ITSELF in
    /// the space between them. Round 6: the old two-Spacer stack let the play
    /// button drift whenever an optional row appeared (voice chip, controls
    /// trio) or the chrome hid — the user saw the controls "disperse in an
    /// uneven uncentered way" with the title bar hidden. Now the top/bottom
    /// blocks never move and the play cluster is always optically centered in
    /// the leftover space, regardless of session state or chrome.
    ///
    /// Round 7: the panel FLOATS — content-hugging height, rounded, softly
    /// shadowed, vertically centered in the trailing column. The old
    /// edge-to-edge `.bar` grew and shrank with the nav bar (the "stretched
    /// out when I hide the title bar" report); a fixed-height floating panel
    /// is pixel-identical whether the chrome is visible or not, and reads as
    /// a deliberate landscape player instead of a strip of UI.
    private var fullPanel: some View {
        // The scroll wrapper is the fix for the "expanded rail ran off the
        // top of the screen" report: a session-active panel (progress +
        // stepper + voice chip + play cluster + controls + rate) is taller
        // than a landscape phone's short axis, and the old centered
        // `.frame(maxHeight: .infinity)` CLIPPED BOTH ENDS of the overflow —
        // taking the minimize chevron (top-trailing) off-screen with it.
        // Overflow now scrolls from the top, so the chevron is always
        // reachable. The `minHeight` inside keeps the round-7 design when
        // the card FITS: a plain ScrollView pins short content to the top
        // (scroll-view origin semantics), and `minHeight: viewport` re-
        // centers it in the column; when the card is taller, the frame is
        // inert and the overflow scrolls.
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    topGroup
                        .padding(.bottom, 10)
                    middleGroup
                    rateSection
                        .padding(.top, 10)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(width: Self.idealWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.bar)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
                )
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
                .overlay(alignment: .topTrailing) {
                    // Minimize — the portrait bar's chevron affordance,
                    // pointing off the trailing edge.
                    Button {
                        Haptics.tap()
                        minimized = true
                    } label: {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .accessibilityLabel("Minimize playback rail")
                }
                // The centering wrapper is OUTERMOST so the card's visuals
                // hug the natural content: when the card is shorter than the
                // column the frame centers it at column height; when it is
                // taller the frame is inert and the overflow scrolls.
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// The minimized rail: a floating rounded capsule on the trailing edge —
    /// the mini-player bubble's idiom, not a bare strip. Live progress ring
    /// around the play glyph, expand chevron beneath. Round 7: the first
    /// edge-to-edge strip looked improvised next to the portrait pill; this
    /// matches it (material, rounding, shadow, progress).
    private var minimizedCapsule: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.tap()
                action.onTogglePlay()
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    if let progress {
                        Circle()
                            .trim(from: 0, to: max(0.001, min(1, progress)))
                            .stroke(theme.accentGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    Image(systemName: playIcon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .disabled(!isPlayEnabled)
            .accessibilityLabel(sessionActive ? "Pause" : "Play")

            Button {
                Haptics.tap()
                minimized = false
            } label: {
                Image(systemName: "chevron.compact.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand playback rail")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// ReadAlongView's trailing inset keeps using idealWidth, so the text
    /// column simply gains breathing room while the rail is collapsed;
    /// nothing can run under it either way.
    static let minimizedWidth: CGFloat = 40

    // MARK: - Zones

    /// Progress capsule + chapter/page stepper + voice chip — pinned to the
    /// panel's top.
    private var topGroup: some View {
        VStack(spacing: 10) {
            progressStrip
            stepStrip
            voiceChip
        }
    }

    /// Landscape prev/next stepper for the reader's unit (chapter or page) —
    /// compact chevrons flanking the live position, mirroring the portrait
    /// chapter/page bar that round 6 removed from this orientation.
    @ViewBuilder
    private var stepStrip: some View {
        if let onStepBack = action.onStepBack, let onStepForward = action.onStepForward {
            HStack(spacing: 8) {
                Button {
                    Haptics.tap()
                    onStepBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!action.stepBackEnabled)
                .accessibilityLabel("Previous")

                Text(action.stepLabel ?? "")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)

                Button {
                    Haptics.tap()
                    onStepForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!action.stepForwardEnabled)
                .accessibilityLabel("Next")
            }
            .foregroundStyle(Color.accentColor)
        }
    }

    /// Play + the read-along/stop/extra trio — one unit, always centered.
    private var middleGroup: some View {
        VStack(spacing: 14) {
            playButton
            if sessionActive {
                controlsRow
            }
        }
        .frame(maxWidth: .infinity)
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
