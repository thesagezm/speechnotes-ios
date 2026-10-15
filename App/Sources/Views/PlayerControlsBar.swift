import SwiftUI
import SpeechLogic

/// Bottom-of-editor controls: voice chip, play/pause/stop, progress bar,
/// speed slider. Extracted from NoteEditorView so that player state changes
/// (progress ticks, slider drags) only re-evaluate this view — not the title
/// field, the editor, or the sheet/alert modifiers.
struct PlayerControlsBar: View {
    let speechText: String
    let note: Note?
    /// Called at the top of every play/pause tap, BEFORE speechText is read —
    /// the editor flushes its (debounced) speech-text cache here so the
    /// engine hears edits made in the last 300ms. Additive optional so other
    /// call sites (if any ever appear) keep working.
    var onBeforeToggle: (() -> Void)? = nil

    @EnvironmentObject private var player: SpeechPlayer
    @EnvironmentObject private var theme: AppTheme
    /// Mirrors NoteEditorView's read-along switch — shared via AppStorage.
    @AppStorage("readAlongEnabled") private var readAlongEnabled = true
    /// Collapsed to the slim pill — frees editor space while playing.
    @AppStorage("editorBarMinimized") private var editorBarMinimized = false

    private var playIcon: String {
        switch player.state {
        case .generating: return "hourglass"
        case .speaking: return "pause.fill"
        case .paused, .idle: return "play.fill"
        }
    }

    private var playButtonDisabled: Bool {
        player.isExporting
            || player.state == .idle
                && speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if editorBarMinimized {
            minimizedPill
        } else {
            expandedBar
        }
    }

    /// Collapsed editor playback bar: one slim translucent pill — frees the
    /// lower half of the editor while still showing play state and progress.
    private var minimizedPill: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                onBeforeToggle?()
                player.togglePlay(SpeechText.forText(speechText), note: note)
            } label: {
                Image(systemName: playIcon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
            }
            .disabled(playButtonDisabled)

            if let progress = player.progress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if player.state == .generating {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 0)

            Button {
                Haptics.tap()
                editorBarMinimized = false
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .accessibilityLabel("Expand playback controls")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var expandedBar: some View {
        VStack(spacing: 8) {
            voiceChip

            if let progress = player.progress, player.state == .speaking {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25))
                        Capsule()
                            .fill(theme.accentFadeGradient)
                            .frame(width: max(4, proxy.size.width * progress))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal)
            }

            HStack(spacing: 14) {
                Button {
                    Haptics.tap()
                    onBeforeToggle?()
                    player.togglePlay(SpeechText.forText(speechText), note: note)
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.accentGradient)
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                        if player.state == .generating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: playIcon)
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                }
                .disabled(playButtonDisabled)
                .accessibilityLabel(player.state == .speaking ? "Pause" : "Play")

                if player.state == .speaking || player.state == .paused || player.state == .generating {
                    // Sentence rewind/forward (2026-10-13): re-speak one
                    // sentence back or skip one ahead, for "I didn't catch
                    // that" / "skip this". Both rebuild the speak call from
                    // the CURRENT played-char position — the engine's own
                    // played-chars tracker is the source of truth — and the
                    // new start becomes the bookmark, so a suspension right
                    // after still resumes where the listener actually is.
                    // The sentence boundaries come from the same
                    // SentenceChunker pieces the read-along highlight uses,
                    // so button and highlight can never disagree.
                    Button {
                        Haptics.tap()
                        stepSpeechSentence(-1)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .accessibilityLabel("Rewind one sentence")

                    // Live read-along toggle: sentence-highlighted reader
                    // replaces the editor while this note is speaking.
                    Button {
                        Haptics.press()
                        readAlongEnabled.toggle()
                    } label: {
                        Image(systemName: readAlongEnabled ? "book.pages.fill" : "book.pages")
                            .font(.body.weight(.medium))
                            .foregroundStyle(readAlongEnabled ? Color.accentColor : .secondary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .accessibilityLabel(readAlongEnabled ? "Read-along on" : "Read-along off")

                    Button {
                        Haptics.tap()
                        stepSpeechSentence(1)
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .accessibilityLabel("Forward one sentence")

                    Button {
                        Haptics.press()
                        player.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.red)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.red.opacity(0.12)))
                    }
                    .accessibilityLabel("Stop playback")
                }

                Slider(value: $player.rateMultiplier, in: 0.5...2.0, step: 0.05)
                    .frame(height: 44)
                    .accessibilityLabel("Speech rate")
                    .accessibilityValue(String(format: "%.2f times", player.rateMultiplier))

                Text(String(format: "%.2f×", player.rateMultiplier))
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)

                Button {
                    Haptics.tap()
                    editorBarMinimized = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .accessibilityLabel("Minimize playback controls")
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// Current engine + voice, one tap from the picker.
    private var voiceChip: some View {
        Button {
            NotificationCenter.default.post(name: .requestVoicePicker, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2.fill")
                    .font(.caption)
                Text(player.currentVoiceDescription)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    /// Sentence rewind/forward for the note being spoken. `delta` is -1
    /// (re-speak the previous sentence) or +1 (skip to the next). The math
    /// runs over the FULL speech text with the engine's played-char position
    /// as the anchor:
    ///   forward  → first sentence boundary strictly after the currently
    ///              sounding sentence's end;
    ///   backward → the boundary at-or-before (playedChars - currentSentence
    ///              length), i.e. the START of the previous sentence — mashing
    ///              rewind keeps stepping back one sentence per press because
    ///              the anchor moves with each re-speak.
    /// The restart goes through SpeechPlayer.playFrom, which snaps, primes
    /// the bookmark at the new offset and keeps the read-along pieces in
    /// sync — one code path for both directions.
    ///
    /// Works while speaking AND while paused (a paused step re-arms from the
    /// new sentence and stays paused is NOT attempted — speech restarts,
    /// which matches every podcast-style rewind UX).
    private func stepSpeechSentence(_ delta: Int) {
        guard delta == -1 || delta == 1 else { return }
        guard let range = player.readAlongRange else { return }
        guard let full = player.activeSpeechText, !full.isEmpty else { return }
        let pieces = SentenceChunker.sentencePieces(in: full)
        guard !pieces.isEmpty else { return }
        let newIndex: Int
        if delta == 1 {
            // First piece that STARTS after the current piece's start.
            guard let idx = pieces.firstIndex(where: { $0.offset > range.lowerBound }) else {
                return  // already on the last sentence
            }
            newIndex = idx
        } else {
            // The piece that starts strictly before the current one; a mash
            // lands on successive earlier pieces because the anchor (readAlong
            // range) follows the re-spoken audio.
            guard let idx = pieces.last(where: { $0.offset < range.lowerBound }) else {
                player.restartFromBeginning(full, note: note)
                return
            }
            newIndex = idx
        }
        player.playFrom(full, at: pieces[newIndex].offset, note: note)
    }
}

extension Notification.Name {
    /// Posted by PlayerControlsBar when the user taps the voice chip. The
    /// editor listens and presents the picker — keeps player-state-driven
    /// controls from holding a reference to the whole editor.
    static let requestVoicePicker = Notification.Name("PlayerControlsBar.requestVoicePicker")
}
