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
    func reset() {
        timer?.invalidate()
        timer = nil
        markers = []
        scheduledEndSample = 0
        lastNodeSample = -1
        nodeSampleBase = 0
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
        lastNodeSample = sample
        let played = nodeSampleBase + sample

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
