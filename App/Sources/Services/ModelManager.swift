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
    @Published private(set) var onnxState: State

    /// Called on the main actor when a model becomes ready.
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

    // MARK: ONNX model set (Plan B engine)

    /// Quantized Kokoro (~82 MB) — the kokoro-onnx/PocketPal default choice.
    static let onnxModelURL = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model_q8f16.onnx")!
    static let onnxTokenizerURL = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/tokenizer.json")!

    nonisolated static var onnxDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KokoroOnnx")
    }

    nonisolated static var onnxModelFileURL: URL {
        onnxDirectory.appendingPathComponent("model.onnx")
    }

    nonisolated static var onnxTokenizerFileURL: URL {
        onnxDirectory.appendingPathComponent("tokenizer.json")
    }

    nonisolated static func onnxFilesAreValid() -> Bool {
        let fm = FileManager.default
        guard let modelSize = (try? fm.attributesOfItem(atPath: onnxModelFileURL.path))?[.size] as? Int64,
              modelSize > 40_000_000 else { return false }
        guard let tokenizerSize = (try? fm.attributesOfItem(atPath: onnxTokenizerFileURL.path))?[.size] as? Int64,
              tokenizerSize > 10_000 else { return false }
        return true
    }

    /// ~342 MB payload; require headroom of roughly 1.3× (PocketPal lesson).
    nonisolated static let requiredFreeBytes: Int64 = 450_000_000
    /// Generous idle timeout — GitHub's media CDN can stall for minutes.
    nonisolated static let requestTimeout: TimeInterval = 120
    nonisolated static let resourceTimeout: TimeInterval = 7200
    nonisolated static let downloadAttempts = 3

    init() {
        if Self.filesAreValid() {
            state = .ready
            Log.shared.info("ModelManager: model already present")
        } else {
            state = .notDownloaded
        }
        if Self.onnxFilesAreValid() {
            onnxState = .ready
            Log.shared.info("ModelManager: ONNX model already present")
        } else {
            onnxState = .notDownloaded
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

    var onnxIsReady: Bool {
        if case .ready = onnxState { return true }
        return false
    }

    func startDownload() {
        if case .downloading = state { return }
        guard !isReady else { return }

        // Disk preflight — fail fast with a clear message instead of dying
        // 300 MB into the download (PocketPal lesson: estimate × ~1.3).
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64,
           free < Self.requiredFreeBytes {
            let message = "Not enough free space: need ~\(Self.requiredFreeBytes / 1_000_000) MB, have \(free / 1_000_000) MB"
            state = .failed(message)
            Log.shared.error("ModelManager: \(message)")
            return
        }

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

    /// Downloads the ONNX engine's model set (~82 MB quantized + tokenizer).
    func startOnnxDownload() {
        if case .downloading = onnxState { return }
        guard !onnxIsReady else { return }

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64,
           free < 150_000_000 {
            let message = "Not enough free space for the ONNX model (need ~150 MB, have \(free / 1_000_000) MB)"
            onnxState = .failed(message)
            Log.shared.error("ModelManager: \(message)")
            return
        }

        onnxState = .downloading(progress: 0)
        Log.shared.info("ModelManager: starting ONNX model download (~82 MB)")

        Task.detached { [weak self] in
            do {
                try await self?.download(
                    from: Self.onnxModelURL,
                    to: Self.onnxModelFileURL,
                    progressRange: 0.0...0.95
                )
                try await self?.download(
                    from: Self.onnxTokenizerURL,
                    to: Self.onnxTokenizerFileURL,
                    progressRange: 0.95...1.0
                )
                await MainActor.run {
                    guard let self else { return }
                    if Self.onnxFilesAreValid() {
                        self.onnxState = .ready
                        Log.shared.info("ModelManager: ONNX download complete")
                        self.onReady?()
                    } else {
                        self.onnxState = .failed("Downloaded ONNX files failed validation")
                        Log.shared.error("ModelManager: ONNX files failed validation after download")
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.onnxState = .failed(error.localizedDescription)
                    Log.shared.error("ModelManager: ONNX download failed: \(error)")
                }
            }
        }
    }

    func deleteOnnxModels() {
        try? FileManager.default.removeItem(at: Self.onnxDirectory)
        for base in [Self.onnxModelFileURL, Self.onnxTokenizerFileURL] {
            try? FileManager.default.removeItem(at: base.appendingPathExtension("part"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("resumeData"))
        }
        onnxState = .notDownloaded
        Log.shared.info("ModelManager: ONNX models deleted")
    }

    func deleteModels() {
        if onnxIsReady {
            Log.shared.error("ModelManager: deleting the voice bank — the ONNX engine needs it too and will stop working until re-downloaded")
        }
        try? FileManager.default.removeItem(at: modelPath)
        try? FileManager.default.removeItem(at: voicesPath)
        for base in [Self.modelFileURL, Self.voicesFileURL] {
            try? FileManager.default.removeItem(at: base.appendingPathExtension("part"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("resumeData"))
        }
        state = .notDownloaded
        Log.shared.info("ModelManager: models deleted")
    }

    private func reportProgress(_ value: Double) {
        if case .downloading = state {
            state = .downloading(progress: value)
        }
    }

    /// Downloads one file with progress, retry, and resume support.
    ///
    /// The completed temp file MUST be moved inside the delegate's
    /// `didFinishDownloadingTo` callback — URLSession deletes it the moment
    /// that method returns, which is exactly the race that produced
    /// "CFNetworkDownload_*.tmp couldn't be moved" on device when the move
    /// ran after an async hop back into the task.
    nonisolated private func download(
        from source: URL,
        to destination: URL,
        progressRange: ClosedRange<Double>
    ) async throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)

        let partURL = destination.appendingPathExtension("part")
        let resumeDataURL = destination.appendingPathExtension("resumeData")

        var lastError: Error?
        for attempt in 1...Self.downloadAttempts {
            do {
                let delegate = ProgressDelegate(partURL: partURL)
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = Self.requestTimeout
                config.timeoutIntervalForResource = Self.resourceTimeout
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
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

                if attempt > 1 {
                    Log.shared.info("ModelManager: retry \(attempt) of \(Self.downloadAttempts)")
                }

                let completedPart = try await withCheckedThrowingContinuation { continuation in
                    delegate.continuation = continuation
                    if let resumeData = try? Data(contentsOf: resumeDataURL), !resumeData.isEmpty {
                        Log.shared.info("ModelManager: continuing partial download")
                        session.downloadTask(withResumeData: resumeData).resume()
                    } else {
                        session.downloadTask(with: source).resume()
                    }
                }

                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: completedPart, to: destination)
                try? FileManager.default.removeItem(at: resumeDataURL)
                return
            } catch {
                lastError = error
                // Persist resume data when iOS offers it, so the next attempt
                // (or the next app launch) continues instead of restarting.
                if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                   !data.isEmpty {
                    try? data.write(to: resumeDataURL, options: .atomic)
                } else {
                    // A failed resume attempt yields no fresh resume data —
                    // clear the stale blob so the next attempt starts clean.
                    try? FileManager.default.removeItem(at: resumeDataURL)
                }
                Log.shared.error("ModelManager: attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
        throw lastError ?? URLError(.badURL)
    }

    /// PocketPal lesson: 342 MB of model files should not ride iCloud backups.
    nonisolated private static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// URLSession download delegate bridging to async/await.
/// Moves the completed file synchronously in `didFinishDownloadingTo` — the
/// system temp location is only valid until that method returns.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let partURL: URL
    var continuation: CheckedContinuation<URL, Error>?
    var onProgress: ((Int64, Int64) -> Void)?

    init(partURL: URL) {
        self.partURL = partURL
    }

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
        do {
            try? FileManager.default.removeItem(at: partURL)
            try FileManager.default.moveItem(at: location, to: partURL)
            continuation?.resume(returning: partURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
