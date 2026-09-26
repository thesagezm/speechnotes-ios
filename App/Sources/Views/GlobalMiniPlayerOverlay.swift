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
    @EnvironmentObject private var wav: WavPlayer
    @AppStorage("miniPlayerCollapsed") private var miniPlayerCollapsed = false

    /// Which bar owns the dock right now — one at a time, audiobook first
    /// (its whole point is surviving the reader), then a playing export,
    /// then the speaking-note bar.
    private var activeBar: Bar {
        if audioBooks.showMiniBar { return .audioBook }
        if wav.showMiniPlayer { return .export }
        if player.showMiniPlayer { return .note }
        return .none
    }

    private enum Bar { case audioBook, export, note, none }

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            // The animation scope wraps ONLY the conditional bar — never the
            // whole window (nav bar included). A root-level .animation made
            // toolbar items rasterize blurry until first interaction
            // (iOS 26 / LiveContainer).
            Group {
                if activeBar != .none {
                    if miniPlayerCollapsed {
                        collapsedBar
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 49 + 34 + 8)
                            .transition(.scale.combined(with: .opacity))
                            .zIndex(1)
                    } else {
                        expandedBar
                            .padding(.bottom, 49 + 34)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(1)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: player.showMiniPlayer)
            .animation(.easeInOut(duration: 0.2), value: audioBooks.showMiniBar)
            .animation(.easeInOut(duration: 0.2), value: wav.showMiniPlayer)
            .animation(.easeInOut(duration: 0.2), value: miniPlayerCollapsed)
        }
    }

    @ViewBuilder private var expandedBar: some View {
        switch activeBar {
        case .audioBook:
            AudioBookMiniPlayerBar {
                jumpToPlayingContent()
            }
        case .export:
            ExportMiniPlayerBar {
                NotificationCenter.default.post(name: .miniPlayerJumpToExports, object: nil)
            }
        default:
            MiniPlayerBar {
                jumpToPlayingContent()
            }
        }
    }

    @ViewBuilder private var collapsedBar: some View {
        switch activeBar {
        case .audioBook:
            AudioBookMiniPlayerBubble()
        case .export:
            ExportMiniPlayerBubble()
        default:
            MiniPlayerBubble()
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
    /// Round 5: same tap while an EXPORT plays — Settings' Storage screen
    /// opens (the export list is the player surface for downloaded audio).
    static let miniPlayerJumpToExports = Notification.Name("MiniPlayerBar.jumpToExports")
}
