import SwiftUI

struct DictationSheetView: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sttLanguage") private var languageHint: String = "auto"

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(dictation.state == .recording ? "Listening…" : "Tap Mic to start")
                        .font(.headline)

                    Text(dictation.partialText.isEmpty ? "…" : dictation.partialText)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .padding()

                    Text(String(format: "%.1fs", dictation.elapsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()

                Picker("Language", selection: $languageHint) {
                    Text("Auto").tag("auto")
                    Text("English").tag("en-US")
                    Text("Spanish").tag("es-ES")
                    Text("French").tag("fr-FR")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Spacer()

                Button {
                    if dictation.state == .recording {
                        dictation.stopRecording()
                        dismiss()
                    } else {
                        dictation.startRecording(language: languageHint == "auto" ? nil : languageHint)
                    }
                } label: {
                    Image(systemName: dictation.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(dictation.state == .recording ? .red : .primary)
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("Dictate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
