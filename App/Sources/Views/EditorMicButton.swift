import SwiftUI

struct EditorMicButton: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @State private var showingSheet = false

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
                    // Phase 1 hook: read final result from dictation and
                    // hand it back to the editor. For now the sheet is modal
                    // and the editor can poll `dictation.partialText` after
                    // dismissal. Phase 2 will inject a completion closure.
                }
        }
    }
}
