import SwiftUI
import AVFoundation
import MediaPlayer
import SpeechLogic

/// The audiobook reader: an already-recorded audiobook file, played as audio
/// rather than synthesized.
///
/// What it deliberately does NOT do:
///  - run any TTS engine — the speech exists in the file;
///  - show text — there is none to show (an M4B/MP3 has chapters, not pages);
///  - own the player — `AudioBookPlayer` is an app-level EnvironmentObject
///    (v1.7 round 3): a view-owned player died on every tab switch, and the
///    chapter ticker/persistence died with it. This view only binds, sends
///    commands and renders whatever the player publishes.
struct BookAudioReaderView: View {
    let book: Book
    let store: BooksStore
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var audioBook: AudioBookPlayer

    @State private var chapterIndex: Int
    /// The scrub thumb's local value while dragging; NOT the playhead — the
    /// live playhead is read straight from the player's published chapter
    /// progress (an onChange sync proved too indirect on device: the time
    /// readouts under the slider froze while the audio moved).
    @State private var scrubValue: Double = 0
    @State private var scrubbing = false
    @State private var showingChapters = false
    /// VLC-style: tap the time readout to flip between chapter position and
    /// whole-book remaining.
    @State private var showingBookRemaining = false

    private var chapters: [AudioChapter] { book.audioChapters ?? [] }
    /// True when the app-level player is currently loaded with THIS book.
    private var isActive: Bool { audioBook.activeBookID == book.id }
    private var isPlaying: Bool { isActive && audioBook.isPlaying }

    init(book: Book, store: BooksStore) {
        self.book = book
        self.store = store
        _chapterIndex = State(initialValue: book.position?.chapterIndex ?? 0)
        _scrubValue = State(initialValue: book.position?.chapterFraction ?? 0)
    }

    /// The playhead the UI renders: the player's published value while this
    /// book is loaded and the user isn't dragging, the local thumb while
    /// scrubbing, the persisted fraction when idle. Read DIRECTLY in body so
    /// every player tick re-renders the slider, the rail strip and the time
    /// readouts — no sync task, no onChange hop.
    private var displayProgress: Double {
        if scrubbing { return scrubValue }
        if isActive { return audioBook.chapterProgress }
        return book.position?.chapterFraction ?? 0
    }

    @Environment(\.isLandscape) private var isLandscape
    /// Tap-to-hide chrome — shared app-wide (ImmersiveBars.swift).
    @AppStorage("immersiveBarsEnabled") private var immersiveBarsHidden = false

