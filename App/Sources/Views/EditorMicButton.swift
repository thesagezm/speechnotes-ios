import SwiftUI

struct EditorMicButton: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @State private var showingSheet = false

    /// Called on the main actor with the finalized transcript when the
    /// dictation sheet dismisses. The editor appends it at the cursor.
    var onTranscribed: ((String) -> Void)?
    var keyboardRefreshTrigger: (() -> Void)?

    init(
        onTranscribed: ((String) -> Void)? = nil,
        keyboardRefreshTrigger: (() -> Void)? = nil
    ) {
        self.onTranscribed = onTranscribed
        self.keyboardRefreshTrigger = keyboardRefreshTrigger
    }

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
                    // After a sheet, SwiftUI sometimes forgets the keyboard
                    // safe-area inset — nudge it by bumping a trigger the
                    // editor observes (it bounces focus for one tick).
                    keyboardRefreshTrigger?()
                }
        }
    }
}

