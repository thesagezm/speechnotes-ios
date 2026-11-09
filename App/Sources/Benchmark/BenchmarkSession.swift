import AVFoundation
import Darwin
import Foundation
import SpeechLogic
import UIKit

/// Sustained-synthesis benchmark session (Phase 3, Docs/PHASE3-BENCHMARK-HARNESS.md).
///
/// Drives ONE engine instance (owned exclusively — never handed to
/// SpeechPlayer) through its benchmark seam on a serial queue, with NO audio
/// output: chunk → samples → dropped. Per chunk it records generation time,
/// audio seconds, RTF, token/step counts, thermal state, and the latest
/// sampler readings (CPU %, `phys_footprint`, `os_proc_available_memory`).
/// At the end it writes a CSV (per-chunk) + JSON (metadata + summary) pair
/// and reports the URLs.
///
/// Threading: all synthesis + sampling on `queue`; everything that touches
/// UIKit / AVAudioSession / @Published on main.
final class BenchmarkSession {
    // MARK: - Result models (internal — BenchmarkExport encodes them)

    struct ChunkRow: Codable {
        let chunk: Int
        let loop: Int
        let wallSeconds: Double
        let chars: Int
        let tokenCount: Int?
        let steps: Int?
        let genSeconds: Double
        let audioSeconds: Double
        let rtf: Double
        let footprintMB: Double?
        let availableMB: Double?
        let cpuPercent: Double?
        let thermal: String
    }

    struct ThermalTransition: Codable {
        let atSeconds: Double
        let from: String
        let to: String
    }

    struct BatterySample: Codable {
        let levelPercent: Double?
        let state: String
    }

    struct Summary: Codable {
        // Provenance — every export must be attributable without the chat log.
        let appVersion: String
        let appBuild: String
        let deviceModel: String
        let osVersion: String
        let ortVersion: String
        let coremltoolsVersion: String?
        let engineTier: String
        let engineLabel: String
        let intraOpThreads: Int?
        let speed: Float
        let mode: String
        let corpusId: String
        let corpusSha256: String
        let corpusChars: Int
        // Timing
        let modelLoadSeconds: Double
        let modelWasWarm: Bool
        let firstChunkSeconds: Double
        let totalWallSeconds: Double
        let totalGenSeconds: Double
        let totalAudioSeconds: Double
        let meanRTF: Double?
        let medianRTF: Double?
        let p95RTF: Double?
        let rtfAt25: Double?
        let rtfAt50: Double?
        let rtfAt75: Double?
        /// True when the overall mean RTF is ≥ 35 % above the first temporal
        /// quartile's mean — the app's own throttling signature (Batch A).
        let throttleSignature: Bool
        // Resources
        let cpuMeanPercent: Double?
        let cpuMaxPercent: Double?
        let cpuSeconds: Double?
        let footprintMeanMB: Double?
        let footprintMaxMB: Double?
        let availableMinMB: Double?
        let batteryStart: BatterySample
        let batteryEnd: BatterySample
        let thermalStart: String
        let thermalEnd: String
        let thermalTransitions: [ThermalTransition]
        // Counts
        let chunks: Int
        let loops: Int
        let errors: Int
        let errorMessages: [String]
    }

    struct ExportResult {
        let csvURL: URL
        let jsonURL: URL
        let summary: Summary
    }

    /// One 1 Hz sampler tick. Only the run loop and the sampler see this.
    fileprivate struct CPUReading {
        let snapshot: CPULoadSnapshot
        var busyPercent: Double?
        let footprintMB: Double?
        let availableMB: Double?
        let thermal: String
    }

    // MARK: - Config + callbacks

    private let config: BenchmarkConfig
    /// Posted on the MAIN thread, per chunk.
    var onLive: ((BenchmarkLive) -> Void)?
    /// Posted on the MAIN thread once, at the end (success or failure).
    var onFinish: ((Result<ExportResult, Error>) -> Void)?
    /// Posted on the MAIN thread when the stop button state changes.
    var onStopChanged: ((Bool) -> Void)?

    // MARK: - State

    private let queue = DispatchQueue(label: "com.speechnotes.benchmark", qos: .userInitiated)
    private var stopRequested = false
    private var running = false
    private let audioKeeper = BenchmarkAudioKeeper()
    private var samplerTimer: DispatchSourceTimer?
    private var sampler: Sampler?

    private var kokoro: OnnxKokoroEngine?
    private var supertonic: SupertonicEngine?

