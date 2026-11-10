import SwiftUI
import UIKit

// MARK: - E-Ink mode (v1.9)
//
// One design language, applied everywhere: paper white, ink black, square
// edges, hairline borders instead of shadows, no translucency, no gradients
// (beyond solid ink), no animations or transitions. The accent picker does
// not matter while the mode is on — ink is ink — and the chosen hue returns
// the moment it is left. Everything below is a strict no-op outside E-Ink
// mode: the regular styling stays exactly as it was.
//
// The pieces:
//   - `\.isEInk` environment — views read the flag to swap styling inline.
//   - `EInk` constants — paper/ink/hairline, shared per call site.
//   - `EInkRootModifier` — the root sweep (nil transactions, grayscale,
//     square buttons), applied from SpeechnotesApp.
//   - `.einkListStyle()` / `.einkPaper {}` / `.einkInk {}` /
//     `.einkCard(radius:style:)` / `.einkClip(cornerRadius:)` — the
//     per-site swap helpers.
//   - `EInk.applyChrome(enabled:)` — flattens the UIKit tab/nav bars and
//     hard-disables UIKit-driven animation (push/pop, sheets, keyboard).
//
// The root also applies `.grayscale(1.0)` in E-Ink mode (see
// SpeechnotesApp) — the blanket that drains every hardcoded tint (pin
// orange, swipe indigo, toggle green) to grayscale app-wide. The per-view
// conditionals in this file exist to go FURTHER than grayscale: shape,
// surface and contrast changes grayscale cannot express.

private struct EInkEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while Appearance → Theme is set to E-Ink.
    var isEInk: Bool {
        get { self[EInkEnvironmentKey.self] }
        set { self[EInkEnvironmentKey.self] = newValue }
    }
}

/// The E-Ink palette and the UIKit-chrome flattener. Values, not SwiftUI
/// views, so both SwiftUI conditionals and the appearance proxies read the
/// same constants.
enum EInk {
    static let paper = Color.white
    static let ink = Color.black
    /// 1pt — E-Ink renders sub-point hairlines as dithered fuzz; a full
    /// point stays a crisp line.
    static let hairline: CGFloat = 1

    /// The flat surface: opaque paper with an ink hairline. Replaces
    /// material pills and shadowed cards at per-call-site conditionals.
    static var surface: some View {
        Rectangle()
            .fill(paper)
            .overlay(Rectangle().strokeBorder(ink, lineWidth: hairline))
    }

    /// Flattens the system chrome to E-Ink and toggles UIKit animation.
    /// Called from SpeechnotesApp at init and on every mode change, so
    /// leaving the mode rebuilds the stock chrome (the app sets no other
    /// appearance proxies, so "default configured" == what it shipped with).
    static func applyChrome(enabled: Bool) {
        // Push/pop, sheet presentation, keyboard — all UIKit-driven and
        // invisible to SwiftUI's .transaction. E-Ink wants instant.
        UIView.setAnimationsEnabled(!enabled)

        let tab = UITabBarAppearance()
        if enabled {
            tab.configureWithOpaqueBackground()
            tab.backgroundColor = UIColor(paper)
            tab.shadowImage = hairlineImage(ink)
            tab.stackedItemAppearance.normal.iconColor = UIColor(ink)
            tab.stackedItemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(ink)]
            tab.stackedItemAppearance.selected.iconColor = UIColor(ink)
            tab.stackedItemAppearance.selected.titleTextAttributes = [
                .foregroundColor: UIColor(ink),
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            ]
        } else {
            tab.configureWithDefaultBackground()
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        if enabled {
            nav.configureWithOpaqueBackground()
            nav.backgroundColor = UIColor(paper)
            nav.shadowImage = hairlineImage(ink)
            nav.titleTextAttributes = [.foregroundColor: UIColor(ink)]
            nav.largeTitleTextAttributes = [.foregroundColor: UIColor(ink)]
            nav.buttonBarButtonItemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(ink)]
        } else {
            nav.configureWithDefaultBackground()
        }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    /// A 1×1 pixel of `color`, stretched by UIKit into the bar's hairline.
    private static func hairlineImage(_ color: UIColor) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        return UIGraphicsImageRenderer(size: rect.size).image { context in
            color.setFill()
            context.fill(rect)
        }
    }
}

// MARK: - Root: no animations, no color

