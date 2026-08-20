import SwiftUI

struct DictationSheetView: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var languageHint: String = Locale.current.language.languageCode?.identifier ?? "en-US"

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
                    PickerItem("English", id: "en-US")
                    PickerItem("Spanish", id: "es-ES")
                    PickerItem("French", id: "fr-FR")
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

private struct PickerItem: Identifiable {
    let label: String
    let id: String
    var body: Text { Text(label) }
    var idValue: String { id }
}
extension PickerItem: Hashable {
    static func == (lhs: PickerItem, rhs: PickerItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
extension PickerItem {
    init(_ label: String, id: String) { self.label = label; self.id = id }
}
