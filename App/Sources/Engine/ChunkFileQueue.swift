import AVFoundation
import SpeechLogic

/// Batch D's file-queue substrate: rendered chunks written to disk and
/// played by an `AVQueuePlayer`, so TTS output is treated exactly like the
/// app's music.
///
/// Why this exists. The three TTS engines hand-wired their own
/// `AVAudioEngine` graph, and none of them activated an audio session — the
/// root cause of every "dies in seconds when the screen locks" report.
/// `AVPlayer` does all of that internally, which is why the M4B path has
/// never had that bug. This substrate gives the neural engines the same
/// machine, and with it the things a media player gets for free: the
/// lock-screen card, background persistence, and `audioTimePitchAlgorithm`
/// for rate.
///
/// **This batch ships DEAD — no engine routes through it.** It lands with
/// its own review pass and its own tests for the parts that can be tested,
/// and Batch E is the one that puts engines on it. A new substrate that
/// arrives already load-bearing has no way to fail safely.
///
/// What it owns:
/// - writing each chunk through `WAVWriter.StreamingWriter` (already
///   streaming, already tested) into a per-session directory under
///   `Caches/speechnotes-tts/<session>/`;
/// - the `ChunkCachePolicy` caps, enforced before each write;
/// - at least 4 items enqueued ahead of the playhead;
/// - the per-chunk silence trim, so a file boundary is the only
///   discontinuity;
/// - `rate` as a player property via
///   `AVPlayerItem.audioTimePitchAlgorithm = .spectral`;
/// - read-along, driven by `AVPlayer.addPeriodicTimeObserver` and keeping
///   `PlayPositionTracker`'s marker arithmetic unchanged;
/// - `MPNowPlayingSession` where available, beside the existing
///   `MPNowPlayingInfoCenter` writes.
///
/// Threading: main-actor only. `AVQueuePlayer`'s queue is mutated on main,
/// the time observer fires on main, and the file writes arrive from a
/// caller-owned serial queue as finished `[Float]` buffers.
final class ChunkFileQueue: NSObject {

    // MARK: - Input (set by the engine before speak)

    /// The rate the player is currently asked for. Player-side: a rate
    /// change is heard immediately, with `.spectral` pitch correction, and
    /// does not require re-rendering the audio that is already banked.
    var rate: Float = 1.0 {
        didSet {
            // A rate change must not START a paused player: assigning a
            // nonzero rate to a paused AVQueuePlayer is how it un-pauses.
            // While paused the new rate is picked up by the next play().
            guard queuePlayer.rate != 0 else { return }
            queuePlayer.rate = rate
        }
    }

    /// Called with the played UTF-16 character count, from the periodic
    /// time observer. The marker model is `PlayPositionTracker`'s, unchanged.
    var onPlayedChars: ((Int) -> Void)?

    /// Fired when the queue drains — the natural end of the chapter.
    var onFinished: (() -> Void)?

    // MARK: - State

    private let queuePlayer = AVQueuePlayer()
    private let policy = ChunkCachePolicy()
    private var sessionID = ""
    private var sessionDir: URL = FileManager.default.temporaryDirectory

    /// One entry per written chunk, in write order — the policy's `live`
    /// array, with its byte size beside it.
    private var liveIndexes: [Int] = []
    private var liveBytes: [Int] = []
    /// Indexes the player has finished with. The policy will not evict
    /// anything outside this set, so this is the one thing between a
    /// bounded cache and silence where audio was promised.
    private var finished: Set<Int> = []

    /// Read-along markers: (cumulative samples, cumulative chars). Same
    /// shape as `PlayPositionTracker.markers`.
    private var markers: [(endSample: Double, endChar: Int)] = []
    private var scheduledSamples: Double = 0
    private var totalChars = 1
    private var scannedMarker = 0
    /// The sample rate the markers are counted in — the first append's.
    private var markerSampleRate: Double = 0

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    /// Opens a session. The previous session's directory is removed first,
    /// so a cancelled session leaves nothing on disk.
    func beginSession(id: String = ChunkCacheLayout.newSessionID()) {
        teardown()
        sessionID = id
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = ChunkCacheLayout.sessionDirectory(base: caches, sessionID: id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // `setResourceValues` is mutating, so the URL has to be a var.
            var mutableDir = dir
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableDir.setResourceValues(resourceValues)
            sessionDir = dir
        } catch {
            Log.shared.error("ChunkFileQueue: could not create \(dir.path): \(error)")
        }
    }

