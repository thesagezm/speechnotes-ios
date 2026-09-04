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
            Section("Reading View") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Text size")
                        Spacer()
                        Text("\(Int(round(theme.previewTextScale * 100)))%")
                            .foregroundStyle(.secondary)
                            .font(.callout.monospacedDigit())
                    }
                    // Steps of 5% feel right on a phone and stay audible to
                    // VoiceOver.
                    Slider(
                        value: $theme.previewTextScale,
                        in: 0.75...1.5,
                        step: 0.05
                    ) { _ in Haptics.tap() }
                    Text("Scales the markdown preview's text (headings, lists, paragraphs).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Appearance")
    }
}
