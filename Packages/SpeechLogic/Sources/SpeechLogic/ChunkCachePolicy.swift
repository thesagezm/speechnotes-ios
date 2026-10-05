//
//  ChunkCachePolicy.swift
//  SpeechLogic
//
//  Batch D: the file-queue substrate's policy — the part that can be
//  reasoned about without a device.
//
//  Approach 3 (render to file, play with AVQueuePlayer) treats TTS output
//  exactly like the app's music. That means the pipeline now writes files,
//  and a thing that writes files needs a disk policy, because unbounded
//  disk growth is what turns a TTS bug into "why is this app 4 GB" in the
//  App Store reviews.
//
//  This file is the arithmetic: the cap, the eviction order, the per-chunk
//  silence trim, and the session-directory naming. Pure functions, no
//  clocks, no I/O, no logging — the whole policy is assertable in CI, which
//  is the only reason it lives in SpeechLogic (see RenderAheadBankPolicy:
//  the app target has no test target, this package is the only one that
//  does). The AVQueuePlayer side lives in App/Sources/Engine/
//  ChunkFileQueue.swift and is deliberately NOT here — it cannot be tested
//  without a device.
//

import Foundation

/// The cache's eviction decision for one session's chunk files.
///
/// Two invariants, both load-bearing:
///
/// 1. **The cap is enforced BEFORE a write, never after.** A policy that
///    trims after the fact has already allocated the bytes; under a burst
///    of 20 s chunks that is the difference between a bounded cache and a
///    200 MB spike.
/// 2. **Only an item the player has FINISHED with may be evicted.** The
///    queue player holds the next few items enqueued; deleting a file under
///    a scheduled `AVPlayerItem` produces silence where audio was promised.
///    The policy therefore takes `finished` as an input rather than
///    guessing it.
public struct ChunkCachePolicy: Equatable {

    /// Most chunk files one session may hold on disk. Sized against a
    /// chapter: ~1300 chunks for a 200k-character chapter at 160 chars/chunk,
    /// so 240 is comfortably below one chapter while keeping the live window
    /// (which is ~4 items) far from the ceiling.
    public var maxItems: Int

    /// Hard ceiling on the session's bytes. At 24 kHz mono Int16 that is
    /// 48 KB/s, so 64 MB ≈ 22 minutes of audio — several chapters — while
    /// staying an order of magnitude under the 32 MB the render-ahead bank
    /// needed in RAM.
    public var maxBytes: Int

    /// Minimum number of chunks to keep even when the caps demand more
    /// eviction. The queue player needs its lookahead; a session whose
    /// cache evicted the item it was about to play would stall every time.
    public var floorItems: Int

    /// The number of samples that must be trimmed for the trim to be worth
    /// doing (see `trimIsWorthwhile`).
    public var minTrimSamples: Int

    public init(
        maxItems: Int = ChunkCachePolicy.defaultMaxItems,
        maxBytes: Int = ChunkCachePolicy.defaultMaxBytes,
        floorItems: Int = ChunkCachePolicy.defaultFloorItems,
        minTrimSamples: Int = ChunkCachePolicy.defaultMinTrimSamples
    ) {
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.floorItems = floorItems
        self.minTrimSamples = minTrimSamples
    }

    public static let defaultMaxItems = 240
    public static let defaultMaxBytes = 64 * 1024 * 1024
    /// 4 items ahead of the playhead is what the queue substrate keeps
    /// enqueued; 8 is twice that, so a full eviction round still leaves the
    /// player its window.
    public static let defaultFloorItems = 8
    /// 20 ms at 24 kHz. Below that the trim buys an extra decode seam for
    /// less than the ear can hear.
    public static let defaultMinTrimSamples = 480

    // MARK: - Eviction

    /// The item indexes that must be deleted before a new write of
    /// `incomingBytes` may proceed.
    ///
    /// `live` is the session's items in write order (index 0 is the oldest),
    /// `bytes` is each item's size, and `finished` is the set of indexes the
    /// player is done with. The result is the oldest finished items first —
    /// the only order that keeps the live window intact.
    ///
    /// When the caps cannot be satisfied (everything still live is
    /// unfinished), the result is empty: the caller then holds the producer
    /// rather than evicting an item the player may still need. That is a
    /// stall, not a corruption, and a stall is the failure mode this
    /// substrate can recover from.
    public func indexesToEvict(
        live: [Int],
        bytes: [Int],
        finished: Set<Int>,
        incomingBytes: Int
    ) -> [Int] {
        guard !live.isEmpty, live.count == bytes.count else { return [] }
        let totalBytes = bytes.reduce(0, +)
        let totalCount = live.count

        let countOverBy = max(0, (totalCount + 1) - maxItems)
        let bytesOverBy = max(0, totalBytes + incomingBytes - maxBytes)
        guard countOverBy > 0 || bytesOverBy > 0 else { return [] }

        var evict: [Int] = []
        var usedCount = totalCount
        var usedBytes = totalBytes
        for (position, index) in live.enumerated() {
            // Oldest first, and only what the player has finished with.
            guard finished.contains(index) else { continue }
            // The floor protects the queue player's lookahead; it is checked
            // per candidate, so a floor breach stops the walk rather than
            // being repaired afterwards.
            if usedCount - 1 < floorItems { break }
            evict.append(index)
            usedCount -= 1
            usedBytes -= bytes[position]
            // The count clause leaves room for the INCOMING write: the cap
            // is on the cache as the caller will hold it after the append,
            // so the walk stops with usedCount one short of maxItems.
            // (`<=` here made the steady-state cache maxItems + 1 items —
            // the round-2 critique's off-by-one, pinned by a test that
            // asserted the wrong count with it.)
            if usedCount < maxItems, usedBytes + incomingBytes <= maxBytes {
                break
            }
        }
        return evict
    }

