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
        case notes, storage, settings
    }

    init() {
        // SpeechPlayer can only resume a bookmarked note if it can resolve
        // the note's current text — wire the lookup once here.
        player.notesProvider = { [notes] id in
            notes.notes.first(where: { $0.id == id })
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                NotesListView()
                    .tag(Tab.notes)
                    .tabItem { Label("Notes", systemImage: "note.text") }
                StorageView()
                    .tag(Tab.storage)
                    .tabItem { Label("Storage", systemImage: "externaldrive") }
                SettingsTabView()
                    .tag(Tab.settings)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .accentColor(theme.accentColor)
            .preferredColorScheme(theme.colorScheme)
            .environmentObject(notes)
            .environmentObject(player)
            .environmentObject(theme)
            // One mini-player for the whole window; per-screen insets used
            // to ride push/pop transitions and get stuck mid-screen.
            .globalMiniPlayer()
            .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToNote)) { _ in
                selectedTab = .notes
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
        }
    }
}
