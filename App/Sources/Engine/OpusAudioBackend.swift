import AVFoundation
import SpeechLogic

/// The Ogg Opus half of `BookAudioBackend`.
///
/// iOS has no Ogg demuxer, so `AVPlayer` can never read a `.opus`/`.ogg`
/// audiobook — this backend reads the container itself (`OggReader`), decodes
/// its packets with Apple's own Opus codec (`OpusPacketDecoder` over
/// `AVAudioConverter`) and plays the PCM through an `AVAudioEngine` in the
/// same shape the TTS engines already use on device: one player node, an
/// `AVAudioUnitTimePitch` for speed with pitch correction, into the mixer.
///
/// Threading contract (mirrors `StreamingTTSPlaybackCore`):
///  - MAIN THREAD: engine/node management, load completion, seek, published
///    position. All BookAudioBackend entry points are called from there.
///  - `feedQueue`: packet decoding. It exclusively owns the
///    `OpusPacketDecoder` and hands buffers to `scheduleBuffer`, which is
///    thread-safe. Completion callbacks hop back to main.
///  - The lock guards the state both threads touch: `generation` — bumped on
///    every rearm so stale feed iterations die quietly — and
///    `scheduledEndSamples`, the content-sample watermark of everything
///    handed to the node since the last rearm.
///
/// Position: the node's sample clock counts CONTENT frames — the time-pitch
/// node downstream pulls rate-scaled, so `nodeClock / 48_000` is book time at
/// any speed. Content position = `baseSamples + nodeClock`, where `base` is
/// the granule of the first sample the current decoder emits; a seek stops
/// the node (clock back to zero), rebuilds the decoder at the target packet
/// and sets a matching base.
final class OpusAudioBackend: BookAudioBackend {

    var onDuration: ((Double) -> Void)?
    var onFailed: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var nodesAttached = false
    private var connectedFormat: AVAudioFormat?

    /// How far ahead of the ears the decoder may schedule — small enough to
    /// stay interactive at a seek, large enough that a thermal-throttled
    /// decode stretch never reaches the ears.
    private static let lookaheadSamples: Int64 = Int64(8 * 48_000)

    private let feedQueue = DispatchQueue(label: "com.speechnotes.opus-feed", qos: .userInitiated)

    private let lock = NSLock()
    private var generation = 0
    /// Content samples scheduled into the node since the current rearm.
    /// Written on the feed queue, read on both threads.
    private var scheduledEndSamples: Int64 = 0
    /// The feed queue reached the stream's end. Written on the feed queue.
    private var feedExhausted = false
    /// A decode error (never a clean end) — reported once, on main.
    private var decodeFailure: Error?
    /// PROBE (feed queue, lock-guarded): has the first decoded buffer been
    /// scheduled this rearm? A play tap that logs "playback start" but never
    /// "first buffer scheduled" means the DECODER produced nothing;
    /// both lines + silence means the decode works and the failure is
    /// downstream (graph/route).
    private var firstBufferScheduled = false

    private var stream: OpusPacketStream?
    /// Exclusively owned by `feedQueue`. Rebuilt by every rearm.
    private var decoder: OpusPacketDecoder?
    /// Content samples at the node clock's zero — the current decode start.
    private var baseSamples: Int64 = 0

    /// Route changes are the one event that tears a hand-wired
    /// `AVAudioEngine` down behind AVPlayer's back; AVPlayer rebuilds its own
    /// pipeline and never sees them, this one has to. The MEDIA-SERVICES
    /// reset is deliberately NOT observed here: `AudioBookPlayer` has its
    /// own observer that tears the backend down and cold-rebuilds it, and a
    /// backend-local report raced it while offering no recovery a backend
    /// can actually perform (its own `play()` no-ops once `streamLoaded` is
    /// false — the critique's P2 dead-rebuild).
    private var configChangeObserver: NSObjectProtocol?

