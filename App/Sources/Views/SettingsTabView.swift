import SwiftUI
import UniformTypeIdentifiers

struct SettingsTabView: View {
    @EnvironmentObject private var notes: NotesStore
    @ObservedObject private var notebooks = NotebooksStore.shared
    /// JEX import picker + result toast state.
    @State private var showingJexImporter = false
    @State private var jexImportMessage: String?
    /// Mini-player jump: push the Storage screen (the playing export's
    /// player surface) programmatically.
    @State private var pushStorageForExport = false

    private static let jexType = UTType(importedAs: "com.joplin.jex")

    var body: some View {
        NavigationStack {
            Form {
                Section("Speech") {
                    NavigationLink("Speech Settings") {
                        SpeechSettingsView()
                    }
                }
                Section("Appearance") {
                    NavigationLink("Appearance") {
                        AppearanceSettingsView()
                    }
                }
                Section("Backup") {
                    NavigationLink("Export notes to Joplin (.jex)") {
                        BackupExportView(
                            notes: notes.notes,
                            notebooks: notebooks.notebooks
                        )
                    }
                    Button {
                        showingJexImporter = true
                    } label: {
                        Label("Import from Joplin (.jex)", systemImage: "square.and.arrow.down")
                    }
                }
                Section("Storage") {
                    // Closure-based link (the value-based NavigationLink from
                    // the first round-6 attempt never registered its
                    // destination inside the lazy Form row on device — taps
                    // highlighted and did nothing). The mini-player jump uses
                    // navigationDestination(isPresented:) at the FORM level,
                    // which registers reliably.
                    NavigationLink("Storage") {
                        StorageSettingsView()
                    }
                }
                Section("About") {
                    NavigationLink("About") {
                        AboutView()
                    }
                    NavigationLink("Logs") {
                        LogsView()
                    }
                }
            }
            .navigationTitle("Settings")
            .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToExports)) { _ in
                // Mini-player tap on a playing export → its player surface.
                pushStorageForExport = true
            }
            .navigationDestination(isPresented: $pushStorageForExport) {
                StorageSettingsView()
            }
            .fileImporter(
                isPresented: $showingJexImporter,
                allowedContentTypes: [.data, Self.jexType],
                allowsMultipleSelection: false
            ) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        importJex(at: url)
                    case .failure(let error):
                        jexImportMessage = error.localizedDescription
                    }
                }
            }
            .alert(
                "JEX import",
                isPresented: Binding(
                    get: { jexImportMessage != nil },
                    set: { if !$0 { jexImportMessage = nil } }
                )
            ) {
                Button("OK") { jexImportMessage = nil }
            } message: {
                Text(jexImportMessage ?? "")
            }
        }
    }

    /// Runs off-main (a JEX can be tens of MB) and reports what landed.
    private func importJex(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let outcome = try JexImporter.importArchive(
                at: url,
                into: notes,
                notebooks: notebooks
            )
            var parts: [String] = []
            if outcome.notesCreated > 0 { parts.append("\(outcome.notesCreated) note\(outcome.notesCreated == 1 ? "" : "s")") }
            if outcome.notebooksCreated > 0 { parts.append("\(outcome.notebooksCreated) notebook\(outcome.notebooksCreated == 1 ? "" : "s")") }
            if outcome.imagesImported > 0 { parts.append("\(outcome.imagesImported) image\(outcome.imagesImported == 1 ? "" : "s")") }
            if outcome.notebooksMerged > 0 { parts.append("\(outcome.notebooksMerged) merged into existing notebooks") }
            jexImportMessage = parts.isEmpty
                ? "Nothing to import — the archive had no notes."
                : "Imported " + parts.joined(separator: ", ") + "."
            Haptics.success()
        } catch {
            jexImportMessage = "Import failed — \(error.localizedDescription)"
            Haptics.warning()
        }
    }
}
