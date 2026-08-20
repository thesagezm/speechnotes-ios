import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        Form {
            Section("Accent Color") {
                Picker("Accent", selection: $theme.accentChoice) {
                    ForEach(AccentColorChoice.allCases) { c in
                        HStack {
                            Circle().fill(c.color).frame(width: 16, height: 16)
                            Text(c.displayName)
                        }.tag(c)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("Appearance") {
                Picker("Theme", selection: $theme.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Appearance")
    }
}