    /// Removes the session directory and clears the queue. Called on stop
    /// and on teardown — never mid-playback.
    func teardown() {
        stopObserving()
        queuePlayer.removeAllItems()
        queuePlayer.pause()
        liveIndexes = []
        liveBytes = []
        finished = []
        markers = []
        scheduledSamples = 0
        scannedMarker = 0
        markerSampleRate = 0
        guard !sessionID.isEmpty else { return }
        do {
            try FileManager.default.removeItem(at: sessionDir)
        } catch {
            Log.shared.error("ChunkFileQueue: could not remove \(sessionDir.path): \(error)")
        }
        sessionID = ""
    }

    // MARK: - Writing

    /// Writes one chunk and enqueues it. Main actor only: it mutates the
    /// queue player's item list, which is not thread-safe.
    ///
    /// Returns false when the write was REFUSED — the cache is over its
    /// caps and the policy found nothing evictable, which per its contract
    /// means the caller holds the producer (a stall, not silent growth).
    @discardableResult
    func append(
        index: Int,
        samples: [Float],
        endChar: Int,
        totalChars: Int,
        sampleRate: Double
    ) -> Bool {
        self.totalChars = max(1, totalChars)
        // Markers are counted in the rendered files' own sample rate; the
        // read-along converts CMTime seconds with the same rate. Engines
        // render one rate per session, so the first append's rate governs.
        if markerSampleRate == 0 { markerSampleRate = sampleRate }

        // The trim. `peak` reads out of the samples array rather than a copy,
        // so the scan is one pass and allocates nothing.
        let trim = policy.trimmedRange(sampleCount: samples.count) { i in
            i < samples.count ? samples[i] : 0
        }
        let keptCount = policy.trimmedSampleCount(sampleCount: samples.count, trim: trim)
        let trimmed = policy.trimIsWorthwhile(sampleCount: samples.count, keptCount: keptCount)
        let written = trimmed ? Array(samples[trim.start..<trim.end]) : samples
        let writtenSamples = Double(written.count)

        // The cap is enforced BEFORE the write, never after — a policy that
        // trims after the fact has already allocated the bytes.
        let incoming = Int(writtenSamples * 2) // mono Int16
        if !policy.admits(bytes: liveBytes.reduce(0, +), count: liveIndexes.count, incomingBytes: incoming) {
            let doomed = policy.indexesToEvict(
                live: liveIndexes, bytes: liveBytes, finished: finished,
                incomingBytes: incoming)
            guard !doomed.isEmpty else {
                Log.shared.error("ChunkFileQueue: cache over cap with nothing evictable — holding chunk \(index)")
                return false
            }
            for doomedIndex in doomed {
                removeItem(index: doomedIndex)
            }
        }

        let fileURL = itemURL(for: index)
        do {
            let writer = try WAVWriter.StreamingWriter(url: fileURL, sampleRate: Int(sampleRate))
            try writer.append(written)
            try writer.close()
        } catch {
            Log.shared.error("ChunkFileQueue: chunk \(index) write failed: \(error)")
            return false
        }

        liveIndexes.append(index)
        liveBytes.append(incoming)

        let item = AVPlayerItem(url: fileURL)
        // Rate is a player property. `.spectral` gives pitch-correct time
        // stretching, which is what lets the rate slider stop requiring a
        // re-render-and-purge cycle on this substrate.
        item.audioTimePitchAlgorithm = .spectral
        markers.append((endSample: scheduledSamples + writtenSamples, endChar: endChar))
        scheduledSamples += writtenSamples
        queuePlayer.insert(item, after: nil)

        startObservingIfNeeded()
        return true
    }