    /// True when a write of `incomingBytes` is allowed without eviction.
    public func admits(bytes live: Int, count: Int, incomingBytes: Int) -> Bool {
        count < maxItems && live + incomingBytes <= maxBytes
    }

    // MARK: - Per-chunk silence trim

    /// The sample range of `samples` with baked leading and trailing
    /// silence removed.
    ///
    /// TTS engines bake silence into their output — Readest measured ~1.0 s
    /// per Edge utterance — and on a file queue that silence is a real gap
    /// the listener hears at every chunk boundary, because the boundary is
    /// a file transition with no crossfade. Ours is measured (see
    /// `trimmedRange`'s callers in ChunkFileQueue) rather than assumed; this
    /// function is the arithmetic, and it is the same arithmetic for every
    /// engine.
    ///
    /// - Parameters:
    ///   - threshold: amplitude below which a sample counts as silence, as a
    ///     fraction of full scale. 0.01 (−40 dB) is quiet enough that a
    ///     whispered vowel is never trimmed, loud enough that the dither
    ///     floor of a quantized render is.
    ///   - padding: samples kept past the last audible one, so the trim does
    ///     clip a plosive's onset.
    /// - Returns: The trimmed range as a half-open sample index pair.
    public func trimmedRange(
        sampleCount: Int,
        peak: (Int) -> Float,
        threshold: Float = 0.01,
        padding: Int = 480
    ) -> (start: Int, end: Int) {
        guard sampleCount > 0 else { return (0, 0) }
        var start = 0
        while start < sampleCount, abs(peak(start)) <= threshold {
            start += 1
        }
        guard start < sampleCount else { return (0, sampleCount) } // all silence — keep it all
        var end = sampleCount
        while end > start, abs(peak(end - 1)) <= threshold {
            end -= 1
        }
        let keepStart = max(0, start - padding)
        let keepEnd = min(sampleCount, end + padding)
        return (keepStart, keepEnd)
    }

    /// Samples the trim above KEEPS (`end - start`) — the caller feeds it
    /// to `trimIsWorthwhile` as `keptCount`. (`sampleCount` is not used in
    /// the arithmetic; it stays in the signature so a call site states the
    /// chunk it is trimming, and so a future floor on the kept fraction has
    /// the input at hand. The doc used to claim the REMOVED count —
    /// inverted — while every call site and test treated it as kept.)
    public func trimmedSampleCount(sampleCount: Int, trim: (start: Int, end: Int)) -> Int {
        max(0, trim.end - trim.start)
    }

    /// True when the trim actually removes enough to matter. Below the
    /// threshold the chunk is written whole: an extra decode seam is a real
    /// discontinuity, and it is not worth paying for 4 ms of silence.
    public func trimIsWorthwhile(sampleCount: Int, keptCount: Int) -> Bool {
        sampleCount - keptCount >= minTrimSamples
    }
}

/// Where a session's chunk files live.
///
/// `Caches/`, not `Documents/`: iOS may purge it under pressure, which is
/// exactly what a disposable render cache should do, and it is excluded
/// from backups by construction. The session subdirectory is removed
/// wholesale on stop/teardown, so a cancelled session leaves nothing —
/// which is the difference between "this app stores 200 MB of audio I
/// cannot see" and a render cache.
///
/// The app-side caller (`ChunkFileQueue`) owns the actual directory
/// creation, the `isExcludedFromBackup` flag and the purge-on-teardown;
/// this is the naming scheme, which is the part a test can pin.
public enum ChunkCacheLayout {

    /// `Caches/speechnotes-tts/<session>/`
    public static func sessionDirectory(base: URL, sessionID: String) -> URL {
        base
            .appendingPathComponent("speechnotes-tts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    /// A new session id. Milliseconds since epoch: time-ordered, so the
    /// oldest session is the first a purge would reclaim, and unique per
    /// process without a counter.
    public static func newSessionID(now: Date = Date()) -> String {
        "s\(Int(now.timeIntervalSince1970 * 1000))"
    }

    /// `<index>.wav` inside the session directory, zero-padded to six digits
    /// so a directory listing sorts the same way the player orders its queue
    /// — `000002.wav` does not sort before `000010.wav`.
    ///
    /// WAV, not CAF: `WAVWriter.StreamingWriter` already writes canonical
    /// 16-bit mono WAV and is CI-tested against the one-shot path, and
    /// `AVPlayer` plays it. A CAF variant is a two-line change to the writer
    /// if a device session shows a decode-latency difference.
    public static func chunkFileName(index: Int) -> String {
        String(format: "%06d.wav", index)
    }
}
