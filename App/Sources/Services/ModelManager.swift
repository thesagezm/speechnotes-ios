import Foundation

/// Downloads and owns the Kokoro model files (Documents/Kokoro/).
/// ~342 MB one-time download on first launch; everything is offline after that.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case failed(String)
        case ready
    }

    @Published private(set) var state: State

    /// Called on the main actor when the model becomes ready.
    var onReady: (() -> Void)?

    /// The 28 voices shipped in the official voice bank (verified on CI).
    static let knownVoices: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica",
        "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    static let modelURL = URL(string: "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/kokoro-v1_0.safetensors")!
    static let voicesURL = URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!

    init() {
        if Self.filesAreValid() {
            state = .ready
            Log.shared.info("ModelManager: model already present")
        } else {
            state = .notDownloaded
        }
    }

    // Paths and file checks are pure FileManager math — usable from any thread.
    nonisolated static var kokoroDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kokoro")
    }

    nonisolated static var modelFileURL: URL {
        kokoroDirectory.appendingPathComponent("kokoro-v1_0.safetensors")
    }

    nonisolated static var voicesFileURL: URL {
        kokoroDirectory.appendingPathComponent("voices.npz")
    }

    nonisolated static func filesAreValid() -> Bool {
        let fm = FileManager.default
        guard let modelSize = (try? fm.attributesOfItem(atPath: modelFileURL.path))?[.size] as? Int64,
              modelSize > 300_000_000 else { return false }
        guard let voicesSize = (try? fm.attributesOfItem(atPath: voicesFileURL.path))?[.size] as? Int64,
              voicesSize > 10_000_000 else { return false }
        return true
    }

    var modelPath: URL { Self.modelFileURL }
    var voicesPath: URL { Self.voicesFileURL }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func startDownload() {
        if case .downloading = state { return }
        guard !isReady else { return }

        state = .downloading(progress: 0)
        Log.shared.info("ModelManager: starting model download (~342 MB)")

        Task.detached { [weak self] in
            do {
                try await self?.download(
                    from: Self.modelURL,
                    to: Self.modelFileURL,
                    progressRange: 0.0...0.95
                )
                try await self?.download(
                    from: Self.voicesURL,
                    to: Self.voicesFileURL,
                    progressRange: 0.95...1.0
                )
                await MainActor.run {
                    guard let self else { return }
                    if Self.filesAreValid() {
                        self.state = .ready
                        Log.shared.info("ModelManager: download complete")
                        self.onReady?()
                    } else {
                        self.state = .failed("Downloaded files failed validation")
                        Log.shared.error("ModelManager: files failed validation after download")
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.state = .failed(error.localizedDescription)
                    Log.shared.error("ModelManager: download failed: \(error)")
                }
            }
        }
    }

    func deleteModels() {
        try? FileManager.default.removeItem(at: modelPath)
        try? FileManager.default.removeItem(at: voicesPath)
        state = .notDownloaded
        Log.shared.info("ModelManager: models deleted")
    }

    private func reportProgress(_ value: Double) {
        if case .downloading = state {
            state = .downloading(progress: value)
        }
    }

    /// Downloads one file with progress, writing to a .part file and renaming
    /// into place only on success.
    private func download(from source: URL, to destination: URL, progressRange: ClosedRange<Double>) async throws {
        let delegate = ProgressDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        delegate.onProgress = { [weak self] written, total in
            guard total > 0 else { return }
            let fraction = min(1.0, Double(written) / Double(total))
            let value = progressRange.lowerBound
                + (progressRange.upperBound - progressRange.lowerBound) * fraction
            Task { @MainActor [weak self] in
                self?.reportProgress(value)
            }
        }

        let tempLocation = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: source).resume()
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partURL = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partURL)
        try FileManager.default.moveItem(at: tempLocation, to: partURL)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
    }
}

/// URLSession download delegate bridging to async/await.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    var continuation: CheckedContinuation<URL, Error>?
    var onProgress: ((Int64, Int64) -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
