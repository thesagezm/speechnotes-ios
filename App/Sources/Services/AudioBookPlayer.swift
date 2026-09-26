import AVFoundation
import MediaPlayer
import SwiftUI
import SpeechLogic
import UIKit

/// App-level audiobook playback owner — the audiobook twin of `SpeechPlayer`.
///
/// v1.7 device round 3: this used to be a `@StateObject` inside
/// `BookAudioReaderView`, and `onDisappear` (which fires on EVERY tab switch)
/// tore the player down — switching tabs stopped the book and there was no
/// mini-player to bring it back. Playback now lives at the app scope (one
/// instance, injected as an `EnvironmentObject`), so audio keeps playing no
/// matter which tab or screen is on top. The reader view only binds, sends
/// commands and renders; chapter auto-advance, position persistence, the
/// lock-screen surface and the chapter ticker all live here, where they keep
/// running with the reader off-screen.
///
/// Single-slot by design: starting another book retires the previous one.
@MainActor
final class AudioBookPlayer: ObservableObject {
    // MARK: Published state — the reader, the mini-player and the shelf read these.

    @Published private(set) var activeBookID: UUID?
    @Published private(set) var activeBook: Book?
    @Published private(set) var isPlaying = false
    @Published private(set) var chapterIndex = 0
    /// 0…1 inside the current chapter — the reader's slider value.
    @Published private(set) var chapterProgress: Double = 0
    /// Absolute position in the FILE, in seconds, published per tick. The
    /// reader's time readout binds to this: "am I an hour or ten hours in"
    /// is a question about the file, and the old per-chapter math answered
    /// it with zeros whenever the manifest's chapter table was degenerate.
    @Published private(set) var elapsed: TimeInterval = 0
    /// The loaded file's length, published once loaded and per tick (a
    /// manifest with a missing/garbage duration still gets a real total).
    @Published private(set) var totalDuration: TimeInterval = 0
    /// True while an audio reader is on screen — the global mini-player then
    /// yields (the reader has full controls; on tab switch onDisappear clears
    /// this and the mini-player takes over, which is exactly the ask).
    @Published var readerVisible = false

    /// The compact bar is shown while a book is loaded (playing or paused),
    /// but never while its own reader is showing the full controls.
    var showMiniBar: Bool { activeBookID != nil && !readerVisible }

    var nowPlayingTitle: String? { activeBook?.title }

    /// The loaded file's length in seconds — nil while nothing is loaded.
    var fileDuration: Double? { player?.duration }

    /// Cover art for the mini-player thumbnail (loaded once per file).
    var artworkImage: UIImage? { cachedArtwork }

    /// "Chapter 3 of 14 — The Reunion" for the mini-player's subtitle row.
    var chapterLabel: String? {
        guard activeBook != nil, chapters.indices.contains(chapterIndex) else { return nil }
        let title = chapters[chapterIndex].title
        guard chapters.count > 1 else { return title }
        return "Chapter \(chapterIndex + 1) of \(chapters.count) — \(title)"
    }

    // MARK: Internals

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// The file currently loaded — reload only when it actually changes.
    private var loadedURL: URL?
    /// The book a future play() starts from (bound by the reader on appear).
    private var boundBook: Book?
    private var chapters: [AudioChapter] = []
    /// In-chapter fraction for a cold resume (remote play after stop).
    private var lastFraction: Double = 0
    private var cachedArtwork: UIImage?
    /// Set by pause(), cleared by play() — a chapter end reached while the
    /// user deliberately parked there must not auto-advance.
    private var userPaused = false
    private var lastPersistAt: Date?
    private var lastPublishAt: Date?
    private var remoteWired = false

    /// Set by the audio reader on appear; position writes go through it.
    weak var store: BooksStore?

    // MARK: Binding (no audio yet)