    init(config: BenchmarkConfig) {
        self.config = config
    }

    var isRunning: Bool { running }

    // MARK: - Control

    func start() {
        guard !running else { return }
        running = true
        stopRequested = false
        onStopChanged?(true)

        // Battery + thermal baselines are read on MAIN (UIDevice contract).
        let batteryStart = BatteryReader.read()
        let thermalStart = Self.thermalName(ProcessInfo.processInfo.thermalState)

        // The silent loop owns the background-audio assertion; it must be up
        // BEFORE the screen goes off in a battery run.
        audioKeeper.start()

        queue.async { [weak self] in
            self?.run(batteryStart: batteryStart, thermalStart: thermalStart)
        }
    }

    /// Stop between chunks: the partial session is a VALID result (a stopped
    /// run still exports its rows and summary), so stop routes through the
    /// normal finish path.
    func stop() {
        queue.async { [weak self] in
            self?.stopRequested = true
        }
    }

    // MARK: - The run loop (benchQueue)

    private func run(batteryStart: BatterySample, thermalStart: String) {
        let clock = ContinuousClock()
        var errors = 0
        var errorMessages: [String] = []
        var rows: [ChunkRow] = []

        func recordError(_ message: String) {
            errors += 1
            if errorMessages.count < 5 {
                errorMessages.append(message)
            }
            Log.shared.error("Benchmark: \(message)")
        }

        do {
            // 1. Engine construction. The instance is owned exclusively by
            // this session.
            switch config.tier {
            case .kokoroFP32:
                let engine = OnnxKokoroEngine(
                    modelFileURL: ModelManager.onnxModelFileURL,
                    modelFilesValid: { ModelManager.onnxFilesAreValid() }
                )
                engine.benchmarkIntraOpThreads = config.intraOpThreads
                kokoro = engine
            case .kokoroCompact:
                let engine = OnnxKokoroEngine(
                    modelFileURL: ModelManager.smallModelFileURL,
                    modelFilesValid: { ModelManager.smallFilesAreValid() }
                )
                engine.benchmarkIntraOpThreads = config.intraOpThreads
                kokoro = engine
            case .supertonicHigh, .supertonicBalanced:
                let engine = SupertonicEngine()
                engine.benchmarkIntraOpThreads = config.intraOpThreads
                supertonic = engine
            }

            // 2. Model load — COLD by construction: every session builds a
            // fresh engine instance, so `modelLoadSeconds` is always the
            // cold number. Warm numbers come from running the benchmark a
            // second time in the same app launch (the protocol's rule).
            let loadStarted = Date()
            let prepared: Bool
            switch config.tier {
            case .kokoroFP32, .kokoroCompact:
                prepared = kokoro?.benchmarkPrepare() ?? false
            case .supertonicHigh, .supertonicBalanced:
                prepared = supertonic?.benchmarkPrepare() ?? false
            }
            guard prepared else {
                throw BenchmarkError.modelNotAvailable(config.tier)
            }
            let modelLoadSeconds = Date().timeIntervalSince(loadStarted)

            // 3. Chunk once, then loop the SAME chunks until the duration
            // target — identical text per loop is what makes the RTF curve
            // a thermal signature rather than a text artifact.
            let chunks = SentenceChunker.chunks(
                for: BenchmarkCorpus.text,
                firstMaxChars: config.tier.firstChunkChars,
                batchMaxChars: config.tier.batchChunkChars
            )
            guard !chunks.isEmpty else { throw BenchmarkError.emptyCorpus }

            let sampler = Sampler(queue: queue, sessionStart: clock.now)
            self.sampler = sampler
            sampler.start()

            let sessionStart = clock.now
            var loopIndex = 0
            var chunkCounter = 0
            var firstChunkSeconds = 0.0

            outer: while !stopRequested {
                for chunk in chunks {
                    if stopRequested { break outer }
                    let wall = Self.seconds(from: sessionStart, to: clock.now)
                    if wall >= config.durationSeconds { break outer }

                    let genStart = clock.now
                    let result: (sampleCount: Int, sampleRate: Double, tokenCount: Int?)
                    do {
                        result = try synthesize(chunk.text)
                    } catch {
                        // A failed chunk is a datapoint, not a session killer —
                        // unless nothing ever succeeded.
                        recordError("chunk \(chunkCounter) (loop \(loopIndex)) failed: \(error.localizedDescription)")
                        if rows.isEmpty && chunkCounter == 0 {
                            throw BenchmarkError.firstChunkFailed(error)
                        }
                        chunkCounter += 1
                        continue
                    }
                    let genSeconds = Self.seconds(from: genStart, to: clock.now)
                    let audioSeconds = Double(result.sampleCount) / result.sampleRate
                    let rtf = audioSeconds > 0 ? genSeconds / audioSeconds : 0
                    if chunkCounter == 0 {
                        firstChunkSeconds = genSeconds
                    }

                    let reading = sampler.readings.last
                    let row = ChunkRow(
                        chunk: chunkCounter,
                        loop: loopIndex,
                        wallSeconds: wall,
                        chars: chunk.text.count,
                        tokenCount: result.tokenCount,
                        steps: config.tier.flowSteps,
                        genSeconds: genSeconds,
                        audioSeconds: audioSeconds,
                        rtf: rtf,
                        footprintMB: reading?.footprintMB,
                        availableMB: reading?.availableMB,
                        cpuPercent: reading?.busyPercent,
                        thermal: reading?.thermal ?? Self.thermalName(ProcessInfo.processInfo.thermalState)
                    )
                    rows.append(row)
                    chunkCounter += 1

                    let live = BenchmarkLive(
                        chunks: chunkCounter,
                        loops: loopIndex,
                        elapsedSeconds: wall,
                        meanRTF: BenchmarkMath.mean(rows.map(\.rtf)) ?? 0,
                        latestCPUPercent: reading?.busyPercent,
                        latestFootprintMB: reading?.footprintMB,
                        thermal: reading?.thermal ?? "nominal"
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.onLive?(live)
                    }
                }
                loopIndex += 1
                // Defensive cap — the wall check already bounds this.
                if loopIndex > 10_000 { break }
            }

            sampler.stop()

            let totalWall = Self.seconds(from: sessionStart, to: clock.now)
            guard !rows.isEmpty else { throw BenchmarkError.noSuccessfulChunks }

            // Everything past this point hops to MAIN: battery/thermal end
            // readings (UIDevice contract), session teardown, export, and the
            // finish callback. The run-loop locals are value-captured.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                self.audioKeeper.stop()
                self.onStopChanged?(false)

                let batteryEnd = BatteryReader.read()
                let thermalEnd = Self.thermalName(ProcessInfo.processInfo.thermalState)
                let summary = Self.buildSummary(
                    config: self.config,
                    rows: rows,
                    cpuReadings: self.sampler?.readings ?? [],
                    thermalTransitions: self.sampler?.transitions ?? [],
                    modelLoadSeconds: modelLoadSeconds,
                    firstChunkSeconds: firstChunkSeconds,
                    totalWallSeconds: totalWall,
                    batteryStart: batteryStart,
                    batteryEnd: batteryEnd,
                    thermalStart: thermalStart,
                    thermalEnd: thermalEnd,
                    loops: loopIndex,
                    errors: errors,
                    errorMessages: errorMessages
                )
                do {
                    let export = try BenchmarkExport.write(rows: rows, summary: summary)
                    Log.shared.info("Benchmark: complete — \(summary.chunks) chunks, mean RTF \(summary.meanRTF.map { String(format: "%.3f", $0) } ?? "?"), exported to \(export.csvURL.lastPathComponent) + .json")
                    self.onFinish?(.success(export))
                } catch {
                    self.onFinish?(.failure(error))
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                self.audioKeeper.stop()
                self.onStopChanged?(false)
                self.onFinish?(.failure(error))
            }
        }
    }

