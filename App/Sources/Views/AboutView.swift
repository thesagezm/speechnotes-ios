import SwiftUI

struct AboutView: View {
    /// Live from the bundle — a hardcoded string always goes stale (sat at
    /// "v1.3.0" through two releases).
    static var versionString: String {
        "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text("Speechnotes")
                            .font(.headline)
                        Text("\(Self.versionString) · offline TTS notes")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Developer") {
                Text("TheSageZM")
            }
            Section("License") {
                Text("MIT")
            }
        }
        .navigationTitle("About")
    }
}
