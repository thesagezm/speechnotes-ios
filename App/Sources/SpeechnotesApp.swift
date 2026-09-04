import SwiftUI

@main
struct SpeechnotesApp: App {
    @StateObject private var notes = NotesStore()
    @StateObject private var player = SpeechPlayer()
    @StateObject private var theme = AppTheme()
    @Environment(\.scenePhase) private var scenePhase
    /// Selected tab — the global mini-player jumps here when the user taps
    /// the bar, then opens the speaking note.
    @State private var selectedTab: Tab = .notes
    /// Has the player/notes wiring been performed? Done lazily on first
    /// body run so we never touch a `@StateObject`'s wrapped value from
    /// `init` — that's the trap that crashes inside LiveContainer / iOS 26
    /// ("Accessing StateObject's object without being installed on a View").
    @State private var didWirePlayback: Bool = false

    private enum Tab: Hashable {
        case notes, storage, settings
    }

    /// SpeechPlayer can only auto-resume a bookmarked note if it can
    /// resolve the note's current text. Wired once, on the main actor,
    /// after the App is installed in a WindowGroup. Pulled out of `init`
    /// because referencing `@StateObject` storage from `init` is undefined
    /// on iOS 18+ with strict concurrency.
    @MainActor
    private func wirePlaybackOnce() {
        guard !didWirePlayback else { return }
        didWirePlayback = true
        let store = notes
        player.notesProvider = { id in
            store.notes.first(where: { $0.id == id })
        }
        player.wirePlayback()
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .onAppear { wirePlaybackOnce() }
        }
    }

    private var rootView: some View {
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