    private func synthesize(_ text: String) throws
        -> (sampleCount: Int, sampleRate: Double, tokenCount: Int?)
    {
        switch config.tier {
        case .kokoroFP32, .kokoroCompact:
            guard let kokoro else { throw BenchmarkError.modelNotAvailable(config.tier) }
            return try kokoro.benchmarkSynthesize(text: text, speed: config.speed)
        case .supertonicHigh, .supertonicBalanced:
            guard let supertonic else { throw BenchmarkError.modelNotAvailable(config.tier) }
            return try supertonic.benchmarkSynthesize(
                text: text,
                speed: config.speed,
                steps: config.tier.flowSteps ?? 8
            )
        }
    }

    // MARK: - Sampling

    /// The 1 Hz sampler: Mach CPU ticks, footprint, available memory, and
    /// thermal state — with transitions recorded as they flip.
    private final class Sampler {
        fileprivate private(set) var readings: [CPUReading] = []
        fileprivate private(set) var transitions: [ThermalTransition] = []
        private let queue: DispatchQueue
        private let sessionStart: ContinuousClock.Instant
        private var timer: DispatchSourceTimer?
        private var lastThermal: String

        init(queue: DispatchQueue, sessionStart: ContinuousClock.Instant) {
            self.queue = queue
            self.sessionStart = sessionStart
            self.lastThermal = BenchmarkSession.thermalName(ProcessInfo.processInfo.thermalState)
        }

