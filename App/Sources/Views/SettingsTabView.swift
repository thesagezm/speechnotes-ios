import SwiftUI

struct SettingsTabView: View {
    @EnvironmentObject private var notes: NotesStore
    @ObservedObject private var notebooks = NotebooksStore.shared

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
                }
                Section("Storage") {
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
        }
    }
}
