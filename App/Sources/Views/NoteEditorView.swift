import SwiftUI

struct NoteEditorView: View {
    let noteId: UUID

    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var player: SpeechPlayer
    @State private var draft: String = ""
    @State private var didLoad = false

    private var currentNote: Note? {
        notes.notes.first { $0.id == noteId }
    }

    private var playIcon: String {
        switch player.state {
        case .speaking: return "pause.fill"
        case .paused, .idle: return "play.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.body)
                .padding(.horizontal, 8)
                .onChange(of: draft) { _ in saveDraft() }

            controlsBar
        }
        .navigationTitle(currentNote?.title ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoad else { return }
            draft = currentNote?.text ?? ""
            didLoad = true
        }
        .onDisappear {
            saveDraft()
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 16) {
            Button {
                player.togglePlay(draft)
            } label: {
                Image(systemName: playIcon)
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && player.state == .idle)

            if player.state != .idle {
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .tint(.red)
            }

            Slider(value: $player.rateMultiplier, in: 0.5...2.0, step: 0.05)

            Text(String(format: "%.2f×", player.rateMultiplier))
                .font(.callout.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func saveDraft() {
        guard var note = currentNote, note.text != draft else { return }
        note.text = draft
        notes.update(note)
    }
}
