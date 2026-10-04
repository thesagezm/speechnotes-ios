import AVFoundation

/// Maps a player node's rendered samples to a played-character position
/// using the sample ranges of the scheduled buffers. Drives play-accurate
/// read-along highlighting: the v0.5 read-along highlighted at SCHEDULE
/// time, which led the audio by up to 3 chunks and drifted out of sync
/// (see HANDOVER). A 0.3 s heartbeat interpolates inside the sounding
/// chunk, so the position advances smoothly and never ahead of the audio.
///
/// Main-thread only: call from the same thread that schedules buffers (the
/// engines schedule on main) — the heartbeat timer also runs on main.
final class PlayPositionTracker {
    private let playerNode: AVAudioPlayerNode
    /// Fired with the played UTF-16 character count of the spoken string.
    var onPlayedChars: ((Int) -> Void)?
    /// Fired from the heartbeat with the node's played sample count in the
    /// tracker's current coordinate system (rebase-aware — see `report()`),
    /// for callers that think in audio time rather than characters: the
    /// streaming core's render-ahead bank drains on this.
    var onPlayedFrames: ((Int64) -> Void)?

    private var markers: [(endSample: Int64, endChar: Int)] = []
    private var scheduledEndSample: Int64 = 0
    private var lastNodeSample: Int64 = -1
    private var nodeSampleBase: Int64 = 0
    private var lastEmittedChar: Int = 0
    private var timer: Timer?
    private var totalChars = 1
    /// Lowest marker index not yet fully passed by playback — `report()`
    /// resumes its scan here instead of walking every marker from zero
    /// (a 200k-char chapter schedules ~1300 markers, 3 heartbeats a second).
    private var scannedMarker = 0

    init(playerNode: AVAudioPlayerNode) {
        self.playerNode = playerNode
    }

    /// Record a buffer's sample span right before it is scheduled.
    func willSchedule(buffer: AVAudioPCMBuffer, endChar: Int, totalChars: Int) {
        self.totalChars = max(1, totalChars)
        scheduledEndSample += Int64(buffer.frameLength)
        markers.append((endSample: scheduledEndSample, endChar: endChar))
        startHeartbeat()
    }

    /// The utterance's final buffer completed playing.
    func finish(totalChars: Int) {
        onPlayedChars?(totalChars)
    }

    /// Clear markers + heartbeat — on idle or a new speak.
    ///
    /// The played-sample coordinate system is re-zeroed against the node's
    /// LIVE clock, not just zeroed: `purgeStaleRateBuffers` resets the
    /// tracker mid-session while the node keeps playing, so a plain zero
    /// would make the next report read the whole running clock as played
    /// (bank accounting would see an empty bank forever and stop pacing).
    /// With `nodeSampleBase = -currentSample`, the next report is
    /// played-SINCE-reset. If the clock restarts afterwards (stop/play),
    /// the first-report heal in `report()` re-zeros the base exactly.
    ///
    /// The clock read is guarded on `engine != nil`: `AVAudioNode.
    /// lastRenderTime` THROWS the `_engine != nil` assertion when the node
    /// is not attached to an engine — which is the normal state of a fresh
    /// `speak()` (this reset runs before the first schedule has ever
    /// attached the node), and was the device crash on every play tap.
    func reset() {
        timer?.invalidate()
        timer = nil
        markers = []
        scheduledEndSample = 0
        if playerNode.engine != nil,
           let renderTime = playerNode.lastRenderTime,
           renderTime.isSampleTimeValid,
           let playerTime = playerNode.playerTime(forNodeTime: renderTime),
           playerTime.isSampleTimeValid {
            nodeSampleBase = -playerTime.sampleTime
        } else {
            nodeSampleBase = 0
        }
        lastNodeSample = -1
        lastEmittedChar = 0
        scannedMarker = 0
    }

    private func startHeartbeat() {
        guard timer == nil else { return }
        let heartbeat = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.report()
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
    }

    private func report() {
        guard playerNode.isPlaying else { return }
        // The heartbeat cannot fire for a node that was never attached (it
        // starts at willSchedule), but a rebuild/teardown racing a tick must
        // not reach the clock — the same `_engine != nil` assertion reset()
        // guards.
        guard playerNode.engine != nil else { return }
        guard let renderTime = playerNode.lastRenderTime,
              renderTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime),
              playerTime.isSampleTimeValid else { return }
        let sample = playerTime.sampleTime
        // A node restart resets its sample clock — rebase instead of walking
        // the markers backwards.
        if lastNodeSample >= 0, sample < lastNodeSample {
            nodeSampleBase += lastNodeSample
        }
        // First report after a reset whose node clock then RESTARTED (the
        // speak() case: reset read the old session's running clock, then
        // stop/play zeroed it). The stored base is negative and the fresh
        // clock starts below it — drop the base so played counts from the
        // restart instead of staying negative until the clock catches up.
        if lastNodeSample < 0, nodeSampleBase < 0, sample < -nodeSampleBase {
            nodeSampleBase = 0
        }
        lastNodeSample = sample
        let played = nodeSampleBase + sample
        onPlayedFrames?(played)

        var prevSample: Int64 = 0
        var prevChar = 0
        var chars: Int? = nil
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
                let frac = Double(played - prevSample) / Double(span)
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
}
