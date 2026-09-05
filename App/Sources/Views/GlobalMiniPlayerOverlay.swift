import SwiftUI

/// Pins `MiniPlayerBar` to the bottom of the whole window whenever speech is
/// active, regardless of which tab or pushed screen is on top.
///
/// Anchoring it once at the root `TabView` keeps it glued to the tab bar
/// forever (the previous per-screen `.miniPlayer(...)` used `safeAreaInset`
/// inside each pushed view, so push/pop transitions dragged the bar across
/// the screen and left it stranded mid-screen). A fixed tab-bar inset
/// (49pt standard + safe-area bottom) lifts the bar just above the tabs.
///
/// Tapping the bar posts `.miniPlayerJumpToNote`: `SpeechnotesApp` switches
/// to the Notes tab and `NotesListView` pushes the speaking note.
struct GlobalMiniPlayerOverlay: ViewModifier {
    @EnvironmentObject private var player: SpeechPlayer

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
                // Standard tab bar (49pt) + safe-area bottom inset = lift
                // the mini player just above the Notes/Storage/Settings tabs.
                .padding(.bottom, 49 + 34)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.showMiniPlayer)
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
