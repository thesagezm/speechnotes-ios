import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("renderMarkdown") private var renderMarkdown = false

    var body: some View {
        Form {
            Section {
                // Dropdown (menu style): one row showing the current color,
                // expanding to all 12 choices on tap — the inline list was
                // too long (user feedback).
                Picker("Accent", selection: $theme.accentChoice) {
                    ForEach(AccentColorChoice.allCases) { c in
                        HStack {
                            Circle().fill(c.color).frame(width: 16, height: 16)
                            Text(c.displayName)
                        }.tag(c)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Used across notes, playback controls and highlights.")
            }
            Section {
                // (v1.7 round 5: moved here from Speech Settings — rendering
                // is how a note LOOKS, not how it speaks.)
                Toggle("Render Markdown", isOn: $renderMarkdown)
            } header: {
                Text("Notes")
            } footer: {
                Text("When on, a note opens in reading mode (headings, emphasis and links rendered; eye button / double-tap to edit). Speech reads what you are looking at: rendered clean text in reading mode, the raw text while editing.")
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

            // Spacing controls (v1.6.3) — the reader's rhythm, tunable after
            // the "too crowded" report. Each slider scales the base values in
            // ReaderSpacing; 100% is the new default (already roomier than the
            // old hardcoded spacing).
            Section {
                spacingSlider(
                    title: "Line spacing",
                    value: $theme.readerLineSpacing,
                    range: 0.8...1.6,
                    caption: "Space between lines inside paragraphs and quotes."
                )
                spacingSlider(
                    title: "Between blocks",
                    value: $theme.readerBlockSpacing,
                    range: 0.8...1.6,
                    caption: "Gap after paragraphs, lists and headings — the one to raise when notes feel cramped."
                )
                spacingSlider(
                    title: "Tables",
                    value: $theme.readerTableSpacing,
                    range: 0.8...2.0,
                    caption: "Row height and cell padding in tables. Its own slider because tables need visibly more air than prose."
                )
                Button("Reset spacing") {
                    Haptics.tap()
                    theme.resetReaderSpacing()
                }
            } header: {
                Text("Spacing")
            } footer: {
                Text("Applies to the markdown reader and the read-along view. 100% is the default.")
            }
        }
        .navigationTitle("Appearance")
    }

    /// One spacing slider: label + live percentage, matching the Text size
    /// slider's layout so the section reads as one control group.
    @ViewBuilder
    private func spacingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(round(value.wrappedValue * 100)))%")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            Slider(value: value, in: range, step: 0.05) { _ in Haptics.tap() }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
