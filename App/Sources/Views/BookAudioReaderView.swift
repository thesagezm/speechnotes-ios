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
    @State private var progress: Double = 0
    /// While the user drags the scrubber the player's 2 Hz publication must
    /// not fight the thumb.
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
        _progress = State(initialValue: book.position?.chapterFraction ?? 0)
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
                .disabled(chapters.count <= 1)
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
            // back) — mirror its live playhead instead of the saved one.
            if audioBook.activeBookID == book.id {
                chapterIndex = audioBook.chapterIndex
                progress = audioBook.chapterProgress
            }
            audioBook.readerVisible = true
        }
        .onChange(of: audioBook.chapterProgress) { newValue in
            guard isActive, !scrubbing else { return }
            progress = newValue
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

    /// Portrait transport cluster: scrub slider, prev / play / next, times.
    private var audioTransport: some View {
        VStack(spacing: 14) {
            Slider(value: $progress, in: 0...1) { editing in
                scrubbing = editing
                if !editing { seekToProgress(progress) }
            }
            .padding(.horizontal, 24)

            HStack(spacing: 28) {
                Button {
                    Haptics.tap()
                    stepChapter(-1)
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }
                .disabled(chapterIndex <= 0)

                Button {
                    Haptics.tap()
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }

                Button {
                    Haptics.tap()
                    stepChapter(1)
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
                .disabled(chapterIndex >= chapters.count - 1)
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
                        .frame(width: 3, height: max(4, (proxy.size.height - 16) * progress))
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

    private var chapterBar: some View {
        HStack(spacing: 16) {
            Button {
                Haptics.tap()
                stepChapter(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(chapterIndex <= 0)

            Spacer()
            Text(chapterLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()

            Button {
                Haptics.tap()
                stepChapter(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(totalChapters > 0 && chapterIndex >= totalChapters - 1)
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
        let elapsed = chapter.startSeconds + progress * (chapter.endSeconds - chapter.startSeconds)
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
        let fraction = (index == audioBook.chapterIndex && progress > 0.005 && !audioBook.isPlaying)
            ? progress
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
        progress = value
    }
}
