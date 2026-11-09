import Foundation

/// Benchmark Mode configuration (Phase 3 of the hybrid CPU+ANE plan).
///
/// Everything a benchmark run varies is a field here, so ONE build can run
/// many experiments: engine tier, sustained duration, ORT intra-op thread
/// count, synthesis speed. The config is persisted before a run starts and
/// re-read by "run at next launch", because a sideloaded app has no launch
/// arguments — the launch-arg parser exists for CI/simulator only.
enum BenchmarkTier: String, CaseIterable, Identifiable {
    /// Kokoro fp32 (325.5 MB model.onnx) — the shipping default tier.
    case kokoroFP32 = "kokoro-fp32"
    /// Kokoro compact int8 (model_quantized.onnx ~92 MB).
    case kokoroCompact = "kokoro-int8"
    /// Supertonic at the full 8 flow-matching steps.
    case supertonicHigh = "supertonic-high"
    /// Supertonic at 6 steps (the "Balanced" dial).
    case supertonicBalanced = "supertonic-balanced"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kokoroFP32: return "Kokoro fp32 (CPU)"
        case .kokoroCompact: return "Kokoro Compact int8 (CPU)"
        case .supertonicHigh: return "Supertonic High · 8 steps (CPU)"
        case .supertonicBalanced: return "Supertonic Balanced · 6 steps (CPU)"
        }
    }

    /// The step count pinned for the run (Supertonic only).
    var flowSteps: Int? {
        switch self {
        case .supertonicHigh: return 8
        case .supertonicBalanced: return 6
        default: return nil
        }
    }

    /// Production chunker shape, so the benchmark's per-chunk RTF
    /// distribution is comparable with real sessions (the core passes these
    /// same values for the two neural engines).
    var firstChunkChars: Int {
        switch self {
        case .kokoroFP32, .kokoroCompact: return 100
        case .supertonicHigh, .supertonicBalanced: return 60
        }
    }

    var batchChunkChars: Int {
        switch self {
        case .kokoroFP32, .kokoroCompact: return 160
        case .supertonicHigh, .supertonicBalanced: return 200
        }
    }
}

struct BenchmarkConfig: Equatable, Codable {
    var tier: BenchmarkTier = .kokoroFP32
    /// Sustained-synthesis wall-clock target in seconds. The loop stops
    /// BETWEEN chunks, so actual wall time slightly exceeds this.
    var durationSeconds: Double = 180
    /// ORT intra-op threads. nil = each engine's production policy (Kokoro:
    /// min(cores, 6); Supertonic: ORT default). Recorded in every export.
    var intraOpThreads: Int? = nil
    /// Synthesis speed passed to the engines (native model speed).
    var speed: Float = 1.0

    static let autostartDefaultsKey = "benchmark.autostart"
    static let lastConfigDefaultsKey = "benchmark.lastConfig"

    /// CI/simulator entry: `-BenchmarkAutoStart [-BenchmarkTier …]
    /// [-BenchmarkDurationSec N] [-BenchmarkThreads N]`. On device the UI +
    /// "run at next launch" replace this.
    static func fromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) -> BenchmarkConfig? {
        guard args.contains("-BenchmarkAutoStart") else { return nil }
        var config = BenchmarkConfig()
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if let raw = value(after: "-BenchmarkTier"), let tier = BenchmarkTier(rawValue: raw) {
            config.tier = tier
        }
        if let raw = value(after: "-BenchmarkDurationSec"), let seconds = Double(raw), seconds > 0 {
            config.durationSeconds = seconds
        }
        if let raw = value(after: "-BenchmarkThreads"), let threads = Int(raw), threads > 0 {
            config.intraOpThreads = threads
        }
        return config
    }

    func persisted() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.lastConfigDefaultsKey)
        }
    }

    static func restored() -> BenchmarkConfig {
        guard let data = UserDefaults.standard.data(forKey: lastConfigDefaultsKey),
              let config = try? JSONDecoder().decode(BenchmarkConfig.self, from: data) else {
            return BenchmarkConfig()
        }
        return config
    }
}

/// What the running session publishes to the UI (1 Hz-ish, per chunk).
struct BenchmarkLive: Equatable {
    var chunks = 0
    var loops = 0
    var elapsedSeconds = 0.0
    var meanRTF = 0.0
    var latestCPUPercent: Double?
    var latestFootprintMB: Double?
    var thermal = "nominal"
}