    /// Points the player at a book so a later play/resume knows where to
    /// start. Does NOT touch the active state: if another book is paused the
    /// mini-player keeps showing it until this book actually plays.
    func bind(to book: Book) {
        guard boundBook?.id != book.id else { return }
        boundBook = book
        chapters = book.audioChapters ?? []
        let position = book.position
        chapterIndex = min(max(0, position?.chapterIndex ?? 0), max(0, chapters.count - 1))
        lastFraction = min(max(0, position?.chapterFraction ?? 0), 0.999)
        loadedURL = nil
    }

    // MARK: Transport

    func play(book: Book, chapterIndex index: Int, withinChapterFraction fraction: Double? = nil) {
        // Single slot: playing another book retires the previous one.
        if let current = activeBookID, current != book.id {
            teardownAudio()
        }
        boundBook = book
        chapters = book.audioChapters ?? []
        chapterIndex = min(max(0, index), max(0, chapters.count - 1))
        activeBook = book
        activeBookID = book.id
        userPaused = false
        let url = BooksStore.resolveAudioOriginalURL(book: book)
        do {
            // Same one-shot session configuration every engine runs on first
            // play — an AVAudioPlayer created with the session still in its
            // launch default (ambient/silent-switch-able) is silenced by the
            // mute switch and pauses when the app backgrounds, which looks
            // like "plays two seconds then dies" on device.
            AudioSessionSetup.configureIfNeeded(prefix: "AudioBookPlayer")
            if loadedURL != url || player == nil {
                player?.stop()
                let p = try AVAudioPlayer(contentsOf: url)
                p.prepareToPlay()
                player = p
                loadedURL = url
                cachedArtwork = Self.loadArtwork(book: book)
            }
            guard let player else { return }
            player.currentTime = clampToChapterStart(fraction: fraction, fileDuration: player.duration)
            player.play()
            isPlaying = true
            chapterProgress = chapterProgressValue
            elapsed = player.currentTime
            totalDuration = player.duration
            startTicker()
            wireRemoteCommandsOnce()
            NowPlayingCenter.shared.configure()
            NowPlayingCenter.shared.setChapterSkipEnabled(chapters.count > 1)
            publishNowPlaying(force: true)
            persistPosition(force: true)
        } catch {
            Log.shared.error("AudioBookPlayer: cannot play \(url.lastPathComponent): \(error)")
        }
    }

