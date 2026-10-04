import SwiftUI

@main
struct SpeechnotesApp: App {
    @StateObject private var notes = NotesStore()
    /// App-level Books store — BookDrop imports must land on the SAME
    /// instance the Books tab displays, so the shelf updates live.
    @StateObject private var books = BooksStore()
    @StateObject private var player = SpeechPlayer()
    /// App-level audiobook playback — owns the AVAudioPlayer for .audio
    /// books so playback survives tab switches (the reader only binds and
    /// renders). Injected below like the other stores.
    @StateObject private var audioBooks = AudioBookPlayer()
    @StateObject private var theme = AppTheme()
    @Environment(\.scenePhase) private var scenePhase
    /// Selected tab — the global mini-player jumps here when the user taps
    /// the bar, then the notes list pushes the speaking note.
    @State private var selectedTab: Tab = .notes

    private enum Tab: Hashable, CaseIterable, Identifiable {
        case notes, books, stats, settings

        var id: Self { self }

        var label: String {
            switch self {
            case .notes: return "Notes"
            case .books: return "Books"
            case .stats: return "Stats"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .notes: return "note.text"
            case .books: return "books.vertical"
            case .stats: return "chart.bar.xaxis"
            case .settings: return "gearshape"
            }
        }
    }

    /// Onboarding gate — true after the first-run flow finishes or is skipped.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    /// The bottom TabView with labels — in BOTH orientations, by request.
    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            NotesListView()
                .tag(Tab.notes)
                .tabItem { Label("Notes", systemImage: "note.text") }
            BooksView()
                .tag(Tab.books)
                .tabItem { Label("Books", systemImage: "books.vertical") }
            StatsTabView()
                .tag(Tab.stats)
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
            SettingsTabView()
                .tag(Tab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }

