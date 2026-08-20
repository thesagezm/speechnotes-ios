import SwiftUI

struct EditorMicButton: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @State private var showingSheet = false

    /// Called on the main actor with the finalized transcript when the
    /// dictation sheet dismisses. The editor appends it at the cursor.
    var onTranscribed: ((String) -> Void)?

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            Image(systemName: dictation.state == .recording ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(dictation.state == .recording ? .red : .primary)
        }
        .sheet(isPresented: $showingSheet) {
            DictationSheetView()
                .onDisappear {
                    let text = dictation.consumeFinal()
                    if !text.isEmpty { onTranscribed?(text) }
                }
        }
    }
}
