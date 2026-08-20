import SwiftUI

@main
struct SpeechnotesApp: App {
    @StateObject private var notes = NotesStore()
    @StateObject private var player = SpeechPlayer()
    @StateObject private var theme = AppTheme()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                NotesListView()
                    .tabItem { Label("Notes", systemImage: "note.text") }
                StorageView()
                    .tabItem { Label("Storage", systemImage: "externaldrive") }
                SettingsTabView()
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
                if phase != .active { notes.flushNow() }
            }
        }
    }
}