    var body: some View {
        // Landscape: the cover/title/chapter block keeps the leading width
        // and the transport cluster (position strip + play) moves to a
        // trailing rail — the short axis is then all reading space. Chapter
        // stepping lives in the cover column's bottom bar (the "steppers
        // stay bottom" rule), so the rail carries no duplicate chevrons.
        //
        // Guided rotation (same fix as the EPUB/PDF readers): one
        // GeometryReader, one content identity, explicit transition. The cover
        // and chapter list stay mounted across the change.
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack(alignment: .bottom) {
                if landscape {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            audioCoverBlock
                            Spacer(minLength: 0)
                            chapterBar
                        }
                        audioRail
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        audioCoverBlock

                        Spacer(minLength: 0)

                        audioTransport
                            .padding(.bottom, 12)

                        chapterBar
                            .padding(.bottom, 8)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: landscape)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        // Tap the cover to hide/show the title + toolbar (immersive reading).
        .toolbar(immersiveBarsHidden ? .hidden : .visible, for: .navigationBar)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            immersiveBarsHidden.toggle()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingChapters = true
                } label: {
                    Label("Chapters", systemImage: "list.number")
                }
            }
        }
        .sheet(isPresented: $showingChapters) {
            chapterSheet
        }
        .onAppear {
            store.markOpened(book)
            audioBook.store = store
            audioBook.bind(to: book)
            // The player may already be playing THIS book (user left and came
            // back) — follow its live chapter, and start the thumb at the
            // live playhead so a first drag doesn't snap.
            if audioBook.activeBookID == book.id {
                chapterIndex = audioBook.chapterIndex
                scrubValue = audioBook.chapterProgress
            }
            audioBook.readerVisible = true
        }
        .onChange(of: audioBook.chapterIndex) { newValue in
            guard isActive else { return }
            chapterIndex = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioBookStopped)) { notification in
            // The shelf deleted this book while its reader was open.
            guard notification.object as? UUID == book.id, isActive else { return }
            audioBook.stop()
        }
        .onDisappear {
            // Playback is app-level now: leaving (tab switch OR pop) must not
            // stop the book — the global mini-player takes over from here.
            audioBook.readerVisible = false
        }
    }

    // MARK: - Layout pieces (portrait + landscape)

    /// Cover + title + author — the reading surface in both orientations.
    private var audioCoverBlock: some View {
        VStack(spacing: 10) {
            BookCoverView(book: book, height: isLandscape ? 150 : 220)
            Text(book.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let author = book.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Portrait transport cluster: scrub slider, ±15 s skip around the play
    /// button (the VLC/Apple-Books shape — chapter stepping lives in the
    /// chapter bar below, which is visible with the chrome hidden too).
    private var audioTransport: some View {
        VStack(spacing: 14) {
            Slider(value: Binding(
                get: { displayProgress },
                set: { scrubValue = $0 }
            ), onEditingChanged: { editing in
                scrubbing = editing
                if !editing { seekToProgress(scrubValue) }
            })
            .padding(.horizontal, 24)

            HStack(spacing: 40) {
                Button {
                    Haptics.tap()
                    audioBook.seekBy(-15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 30))
                }

                Button {
                    Haptics.tap()
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }

                Button {
                    Haptics.tap()
                    audioBook.seekBy(15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 30))
                }
            }
            .foregroundStyle(Color.accentColor)

            timeReadout
        }
    }

    /// Landscape transport rail: vertical position strip, a 46pt play/pause
    /// and the time readout. The strip fills TOP-DOWN (same direction as the
    /// playback rails) and the scrub slider stays portrait-only — a
    /// horizontal slider is the wrong control for a 110pt-tall slot. The
    /// content is centered inside the documented 78pt column (round 3: the
    /// old asymmetric paddings hugged everything to the trailing edge).
    private var audioRail: some View {
        HStack(spacing: 0) {
            // Vertical position strip (the rail twin of the scrub slider).
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 3)
                    Capsule()
                        .fill(theme.accentFadeVerticalGradient)
                        .frame(width: 3, height: max(4, (proxy.size.height - 16) * displayProgress))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 3)
            .padding(.vertical, 8)

            VStack(spacing: 14) {
                Button {
                    Haptics.tap()
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(Color.accentColor)
                }

                Spacer(minLength: 0)

                timeReadout
                    .font(.caption2.monospacedDigit())
            }
            .padding(.horizontal, 6)
        }
        .frame(width: 78)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    /// Elapsed/chapter position — tap flips to whole-book remaining.
    private var timeReadout: some View {
        Text(timeLabel)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .onTapGesture {
                Haptics.tap()
                showingBookRemaining.toggle()
            }
            .accessibilityLabel(showingBookRemaining ? "Time remaining" : "Chapter position")
    }

    // MARK: - Chapter bar

    /// Chapter bar — visible in BOTH orientations at the bottom of the cover
    /// column, and reachable while the nav bar (and its Chapters button) is
    /// tap-hidden. Leading: the chapter list (TOC). Centre: position + title.
    /// Trailing: chapter stepping, the semantic next/prev the ±15 s skips
    /// deliberately are not.
    private var chapterBar: some View {
        HStack(spacing: 16) {
            Button {
                Haptics.tap()
                showingChapters = true
            } label: {
                Image(systemName: "list.number")
            }
            .accessibilityLabel("Chapter list")

            Spacer()
            Text(chapterLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()

            Button {
                Haptics.tap()
                stepChapter(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(chapterIndex <= 0)
            .accessibilityLabel("Previous chapter")

            Button {
                Haptics.tap()
                stepChapter(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(totalChapters > 0 && chapterIndex >= totalChapters - 1)
            .accessibilityLabel("Next chapter")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var totalChapters: Int { max(chapters.count, 1) }

    private var chapterLabel: String {
        if chapters.indices.contains(chapterIndex) {
            return "Chapter \(chapterIndex + 1) of \(totalChapters) · \(chapters[chapterIndex].title)"
        }
        return "Chapter \(chapterIndex + 1) of \(totalChapters)"
    }

    private var timeLabel: String {
        guard chapters.indices.contains(chapterIndex) else { return "" }
        let chapter = chapters[chapterIndex]
        let elapsed = chapter.startSeconds + displayProgress * (chapter.endSeconds - chapter.startSeconds)
        if showingBookRemaining {
            let total = book.audioDuration ?? (isActive ? audioBookFileDuration : 0)
            guard total > 0 else { return Self.clock(elapsed) }
            return "\(Self.remainingClock(max(0, total - elapsed))) left"
        }
        return "\(Self.clock(elapsed)) / \(Self.clock(chapter.endSeconds))"
    }

    /// Real file length while this book is loaded (legacy manifests can lack
    /// `audioDuration`); zero when idle, which hides the remaining readout.
    private var audioBookFileDuration: Double {
        audioBook.fileDuration ?? 0
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// Remaining-time readout: H:MM:SS once hours are involved, M:SS below.
    private static func remainingClock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Chapters sheet

    private var chapterSheet: some View {
        NavigationStack {
            List(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                Button {
                    Haptics.tap()
                    showingChapters = false
                    playChapter(index)
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(Self.clock(chapter.startSeconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if index == chapterIndex, isPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingChapters = false }
                }
            }
            .overlay {
                // VLC's honesty rule: no chapters is a fact about the file,
                // not a disabled button — say so where the list would be.
                if chapters.isEmpty {
                    ContentUnavailableView(
                        "No chapter markers",
                        systemImage: "list.number",
                        description: Text("This audiobook file doesn't carry chapter metadata. Use the ±15 s skip buttons to move around.")
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Playback

    private func togglePlayback() {
        if isPlaying {
            audioBook.pause()
        } else {
            playChapter(chapterIndex)
        }
    }

    private func playChapter(_ index: Int) {
        guard chapters.indices.contains(index) else { return }
        chapterIndex = index
        // Resume where the playhead is: a fresh chapter start only when the
        // user picked a DIFFERENT chapter or the playhead sits at zero.
        let fraction = (index == audioBook.chapterIndex && displayProgress > 0.005 && !audioBook.isPlaying)
            ? displayProgress
            : nil
        audioBook.play(book: book, chapterIndex: index, withinChapterFraction: fraction)
        progress = audioBook.chapterProgress
    }

    private func stepChapter(_ delta: Int) {
        let target = max(0, min(chapters.count - 1, chapterIndex + delta))
        guard target != chapterIndex else { return }
        playChapter(target)
    }

    private func seekToProgress(_ value: Double) {
        guard chapters.indices.contains(chapterIndex) else { return }
        audioBook.seek(toFraction: value)
    }
}
