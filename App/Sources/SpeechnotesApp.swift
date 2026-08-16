import SwiftUI

@main
struct SpeechnotesApp: App {
    @StateObject private var notes = NotesStore()
    @StateObject private var player = SpeechPlayer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                NotesListView()
                    .tabItem { Label("Notes", systemImage: "note.text") }
                LogsView()
                    .tabItem { Label("Logs", systemImage: "ladybug") }
            }
            .environmentObject(notes)
            .environmentObject(player)
            // Saves are coalesced in NotesStore; the second the app could be
            // suspended is the one moment a pending write must not be lost.
            .onChange(of: scenePhase) { phase in
                if phase != .active { notes.flushNow() }
            }
        }
    }
}