    var body: some Scene {
        WindowGroup {
            // Bottom tab bar in both orientations (the lateral tab rail was
            // removed by request). The playback controls stay lateral — that
            // distinction is deliberate.
            tabContent
                .accentColor(theme.accentColor)
                .preferredColorScheme(theme.colorScheme)
                // Eager StateObject work (engine session setup,
                // NowPlayingCenter) must NOT run during App.init or inside
                // the first render transaction — HANDOVER: this is what
                // crashed the app on launch in LiveContainer. Defer it
                // past the first committed frame.
                .onAppear {
                    let notes = self.notes
                    let books = self.books
                    player.notesProvider = { [notes] id in
                        notes.notes.first(where: { $0.id == id })
                    }
                    BookPlaybackController.shared.bind(to: player)
                    // Foreground reconcile: a book bookmark left behind by a
                    // suspended background session. The store must be in
                    // scope here — SpeechPlayer deliberately knows nothing
                    // about BooksStore.
                    player.bookResumeHandler = { [weak books] bookId, chapterIndex in
                        guard let book = books?.books.first(where: { $0.id.uuidString == bookId }) else {
                            Log.shared.info("SpeechPlayer: book bookmark for a book that is no longer in the library — dropping")
                            return
                        }
                        Task { @MainActor in
                            await BookPlaybackController.shared.resumeBook(book: book, from: chapterIndex)
                        }
                    }
                    // Listening-time recording derives from the players'
                    // published state — zero hooks inside the engines.
                    StatsCenter.shared.attach(player: player, audioBooks: audioBooks)
                    // BookDrop: route landed files into the import
                    // pipelines; start the receiver if the toggle was left on.
                    let books = self.books
                    LocalSendReceiver.shared.router = { @MainActor url in
                        let ext = url.pathExtension.lowercased()
                        if ext == "jex" {
                            do {
                                let outcome = try JexImporter.importArchive(
                                    at: url,
                                    into: notes,
                                    notebooks: NotebooksStore.shared
                                )
                                LocalSendReceiver.shared.reportImport(
                                    name: url.lastPathComponent,
                                    size: 0,
                                    outcome: .imported("\(outcome.notesCreated) notes imported")
                                )
                            } catch {
                                LocalSendReceiver.shared.reportImport(
                                    name: url.lastPathComponent,
                                    size: 0,
                                    outcome: .failed(error.localizedDescription)
                                )
                            }
                            try? FileManager.default.removeItem(at: url)
                            return
                        }
                        if let imported = await books.importBook(from: url) {
                            LocalSendReceiver.shared.reportImport(
                                name: imported.title,
                                size: 0,
                                outcome: .imported("Added to Books")
                            )
                            try? FileManager.default.removeItem(at: url)
                        } else {
                            LocalSendReceiver.shared.reportImport(
                                name: url.lastPathComponent,
                                size: 0,
                                outcome: .failed(books.importError ?? "Import failed")
                            )
                        }
                    }
                    LocalSendReceiver.shared.applyPersistedEnabledState()
                    Task { @MainActor in
                        player.wirePlaybackOnce()
                        // ARMED LAST, AFTER WIRING. The hang watchdog is
                        // the only component that watches for a blocked
                        // main thread (a blocked thread also blocks every
                        // timer that runs on it, so nothing in-process
                        // can notice its own freeze). Armed past the first
                        // frame: launch is legitimately slow, and arming
                        // it earlier would trip on LiveContainer's
                        // cold-start stall.
                        //
                        // When it fires: the shelf backfill — the heaviest
                        // main-adjacent work in the app — is cancelled
                        // mid-pass, so the freeze stops being terminal and
                        // clears when the block lifts instead of needing a
                        // hard restart. See HangWatchdog for why it does
                        // not (and must not) relaunch the UI.
                        HangWatchdog.shared.onBlocked = {
                            NotificationCenter.default.post(name: .hangWatchdogFired, object: nil)
                        }
                        HangWatchdog.shared.start()
                    }
                }
                // One mini-player for the whole window; per-screen insets
                // used to ride push/pop transitions and get stuck
                // mid-screen.
                // MUST stay ABOVE the .environmentObject(...) calls: a
                // modifier attached outside the injection node cannot see
                // the injected objects, and GlobalMiniPlayerOverlay's
                // @EnvironmentObject player traps (EnvironmentObject.error
                // → EXC_BREAKPOINT) on the very first layout pass — the
                // confirmed launch crash (device .ips 2026-09-05 17:39).
                .globalMiniPlayer()
                // Landscape flag for the whole tree — drives the lateral
                // playback rails inside the root size observer (both sit
                // inside the environmentObject injection below).
                .landscapeAware()
                // Toast surface — no environment dependency (uses
                // ToastCenter.shared), so it can sit beside the mini-player.
                .appToasts()
                .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToNote)) { _ in
                    selectedTab = .notes
                }
                .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToBook)) { _ in
                    // BooksView listens for the same notification and pushes
                    // the playing book's reader.
                    selectedTab = .books
                }
                .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToExports)) { _ in
                    // Playing export: the Storage screen is its player surface
                    // (SettingsTabView listens for the same notification and
                    // pushes Storage).
                    selectedTab = .settings
                }
                // Saves are coalesced in NotesStore; the second the app
                // could be suspended is the one moment a pending write must
                // not be lost.
                .onChange(of: scenePhase) { phase in
                    // The watchdog is armed only while foregrounded: a
                    // suspended process freezes the probe thread with it,
                    // and measuring across the pause is what logged hours
                    // as one "blocked" incident and cancelled the shelf
                    // backfill on every resume. setActive re-arms with a
                    // fresh baseline, so the pause never enters a
                    // measurement.
                    HangWatchdog.shared.setActive(phase == .active)
                    if phase != .active {
                        notes.flushNow()
                        // Notebooks mirror the notes flush: a rename or delete
                        // pending in the 400 ms debounce must not be lost to
                        // a suspension the moment the app leaves the screen.
                        NotebooksStore.shared.flushNow()
                        // Mid-speech: a bookmark lets playback resume where
                        // it stopped if iOS suspends or kills the process.
                        player.persistPlaybackBookmark()
                        // Audiobook playhead → the book manifest, so a
                        // suspension or kill resumes within the chapter.
                        audioBooks.persistNow()
                    }
                    if phase == .active {
                        // Returning from the app switcher / lock screen:
                        // re-assert a live session, repair the "playing
                        // nothing" wedge, and resume a recent bookmark
                        // (notes AND books) if the process lost its engines.
                        player.reconcileOnForeground()
                    }
                }
                // Environment injection is attached LAST (outermost) so
                // every node below it — TabView content AND the mini-player
                // modifier — resolves @EnvironmentObject.
                .environmentObject(notes)
                .environmentObject(books)
                .environmentObject(player)
                .environmentObject(audioBooks)
                .environmentObject(WavPlayer.shared)
                .environmentObject(theme)
                // First launch only — self-contained, no eager work
                // (LiveContainer launch hygiene).
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
