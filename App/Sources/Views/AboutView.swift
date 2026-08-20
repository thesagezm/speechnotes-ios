import SwiftUI

struct AboutView: View {
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
                        Text("v1.3.0 · offline TTS notes")
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
