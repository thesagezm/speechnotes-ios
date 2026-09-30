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

    /// One identity for "everything that can make the bar appear,
    /// disappear, or change shape" — so the overlay attaches ONE spring to
    /// one value instead of four easings to four.
    private var barAnimationKey: String {
        "\(player.showMiniPlayer)|\(audioBooks.showMiniBar)|\(wav.showMiniPlayer)|\(miniPlayerCollapsed)|\(player.state)|\(audioBooks.isPlaying)"
    }

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
                        // v1.7.2: the round bubble is USER-MOVABLE — drag it
                        // anywhere; release snaps it to the nearest edge and
                        // persists the spot. The old hard-coded bottom-right
                        // placement is the default it starts from.
                        EdgeSnappingBubble {
                            collapsedBar
                        }
                        .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                        .zIndex(1)
                    } else {
                        expandedBar
                            .padding(.bottom, 49 + 34)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(1)
                    }
                }
            }
            // One spring for the whole bar. The four separate .animation
            // modifiers each attached their own 0.2 s ease to a DIFFERENT
            // value, so a bar that changed two of them at once (play → the
            // mini-player surfaces AND the collapsed state flips) animated
            // two conflicting transactions and the bar visibly snapped
            // rather than eased. A single spring on the union of the four
            // values gives one coherent motion, and the longer,
            // lower-bounce curve is what reads as "smooth" rather than
            // "popped". The tuck expand/collapse keeps its own spring
            // modifier inside AudioBookMiniPlayerBar.
            .animation(.spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0.12),
                       value: barAnimationKey)
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

/// The user-movable floating bubble (v1.7.2, user ask: "move it to any edge
/// location, not just the bottom right").
///
/// The bubble's CENTER lives in a normalized (0…1, 0…1) spot of the usable
/// area — persisted, so the chosen corner survives relaunch and rotation.
/// Dragging moves it freely; releasing SNAPS it to the nearest of the four
/// edges (keeping the along-edge coordinate), which is what keeps the
/// bubble one-thumb reachable instead of drifting into the middle of
/// content.
///
/// Tap vs drag: the bubble stays a Button (tap expands back to the bar);
/// the drag gesture needs 10 pt of travel before it claims the touch, so a
/// tap never turns into a micro-drag and a drag never fires the tap.
/// Layout constants live OUTSIDE the generic struct — Swift forbids static
/// stored properties on generic types.
private enum BubbleLayout {
    /// Half the bubble's size (all three bubble variants are ~58 pt).
    static let radius: CGFloat = 29
    static let margin: CGFloat = 12
    /// The tab bar (49 pt) plus breathing room: the bottom edge stops above
    /// the tab bar so a parked bubble never covers its right-hand tabs.
    static let bottomReserve: CGFloat = 57
}

private struct EdgeSnappingBubble<Bubble: View>: View {
    @ViewBuilder let bubble: () -> Bubble

    @AppStorage("miniBubbleX") private var storedX: Double = 1
    @AppStorage("miniBubbleY") private var storedY: Double = 1
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            // GeometryReader's insets are EdgeInsets: leading/trailing, not
            // left/right.
            let insets = geo.safeAreaInsets
            let minX = insets.leading + BubbleLayout.margin + BubbleLayout.radius
            let maxX = geo.size.width - insets.trailing - BubbleLayout.margin - BubbleLayout.radius
            // Bottom clamps above the tab bar; the other three edges keep
            // the plain safe-area margin.
            let minY = insets.top + BubbleLayout.margin + BubbleLayout.radius
            let maxY = geo.size.height - insets.bottom - BubbleLayout.bottomReserve - BubbleLayout.margin - BubbleLayout.radius
            let baseX = minX + (maxX - minX) * min(max(storedX, 0), 1)
            let baseY = minY + (maxY - minY) * min(max(storedY, 0), 1)
            let liveX = min(max(baseX + dragOffset.width, minX), maxX)
            let liveY = min(max(baseY + dragOffset.height, minY), maxY)

            bubble()
                .position(x: liveX, y: liveY)
                // NOT simultaneous: a simultaneous drag still lets the
                // Button fire on release, so every drag END expanded the
                // bar. With a plain gesture the drag owns the touch and the
                // button only sees genuine taps.
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            let x = min(max(baseX + value.translation.width, minX), maxX)
                            let y = min(max(baseY + value.translation.height, minY), maxY)
                            // Snap to the nearest edge; the other coordinate
                            // keeps its (clamped) place along that edge.
                            let toLeft = x - minX
                            let toRight = maxX - x
                            let toTop = y - minY
                            let toBottom = maxY - y
                            let nearest = min(toLeft, toRight, toTop, toBottom)
                            var snappedX = x
                            var snappedY = y
                            if nearest == toLeft {
                                snappedX = minX
                            } else if nearest == toRight {
                                snappedX = maxX
                            } else if nearest == toTop {
                                snappedY = minY
                            } else {
                                snappedY = maxY
                            }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                dragOffset = .zero
                                storedX = maxX > minX ? Double((snappedX - minX) / (maxX - minX)) : 1
                                storedY = maxY > minY ? Double((snappedY - minY) / (maxY - minY)) : 1
                            }
                        }
                )
        }
        .ignoresSafeArea()
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