    /// A seek that arrived before the stream finished loading
    /// (`AudioBookPlayer` commits a cold seek immediately; reading a long
    /// file loses that race) — applied the moment the load lands.
    private var pendingSeekTarget: Double?
    private var wantsPlayback = false
    private var streamLoaded = false

    /// The engine path plays through a pitch node — nothing buffers ahead of
    /// it, so "resume rate" and "live rate" are the same knob. `defaultRate`
    /// exists for protocol symmetry with AVPlayer.
    var defaultRate: Float {
        get { timePitch.rate }
        set { /* applied through `rate` */ }
    }

    var rate: Float {
        get { timePitch.rate }
        set {
            let clamped = max(0.5, min(3.0, newValue))
            timePitch.rate = clamped
            // Crossing the unity boundary re-routes the graph. The rate
            // applies to buffers scheduled AFTER the reconnect — the ones in
            // the node's queue keep their node-clock sample time, so position
            // stays continuous across the swap.
            if abs(clamped - 1.0) < 0.01 {
                if graphRoutesThroughTimePitch, node.engine != nil {
                    connectBypassingTimePitch()
                    if engine.isRunning, wantsPlayback, !node.isPlaying { node.play() }
                }
            } else {
                if !graphRoutesThroughTimePitch, node.engine != nil {
                    connectThroughTimePitch()
                    if engine.isRunning, wantsPlayback, !node.isPlaying { node.play() }
                }
            }
        }
    }

    var isRendering: Bool { engine.isRunning && node.isPlaying }

    /// True while a play() is in flight but the stream has not finished
    /// loading (a long file read can take a second or two). The player's
    /// ticker keeps the "playing" surface steady across this instead of
    /// flickering to paused and back.
    var isPreparingPlayback: Bool { wantsPlayback && !streamLoaded }

    var currentTime: Double? {
        guard streamLoaded else { return nil }
        // After a paused seek the node clock is zero — the base alone is the
        // honest playhead. Mid-pause (no seek) the clock is frozen where
        // pause() stopped it. Both fall out of the same sum.
        //
        // The engine guard is load-bearing: `lastRenderTime` THROWS the
        // `_engine != nil` assertion on a node that was never attached, and
        // the mini-player/Now Playing poll this property the moment the
        // stream loads — before the first play() has attached anything. That
        // was the device crash on every book open whose decode had failed.
        if node.engine != nil,
           let renderTime = node.lastRenderTime,
           renderTime.isSampleTimeValid,
           let nodeTime = node.playerTime(forNodeTime: renderTime),
           nodeTime.isSampleTimeValid {
            return Double(baseSamples + nodeTime.sampleTime) / 48_000
        }
        return Double(baseSamples) / 48_000
    }

    // MARK: Load

    /// A valid Ogg container that carries something the app cannot decode
    /// (Vorbis, FLAC, Speex) — distinct from a parse failure.
    struct NotOpusError: LocalizedError {
        let codec: String
        var errorDescription: String? {
            "This Ogg stream holds \(codec), not Opus — the reader cannot decode it."
        }
    }