        func start() {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.tick()
            }
            timer.resume()
            self.timer = timer
        }

        func stop() {
            timer?.cancel()
            timer = nil
        }

        private func tick() {
            var reading = CPUReading(
                snapshot: BenchmarkSession.cpuSnapshot(),
                busyPercent: nil,
                footprintMB: ProcessMemory.footprintBytes().map { Double($0) / 1_048_576 },
                availableMB: ProcessMemory.availableBytes().map { Double($0) / 1_048_576 },
                thermal: BenchmarkSession.thermalName(ProcessInfo.processInfo.thermalState)
            )
            if let previous = readings.last {
                reading.busyPercent = BenchmarkMath.cpuBusyPercent(
                    previous: previous.snapshot,
                    current: reading.snapshot
                )
            }
            if reading.thermal != lastThermal {
                transitions.append(ThermalTransition(
                    atSeconds: BenchmarkSession.seconds(from: sessionStart, to: ContinuousClock.now),
                    from: lastThermal,
                    to: reading.thermal
                ))
                lastThermal = reading.thermal
            }
            readings.append(reading)
        }
    }

    /// Aggregated Mach CPU ticks across all cores. Indices into
    /// `processor_cpu_load_info` are CPU_STATE_USER(0), SYSTEM(1), IDLE(2),
    /// NICE(3) — spelled literally because the C enum does not import into
    /// Swift.
    fileprivate static func cpuSnapshot() -> CPULoadSnapshot {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuMsgCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuMsgCount
        )
        guard kr == KERN_SUCCESS, let info = cpuInfo, cpuCount > 0 else {
            return .zero
        }
        defer {
            let byteCount = vm_size_t(cpuMsgCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: UnsafeRawPointer(info))),
                byteCount
            )
        }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            user += UInt64(max(0, info[base + 0]))
            system += UInt64(max(0, info[base + 1]))
            idle += UInt64(max(0, info[base + 2]))
            nice += UInt64(max(0, info[base + 3]))
        }
        return CPULoadSnapshot(user: user, system: system, idle: idle, nice: nice)
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    /// Elapsed seconds from `start` to `end`.
    static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Summary

    private static func buildSummary(
        config: BenchmarkConfig,
        rows: [ChunkRow],
        cpuReadings: [CPUReading],
        thermalTransitions: [ThermalTransition],
        modelLoadSeconds: Double,
        firstChunkSeconds: Double,
        totalWallSeconds: Double,
        batteryStart: BatterySample,
        batteryEnd: BatterySample,
        thermalStart: String,
        thermalEnd: String,
        loops: Int,
        errors: Int,
        errorMessages: [String]
    ) -> Summary {
        let rtfs = rows.map(\.rtf)
        // Temporal quartiles (the Batch A convention): mean of the RTFs in
        // each quarter of the session's chunks, in time order — the shape a
        // thermal throttle draws.
        func temporalQuartileMean(_ quarter: Int) -> Double? {
            let n = rows.count
            guard n >= 4 else { return nil }
            let lower = n * (quarter - 1) / 4
            let upper = max(lower + 1, n * quarter / 4)
            return BenchmarkMath.mean(Array(rtfs[lower..<upper]))
        }
        let rtfAt25 = temporalQuartileMean(1)
        let overallMean = BenchmarkMath.mean(rtfs)
        let throttle = (overallMean != nil && rtfAt25 != nil && rtfAt25! > 0)
            ? overallMean! >= 1.35 * rtfAt25!
            : false

        let busyPercents = cpuReadings.compactMap(\.busyPercent)
        let footprints = cpuReadings.compactMap(\.footprintMB)
        let availables = cpuReadings.compactMap(\.availableMB)
        // CPU-seconds: mean busy % integrated over the session's wall time.
        let cpuSeconds = BenchmarkMath.mean(busyPercents).map { $0 / 100 * totalWallSeconds }

        let info = DeviceInfo.current()

        return Summary(
            appVersion: info.appVersion,
            appBuild: info.appBuild,
            deviceModel: info.deviceModel,
            osVersion: info.osVersion,
            ortVersion: "1.24.2 (SPM pin)",
            coremltoolsVersion: nil,
            engineTier: config.tier.rawValue,
            engineLabel: config.tier.label,
            intraOpThreads: config.intraOpThreads,
            speed: config.speed,
            mode: "synthesis",
            corpusId: BenchmarkCorpus.id,
            corpusSha256: BenchmarkCorpus.sha256Hex,
            corpusChars: BenchmarkCorpus.chars,
            modelLoadSeconds: modelLoadSeconds,
            modelWasWarm: false,
            firstChunkSeconds: firstChunkSeconds,
            totalWallSeconds: totalWallSeconds,
            totalGenSeconds: rows.reduce(0) { $0 + $1.genSeconds },
            totalAudioSeconds: rows.reduce(0) { $0 + $1.audioSeconds },
            meanRTF: overallMean,
            medianRTF: BenchmarkMath.median(rtfs),
            p95RTF: BenchmarkMath.percentile(rtfs, 0.95),
            rtfAt25: rtfAt25,
            rtfAt50: temporalQuartileMean(2),
            rtfAt75: temporalQuartileMean(3),
            throttleSignature: throttle,
            cpuMeanPercent: BenchmarkMath.mean(busyPercents),
            cpuMaxPercent: busyPercents.max(),
            cpuSeconds: cpuSeconds,
            footprintMeanMB: BenchmarkMath.mean(footprints),
            footprintMaxMB: footprints.max(),
            availableMinMB: availables.min(),
            batteryStart: batteryStart,
            batteryEnd: batteryEnd,
            thermalStart: thermalStart,
            thermalEnd: thermalEnd,
            thermalTransitions: thermalTransitions,
            chunks: rows.count,
            loops: loops,
            errors: errors,
            errorMessages: errorMessages
        )
    }
}

