import SwiftUI

/// One shared answer to "are we in landscape?" for every surface.
///
/// Why an environment key instead of each view reading
/// `@Environment(\.verticalSizeClass)`: the app is iPhone-only
/// (`TARGETED_DEVICE_FAMILY: "1"`), so compact height ⇔ landscape, and putting
/// the rule in ONE place means a future size-class subtlety (iPad split view,
/// Stage Manager) is a single edit rather than four divergent copies.
///
/// The key is injected once at the window root by `.landscapeAware()` — see
/// the View extension at the bottom of this file. Views read
/// `@Environment(\.isLandscape)`; because the value changes on rotation, every
/// reader observes it and re-layouts without any manual notification.
struct LandscapeKey: EnvironmentKey {
    /// Default `.regular` before the root injector runs — surfaces then lay out
    /// in their portrait form, which is the safe default for one frame.
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    /// True when the window is in landscape (compact vertical size class on an
    /// iPhone). Drives the lateral playback rails (PlaybackRail) and the
    /// read-along trailing inset.
    var isLandscape: Bool {
        get { self[LandscapeKey.self] }
        set { self[LandscapeKey.self] = newValue }
    }
}

/// Injects `isLandscape` into the environment for a whole subtree.
///
/// Attached ONCE to the root TabView in SpeechnotesApp (next to
/// `.globalMiniPlayer()`). The observer runs off the body-evaluation path: the
/// modifier's own body is a single `GeometryReader`-free size-class read, so a
/// rotation costs one environment write, not a layout pass per child.
struct LandscapeInjector: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content.environment(\.isLandscape, verticalSizeClass == .compact)
    }
}

extension View {
    /// Makes `\.isLandscape` available to this subtree.
    func landscapeAware() -> some View {
        modifier(LandscapeInjector())
    }
}