    /// Reads and parses the whole Ogg stream off-main, then reports its
    /// duration. A parse failure is permanent — `onFailed` fires and the
    /// reader shows why.
    ///
    /// 2026-10-08 device log: the eager `OggReader.read` holds every
    /// packet's bytes, so the 11-hour full-cast book (1.7 GB) died at the
    /// load with `NSPOSIXErrorDomain Code=12, cannot allocate memory` —
    /// before a single sample decoded. The lazy walk keeps granules and
    /// byte ranges only (~80 MB for 2 M packets) and reads each payload
    /// from the MAPPED file on demand, so peak memory is one chunk no
    /// matter what the book weighs.
    func loadOgg(url: URL) {
        let generation0 = nextGeneration()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let stream = try OggReader.readLazy(url: url)
                DispatchQueue.main.async { [weak self] in
                    self?.streamDidLoad(stream, generation: generation0)
                }
            } catch let error as OggReader.NotOpusStreamError {
                DispatchQueue.main.async { [weak self] in
                    self?.streamDidFail(NotOpusError(codec: error.codec), generation: generation0)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.streamDidFail(error, generation: generation0)
                }
            }
        }
    }

    /// The Opus-in-MP4 path: demux the sample table off-main. Same failure
    /// contract as `loadOgg`.
    func loadOpusInMp4(url: URL) {
        let generation0 = nextGeneration()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try Data(contentsOf: url)
                let stream = try Mp4OpusReader.read(data)
                DispatchQueue.main.async { [weak self] in
                    self?.streamDidLoad(stream, generation: generation0)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.streamDidFail(error, generation: generation0)
                }
            }
        }
    }

    /// Main thread only.
    private func streamDidLoad(_ loaded: OpusPacketStream, generation generation0: Int) {
        guard generation == generation0 else { return }
        stream = loaded
        streamLoaded = true
        Log.shared.info(
            "OpusAudioBackend: stream ready — \(loaded.packets.count) packets, " +
            String(format: "%.1f", loaded.duration) + "s, pre-skip \(loaded.preSkip), " +
            "\(loaded.channels)ch"
        )
        onDuration?(loaded.duration)
        rearmDecoder(at: pendingSeekTarget ?? 0)
        pendingSeekTarget = nil
        if wantsPlayback { startPlayback() }
    }

    /// Main thread only.
    private func streamDidFail(_ error: Error, generation generation0: Int) {
        guard generation == generation0 else { return }
        Log.shared.error("OpusAudioBackend: stream load failed — \(error)")
        onFailed?(error)
    }

    // MARK: BookAudioBackend (main thread)

    func play() {
        wantsPlayback = true
        guard streamLoaded else { return }  // startPlayback fires when the load lands
        startPlayback()
    }

    func pause() {
        wantsPlayback = false
        guard streamLoaded else { return }
        node.pause()
    }

    func seek(to seconds: Double, tolerance: Double) {
        guard streamLoaded else {
            pendingSeekTarget = max(0, seconds)
            return
        }
        // The node's old scheduled buffers die with it — a seek's first
        // sample must never queue up behind the old position's audio.
        node.stop()
        rearmDecoder(at: seconds)
        if wantsPlayback { startPlayback() }
    }

    func stop() {
        _ = nextGeneration()
        wantsPlayback = false
        streamLoaded = false
        node.stop()
        engine.stop()
        stream = nil
        decoder = nil
        pendingSeekTarget = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        lock.lock()
        scheduledEndSamples = 0
        feedExhausted = false
        decodeFailure = nil
        firstBufferScheduled = false
        lock.unlock()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    // MARK: Rearm — the load path and every seek come through here

    /// Rebuilds the pipeline at `seconds`: a fresh decoder at the packet that
    /// owns that instant, and a node-clock base that places its first output
    /// sample on the timeline. Main thread.
    private func rearmDecoder(at seconds: Double) {
        guard let stream else { return }
        let target = min(max(0, seconds), max(0, stream.duration - 0.01))
        let packetIndex = stream.packetIndex(at: target)
        let firstAudio = stream.packets.firstIndex { $0.granule > 0 } ?? 0
        // A decode starting at the stream's first audio packet consumes the
        // pre-skip; a mid-stream start does not — its own granule already
        // places it on the timeline.
        let drop = packetIndex <= firstAudio ? stream.preSkip : 0
        do {
            decoder = try OpusPacketDecoder(
                stream: stream,
                startAtPacket: packetIndex,
                dropSamples: drop
            )
        } catch {
            Log.shared.error("OpusAudioBackend: decoder rearm failed — \(error)")
            onFailed?(error)
            return
        }
        // The first output sample of packet `packetIndex` sits where the
        // PREVIOUS packet's granule ended (its start), minus pre-skip.
        let baseGranule: UInt64 = packetIndex > 0 ? stream.packets[packetIndex - 1].granule : UInt64(stream.preSkip)
        baseSamples = max(0, Int64(baseGranule) - Int64(stream.preSkip))

        lock.lock()
        scheduledEndSamples = 0
        feedExhausted = false
        decodeFailure = nil
        firstBufferScheduled = false
        lock.unlock()
        _ = nextGeneration()
        pump()
    }

    // MARK: Engine + feed

    /// Main thread.
    private func startPlayback() {
        guard let decoder else { return }
        // PROBE: the device log from an Opus play tap has never gone deeper
        // than "stream ready" — without this line a silent failure cannot be
        // placed between "engine never started" and "engine ran, no sound".
        Log.shared.info(
            "OpusAudioBackend: playback start — \(Int(decoder.format.sampleRate)) Hz, " +
            "\(decoder.format.channelCount)ch, rate \(rate)"
        )
        AudioSessionSetup.configureAndActivate(source: .audiobook, prefix: "OpusAudioBackend")
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main
            ) { [weak self] _ in self?.handleEngineConfigurationChange() }
        }
        if !nodesAttached {
            engine.attach(node)
            engine.attach(timePitch)
            nodesAttached = true
        }
        // AVAudioUnitTimePitch is a phase-vocoder: even at rate 1.0 it
        // re-synthesizes every buffer through its FFT overlap-add, and that
        // pass is audibly lossy on speech ("something is lost quality wise",
        // 2026-10-08 — the same class of smear AVAudioUnitTimePitch adds to
        // music). At unity the graph bypasses it: player → mixer. Any other
        // rate re-connects through it, and `rate`'s setter keeps working on
        // the bypass because `connectTimePitch` re-routes on the next
        // non-unity rate.
        if abs(rate - 1.0) < 0.01 {
            connectBypassingTimePitch()
        } else {
            connectThroughTimePitch()
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                Log.shared.error("OpusAudioBackend: engine failed to start — \(error)")
                onFailed?(error)
                return
            }
        }
        // Re-assert on every start: an interruption or route change can leave
        // the session inactive behind our back, and a configured-but-inactive
        // session is suspended seconds after the app backgrounds.
        AudioSessionSetup.activate(prefix: "OpusAudioBackend")
        timePitch.rate = rate
        if !node.isPlaying {
            node.play()
        }
        pump()
    }

    /// Which graph the player node feeds. `graphRoutesThroughTimePitch` is
    /// the one piece of connect-state the rate path needs — `connectedFormat`
    /// alone cannot tell "connected straight to the mixer" from "connected
    /// through time-pitch", and a rate change that assumed the wrong one
    /// would leave the node feeding a detached filter.
    private var graphRoutesThroughTimePitch = false

    private func connectBypassingTimePitch() {
        guard let decoder else { return }
        if !graphRoutesThroughTimePitch, connectedFormat == decoder.format { return }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: decoder.format)
        connectedFormat = decoder.format
        graphRoutesThroughTimePitch = false
    }

    private func connectThroughTimePitch() {
        guard let decoder else { return }
        if graphRoutesThroughTimePitch, connectedFormat == decoder.format { return }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: timePitch, format: decoder.format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: decoder.format)
        connectedFormat = decoder.format
        graphRoutesThroughTimePitch = true
    }

    /// The hardware sample rate changed under us. Repair the graph REGARDLESS
    /// of playback state — a resume against a graph invalidated by the route
    /// change is the silent-node condition (the same commit's own comment in
    /// StreamingTTSPlaybackCore explains why a format match proves nothing).
    /// A PAUSED backend stays paused: no session activation (re-activating
    /// with nothing to resume steals the session from whatever the user
    /// played during the route change), no node.play, no engine start.
    private func handleEngineConfigurationChange() {
        Log.shared.info("OpusAudioBackend: engine configuration change — reconnecting")
        guard let decoder else { return }
        // Force the reconnect: a configuration change can invalidate the
        // graph even when the node→mixer format is unchanged. The rebuilt
        // graph keeps the CURRENT routing (bypass at unity rate, time-pitch
        // otherwise) — a config change must not silently re-introduce the
        // phase-vocoder the rate path deliberately removed.
        if abs(timePitch.rate - 1.0) < 0.01 {
            connectedFormat = nil
            graphRoutesThroughTimePitch = true   // so connectBypassing actually rewires
            connectBypassingTimePitch()
        } else {
            connectedFormat = nil
            graphRoutesThroughTimePitch = false
            connectThroughTimePitch()
        }
        engine.prepare()
        guard wantsPlayback else { return }
        AudioSessionSetup.activate(prefix: "OpusAudioBackend")
        if !engine.isRunning {
            do { try engine.start() } catch {
                Log.shared.error("OpusAudioBackend: restart after configuration change failed — \(error)")
                onFailed?(error)
                return
            }
        }
        if !node.isPlaying { node.play() }
        pump()
    }

    /// Refills the schedule-ahead window: captures the current decoder +
    /// generation and hands them to the feed queue. Main thread.
    private func pump() {
        guard let decoder else { return }
        let generation0 = generation
        feedQueue.async { [weak self] in
            self?.feed(decoder: decoder, generation: generation0)
        }
    }

    /// Feed-queue only. Decodes chunks until the lookahead window is full,
    /// the stream ends, or a newer generation takes over.
    private func feed(decoder: OpusPacketDecoder, generation generation0: Int) {
        while true {
            lock.lock()
            if generation != generation0 || feedExhausted {
                lock.unlock()
                return
            }
            lock.unlock()

            var chunk: AVAudioPCMBuffer?
            do {
                chunk = try decoder.decodeChunk(packetLimit: 64)
            } catch {
                lock.lock()
                if generation == generation0 {
                    decodeFailure = error
                    feedExhausted = true
                }
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation0 else { return }
                    self.onFailed?(error)
                }
                return
            }
            guard let chunk else {
                // Clean end of stream. The published playhead now sits at the
                // duration, so the player's chapter-end logic takes over.
                lock.lock()
                if generation == generation0 { feedExhausted = true }
                lock.unlock()
                return
            }

            let frames = Int64(chunk.frameLength)
            lock.lock()
            let first = !firstBufferScheduled
            firstBufferScheduled = true
            lock.unlock()
            if first {
                Log.shared.info("OpusAudioBackend: first buffer scheduled (\(frames) frames) — decode confirmed live")
            }
            node.scheduleBuffer(chunk) { [weak self] in
                // A buffer finished: the window has room again.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation0 else { return }
                    if self.wantsPlayback, self.node.isPlaying { self.pump() }
                }
            }
            lock.lock()
            scheduledEndSamples += frames
            let ahead = scheduledEndSamples - nodeClockSamples()
            lock.unlock()
            if ahead < Self.lookaheadSamples { continue }
            return
        }
    }

    /// The node's consumed content samples since the current rearm. Thread-
    /// safe to read; 0 while the node has no clock (stopped, paused before
    /// first play). The engine check keeps the read legal on a node that was
    /// never attached — `lastRenderTime` asserts `_engine != nil` on one,
    /// and the feed queue calls this after its first schedule, which can
    /// land before any play() (a book open without playback).
    private func nodeClockSamples() -> Int64 {
        guard node.engine != nil,
              let renderTime = node.lastRenderTime,
              renderTime.isSampleTimeValid,
              let nodeTime = node.playerTime(forNodeTime: renderTime),
              nodeTime.isSampleTimeValid else { return 0 }
        return max(0, nodeTime.sampleTime)
    }

    private func nextGeneration() -> Int {
        lock.lock()
        generation += 1
        let value = generation
        lock.unlock()
        return value
    }
}
