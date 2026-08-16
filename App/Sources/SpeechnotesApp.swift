import SwiftUI

@main
struct SpeechnotesApp: App {
    @StateObject private var notes = NotesStore()
    @StateObject private var player = SpeechPlayer()

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
        }
    }
}
