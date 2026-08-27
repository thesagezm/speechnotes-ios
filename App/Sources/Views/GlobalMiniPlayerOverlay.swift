import SwiftUI

/// Pins a `MiniPlayerBar` to the bottom of the whole window **whenever speech
/// is active, regardless of which tab or screen is on top**.
///
/// Why this exists: the old per-screen `safeAreaInset` attached the bar to
/// the view being pushed/popped, so iOS navigation transitions dragged it
/// across the screen and could leave it stranded mid-transition — the "stuck
/// in the center of the screen" bug. Anchoring the bar at the root `TabView`
/// level keeps it glued to the bottom of the tab host forever.
///
/// Showing/hiding uses the plain `showMiniPlayer` state from SpeechPlayer:
/// - speaking/paused/generating → visible
/// - idle / audition → hidden
///
/// Jump-to-note is routed through a `Notification` because the overlay can't
/// reach the notes list's `NavigationPath` directly: `SpeechnotesApp`
/// selects the Notes tab on receipt, and `NotesListView` pushes the note.
struct GlobalMiniPlayerOverlay: ViewModifier {
    @EnvironmentObject private var player: SpeechPlayer

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if player.showMiniPlayer {
                MiniPlayerBar {
                    NotificationCenter.default.post(
                        name: .miniPlayerJumpToNote,
                        object: player.nowPlayingNoteId
                    )
                }
            }
        }
    }
}

extension View {
    /// Attach ONCE to the root TabView (SpeechnotesApp).
    func globalMiniPlayer() -> some View {
        modifier(GlobalMiniPlayerOverlay())
    }
}

extension Notification.Name {
    /// Posted by the global mini-player when the user taps the bar body.
    /// `object` is the speaking note's `UUID` (nil for anonymous text).
    static let miniPlayerJumpToNote = Notification.Name("MiniPlayerBar.jumpToNote")
}
