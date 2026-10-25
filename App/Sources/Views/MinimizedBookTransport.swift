import SwiftUI

/// The MINIMISED bottom transport every book reader shares (EPUB, PDF and
/// audiobook) — the note editor's `PlayerControlsBar.minimizedPill` shape:
/// one slim translucent pill (ultraThinMaterial, like Notes) that gives the
/// reading surface its space back.
///
/// Why the chapter steppers ride this pill: the readers put the chapter /
/// page bar in a SIBLING row ABOVE the playback bar, so collapsing only the
/// playback bar left that bar on screen — the exact complaint behind
/// "the next/previous chapter controls and the chapter number persist above
/// the minimised bar" (2026-10-25 device feedback). The readers now hide
/// that bar entirely while minimised, and the steppers move here so the
/// navigation stays one tap away without spending the vertical space.
struct MinimizedBookTransport: View {
    /// SF Symbol for the play/pause button.
    let playIcon: String
    /// A generation spinner replaces the glyph (the engine is rendering).
    var isGenerating: Bool = false
    /// The short readout (a percentage, like Notes' pill).
    var progressText: String = ""
    var stepBackEnabled: Bool = true
    var stepForwardEnabled: Bool = true
    var onToggle: () -> Void
    /// nil hides that side's stepper (a book with one chapter).
    var onStepBack: (() -> Void)? = nil
    var onStepForward: (() -> Void)? = nil
    var onExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                onToggle()
            } label: {
                Group {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Image(systemName: playIcon)
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)

            if let onStepBack {
                stepButton(
                    systemName: "chevron.left",
                    enabled: stepBackEnabled,
                    label: "Previous chapter",
                    action: onStepBack
                )
            }

            if !progressText.isEmpty {
                Text(progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let onStepForward {
                stepButton(
                    systemName: "chevron.right",
                    enabled: stepForwardEnabled,
                    label: "Next chapter",
                    action: onStepForward
                )
            }

            Button {
                Haptics.tap()
                onExpand()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
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

    /// A chapter stepper in the pill's own affordance — a plain chevron in a
    /// soft circle, the same weight as the expand button.
    private func stepButton(
        systemName: String,
        enabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
