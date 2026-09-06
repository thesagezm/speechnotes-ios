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

    private enum Tab: Hashable {
        case notes, books, settings
    }

    /// Onboarding gate — true after the first-run flow finishes or is skipped.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some Scene {
        WindowGroup {
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
