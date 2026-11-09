import Foundation
import SwiftUI

/// App-level owner of the benchmark state: the Settings screen drives it,
/// and "run at next launch" re-enters it after a relaunch (a sideloaded app
/// cannot receive launch arguments, so the relaunch IS the scripted entry).
@MainActor
final class BenchmarkModel: ObservableObject {
    static let shared = BenchmarkModel()

    enum Phase: Equatable {
        case idle
        case running
        case finished
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var live = BenchmarkLive()
    @Published var lastResult: BenchmarkSession.ExportResult?

    private var session: BenchmarkSession?

    private init() {}

    /// Launch-time entry: launch arguments win (CI/simulator), otherwise the
    /// persisted "run at next launch" toggle.
    func autostartIfNeeded() {
        guard phase == .idle else { return }
        let defaults = UserDefaults.standard
        if let config = BenchmarkConfig.fromLaunchArguments() {
            Log.shared.info("Benchmark: auto-start from launch arguments (\(config.tier.rawValue))")
            start(config: config)
            return
        }
        if defaults.bool(forKey: BenchmarkConfig.autostartDefaultsKey) {
            let config = BenchmarkConfig.restored()
            Log.shared.info("Benchmark: auto-start from stored config (\(config.tier.rawValue), \(Int(config.durationSeconds))s)")
            start(config: config)
        }
    }

    func start(config: BenchmarkConfig) {
        guard phase != .running else { return }
        config.persisted()
        live = BenchmarkLive()
        lastResult = nil
        phase = .running

        let session = BenchmarkSession(config: config)
        session.onLive = { [weak self] live in
            self?.live = live
        }
        session.onFinish = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let export):
                self.lastResult = export
                self.phase = .finished
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
        self.session = session
        session.start()
    }

    func stop() {
        session?.stop()
    }
}
