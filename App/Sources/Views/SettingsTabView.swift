import SwiftUI

/// Settings root — speechnotes-android SettingsHomeScreen parity: a flat
/// navigation list, one icon + title + subtitle row per area, no section
/// headers repeating the row's own name ("Storage" header → "Storage" row
/// read as a stutter). Diagnostics keeps its small group (Benchmark mode +
/// Logs); About stands alone at the end.
struct SettingsTabView: View {
    /// Mini-player jump: push the Storage screen (the playing export's
    /// player surface) programmatically.
    @State private var pushStorageForExport = false

    var body: some View {
        NavigationStack {
            Form {
                link("waveform", "Speech engine",
                     "Engine, voices, model downloads") {
                    SpeechSettingsView()
                }
                link("paintbrush", "Appearance",
                     "Theme, accent, reader, keep screen on") {
                    AppearanceSettingsView()
                }
                link("wifi", "BookDrop",
                     "Books and audio to nearby devices") {
                    BookDropView()
                }
                link("arrow.down.doc", "Backup",
                     "Joplin .jex export and import") {
                    BackupExportView()
                }
                link("lock", "Encryption",
                     "Passphrase-sealed notes, Joplin-compatible") {
                    EncryptionSettingsView()
                }
                link("internaldrive", "Storage",
                     "Usage, exports, cached images") {
                    StorageSettingsView()
                }

                Section("Diagnostics") {
                    link("gauge", "Benchmark mode",
                         "Sustained synthesis harness") {
                        BenchmarkView()
                    }
                    link("doc.text.magnifyingglass", "Logs",
                         "What the app has been doing") {
                        LogsView()
                    }
                }

                // Headerless trailing group so "About" never sits under an
                // "About" header saying the same thing twice.
                Section {
                    link("info.circle", "About",
                         "Version and credits") {
                        AboutView()
                    }
                }
            }
            .navigationTitle("Settings")
            // Text fields downstream could hold the keyboard hostage — no
            // native tap-outside in SwiftUI. Both halves: drag the list, or
            // tap anywhere that is not the field.
            .scrollDismissesKeyboard(.immediately)
            .dismissesKeyboardOnTapOutside()
            .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToExports)) { _ in
                // Mini-player tap on a playing export → its player surface.
                pushStorageForExport = true
            }
            .navigationDestination(isPresented: $pushStorageForExport) {
                StorageSettingsView()
            }
        }
    }

    /// One Android-style row: accent-tinted icon, title with its one-line
    /// subtitle underneath, chevron. Closure-based destination (the
    /// value-based NavigationLink from the first round-6 attempt never
    /// registered its destination inside the lazy Form row on device — taps
    /// highlighted and did nothing).
    private func link(_ icon: String, _ title: String, _ subtitle: String,
                      @ViewBuilder destination: () -> some View) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
