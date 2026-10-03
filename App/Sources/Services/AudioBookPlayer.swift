import AVFoundation
import MediaPlayer
import SwiftUI
import SpeechLogic
import UIKit

// AVPlayer, not AVAudioPlayer. The Files app plays the EAC3/5.1 'Harry
// Potter' m4b without complaint because it hands the file to the same
// media stack AVPlayer uses; AVAudioPlayer goes through Audio File
// Services, which fails on Dolby Digital Plus with
// kAudioFileInvalidChunkError. The cost of the swap is that position and
// duration move to CMTime — the two helpers below keep the rest of this
// player's arithmetic in plain seconds.

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

    // MARK: Playback speed + sleep timer (v1.7.2)

    /// Playback speed, 0.5…3.0. Applied through `defaultRate` (iOS 16+ — the
    /// deployment target is 18) so play()/pause() resume at the chosen speed
    /// without every call site having to re-set `rate` — setting `rate`
    /// directly on a PAUSED player would silently start playback.
    @Published private(set) var rate: Double {
        didSet { UserDefaults.standard.set(rate, forKey: Self.rateDefaultsKey) }
    }

    /// Seconds left on the sleep timer, published per tick while armed (nil
    /// when off). The countdown only advances while the book is actually
    /// playing — parking the book must not eat the timer.
    @Published private(set) var sleepRemaining: TimeInterval?
    /// End-of-chapter sleep mode: pause when THIS chapter finishes instead of
    /// auto-advancing (the "let me finish this chapter" option).
    @Published private(set) var sleepAtChapterEnd = false

    var sleepTimerActive: Bool { sleepRemaining != nil || sleepAtChapterEnd }

    private var lastTickAt: Date?

    static let rateDefaultsKey = "audioBookRate"
    static let rateRange: ClosedRange<Double> = 0.5...3.0
    /// The speed menu's presets — the values audiobook apps converge on.
    static let ratePresets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// The compact bar is shown while a book is loaded (playing or paused),
    /// but never while its own reader is showing the full controls.
    var showMiniBar: Bool { activeBookID != nil && !readerVisible }

    var nowPlayingTitle: String? { activeBook?.title }

    /// The manifest's duration — the fallback while an item is still
    /// opening (AVPlayer reports an indefinite duration until the stream
    /// is ready, and the manifest value is right by construction).
    private var bookDurationFallback: Double { activeBook?.audioDuration ?? 0 }

    /// The file's length, loaded ASYNC once per item. Every transport read
    /// reads THIS — never `AVPlayerItem.duration` synchronously: it is the
    /// one AVFoundation property Apple documents as "may block the calling
    /// thread" (deprecated in iOS 16 for exactly that), and it sat inside
    /// seekBy, tick, chapterProgressValue and chapterIsFinished, so
    /// mashing the transport hammered it dozens of times a second on the
    /// main thread.
    private var cachedFileDuration: Double?

    /// The file length the transport math uses: the async cache, then the
    /// manifest, then zero. No synchronous AVPlayerItem property access.
    private var fileLength: Double {
        cachedFileDuration ?? (totalDuration > 0 ? totalDuration : bookDurationFallback)
    }

    /// Coalesced transport (VLC's behavior): rapid ±15 s / chapter presses
    /// each recompute the target and move the PUBLISHED playhead, but only
    /// the last press commits an actual seek + publish + persist. The
    /// media stack re-primes per seek — N rapid presses must cost one
    /// seek, not N — and every commit also carried a now-playing publish
    /// and a position write.
    private struct PendingSeek {
        var target: Double
        var wasPlaying: Bool
    }
    private var pendingSeek: PendingSeek?
    private var seekCommitTimer: Timer?

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

    /// libx264 saves key frames at 10-second intervals, so the AVPlayer seek
    /// tolerance is deliberately loose: a tap lands within a key frame
    /// boundary and playback resumes from there. 1000 is the CMTime
    /// timescale for every position in this player — one second of
    /// millisecond resolution is plenty for chapter-accurate scrubbing.
    private static let timeScale: CMTimeScale = 1000

    /// The audio backend the loaded file plays through: `AVPlayerBackend`
    /// for every container AVFoundation demuxes natively, `OpusAudioBackend`
    /// (engine + own demux/decode) for Ogg Opus, which AVFoundation cannot
    /// open at all. Created in `play` — see the backend-selection note there.
    private var backend: BookAudioBackend?
    private var ticker: Timer?
    /// Set true only by the backend-creation branch in play(), and read
    /// right after: a freshly created backend commits its first seek
    /// immediately (no coalescing window on a cold start).
    private var loadedItemJustCreated = false
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

    /// Set when a book's file cannot be decoded by the player at all.
    /// The device log showed 30+ identical "cannot play original.m4b"
    /// errors for the EAC3/5.1 'Harry Potter' file — the import succeeded,
    /// every tap of Play retried the same un-decodable file. Reads set this
    /// to nil; a non-nil value disables the play affordance and the reader
    /// shows why (an honest "this file's audio can't be decoded" beats 30
    /// retries and a dead bar).
    @Published private(set) var playbackBlockedReason: String?

    /// Set when this book's file cannot be decoded by the player at all.
    var isBlocked: Bool { playbackBlockedReason != nil }

    /// The one-per-book AVPlayer→engine retry for Opus-in-MP4 books (see
    /// `handleBackendFailure`). Reset per play() like the blocked reason.
    private var attemptedOpusEngineFallback = false

    /// Set by the audio reader on appear; position writes go through it.
    weak var store: BooksStore?

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.rateDefaultsKey)
        rate = Self.rateRange.contains(stored) && stored > 0 ? stored : 1.0
    }

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
        playbackBlockedReason = nil
        attemptedOpusEngineFallback = false
        let url = BooksStore.resolveAudioOriginalURL(book: book)
        do {
            // Same one-shot session configuration every engine runs on first
            // play — an item created while the session is still in its
            // launch default (ambient/silent-switch-able) is silenced by the
            // mute switch and pauses when the app backgrounds, which looks
            // like "plays two seconds then dies" on device.
            AudioSessionSetup.configureIfNeeded(prefix: "AudioBookPlayer")
            if loadedURL != url || backend == nil {
                // A failure must not leave the previous backend's callbacks
                // attached to the new one.
                backend?.stop()
                backend = try Self.makeBackend(url: url, rate: rate, into: self)
                loadedURL = url
                loadedItemJustCreated = true
                cachedFileDuration = nil
                cachedArtwork = Self.loadArtwork(book: book)
            }
            guard let backend else { return }
            let fileDuration = fileLength
            let start = clampToChapterStart(fraction: fraction, fileDuration: fileDuration)
            isPlaying = true
            totalDuration = fileDuration
            startTicker()
            wireRemoteCommandsOnce()
            wireSessionObserversOnce()
            NowPlayingCenter.shared.configure()
            NowPlayingCenter.shared.setChapterSkipEnabled(chapters.count > 1)
            // The lock screen's ±15 s skip buttons live only while an
            // audiobook owns playback (v1.7.2).
            NowPlayingCenter.shared.setSkipBackForwardEnabled(true, interval: 15)
            // The backend seeks before play so the first rendered frame is
            // already the chapter start; a seek during playback would be
            // the pre-roll glitch VLC avoids.
            //
            // The commit is split by WHERE the press came from: a cold
            // start (the backend above was just created — the tap is already
            // slow) and a fraction-carrying resume commit at once; a
            // chapter jump on the LIVE backend is the mash path — the UI
            // state above is already live, and the actual seek waits for
            // the presses to stop (see PendingSeek).
            if fraction != nil {
                userPaused = false
                backend.play()
                commitSeek(to: start, wasPlaying: true, fileDuration: fileDuration)
            } else if loadedItemJustCreated {
                loadedItemJustCreated = false
                userPaused = false
                backend.play()
                commitSeek(to: start, wasPlaying: true, fileDuration: fileDuration)
            } else {
                userPaused = false
                elapsed = start
                chapterProgress = 0
                scheduleSeekCommit(target: start, wasPlaying: true)
            }
        } catch {
            // ONE line, and a reason the UI can act on. The device log for
            // the EAC3 'Harry Potter' book showed this catch firing 30+
            // times for one book.
            let reason = AudioBookPlayer.unplayableReason(for: error, url: url)
            Log.shared.error("AudioBookPlayer: cannot play \(url.lastPathComponent): \(error) — \(reason)")
            playbackBlockedReason = reason
            isPlaying = false
            // Leave the ticker running off; a dead ticker would keep
            // publishing a playhead that never moves.
            stopTicker()
        }
    }

    /// Builds the right backend for a file.
    ///
    /// The Ogg check is by MAGIC, not extension: `.opus`/`.ogg`/`.oga` are
    /// the Ogg extensions, but an Ogg stream wearing another extension
    /// still needs the engine path, and a mislabeled file must keep the
    /// AVPlayer path.
    ///
    /// The MP4-Opus check exists because the device log says so: a
    /// `book.opus` whose import reports duration, cover and author is an
    /// Opus-in-MP4 track — AVFoundation parses that container (that is how
    /// the import read its metadata) but cannot DECODE the codec behind
    /// AVPlayer. Routing it to AVPlayer would fail 100% of the time, so
    /// the engine path (own demux via `Mp4OpusReader` + Apple's Opus codec)
    /// takes it directly.
    private static func makeBackend(
        url: URL,
        rate: Float,
        into player: AudioBookPlayer
    ) throws -> BookAudioBackend {
        if BooksStore.isOggContainer(url) {
            let opus = OpusAudioBackend()
            opus.rate = rate
            opus.onDuration = { seconds in
                Task { @MainActor in
                    player.cachedFileDuration = seconds
                }
            }
            opus.onFailed = { error in
                Task { @MainActor in
                    player.handleBackendFailure(error)
                }
            }
            // The whole-file read + parse runs off-main inside the backend;
            // play() and the cold seek (committed right after this returns)
            // queue behind it via pendingSeekTarget.
            opus.loadOgg(url: url)
            Log.shared.info("AudioBookPlayer: Ogg container — engine backend (own demux + decode)")
            return opus
        }
        if Self.sniffsOpusInMp4(url: url) {
            let opus = OpusAudioBackend()
            opus.rate = rate
            opus.onDuration = { seconds in
                Task { @MainActor in
                    player.cachedFileDuration = seconds
                }
            }
            opus.onFailed = { error in
                Task { @MainActor in
                    player.handleBackendFailure(error)
                }
            }
            opus.loadOpusInMp4(url: url)
            Log.shared.info("AudioBookPlayer: Opus-in-MP4 track — engine backend (own demux + decode)")
            return opus
        }
        let av = AVPlayerBackend(url: url, rate: rate)
        av.onDuration = { seconds in
            Task { @MainActor in
                player.cachedFileDuration = seconds
            }
        }
        av.onFailed = { error in
            Task { @MainActor in
                player.handleBackendFailure(error)
            }
        }
        return av
    }

    /// A codec-level failure is the file's, not a transient: name it so the
    /// reader can show it instead of retrying forever.
    ///
    /// This path only ever sees AVPlayer-backend failures now — Ogg files
    /// play through `OpusAudioBackend`, whose own decode errors carry their
    /// message straight from the decoder.
    private static func unplayableReason(for error: Error, url: URL) -> String {
        let nsError = error as NSError
        // 1685348671 = kAudioFileInvalidChunkError: the container/codec walk
        // failed — in practice EAC3/Atmos or another software-undecodable
        // stream. Sniff the codec so the message is specific.
        let codec = sniffedCodec(url: url)
        if let codec {
            return "This file's audio (\(codec)) can't be decoded on this device. Re-encode it as AAC or MP3 and re-import."
        }
        if nsError.code == 1685348671 {
            return "This file's audio format can't be decoded on this device. Re-encode it as AAC or MP3 and re-import."
        }
        return "Couldn't read this file (\(nsError.localizedDescription))."
    }

    /// True when the head slice looks like an MP4/M4A container whose
    /// sample entry says Opus: an `ftyp` box plus the `Opus` fourCC (or the
    /// `dOps` box the spec requires). The head slice is the same cheap read
    /// `sniffedCodec` makes.
    private static func sniffsOpusInMp4(url: URL) -> Bool {
        guard let head = BooksStore.slice(of: url, from: 0, length: 256 * 1024) else { return false }
        let isMp4 = head.range(of: Data("ftyp".utf8)) != nil
            || head.range(of: Data("moov".utf8)) != nil
        let saysOpus = head.range(of: Data("Opus".utf8)) != nil
            || head.range(of: Data("dOps".utf8)) != nil
        return isMp4 && saysOpus
    }

    /// The first audio stream's codec, read from the container's own
    /// `stsd`/`esds` descriptors. Cheap — one small head read, and only
    /// ever called on the failure path.
    private static func sniffedCodec(url: URL) -> String? {
        guard let head = BooksStore.slice(of: url, from: 0, length: 256 * 1024) else { return nil }
        let known: [(String, String)] = [
            ("ec-3", "Dolby Digital Plus (EAC3)"),
            ("EAC3", "Dolby Digital Plus (EAC3)"),
            ("ac-3", "Dolby Digital (AC3)"),
            ("AC-3", "Dolby Digital (AC3)"),
            ("alac", "Apple Lossless (ALAC)"),
            ("Opus", "Opus"),
            ("fLaC", "FLAC"),
        ]
        for (fourCC, label) in known {
            if head.range(of: Data(fourCC.utf8)) != nil { return label }
        }
        return nil
    }

    func pause() {
        // A press is pending its commit: it must not come back playing
        // over an explicit pause.
        pendingSeek?.wasPlaying = false
        backend?.pause()
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
        // Nothing left to pause — an armed timer on a stopped book is a
        // phantom.
        sleepRemaining = nil
        sleepAtChapterEnd = false
        NowPlayingCenter.shared.clear()
        NowPlayingCenter.shared.setChapterSkipEnabled(false)
        NowPlayingCenter.shared.setSkipBackForwardEnabled(false)
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
        if backend == nil {
            // Cold resume: start the last chapter at the last fraction.
            play(book: book, chapterIndex: chapterIndex, withinChapterFraction: lastFraction)
        } else {
            userPaused = false
            backend?.play()
            applyRate(force: true)
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

    // MARK: Speed + sleep timer

    /// Sets playback speed and applies it to the live player. Applied through
    /// `defaultRate` so the next play()/pause() cycle keeps the speed; while
    /// PLAYING the live `rate` moves too. (Setting `rate` while paused would
    /// start playback — a trap the default-rate API exists to avoid.)
    func setRate(_ newRate: Double) {
        rate = min(max(newRate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        applyRate()
    }

    private func applyRate(force: Bool = false) {
        guard let backend else { return }
        backend.defaultRate = Float(rate)
        // After a play() call isRendering may not have flipped yet — the
        // force variant (used right after play) sets the live rate
        // regardless.
        if force || backend.isRendering {
            backend.rate = Float(rate)
        }
    }

    /// Arms the sleep timer for N minutes. The countdown runs only while the
    /// book plays, so parking mid-story does not burn the timer.
    func startSleepTimer(minutes: Int) {
        sleepAtChapterEnd = false
        sleepRemaining = TimeInterval(minutes * 60)
        lastTickAt = nil
        Log.shared.info("AudioBookPlayer: sleep timer armed for \(minutes) min")
    }

    /// Arms the end-of-chapter variant: pause when the current chapter ends,
    /// instead of auto-advancing.
    func startSleepTimerToEndOfChapter() {
        sleepRemaining = nil
        sleepAtChapterEnd = true
        Log.shared.info("AudioBookPlayer: sleep timer armed to end of chapter")
    }

    func cancelSleepTimer() {
        guard sleepTimerActive else { return }
        sleepRemaining = nil
        sleepAtChapterEnd = false
    }

    /// The timer fired: pause, disarm, say so. The user may be asleep — the
    /// toast is for whoever looks next.
    private func fireSleepTimer() {
        sleepRemaining = nil
        sleepAtChapterEnd = false
        if isPlaying { pause() }
        ToastCenter.shared.show("Sleep timer: paused")
    }

    /// VLC-style skip: ±N seconds from the playhead. The chapter index is
    /// re-resolved for the new absolute position, so a skip across a
    /// chapter boundary moves the chapter (and the lock-screen chapter
    /// metadata) with it — the old chapter chevrons did nothing on files
    /// without chapter metadata, which read as "navigation not working".
    ///
    /// Mashing accumulates on the PENDING target: the playhead has not
    /// moved yet for presses 2…N, so computing each press from
    /// currentTime() would make them no-ops (five −15 s taps must rewind
    /// 75 s, not 15). The published playhead updates per press; one seek
    /// commits when the presses stop.
    func seekBy(_ seconds: Double) {
        guard let backend else { return }
        let base = pendingSeek?.target ?? (backend?.currentTime ?? 0)
        let target = min(max(0, base + seconds), max(0, fileLength - 0.05))
        if let index = chapters.firstIndex(where: { target >= $0.startSeconds && target < $0.endSeconds }) {
            chapterIndex = index
        }
        userPaused = false
        elapsed = target
        let wasPlaying = isPlaying || pendingSeek?.wasPlaying == true
        scheduleSeekCommit(target: target, wasPlaying: wasPlaying)
    }

    /// Scrub to a 0…1 fraction of the CURRENT chapter — the reader's slider.
    /// One deliberate jump per drag end — committed immediately, no
    /// coalescing window.
    func seek(toFraction value: Double) {
        guard chapters.indices.contains(chapterIndex) else { return }
        let chapter = chapters[chapterIndex]
        guard let end = effectiveChapterEnd(fileDuration: fileLength) else { return }
        let span = end - chapter.startSeconds
        guard span > 0 else { return }
        let target = min(max(0, chapter.startSeconds + value * span), max(0, end - 0.05))
        userPaused = false
        commitSeek(to: target, wasPlaying: isPlaying, fileDuration: fileLength)
    }

    // MARK: Seek commit (coalesced transport)

    /// Schedules (or re-schedules) the single seek commit 0.2 s after the
    /// last press. The window is short enough to feel instant, long enough
    /// that a mash costs one seek instead of one per press.
    private func scheduleSeekCommit(target: Double, wasPlaying: Bool) {
        pendingSeek = PendingSeek(target: target, wasPlaying: wasPlaying)
        seekCommitTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let pending = self.pendingSeek else { return }
                self.commitSeek(
                    to: pending.target,
                    wasPlaying: pending.wasPlaying,
                    fileDuration: self.fileLength
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        seekCommitTimer = timer
    }

    /// The ONE place a seek actually reaches AVPlayer, with loose
    /// tolerance (the class comment always said "deliberately loose" — the
    /// old `seek(to:)` call was the EXACT variant, kCMTimeZero on both
    /// sides, forcing the decoder to land sample-exact on every press).
    /// ±0.25 s is inaudible in an audiobook and lets the media stack land
    /// on a decode boundary. Seeks before play (wasPlaying) keep the
    /// first-rendered-frame-already-at-target property.
    private func commitSeek(to target: Double, wasPlaying: Bool, fileDuration: Double) {
        pendingSeek = nil
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        guard let backend else { return }
        backend.seek(to: target, tolerance: 0.25)
        if wasPlaying {
            backend.play()
            applyRate(force: true)
        }
        chapterProgress = chapterProgressValue
        elapsed = target
        if fileDuration > 0 { totalDuration = fileDuration }
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
        guard let backend, chapters.indices.contains(chapterIndex) else { return 0 }
        let chapter = chapters[chapterIndex]
        guard let end = effectiveChapterEnd(fileDuration: fileLength) else { return 0 }
        let span = end - chapter.startSeconds
        guard span > 0 else { return 0 }
        let here = backend.currentTime ?? chapter.startSeconds
        return min(1, max(0, (here - chapter.startSeconds) / span))
    }

    private var chapterIsFinished: Bool {
        guard let backend else { return false }
        guard let end = effectiveChapterEnd(fileDuration: fileLength) else { return false }
        let here = backend.currentTime ?? 0
        return here >= end - 0.05
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
        guard let backend else { return }
        // A transport press is pending its commit: hold the surface steady
        // — the playhead is about to jump, so neither the published state
        // nor the chapter auto-advance may react to the pre-seek position
        // (mid-mash, chapterIsFinished still reads the OLD playhead and
        // would fire an auto-advance that fights the user's rewind).
        if pendingSeek != nil { return }
        // timeControlStatus is AVPlayer's "is it actually producing audio"
        // — .playing while rendering, .paused when paused, and
        // .waitingToPlayAtSpecifiedRate while buffering a big file.
        let playing = backend.isRendering
        if isPlaying != playing { isPlaying = playing }
        let value = chapterProgressValue
        if chapterProgress != value { chapterProgress = value }
        let now = backend.currentTime ?? 0
        if elapsed != now { elapsed = now }
        let duration = cachedFileDuration ?? 0
        if totalDuration != duration, duration > 0 { totalDuration = duration }

        // Sleep timer countdown — real elapsed time between ticks, advanced
        // ONLY while the book is audibly playing (a parked book must not
        // burn the timer).
        if let last = lastTickAt {
            let dt = Date().timeIntervalSince(last)
            if playing, let remaining = sleepRemaining {
                let left = remaining - dt
                if left <= 0 {
                    lastTickAt = Date()
                    fireSleepTimer()
                    return
                }
                if sleepRemaining != left { sleepRemaining = left }
            }
        }
        lastTickAt = Date()

        guard chapterIsFinished, !userPaused else {
            // Playing, mid-chapter: a refresh of the lock surface and the
            // persisted position. publishNowPlaying throttles itself to a
            // 1 s cadence — the lock-screen clock ticks in seconds, so the
            // cadence must match what the user watches.
            if isPlaying {
                publishNowPlaying()
                persistPosition()
            }
            return
        }

        // End-of-chapter sleep mode fires HERE — at the chapter boundary,
        // before the auto-advance can start the next chapter.
        if sleepAtChapterEnd {
            fireSleepTimer()
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
            case .skipBackward:
                self.seekBy(-15)
            case .skipForward:
                self.seekBy(15)
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
        // 1 s cadence (v1.7.2, user ask): the lock screen's clock must tick
        // in SECONDS. The old 10 s VLC-style cadence relied on iOS
        // extrapolating from rate + elapsed — which held on some builds but
        // left the lock-screen readout jumping in 10-second lumps on this
        // one. One dictionary write per second is nothing next to decoding.
        if !force, let last = lastPublishAt, now.timeIntervalSince(last) < 1 { return }
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
            rate: Float(rate),
            elapsedSeconds: backend?.currentTime,
            durationSeconds: book.audioDuration ?? cachedFileDuration,
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
        backend?.stop()
        backend = nil
        loadedURL = nil
        loadedItemJustCreated = false
        cachedFileDuration = nil
        pendingSeek = nil
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        cachedArtwork = nil
        stopTicker()
    }

    // MARK: - CMTime helpers

    /// Position/duration in seconds, or nil when the value is indefinite
    /// (AVPlayer reports that before a stream is ready).
    static func seconds(of time: CMTime?) -> Double? {
        guard let time, time.isNumeric, !time.isIndefinite else { return nil }
        return time.seconds
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timeScale)
    }

    /// The backends' async failure path — an un-decodable codec surfaces
    /// here, not at construction, so the honest banner comes from this hook
    /// too. The backend's own decode errors (the Opus engine path) already
    /// carry a user-facing message; AVPlayer's need the codec sniff.
    private func handleBackendFailure(_ error: Error) {
        guard let url = loadedURL else { return }
        // Second chance, once per book: AVPlayer failed on a file whose
        // codec sniff says Opus — the container-parse-but-cannot-decode
        // case `makeBackend`'s sniff missed (e.g. the sample entry sits
        // deeper than the head slice). Rebuild on the engine path at the
        // playhead where the failure happened.
        if backend is AVPlayerBackend, !attemptedOpusEngineFallback,
           Self.sniffedCodec(url: url) == "Opus" {
            attemptedOpusEngineFallback = true
            let resumeAt = elapsed
            Log.shared.info(
                "AudioBookPlayer: AVPlayer cannot decode an Opus track — retrying through the engine path at \(Int(resumeAt))s"
            )
            let opus = OpusAudioBackend()
            opus.rate = rate
            opus.onDuration = { seconds in
                Task { @MainActor in
                    self.cachedFileDuration = seconds
                }
            }
            opus.onFailed = { failed in
                Task { @MainActor in
                    self.handleBackendFailure(failed)
                }
            }
            backend?.stop()
            backend = opus
            playbackBlockedReason = nil
            isPlaying = true
            startTicker()
            opus.loadOpusInMp4(url: url)
            opus.seek(to: resumeAt, tolerance: 0.25)
            opus.play()
            return
        }
        let reason: String
        if backend is OpusAudioBackend {
            reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        } else {
            reason = Self.unplayableReason(for: error, url: url)
        }
        Log.shared.error("AudioBookPlayer: \(url.lastPathComponent) failed to decode — \(reason)")
        playbackBlockedReason = reason
        isPlaying = false
        stopTicker()
    }

    // MARK: Audio session resilience — the background-kill fix

    /// The device report: one audiobook persists on the lock screen all
    /// session long while another (the EAC3 'Harry Potter' file) gets the
    /// app suspended "the way Apple does not allow apps to run in the
    /// background". The difference is not the app's background mode — it
    /// is the SESSION surviving what iOS does around it. Interruptions
    /// (calls, Siri, alarms) and route reconfigurations tear the session
    /// down; multichannel EAC3 content triggers decoder reconfigurations
    /// that stereo AAC never sees. With no handlers, the session dies in
    /// the background, no audio renders, and iOS suspends the process a
    /// few seconds later — playback "closed by the system". VLC never
    /// loses background audio because it owns its audio output and
    /// re-activates after every session event; these handlers are the
    /// AVPlayer equivalent of that contract.
    private var sessionObserversWired = false
    private var sessionObservers: [NSObjectProtocol] = []
    /// Set when iOS interrupts (began) while we were audibly playing — the
    /// .ended event resumes from THIS, not from the published isPlaying
    /// (which .began just set false).
    private var interruptedWhilePlaying = false

    private func wireSessionObserversOnce() {
        guard !sessionObserversWired else { return }
        sessionObserversWired = true
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // iOS paused the pipeline. userPaused stays false — an
            // interruption is not the user parking the book.
            interruptedWhilePlaying = isPlaying
            if isPlaying { isPlaying = false }
        case .ended:
            defer { interruptedWhilePlaying = false }
            guard interruptedWhilePlaying, !userPaused else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                resumeAfterSessionEvent()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones yanked: the system already paused the pipeline —
        // reflect it (auto-resuming onto the speaker would blast audio).
        if reason == .oldDeviceUnavailable, !userPaused {
            isPlaying = backend?.isRendering ?? false
        }
    }

    private func handleMediaServicesReset() {
        // The media server died: session configuration and the loaded item
        // are both void. Re-arm the setup and cold-resume where the user
        // was — a stuck "playing" surface with a dead pipeline is exactly
        // the state that gets the app suspended.
        Log.shared.error("AudioBookPlayer: media services reset — rebuilding the session and resuming")
        AudioSessionSetup.invalidateConfiguration()
        guard let book = activeBook else { return }
        let fraction = chapterProgress
        let wasPlaying = isPlaying
        teardownAudio()
        if wasPlaying {
            play(book: book, chapterIndex: chapterIndex, withinChapterFraction: fraction)
        }
    }

    /// Interruption ended with shouldResume: re-activate the session and
    /// pick up where the interruption cut in. Without the explicit
    /// re-activation the session stays deactivated and, in the background,
    /// the process is suspended seconds later.
    private func resumeAfterSessionEvent() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.shared.error("AudioBookPlayer: session re-activate failed: \(error)")
        }
        backend?.play()
        applyRate(force: true)
        isPlaying = true
        publishNowPlaying(force: true)
    }
}
