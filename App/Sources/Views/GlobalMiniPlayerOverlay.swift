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
/// Tapping the bar jumps to the speaking content: a playing BOOK routes to
/// the Books tab (`.miniPlayerJumpToBook`, pushing the book's reader), a
/// playing note routes to the Notes tab (`.miniPlayerJumpToNote`, where
/// NotesListView pushes the note). The layout is identical in both
/// orientations — the tab bar it docks above is back in landscape.
struct GlobalMiniPlayerOverlay: ViewModifier {
    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var audioBooks: AudioBookPlayer
    @AppStorage("miniPlayerCollapsed") private var miniPlayerCollapsed = false

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            // The animation scope wraps ONLY the conditional bar — never the
            // whole window (nav bar included). A root-level .animation made
            // toolbar items rasterize blurry until first interaction
            // (iOS 26 / LiveContainer).
            Group {
                // An audiobook that is loaded (playing or paused) wins the
                // dock: its reader left the screen and this bar is how the
                // book keeps playing across tabs.
                if audioBooks.showMiniBar {
                    if miniPlayerCollapsed {
                        AudioBookMiniPlayerBubble()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 49 + 34 + 8)
                            .transition(.scale.combined(with: .opacity))
                            .zIndex(1)
                    } else {
                        AudioBookMiniPlayerBar {
                            jumpToPlayingContent()
                        }
                        .padding(.bottom, 49 + 34)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                    }
                } else if player.showMiniPlayer {
                    // Same layout in both orientations now — the bottom tab bar
                    // returns in landscape (user request), so the mini-player
                    // keeps its original bottom-docked chrome everywhere.
                    if miniPlayerCollapsed {
                        MiniPlayerBubble()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 49 + 34 + 8)
                            .transition(.scale.combined(with: .opacity))
                            .zIndex(1)
                    } else {
                        MiniPlayerBar {
                            jumpToPlayingContent()
                        }
                        // Standard tab bar (49pt) + safe-area bottom inset = lift
                        // the mini player just above the Notes/Books/Settings tabs.
                        .padding(.bottom, 49 + 34)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: player.showMiniPlayer)
            .animation(.easeInOut(duration: 0.2), value: audioBooks.showMiniBar)
            .animation(.easeInOut(duration: 0.2), value: miniPlayerCollapsed)
        }
    }

    private func jumpToPlayingContent() {
        // The bar that is visible decides the jump target.
        if audioBooks.showMiniBar, let bookId = audioBooks.activeBookID {
            // The pending slot makes the jump survive the tab-switch race:
            // the notification fires before BooksView installs its listener,
            // so the view also consumes the slot in onAppear.
            player.pendingBookJumpId = bookId.uuidString
            NotificationCenter.default.post(name: .miniPlayerJumpToBook, object: bookId.uuidString)
        } else if let bookId = player.nowPlayingBookId {
            player.pendingBookJumpId = bookId
            NotificationCenter.default.post(name: .miniPlayerJumpToBook, object: bookId)
        } else {
            NotificationCenter.default.post(name: .miniPlayerJumpToNote, object: nil)
        }
    }
}

/// Attached ONCE to the root TabView in SpeechnotesApp.
extension View {
    func globalMiniPlayer() -> some View {
        modifier(GlobalMiniPlayerOverlay())
    }
}

extension Notification.Name {
    /// Posted when an audiobook file is deleted while its reader is open —
    /// the reader stops its own player so nothing plays a removed file.
    static let audioBookStopped = Notification.Name("AudioBook.stopped")
    /// Posted by the global mini-player when the user taps the bar body.
    static let miniPlayerJumpToNote = Notification.Name("MiniPlayerBar.jumpToNote")
    /// v1.5: same tap while a BOOK speaks — object carries the book UUID string.
    static let miniPlayerJumpToBook = Notification.Name("MiniPlayerBar.jumpToBook")
}