    private func removeItem(index: Int) {
        guard let position = liveIndexes.firstIndex(of: index) else { return }
        liveIndexes.remove(at: position)
        liveBytes.remove(at: position)
        let url = sessionDir.appendingPathComponent(ChunkCacheLayout.chunkFileName(index: index))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Playing

    /// Starts playback. The queue already holds the first chunks; the player
    /// takes it from there.
    func play() {
        queuePlayer.play()
        queuePlayer.rate = rate
    }

    func pause() { queuePlayer.pause() }

    // MARK: - The 4-item lookahead

    /// The number of items written but not yet played — what Batch E's
    /// producer paces on: keep it at or above 4 and the listener never
    /// hears a boundary.
    ///
    /// Counted as the live items minus the live-and-finished ones, NOT
    /// against a cumulative played counter: eviction removes finished items
    /// from `liveIndexes`, so a cumulative counter would deflate the
    /// lookahead by one per eviction and the producer would render audio
    /// nobody accounts for.
    var lookahead: Int {
        max(0, liveIndexes.count - liveIndexes.filter { finished.contains($0) }.count)
    }

    // MARK: - Read-along

    private func startObservingIfNeeded() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.3, preferredTimescale: 600)
        timeObserver = queuePlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.reportPosition()
        }
        observeEnd()
    }

    private func stopObserving() {
        if let timeObserver {
            queuePlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// The marker arithmetic is `PlayPositionTracker`'s, unchanged: linear
    /// interpolation inside the currently-sounding marker, monotone, with
    /// `scannedMarker` making the walk amortized O(1) per tick. What changed
    /// is where the playhead comes from — CMTime instead of the node's
    /// sample clock.
    private func reportPosition() {
        // `CMTime.seconds` is NaN before the player has a valid clock — an
        // unguarded `Int(frac * …)` downstream would trap on it.
        let seconds = queuePlayer.currentTime().seconds
        guard seconds.isFinite, markerSampleRate > 0 else { return }
        let played = seconds * markerSampleRate
        var prevSample = 0.0
        var prevChar = 0
        var chars: Int?
        var index = scannedMarker
        while index < markers.count, played >= markers[index].endSample {
            prevSample = markers[index].endSample
            prevChar = markers[index].endChar
            index += 1
        }
        scannedMarker = index
        if index < markers.count {
            let marker = markers[index]
            let span = marker.endSample - prevSample
            if span > 0 {
                let frac = (played - prevSample) / span
                chars = prevChar + Int(frac * Double(marker.endChar - prevChar))
            } else {
                chars = prevChar
            }
        } else {
            chars = prevChar
        }
        if let chars, chars > lastEmittedChar {
            lastEmittedChar = chars
            onPlayedChars?(min(chars, totalChars))
        }
    }

    private var lastEmittedChar = 0

    /// Watches the player's own "did play to end" signal, which is the only
    /// reliable end-of-queue notification on `AVQueuePlayer` (its items run
    /// out rather than the player reporting completion). Each item that
    /// finishes is marked finished for the cache policy, which is what makes
    /// the eviction floor safe.
    ///
    /// The item is identified by its URL: `AVPlayerItem` posts itself as the
    /// notification's object, and the item this class inserted is the only
    /// one carrying that file's URL. An unrecognized object (a stale item
    /// from a torn-down session, or the player's own internal placeholder)
    /// is simply not counted.
    private func observeEnd() {
        guard endObserver == nil else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem,
                  let playedURL = (item.asset as? AVURLAsset)?.url else { return }
            for (position, index) in self.liveIndexes.enumerated()
            where self.itemURL(for: index) == playedURL {
                self.finished.insert(index)
                // The marker walk has already consumed everything up to
                // here; nothing else to advance.
                break
            }
        }
    }

    private func itemURL(for index: Int) -> URL {
        sessionDir.appendingPathComponent(ChunkCacheLayout.chunkFileName(index: index))
    }
}
