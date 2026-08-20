import SwiftUI

struct SettingsTabView: View {
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
                Section("Storage") {
                    NavigationLink("Storage") {
                        StorageSettingsView()
                    }
                }
                Section("Voices") {
                    NavigationLink("Import Voices") {
                        ImportVoicesView()
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