// MARK: - Supporting types

enum BenchmarkError: LocalizedError {
    case modelNotAvailable(BenchmarkTier)
    case emptyCorpus
    case firstChunkFailed(Error)
    case noSuccessfulChunks

    var errorDescription: String? {
        switch self {
        case .modelNotAvailable(let tier):
            return "The \(tier.label) model is not downloaded or failed to load."
        case .emptyCorpus:
            return "The benchmark corpus chunked to nothing."
        case .firstChunkFailed(let error):
            return "The first benchmark chunk failed: \(error.localizedDescription)"
        case .noSuccessfulChunks:
            return "No chunk completed successfully — nothing to report."
        }
    }
}

/// Reads what iOS will tell us about the battery. Airplane mode itself has
/// no public API — the protocol makes it a manual step; the state string
/// records whether the run was on charge (which would invalidate a drain
/// comparison).
enum BatteryReader {
    static func read() -> BenchmarkSession.BatterySample {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let levelPercent = (level >= 0) ? Double(level) * 100 : nil
        let state: String
        switch device.batteryState {
        case .unknown: state = "unknown"
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        @unknown default: state = "other"
        }
        return .init(levelPercent: levelPercent, state: state)
    }
}

struct DeviceInfo {
    let appVersion: String
    let appBuild: String
    let deviceModel: String
    let osVersion: String

    static func current() -> DeviceInfo {
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
            var parts: [UInt8] = []
            for byte in buffer.bindMemory(to: UInt8.self) {
                if byte == 0 { break }
                parts.append(byte)
            }
            return String(decoding: parts, as: UTF8.self)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return DeviceInfo(
            appVersion: version,
            appBuild: build,
            deviceModel: model.isEmpty ? "?" : model,
            osVersion: UIDevice.current.systemVersion
        )
    }
}

/// Holds the `audio` background assertion with a SILENT player loop, so a
/// screen-off, airplane-mode battery run measures synthesis instead of
/// measuring the app being suspended. No ducking options — the benchmark has
/// no business silencing the user's other audio.
final class BenchmarkAudioKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var active = false

    func start() {
        guard !active else { return }
        active = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            Log.shared.error("Benchmark: audio session setup failed: \(error) — screen-off runs will suspend")
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // 0.1 s of silence, rescheduled on completion for the session's life.
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400)!
        buffer.frameLength = buffer.frameCapacity
        do {
            try engine.start()
        } catch {
            Log.shared.error("Benchmark: silence engine failed to start: \(error)")
            return
        }
        player.play()
        scheduleSilence(buffer)
    }

    private func scheduleSilence(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            guard let self, self.active else { return }
            DispatchQueue.main.async {
                self.scheduleSilence(buffer)
            }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