/// Root-level E-Ink sweep: every SwiftUI transaction loses its animation
/// (springs, transitions, animated state changes all snap), and the whole
/// tree drains to grayscale — the blanket over the ~33 hardcoded tint
/// call sites. Applied from SpeechnotesApp with the theme's flag; a plain
/// Bool, because the root sits ABOVE the environmentObject injection.
struct EInkRootModifier: ViewModifier {
    let isEInk: Bool

    func body(content: Content) -> some View {
        if isEInk {
            content
                .transaction { transaction in transaction.animation = nil }
                .grayscale(1.0)
                // Square every bordered/prominent button app-wide —
                // buttonBorderShape propagates through the environment.
                .buttonBorderShape(.rectangle)
        } else {
            content
        }
    }
}

// MARK: - Lists

/// E-Ink lists go flat and full-width: plain rows with hairline separators
/// instead of the rounded inset cards, on an explicit paper background
/// (scrollContentBackground must be hidden for the paper to show through).
private struct EInkListStyleModifier: ViewModifier {
    @Environment(\.isEInk) private var isEInk

    func body(content: Content) -> some View {
        if isEInk {
            content
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(EInk.paper)
        } else {
            content
        }
    }
}

extension View {
    /// Flat, full-width list rows on paper in E-Ink mode; untouched otherwise.
    func einkListStyle() -> some View {
        modifier(EInkListStyleModifier())
    }

    /// Surface swap for the dominant call-site pattern — a translucent or
    /// material-filled control background:
    ///
    ///     .background(Circle().fill(Color.secondary.opacity(0.12)))
    /// →   .einkPaper { Circle().fill(Color.secondary.opacity(0.12)) }
    ///
    /// E-Ink mode renders a square paper tile with an ink hairline; the
    /// regular styling applies verbatim otherwise.
    func einkPaper(@ViewBuilder regular: @escaping () -> some View) -> some View {
        modifier(EInkPaperModifier(regular: regular))
    }

    /// The solid-ink variant — a filled accent control (play button, active
    /// chip) becomes an opaque ink block in E-Ink mode:
    ///
    ///     .einkInk { Circle().fill(theme.accentGradient) }
    func einkInk(@ViewBuilder regular: @escaping () -> some View) -> some View {
        modifier(EInkInkModifier(regular: regular))
    }

    /// A rounded card that squares off in E-Ink mode — same fill, square
    /// corners, ink hairline (`bordered: false` keeps it rule-free, e.g.
    /// for fills that sit inside another bordered surface):
    ///
    ///     .background(RoundedRectangle(cornerRadius: 18).fill(bg))
    /// →   .einkCard(radius: 18, style: bg)
    func einkCard<Style: ShapeStyle>(
        radius: CGFloat,
        style: Style,
        bordered: Bool = true
    ) -> some View {
        modifier(EInkCardModifier(radius: radius, style: style, bordered: bordered))
    }

    /// Squares a content clipShape in E-Ink mode (book covers, thumbnails):
    ///
    ///     .clipShape(isEInk ? AnyShape(Rectangle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
    /// →   .einkClip(cornerRadius: 4)
    func einkClip(cornerRadius: CGFloat) -> some View {
        modifier(EInkClipModifier(cornerRadius: cornerRadius))
    }
}

/// The `.einkPaper {}` background swap.
private struct EInkPaperModifier<Regular: View>: ViewModifier {
    @Environment(\.isEInk) private var isEInk
    let regular: () -> Regular

    func body(content: Content) -> some View {
        content.background {
            if isEInk {
                EInk.surface
            } else {
                regular()
            }
        }
    }
}

/// The `.einkInk {}` background swap.
private struct EInkInkModifier<Regular: View>: ViewModifier {
    @Environment(\.isEInk) private var isEInk
    let regular: () -> Regular

    func body(content: Content) -> some View {
        content.background {
            if isEInk {
                Rectangle().fill(EInk.ink)
            } else {
                regular()
            }
        }
    }
}

/// The `.einkCard(radius:style:)` background swap.
private struct EInkCardModifier<Style: ShapeStyle>: ViewModifier {
    @Environment(\.isEInk) private var isEInk
    let radius: CGFloat
    let style: Style
    let bordered: Bool

    func body(content: Content) -> some View {
        content.background {
            if isEInk {
                Rectangle()
                    .fill(style)
                    .overlay {
                        if bordered {
                            Rectangle().strokeBorder(EInk.ink, lineWidth: EInk.hairline)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(style)
            }
        }
    }
}

/// The `.einkClip(cornerRadius:)` content clip.
private struct EInkClipModifier: ViewModifier {
    @Environment(\.isEInk) private var isEInk
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.clipShape(
            isEInk
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
    }
}
