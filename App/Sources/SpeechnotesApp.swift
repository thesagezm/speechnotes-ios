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
        // Diagnostics: write directly to a file in case LogStore itself is crashing.
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("launch-diagnostics.log")
        let ts = ISO8601DateFormatter().string(from: Date())
        let msg = "\(ts): SpeechnotesApp.init\n"
        try? msg.write(to: url, atomically: true, encoding: .utf8)
    }

    var body: some Scene {
        WindowGroup {
            let _ = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("launch-diagnostics.log")
                .appendLine("WindowGroup content start")
            return TabView(selection: $selectedTab) {
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
            .onAppear {
                let _ = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("launch-diagnostics.log")
                    .appendLine("root onAppear")
                player.notesProvider = { [notes] id in
                    notes.notes.first(where: { $0.id == id })
                }
                player.wirePlaybackOnce()
            }
            .globalMiniPlayer()
            .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToNote)) { _ in
                selectedTab = .notes
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active {
                    notes.flushNow()
                    player.persistPlaybackBookmark()
                }
                if phase == .active {
                    player.resumeIfBookmarkPending()
                }
            }
        }
    }
}

private extension URL {
    func appendLine(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let msg = "\(ts): \(line)\n"
        if let handle = try? FileHandle(forWritingTo: self) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(Data(msg.utf8))
        } else {
            try? msg.write(to: self, atomically: true, encoding: .utf8)
        }
    }
}
