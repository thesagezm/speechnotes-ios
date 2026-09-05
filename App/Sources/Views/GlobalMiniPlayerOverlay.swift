import SwiftUI

/// Pins `MiniPlayerBar` to the bottom of the whole window whenever speech is
/// active, regardless of which tab or pushed screen is on top.
///
/// The previous per-screen `.miniPlayer(...)` used `safeAreaInset` inside
/// each pushed view, so push/pop navigation transitions dragged the bar
/// across the screen and could leave it stranded mid-screen. Anchoring it
/// once at the root `TabView` keeps it glued to the tab bar forever.
///
/// Tapping the bar posts `.miniPlayerJumpToNote`: `SpeechnotesApp` switches
/// to the Notes tab and `NotesListView` pushes the speaking note (the
/// overlay can't reach the list's `NavigationPath` directly).
struct GlobalMiniPlayerOverlay: ViewModifier {
    @EnvironmentObject private var player: SpeechPlayer

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if player.showMiniPlayer {
                MiniPlayerBar {
                    NotificationCenter.default.post(
                        name: .miniPlayerJumpToNote,
                        object: nil
                    )
                }
            }
        }
    }
}

extension View {
    /// Attach ONCE to the root TabView in SpeechnotesApp.
    func globalMiniPlayer() -> some View {
        modifier(GlobalMiniPlayerOverlay())
    }
}

extension Notification.Name {
    /// Posted by the global mini-player when the user taps the bar body.
    static let miniPlayerJumpToNote = Notification.Name("MiniPlayerBar.jumpToNote")
}
