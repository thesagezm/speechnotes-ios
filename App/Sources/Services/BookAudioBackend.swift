import AVFoundation

/// The audio surface `AudioBookPlayer` plays a book through.
///
/// Two backends implement it: `AVPlayerBackend` — the container formats
/// AVFoundation demuxes and decodes natively (M4B/AAC, MP3, the EAC3 the
/// Files app plays) — and `OpusAudioBackend`, which owns an `AVAudioEngine`
/// and decodes an Ogg Opus stream itself, because iOS ships no Ogg demuxer
/// and `AVPlayer` can never read one.
///
/// The protocol is deliberately the AVPlayer surface `AudioBookPlayer`
/// already speaks (a playhead in seconds, a rate, a seek, an async length,
/// an async failure), so the player's transport logic — coalesced seeks,
/// chapter advance, the lock-screen surface — runs unchanged over either
/// backend.
protocol BookAudioBackend: AnyObject {
    /// True while the backend is actually rendering audio. AVPlayer's
    /// `timeControlStatus == .playing`; the engine path's node-playing-and-
    /// engine-running.
    var isRendering: Bool { get }

    /// The playhead in file seconds, or nil while the backend cannot say
    /// (an AVPlayer item still opening, an Opus stream still loading).
    var currentTime: Double? { get }

    /// The rate playback resumes at after play()/pause(). Kept separate from
    /// `rate` because setting `rate` on a PAUSED AVPlayer silently starts
    /// playback — `AudioBookPlayer.applyRate` documents the trap.
    var defaultRate: Float { get set }
    /// The live rate. Writing this while paused must NOT start playback.
    var rate: Float { get set }

    /// The file's true length in seconds, when the backend learns it
    /// (AVPlayer: the container parses; Opus: the stream is read whole).
    var onDuration: ((Double) -> Void)? { get set }
    /// A decode failure that will not heal — the honest-message path. The
    /// player maps the error to a user-facing reason and stops retrying.
    var onFailed: ((Error) -> Void)? { get set }

    func play()
    func pause()
    /// Seek to `seconds` in file time. `tolerance` is advisory — AVPlayer
    /// lands within it on a decode boundary; a packet-based backend is
    /// exact and ignores it.
    func seek(to seconds: Double, tolerance: Double)
    /// Full teardown. The backend is unusable afterwards.
    func stop()
}

/// The AVPlayer half of `BookAudioBackend` — the item construction, the
/// status/duration KVO and the tolerance-carrying seek, extracted from
/// `AudioBookPlayer.play` so both backends live behind one protocol.
final class AVPlayerBackend: BookAudioBackend {

    var onDuration: ((Double) -> Void)?
    var onFailed: ((Error) -> Void)?

    /// The item's failure surfaces through the status observer — that is
    /// where `AudioBookPlayer` gets its honest message today.
    private let item: AVPlayerItem
    private let player: AVPlayer
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?

    var isRendering: Bool { player.timeControlStatus == .playing }

    var currentTime: Double? { AudioBookPlayer.seconds(of: player.currentTime()) }

    var defaultRate: Float {
        get { player.defaultRate }
        set { player.defaultRate = newValue }
    }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    init(url: URL, rate: Float) {
        item = AVPlayerItem(url: url)
        // The player is fully built BEFORE the observers attach: the KVO
        // closures capture self, and Swift's definite-initialization rules
        // forbid that while a stored property is still unset. Both item
        // states (failure, resolved duration) only ever surface
        // asynchronously, so nothing is missed by attaching after.
        player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.defaultRate = rate
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard let self, observedItem.status == .failed else { return }
            self.onFailed?(observedItem.error ?? URLError(.cannotDecodeContentData))
        }
        // The file's length arrives by KVO: AVPlayerItem.duration starts
        // indefinite and changes once the container is parsed. Reading it
        // here (not synchronously on demand) keeps every transport read off
        // the deprecated blocking accessor.
        durationObserver = item.observe(\.duration, options: [.new]) { [weak self] observedItem, _ in
            guard let self, let seconds = AudioBookPlayer.seconds(of: observedItem.duration) else { return }
            self.onDuration?(seconds)
        }
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func seek(to seconds: Double, tolerance: Double) {
        player.seek(
            to: AudioBookPlayer.time(seconds),
            toleranceBefore: AudioBookPlayer.time(tolerance),
            toleranceAfter: AudioBookPlayer.time(tolerance)
        )
    }

    func stop() {
        statusObserver?.invalidate()
        durationObserver?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
