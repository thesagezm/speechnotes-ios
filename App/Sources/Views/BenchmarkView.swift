import SwiftUI

/// Settings → Diagnostics → Benchmark mode. Configures and drives the
/// sustained-synthesis harness (Phase 3, Docs/PHASE3-BENCHMARK-HARNESS.md).
///
/// The protocol for comparable numbers (also in the doc):
/// charge ≥ 80 % → airplane mode → auto-brightness off, fixed brightness →
/// start the run → lock the screen (the harness holds the background-audio
/// assertion with a silent loop) → export when it finishes.
struct BenchmarkView: View {
    @ObservedObject private var model = BenchmarkModel.shared
    @AppStorage(BenchmarkConfig.autostartDefaultsKey) private var runAtNextLaunch = false

    @State private var tier: BenchmarkTier = .kokoroFP32
    @State private var durationSeconds: Double = 180
    @State private var threads: Int? = nil

    var body: some View {
        Form {
            Section {
                Picker("Engine tier", selection: $tier) {
                    ForEach(BenchmarkTier.allCases) { tier in
                        Text(tier.label).tag(tier)
                    }
                }
                Picker("Duration", selection: $durationSeconds) {
                    Text("1 min").tag(60.0)
                    Text("3 min").tag(180.0)
                    Text("5 min").tag(300.0)
                    Text("10 min").tag(600.0)
                }
                Picker("ORT threads", selection: $threads) {
                    Text("Engine default").tag(Int?.none)
                    Text("1").tag(Int?.some(1))
                    Text("2").tag(Int?.some(2))
                    Text("4").tag(Int?.some(4))
                    Text("6").tag(Int?.some(6))
                    Text("8").tag(Int?.some(8))
                }
                Toggle("Run at next launch", isOn: $runAtNextLaunch)
            } header: {
                Text("Configuration")
            } footer: {
                Text("«Run at next launch» starts this configuration as soon as the app opens — the device-side replacement for launch arguments. Corpus: \(BenchmarkCorpus.chars) chars (\(BenchmarkCorpus.id)).")
            }

            Section {
                switch model.phase {
                case .idle:
                    Label("Ready", systemImage: "circle.dashed")
                case .running:
                    Label("Running…", systemImage: "waveform.path")
                    liveRows
                case .finished:
                    if let result = model.lastResult {
                        summaryRows(result)
                        shareButtons(result)
                    }
                case .failed(let message):
                    Label("Failed: \(message)", systemImage: "exclamationmark.triangle")
                }
            } header: {
                Text("Session")
            } footer: {
                if model.phase == .running {
                    Text("You can leave this screen, lock the phone, or background the app — the run holds its own audio assertion. Stop lands between chunks and still exports.")
                }
            }

            Section {
                if model.phase == .running {
                    Button("Stop", role: .destructive) { model.stop() }
                } else {
                    Button("Start benchmark") {
                        model.start(config: BenchmarkConfig(
                            tier: tier,
                            durationSeconds: durationSeconds,
                            intraOpThreads: threads,
                            speed: 1.0
                        ))
                    }
                }
            } footer: {
                Text("Protocol for comparable numbers: charge ≥ 80 %, airplane mode, auto-brightness off, fixed brightness, start, then lock the screen. Don't play notes while a run is active — a live engine competes for the same cores and poisons the RTF.")
            }
        }
        .navigationTitle("Benchmark mode")
    }

    @ViewBuilder
    private var liveRows: some View {
        LabeledContent("Chunks", value: "\(model.live.chunks) (loop \(model.live.loops))")
        LabeledContent("Elapsed", value: String(format: "%.0f s", model.live.elapsedSeconds))
        LabeledContent("Mean RTF", value: String(format: "%.3f", model.live.meanRTF))
        LabeledContent("CPU", value: model.live.latestCPUPercent.map { String(format: "%.0f %%", $0) } ?? "…")
        LabeledContent("Footprint", value: model.live.latestFootprintMB.map { String(format: "%.0f MB", $0) } ?? "…")
        LabeledContent("Thermal", value: model.live.thermal)
    }

    @ViewBuilder
    private func summaryRows(_ result: BenchmarkSession.ExportResult) -> some View {
        let s = result.summary
        LabeledContent("Chunks", value: "\(s.chunks) over \(s.loops) loop(s), \(s.errors) error(s)")
        LabeledContent("Mean RTF", value: s.meanRTF.map { String(format: "%.3f", $0) } ?? "—")
        LabeledContent("RTF 25/50/75 %", value: [
            s.rtfAt25, s.rtfAt50, s.rtfAt75,
        ].map { $0.map { String(format: "%.2f", $0) } ?? "—" }.joined(separator: " / "))
        if s.throttleSignature {
            Label("Throttle signature (mean ≥ 35 % above first quartile)", systemImage: "flame")
                .foregroundStyle(.orange)
        }
        LabeledContent("First chunk", value: String(format: "%.2f s (load %.1f s)", s.firstChunkSeconds, s.modelLoadSeconds))
        LabeledContent("CPU", value: s.cpuMeanPercent.map { String(format: "%.0f %% mean → %.0f CPU-s", $0, s.cpuSeconds ?? 0) } ?? "—")
        LabeledContent("Memory", value: "peak \(s.footprintMaxMB.map { String(format: "%.0f", $0) } ?? "?") MB, min available \(s.availableMinMB.map { String(format: "%.0f", $0) } ?? "?") MB")
        LabeledContent("Battery", value: batteryText(s))
        LabeledContent("Thermal", value: "\(s.thermalStart) → \(s.thermalEnd)")
    }

    @ViewBuilder
    private func shareButtons(_ result: BenchmarkSession.ExportResult) -> some View {
        HStack {
            ShareLink(item: result.csvURL)
            Text(result.csvURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            ShareLink(item: result.jsonURL)
            Text(result.jsonURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func batteryText(_ s: BenchmarkSession.Summary) -> String {
        func level(_ sample: BenchmarkSession.BatterySample) -> String {
            sample.levelPercent.map { String(format: "%.0f %%", $0) } ?? "?"
        }
        return "\(level(s.batteryStart)) → \(level(s.batteryEnd)) (\(s.batteryEnd.state))"
    }
}
