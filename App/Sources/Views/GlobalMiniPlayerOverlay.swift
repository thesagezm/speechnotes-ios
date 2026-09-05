import SwiftUI

/// Pins `MiniPlayerBar` to the bottom of the whole window whenever speech is
/// active, regardless of which tab or pushed screen is on top.
///
/// The previous per-screen `.miniPlayer(...)` used `safeAreaInset` inside
/// each pushed view, so push/pop navigation transitions dragged the bar
/// across the screen and could leave it stranded mid-screen. Anchoring it
/// at the window level keeps it glued above the tab bar forever — and the
/// UIKit tab-bar height is read live from the hosting environment, so a
/// compact-height change (large-title inline, landscape) keeps the bar hugging
/// the tab bar instead of eating into it.
///
/// Tapping the bar posts `.miniPlayerJumpToNote`: `SpeechnotesApp` switches
/// to the Notes tab and `NotesListView` pushes the speaking note.
struct GlobalMiniPlayerOverlay: ViewModifier {
    @EnvironmentObject private var player: SpeechPlayer
    @State private var tabBarHeight: CGFloat = 49

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            if player.showMiniPlayer {
                MiniPlayerBar {
                    NotificationCenter.default.post(
                        name: .miniPlayerJumpToNote,
                        object: nil
                    )
                }
                // Lift above the system tab bar.
                .padding(.bottom, tabBarHeight)
                // Measure the actual tab bar so the inset stays right even if
                // iOS changes the bar height (large-title inline, etc.).
                .background(
                    TabBarHeightProbe { height in
                        if height > 0 { tabBarHeight = height }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.showMiniPlayer)
    }
}

/// A 1×1 UIKit intruder that walks the window to find the live tab-bar
/// height. Purely a measurement hack — it adds no visual element and does
/// not intercept touches (UIView-Representable, `isUserInteractionEnabled`
/// is false — touches fall through).
private struct TabBarHeightProbe: UIViewRepresentable {
    var onMeasure: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let probe = UIView()
        probe.isUserInteractionEnabled = false
        probe.backgroundColor = .clear
        probe.scheduleMeasure(onMeasure)
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private func scheduleMeasure(_ view: UIView, _ onMeasure: @escaping (CGFloat) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = view.window ?? view.superview?.window else {
                // Not in hierarchy yet (shouldn't happen on .onAppear) — retry.
                view.scheduleMeasure(onMeasure)
                return
            }
            guard window.rootViewController?.children.first is UITabBarController == false else { return }
            // Walk the view hierarchy for a UITabBar sibling
            let root = window.subviews.first ?? window
            if let tabBar = findTabBar(in: root) {
                onMeasure(tabBar.bounds.height + tabBar.safeAreaInsets.bottom)
            } else {
                onMeasure(49) // standard tab-bar height
            }
        }
    }

    private func findTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        return view.subviews.lazy.compactMap(findTabBar).first
    }
}

/// Attached ONCE to the root TabView in SpeechnotesApp.
extension View {
    func globalMiniPlayer() -> some View {
        modifier(GlobalMiniPlayerOverlay())
    }
}

extension Notification.Name {
    /// Posted by the global mini-player when the user taps the bar body.
    static let miniPlayerJumpToNote = Notification.Name("MiniPlayerBar.jumpToNote")
}
