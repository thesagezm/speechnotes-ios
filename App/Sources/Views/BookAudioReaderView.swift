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
///  - reuse the note/read-along path — `SpeechPlayer` owns the engines and the
///    read-along, and an audiobook touches none of that.
///
/// What it does: play/pause/skip within and across the file's own chapters,
/// keep the position so reopening resumes where the listener stopped, and
/// drive the lock screen through the same `NowPlayingCenter` everything else
/// uses (single writer, same as notes and books).
struct BookAudioReaderView: View {
    let book: Book
    let store: BooksStore
    @EnvironmentObject private var theme: AppTheme

    /// Owns playback for this view. One instance per reader; a second reader
    /// would stop the first, which is the correct single-slot behaviour.
    @StateObject private var audioPlayer = AudioBookPlayer()

    @State private var chapterIndex: Int
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var showingChapters = false
    /// 2 Hz refresh of the slider from the player's playhead. The reader owns
    /// it (not AudioBookPlayer) because the reader also advances chapters and
    /// persists the position — one place decides what "now" means.
    @State private var progressTask: Task<Void, Never>?

    private var chapters: [AudioChapter] { book.audioChapters ?? [] }

    init(book: Book, store: BooksStore) {
        self.book = book
        self.store = store
        _chapterIndex = State(initialValue: book.position?.chapterIndex ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                BookCoverView(book: book, height: 220)
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

            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Slider(value: $progress, in: 0...1) { editing in
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

                Text(timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            chapterBar
                .padding(.bottom, 8)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
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
            audioPlayer.bind(to: book, startChapter: chapterIndex)
            wireRemoteCommands()
            startProgressUpdates()
        }
        .onDisappear {
            progressTask?.cancel()
            progressTask = nil
            audioPlayer.stop()
            NowPlayingCenter.shared.clear()
            NowPlayingCenter.shared.setChapterSkipEnabled(false)
        }
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
        return "\(Self.clock(elapsed)) / \(Self.clock(chapter.endSeconds))"
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
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

    /// Mirrors the player's playhead into the slider and advances at the
    /// chapter end. 2 Hz is enough for a slider and cheap next to the 0.3 s
    /// heartbeat the note read-along already runs.
    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                let next = audioPlayer.chapterProgress
                if abs(next - progress) > 0.005 {
                    progress = next
                    publishNowPlaying()
                }
                if audioPlayer.chapterIsFinished, chapterIndex < chapters.count - 1 {
                    stepChapter(1)
                }
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            audioPlayer.pause()
            isPlaying = false
        } else {
            playChapter(chapterIndex)
        }
        publishNowPlaying()
    }

    private func playChapter(_ index: Int) {
        guard chapters.indices.contains(index) else { return }
        chapterIndex = index
        audioPlayer.play(book: book, chapterIndex: index)
        isPlaying = true
        publishNowPlaying()
        persistPosition()
    }

    /// True once this reader has installed the remote-command handlers.
    @State private var remoteWired = false

    /// Installs the lock-screen play/pause/skip handlers. `SpeechPlayer` wires
    /// its own on first note/book playback; an audiobook never goes through
    /// the player, so without this the Control Center buttons would be
    /// registered with no handler at all.
    private func wireRemoteCommands() {
        guard !remoteWired else { return }
        remoteWired = true
        NowPlayingCenter.shared.onCommand = { [weak self] command in
            Task { @MainActor in
                guard let self else { return }
                switch command {
                case .play, .toggle:
                    if self.isPlaying {
                        self.audioPlayer.pause()
                        self.isPlaying = false
                    } else {
                        self.playChapter(self.chapterIndex)
                    }
                case .pause:
                    self.audioPlayer.pause()
                    self.isPlaying = false
                case .stop:
                    self.audioPlayer.stop()
                    self.isPlaying = false
                    NowPlayingCenter.shared.clear()
                case .previousChapter:
                    self.stepChapter(-1)
                case .nextChapter:
                    self.stepChapter(1)
                }
                self.publishNowPlaying()
            }
        }
    }

    /// Lock screen / Control Center, through the same NowPlayingCenter every
    /// other playback path uses (single writer). An audiobook has real audio,
    /// so the surface shows the book, the sounding chapter, and the artwork
    /// when the file carries one.
    private func publishNowPlaying() {
        let chapterTitle = chapters.indices.contains(chapterIndex)
            ? chapters[chapterIndex].title
            : nil
        let total = chapters.count > 1 ? "Chapter \(chapterIndex + 1) of \(chapters.count)" : nil
        NowPlayingCenter.shared.publish(
            title: book.title,
            subtitle: [total, chapterTitle].compactMap { $0 }.joined(separator: " — "),
            artwork: Self.loadArtwork(book: book),
            isPlaying: isPlaying,
            progress: nil,
            rate: 1.0
        )
        // Chapter skip is real for an audiobook: the chapters are in the file.
        NowPlayingCenter.shared.setChapterSkipEnabled(chapters.count > 1)
    }

    /// Reads the cover once off-main. Nil when the book has no embedded art
    /// or no embedded art could be decoded — the surface then shows text only.
    private static func loadArtwork(book: Book) -> UIImage? {
        guard book.hasCover else { return nil }
        let url = BooksStore.coverFileURL(book)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func stepChapter(_ delta: Int) {
        let target = max(0, min(chapters.count - 1, chapterIndex + delta))
        guard target != chapterIndex else { return }
        playChapter(target)
    }

    private func seekToProgress(_ value: Double) {
        guard chapters.indices.contains(chapterIndex) else { return }
        let chapter = chapters[chapterIndex]
        audioPlayer.seek(to: chapter.startSeconds + value * (chapter.endSeconds - chapter.startSeconds))
        persistPosition()
    }

    private func persistPosition() {
        store.updatePosition(book, chapterIndex: chapterIndex, chapterFraction: progress, cfi: nil)
    }
}

/// Plays an audiobook file's chapter range. One `AVAudioPlayer` per chapter
/// seek (a player is bound to the file, and a chapter is a time range inside
/// it), which is why the URL is loaded once and the position is set on seek.
@MainActor
final class AudioBookPlayer: ObservableObject {
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// The file currently loaded — reload only when it actually changes.
    private var loadedURL: URL?
    private var book: Book?
    private var chapters: [AudioChapter] = []
    private var chapterIndex = 0

    func bind(to book: Book, startChapter: Int) {
        guard self.book?.id != book.id else { return }
        self.book = book
        self.chapters = book.audioChapters ?? []
        self.chapterIndex = min(max(0, startChapter), max(0, chapters.count - 1))
        loadedURL = nil
    }

    func play(book: Book, chapterIndex: Int) {
        self.book = book
        self.chapters = book.audioChapters ?? []
        self.chapterIndex = chapterIndex
        let url = BooksStore.originalFileURL(book)
        do {
            if loadedURL != url || player == nil {
                let p = try AVAudioPlayer(contentsOf: url)
                p.prepareToPlay()
                player = p
                loadedURL = url
            }
            guard let player else { return }
            let chapter = chapters[chapterIndex]
            player.currentTime = chapter.startSeconds
            player.play()
            startTicker()
        } catch {
            Log.shared.error("AudioBookPlayer: cannot play \(url.lastPathComponent): \(error)")
        }
    }

    func pause() {
        player?.pause()
        stopTicker()
    }

    func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        stopTicker()
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
    }

    /// Seconds into the current chapter, 0…1 — the reader's slider value.
    var chapterProgress: Double {
        guard let player,
              chapters.indices.contains(chapterIndex) else { return 0 }
        let chapter = chapters[chapterIndex]
        let span = chapter.endSeconds - chapter.startSeconds
        guard span > 0 else { return 0 }
        return min(1, max(0, (player.currentTime - chapter.startSeconds) / span))
    }

    /// True when the playhead has passed the chapter's end — the reader
    /// advances. Checked by the reader's own ticker, which is why this is a
    /// var and not a callback: the reader owns chapter navigation.
    var chapterIsFinished: Bool {
        guard let player,
              chapters.indices.contains(chapterIndex) else { return false }
        return player.currentTime >= chapters[chapterIndex].endSeconds
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if self.chapterIsFinished { self.pause() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
