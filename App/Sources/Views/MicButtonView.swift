import SwiftUI

/// Notes-list toolbar mic button: opens the same dictation sheet the editor
/// uses; the transcript lands as a new note when the sheet dismisses.
struct MicButtonView: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var notes: NotesStore
    @State private var showingSheet = false

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            Image(systemName: dictation.state == .recording ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(dictation.state == .recording ? .red : .primary)
        }
        .accessibilityLabel("Dictate")
        .sheet(isPresented: $showingSheet) {
            DictationSheetView()
                .onDisappear {
                    if dictation.state == .recording || dictation.state == .transcribing {
                        dictation.stopRecording()
                    }
                    let text = dictation.consumeFinalOrPartial()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let note = notes.createNote()
                    var updated = note
                    updated.text = text
                    notes.update(updated)
                    Haptics.success()
                }
        }
    }
}
