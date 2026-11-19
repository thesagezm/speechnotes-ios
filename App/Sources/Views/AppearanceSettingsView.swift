import SwiftUI
import SpeechLogic

/// Appearance settings. 2026-11-19 cleanup: the Bypass Paywalls and Image
/// caching toggles are gone (bypass always runs on web import, images cache
/// automatically — neither earned a switch), Keep Screen On moved here from
/// the Settings tab root, and the per-section footer essays are gone.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("renderMarkdown") private var renderMarkdown = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    /// Keep Screen On (was on the Settings tab root): the key/default live
    /// in `ScreenAwakePolicy` (SpeechLogic) so the toggle and the controller
    /// cannot drift apart. The controller re-applies on this change via
    /// `.onChange` below.
    @AppStorage(ScreenAwakePolicy.preferenceKey) private var keepScreenOn = ScreenAwakePolicy.defaultEnabled

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: $theme.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                    Text("E-Ink").tag("eink")
                }
                .pickerStyle(.segmented)

                // Menu style: one row showing the current color, expanding to
                // all 12 choices on tap — the inline list was too long
                // (user feedback).
                Picker("Accent", selection: $theme.accentChoice) {
                    ForEach(AccentColorChoice.allCases) { c in
                        HStack {
                            Circle().fill(c.color).frame(width: 16, height: 16)
                            Text(c.displayName)
                        }.tag(c)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Notes") {
                Toggle("Render Markdown", isOn: $renderMarkdown)
                Toggle("Haptic feedback", isOn: $hapticsEnabled)
            }

            Section("Reading") {
                Toggle("Keep Screen On", isOn: $keepScreenOn)
                    .onChange(of: keepScreenOn) { _ in
                        // The controller reads the preference fresh, so one
                        // nudge re-applies it to whatever is on screen.
                        ScreenAwake.shared.refresh()
                    }
                readingSlider(
                    title: "Text size",
                    value: $theme.previewTextScale,
                    range: 0.75...1.5,
                    caption: "Scales the markdown preview's text (headings, lists, paragraphs)."
                )
                readingSlider(
                    title: "Line spacing",
                    value: $theme.readerLineSpacing,
                    range: 0.8...1.6,
                    caption: "Space between lines inside paragraphs and quotes."
                )
                readingSlider(
                    title: "Between blocks",
                    value: $theme.readerBlockSpacing,
                    range: 0.8...1.6,
                    caption: "Gap after paragraphs, lists and headings — the one to raise when notes feel cramped."
                )
                readingSlider(
                    title: "Tables",
                    value: $theme.readerTableSpacing,
                    range: 0.8...2.0,
                    caption: "Row height and cell padding in tables."
                )
                Button("Reset spacing") {
                    Haptics.tap()
                    theme.resetReaderSpacing()
                }
            }
        }
        .navigationTitle("Appearance")
    }

    /// One slider row: label + live percentage + the short caption. Sliders
    /// scale the base values in ReaderSpacing; 100% is the default.
    @ViewBuilder
    private func readingSlider(
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
            // Steps of 5% feel right on a phone and stay audible to
            // VoiceOver.
            Slider(value: value, in: range, step: 0.05) { _ in Haptics.tap() }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
