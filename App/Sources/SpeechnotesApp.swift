import SwiftUI

@main
struct SpeechnotesApp: App {
    @StateObject private var notes = NotesStore()
    @StateObject private var player = SpeechPlayer()
    @StateObject private var theme = AppTheme()
    @Environment(\.scenePhase) private var scenePhase
    /// Selected tab — the global mini-player jumps here when the user taps
    /// the bar, then the notes list pushes the speaking note.
    @State private var selectedTab: Tab = .notes

    private enum Tab: Hashable, CaseIterable, Identifiable {
        case notes, books, settings

        var id: Self { self }

        var label: String {
            switch self {
            case .notes: return "Notes"
            case .books: return "Books"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .notes: return "note.text"
            case .books: return "books.vertical"
            case .settings: return "gearshape"
            }
        }
    }

    /// Onboarding gate — true after the first-run flow finishes or is skipped.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    /// iPhone-only target: compact vertical size class ⇔ landscape. Injected
    /// once at the window root (OrientationState.landscapeAware()).
    @Environment(\.isLandscape) private var isLandscape

    /// Portrait: the standard bottom TabView with labels. In landscape its own
    /// tab bar hides so the lateral rail is the only destination chrome — no
    /// two tab bars on screen at once.
    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            NotesListView()
                .tag(Tab.notes)
                .tabItem { Label("Notes", systemImage: "note.text") }
            BooksView()
                .tag(Tab.books)
                .tabItem { Label("Books", systemImage: "books.vertical") }
            SettingsTabView()
                .tag(Tab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .toolbar(isLandscape ? .hidden : .visible, for: .tabBar)
    }

    /// Landscape: icon-only rail on the leading edge. The TabView keeps its
    /// own (portrait) bar hidden underneath — `.toolbar(.hidden, for:
    /// .tabBar)` — so the rail is the only destination chrome. Each row is a
    /// 56pt full-height target with the accent under the active tab, matching
    /// the portrait bar's selection language.
    private var landscapeTabRail: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        Haptics.tap()
                        selectedTab = tab
                    } label: {
                        Image(systemName: tab.icon)
                            .font(.title3)
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                            .frame(width: 56, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.label)
                    // Active indicator — the portrait bar's equivalent.
                    .overlay(alignment: .bottom) {
                        if selectedTab == tab {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 24, height: 2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .padding(.leading, 4)
            .frame(width: 62)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .trailing) {
                Divider()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            // Landscape docks the tab bar to the LEADING edge with icons only
            // (labels off) — the reading surface keeps every point of the short
            // axis, and the three destinations stay one thumb-tap away
            // (user request: "move the tabs lateral, icons without the words,
            // use a bit more of the lateral space"). Portrait keeps the bottom
            // tab bar with labels, untouched.
            ZStack(alignment: .leading) {
                tabContent
                if isLandscape {
                    landscapeTabRail
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isLandscape)
            .accentColor(theme.accentColor)
            .preferredColorScheme(theme.colorScheme)
            // Eager StateObject work (engine session setup, NowPlayingCenter)
            // must NOT run during App.init or inside the first render
            // transaction — HANDOVER: this is what crashed the app on launch
            // in LiveContainer. Defer it past the first committed frame.
            .onAppear {
                let notes = self.notes
                player.notesProvider = { [notes] id in
                    notes.notes.first(where: { $0.id == id })
                }
                BookPlaybackController.shared.bind(to: player)
                Task { @MainActor in
                    player.wirePlaybackOnce()
                }
            }
            // One mini-player for the whole window; per-screen insets used
            // to ride push/pop transitions and get stuck mid-screen.
            // MUST stay ABOVE the .environmentObject(...) calls: a modifier
            // attached outside the injection node cannot see the injected
            // objects, and GlobalMiniPlayerOverlay's @EnvironmentObject
            // player traps (EnvironmentObject.error → EXC_BREAKPOINT) on the
            // very first layout pass — the confirmed launch crash
            // (device .ips 2026-09-05 17:39).
            .globalMiniPlayer()
            // Landscape flag for the whole tree — drives the lateral playback
            // rails. Placed after the mini-player so the overlay itself can
            // read it; both sit inside the environmentObject injection below.
            .landscapeAware()
            // Toast surface — no environment dependency (uses
            // ToastCenter.shared), so it can sit beside the mini-player.
            .appToasts()
            .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToNote)) { _ in
                selectedTab = .notes
            }
            .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToBook)) { _ in
                // BooksView listens for the same notification and pushes the
                // playing book's reader.
                selectedTab = .books
            }
            // Saves are coalesced in NotesStore; the second the app could be
            // suspended is the one moment a pending write must not be lost.
            .onChange(of: scenePhase) { phase in
                if phase != .active {
                    notes.flushNow()
                    // Mid-speech: a bookmark lets playback resume where it
                    // stopped if iOS suspends or kills the process.
                    player.persistPlaybackBookmark()
                }
                if phase == .active {
                    // Returning from the app switcher / lock screen: if iOS
                    // suspended us mid-speech, restart from the bookmark.
                    player.resumeIfBookmarkPending()
                }
            }
            // Environment injection is attached LAST (outermost) so every
            // node below it — TabView content AND the mini-player modifier —
            // resolves @EnvironmentObject.
            .environmentObject(notes)
            .environmentObject(player)
            .environmentObject(theme)
            // First launch only — self-contained, no eager work (LiveContainer
            // launch hygiene).
            .fullScreenCover(isPresented: Binding(
                get: { !hasOnboarded },
                set: { if !$0 { hasOnboarded = true } }
            )) {
                OnboardingView { hasOnboarded = true }
                    .interactiveDismissDisabled()
            }
        }
    }
}