    func pause() {
        player?.pause()
        userPaused = true
        isPlaying = false
        persistPosition(force: true)
        publishNowPlaying(force: true)
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            resumeCurrent()
        }
    }

    func stop() {
        persistPosition(force: true)
        teardownAudio()
        activeBookID = nil
        activeBook = nil
        isPlaying = false
        chapterProgress = 0
        elapsed = 0
        totalDuration = 0
        NowPlayingCenter.shared.clear()
        NowPlayingCenter.shared.setChapterSkipEnabled(false)
    }

    /// The shelf's delete path: stop only when THIS book is the active one.
    func stopIfPlaying(_ book: Book) {
        guard activeBookID == book.id else { return }
        stop()
    }

    /// Resumes the loaded book, or the bound book on first use. The remote
    /// play button has no chapter index of its own; with nothing bound there
    /// is nothing to resume and it no-ops.
    func resumeCurrent() {
        guard let book = activeBook ?? boundBook else { return }
        if player == nil {
            // Cold resume: start the last chapter at the last fraction.
            play(book: book, chapterIndex: chapterIndex, withinChapterFraction: lastFraction)
        } else {
            userPaused = false
            player?.play()
            isPlaying = true
            publishNowPlaying(force: true)
        }
    }

    /// Chapter step for the remote skip buttons and the reader.
    func stepChapter(_ delta: Int) {
        let target = max(0, min(chapters.count - 1, chapterIndex + delta))
        guard target != chapterIndex, let book = activeBook ?? boundBook else { return }
        play(book: book, chapterIndex: target)
    }

    /// VLC-style skip: ±N seconds from the playhead. The chapter index is
    /// re-resolved for the new absolute position, so a skip across a
    /// chapter boundary moves the chapter (and the lock-screen chapter
    /// metadata) with it — the old chapter chevrons did nothing on files
    /// without chapter metadata, which read as "navigation not working".
    func seekBy(_ seconds: Double) {
        guard let player else { return }
        let target = min(max(0, player.currentTime + seconds), max(0, player.duration - 0.05))
        if let index = chapters.firstIndex(where: { target >= $0.startSeconds && target < $0.endSeconds }) {
            chapterIndex = index
        }
        userPaused = false
        player.currentTime = target
        chapterProgress = chapterProgressValue
        elapsed = target
        // VLC's rule: republish the full surface right after a seek.
        publishNowPlaying(force: true)
        persistPosition(force: true)
    }

    /// Scrub to a 0…1 fraction of the CURRENT chapter — the reader's slider.
    func seek(toFraction value: Double) {
        guard let player, chapters.indices.contains(chapterIndex) else { return }
        let chapter = chapters[chapterIndex]
        guard let end = effectiveChapterEnd(fileDuration: player.duration) else { return }
        let span = end - chapter.startSeconds
        guard span > 0 else { return }
        player.currentTime = min(max(0, chapter.startSeconds + value * span), max(0, end - 0.05))
        userPaused = false
        chapterProgress = chapterProgressValue
        elapsed = player.currentTime
        // VLC's rule: republish the full surface right after a seek — iOS
        // extrapolates the in-between from rate + elapsed.
        publishNowPlaying(force: true)
        persistPosition(force: true)
    }

    /// App-scoped hook for scenePhase changes: flush the position so a
    /// suspension never loses more than the last few seconds of bookkeeping.
    func persistNow() {
        persistPosition(force: true)
    }

    // MARK: Playhead

    /// The chapter's real end, cross-checked against the FILE the player is
    /// actually playing. The manifest's chapter table is best-effort (an
    /// import from before the chapter-track reader shipped a single chapter
    /// whose end was a raced duration — sometimes ≈ 2 s — and the ticker
    /// then paused two seconds into a ten-hour book). A chapter end that is
    /// implausibly short (< 5 s of audio) or beyond the file plays to the
    /// file's end instead; real chapter tables are unaffected.
    private func effectiveChapterEnd(fileDuration: Double) -> Double? {
        guard chapters.indices.contains(chapterIndex) else { return nil }
        let chapter = chapters[chapterIndex]
        var end = chapter.endSeconds
        if fileDuration > 0, end > fileDuration { end = fileDuration }
        guard end > chapter.startSeconds + 5 else {
            return fileDuration > chapter.startSeconds ? fileDuration : nil
        }
        return end
    }

    private var chapterProgressValue: Double {
        guard let player, chapters.indices.contains(chapterIndex) else { return 0 }
        let chapter = chapters[chapterIndex]
        guard let end = effectiveChapterEnd(fileDuration: player.duration) else { return 0 }
        let span = end - chapter.startSeconds
        guard span > 0 else { return 0 }
        return min(1, max(0, (player.currentTime - chapter.startSeconds) / span))
    }

    private var chapterIsFinished: Bool {
        guard let player else { return false }
        guard let end = effectiveChapterEnd(fileDuration: player.duration) else { return false }
        return player.currentTime >= end - 0.05
    }

    private func clampToChapterStart(fraction: Double?, fileDuration: Double) -> Double {
        guard chapters.indices.contains(chapterIndex) else { return 0 }
        let chapter = chapters[chapterIndex]
        var start = chapter.startSeconds
        if let fraction, fraction > 0.005,
           let end = effectiveChapterEnd(fileDuration: fileDuration) {
            start += min(fraction, 0.999) * (end - chapter.startSeconds)
        }
        // Clamp to the file: a garbage chapter start (legacy manifests)
        // otherwise seeks past the end and the ticker stalls instantly.
        return min(max(0, start), max(0, fileDuration - 0.05))
    }

    // MARK: Ticker — chapter advance, publish, persist (runs app-wide)

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        let playing = player.isPlaying
        if isPlaying != playing { isPlaying = playing }
        let value = chapterProgressValue
        if chapterProgress != value { chapterProgress = value }
        let now = player.currentTime
        if elapsed != now { elapsed = now }
        let duration = player.duration
        if totalDuration != duration { totalDuration = duration }

        guard chapterIsFinished, !userPaused else {
            // Playing, mid-chapter: a slow-cadence refresh of the lock
            // surface and the persisted position. Between publishes iOS
            // extrapolates elapsed time from rate + elapsed, so 10 s is
            // plenty (VLC publishes absolute seconds on state changes and
            // lets the system tick in between).
            if isPlaying {
                publishNowPlaying()
                persistPosition()
            }
            return
        }

        if chapterIndex < chapters.count - 1, let book = activeBook ?? boundBook {
            play(book: book, chapterIndex: chapterIndex + 1)
        } else {
            finishBook()
        }
    }

    private func finishBook() {
        // A finished book restarts fresh on next open — the last chapter
        // would otherwise resume at its own end and instantly "finish" again.
        if let book = activeBook {
            store?.updatePosition(book, chapterIndex: 0, chapterFraction: 0)
        }
        boundBook = nil
        lastFraction = 0
        stop()
    }

    // MARK: Position persistence

    private func persistPosition(force: Bool = false) {
        guard let book = activeBook, let store else { return }
        let now = Date()
        if !force, let last = lastPersistAt, now.timeIntervalSince(last) < 5 { return }
        lastPersistAt = now
        lastFraction = chapterProgress
        store.updatePosition(book, chapterIndex: chapterIndex, chapterFraction: chapterProgress, cfi: nil)
    }

    // MARK: Lock screen / Control Center

    /// Installs the audiobook's remote-command consumer once. A router, not a
    /// steal: `NowPlayingCenter` tries this first and falls through to
    /// SpeechPlayer's handler whenever no audiobook is active, so the two
    /// playback paths never fight over `onCommand`.
    private func wireRemoteCommandsOnce() {
        guard !remoteWired else { return }
        remoteWired = true
        NowPlayingCenter.shared.audioBookHandler = { [weak self] command in
            guard let self, self.activeBookID != nil else { return false }
            switch command {
            case .play:
                self.resumeCurrent()
            case .pause:
                self.pause()
            case .toggle:
                if self.isPlaying { self.pause() } else { self.resumeCurrent() }
            case .stop:
                self.stop()
            case .previousChapter:
                self.stepChapter(-1)
            case .nextChapter:
                self.stepChapter(1)
            }
            return true
        }
    }

    /// Lock screen / Control Center, through the same NowPlayingCenter every
    /// other playback path uses. Absolute file seconds go out (VLC's
    /// pattern): duration + elapsed + rate let iOS extrapolate the scrubber
    /// between publishes, and chapter count/number drive the system's
    /// chapter affordances.
    private func publishNowPlaying(force: Bool = false) {
        let now = Date()
        if !force, let last = lastPublishAt, now.timeIntervalSince(last) < 10 { return }
        lastPublishAt = now
        guard let book = activeBook else { return }
        let chapterTitle = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : nil
        let countLabel = chapters.count > 1 ? "Chapter \(chapterIndex + 1) of \(chapters.count)" : nil
        NowPlayingCenter.shared.publish(
            title: book.title,
            subtitle: [countLabel, chapterTitle].compactMap { $0 }.joined(separator: " — "),
            artwork: cachedArtwork,
            isPlaying: isPlaying,
            progress: nil,
            rate: 1.0,
            elapsedSeconds: player?.currentTime,
            durationSeconds: book.audioDuration ?? player?.duration,
            chapterCount: chapters.count > 1 ? chapters.count : nil,
            chapterNumber: chapters.count > 1 ? chapterIndex + 1 : nil
        )
    }

    /// Reads the cover once per file load. Nil when the book has no embedded
    /// art or it could not be decoded — the surface then shows text only.
    private static func loadArtwork(book: Book) -> UIImage? {
        guard book.hasCover else { return nil }
        let url = BooksStore.coverFileURL(book)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func teardownAudio() {
        player?.stop()
        player = nil
        loadedURL = nil
        cachedArtwork = nil
        stopTicker()
    }
}
