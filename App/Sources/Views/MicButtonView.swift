import SwiftUI

/// Phase 0 placeholder — shows a mic button that does nothing yet.
/// Phase 1 wires it to DictationCoordinator.startRecording()
struct MicButtonView: View {
    @EnvironmentObject private var dictation: DictationCoordinator

    var body: some View {
        Button {
            // placeholder: state will be idle in Phase 0
            dictation.state == .idle ? dictation.startRecording() : dictation.stopRecording()
        } label: {
            Image(systemName: dictation.state == .recording ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(dictation.state == .recording ? .red : .primary)
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(Color.secondary.opacity(0.12))
                )
        }
        .accessibilityLabel("Dictate")
    }
}
