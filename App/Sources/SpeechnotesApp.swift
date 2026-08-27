import SwiftUI

@main
struct SpeechnotesApp: App {
    @StateObject private var notes = NotesStore()
    @StateObject private var player = SpeechPlayer()
    @StateObject private var theme = AppTheme()
    @StateObject private var dictation = DictationCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    /// Selected tab — the global mini-player jumps here when the user taps
    /// the bar, then opens the speaking note.
    @State private var selectedTab: Tab = .notes

    private enum Tab: Hashable {
        case notes, stt, settings
    }

    init() {
        // SpeechPlayer can only auto-resume a bookmarked note if it can
        // resolve the note's current text — wire the lookup once here.
        player.notesProvider = { id in
            notes.notes.first(where: { $0.id == id })
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                NotesListView()
                    .tag(Tab.notes)
                    .tabItem { Label("Notes", systemImage: "note.text") }
                DictationTabView()
                    .tag(Tab.stt)
                    .tabItem { Label("Speech to text", systemImage: "mic.fill") }
                SettingsTabView()
                    .tag(Tab.settings)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .accentColor(theme.accentColor)
            .preferredColorScheme(theme.colorScheme)
            .environmentObject(notes)
            .environmentObject(player)
            .environmentObject(theme)
            .environmentObject(dictation)
            // One overlay for the whole app — the OLD per-screen version got
            // dragged across the screen during push/pop transitions and could
            // end up stuck in the middle.
            .globalMiniPlayer()
            .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToNote)) { _ in
                selectedTab = .notes
            }
            // Saves are coalesced in NotesStore; the second the app could be
            // suspended is the one moment a pending write must not be lost.
            .onChange(of: scenePhase) { phase in
                if phase != .active {
                    notes.flushNow()
                    player.persistPlaybackBookmark()
                }
                if phase == .active {
                    // Returning from the app switcher / lock screen: if iOS
                    // suspended the process mid-speech, offer the saved
                    // bookmark as an immediate resume path.
                    player.resumeIfBookmarkPending()
                }
            }
        }
    }
}
