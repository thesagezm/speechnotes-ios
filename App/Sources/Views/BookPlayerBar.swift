import SwiftUI

/// Compact playback control for the book reader: play/pause, stop, progress
/// and speed. Deliberately its own view (not the note PlayerControlsBar):
/// that one is coupled to note identity, the voice picker sheet and the
/// editor — a book chapter plays through the same SpeechPlayer with none of
/// those. Speed reuses SpeechPlayer.rateMultiplier so the preference is
/// shared with note playback.
struct BookPlayerBar: View {
    let book: Book
    let chapterIndex: Int
    @ObservedObject var player: SpeechPlayer
    /// Fires BookPlaybackController.togglePlay for the current chapter.
    let onToggle: () -> Void
    /// Chapter label for the sounding session — during auto-advance the
    /// user otherwise can't tell WHICH chapter is playing.
    @ObservedObject private var controller = BookPlaybackController.shared
    /// v1.5 per-chapter WAV export (present only when the reader offers it).
    /// Renders THIS chapter only — the whole book stays off the table.
    var onExport: (() -> Void)? = nil

    @AppStorage("readAlongEnabled") private var readAlongEnabled = true

    private var chapterIsActive: Bool {
        player.nowPlayingBookId == book.id.uuidString
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                Haptics.tap()
                onToggle()
            } label: {
                Group {
                    if chapterIsActive && player.state == .generating {
                        ProgressView()
                    } else if player.state == .speaking && chapterIsActive {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 34))
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                    }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            if chapterIsActive {
                Button {
                    Haptics.press()
                    player.stop()
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)

                if let onExport {
                    Button {
                        Haptics.tap()
                        onExport()
                    } label: {
                        if player.isExporting {
                            ProgressView()
                                .frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 19))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(player.isExporting)
                }

                VStack(alignment: .leading, spacing: 1) {
                    if chapterIsActive, let label = controller.nowPlayingChapterLabel {
                        Text(label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(progressLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            } else {
                Text("Listen to this chapter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }

            // Read-along toggle — same storage key as the note editor so the
            // preference carries across the app.
            Button {
                Haptics.tap()
                readAlongEnabled.toggle()
            } label: {
                Image(systemName: "book.pages")
                    .foregroundStyle(readAlongEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                Slider(
                    value: Binding(
                        get: { player.rateMultiplier },
                        set: { player.rateMultiplier = $0 }
                    ),
                    in: 0.5...2.0,
                    step: 0.05
                )
                Text("\(String(format: "%.2f", player.rateMultiplier))×")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var progressLabel: String {
        if let progress = player.progress {
            return "\(Int((progress * 100).rounded()))% of chapter"
        }
        return player.state == .generating ? "Preparing…" : "Paused"
    }
}
