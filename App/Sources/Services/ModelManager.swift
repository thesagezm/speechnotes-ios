import Foundation

/// Downloads and owns the Kokoro model files (Documents/KokoroOnnx/):
/// quantized ONNX model (~86 MB) + voice bank (~15 MB) + tokenizer (~4 KB).
/// One-time download on first launch; everything is offline after that.
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
    @Published private(set) var kittenState: State

    /// Called on the main actor when any model becomes ready.
    var onReady: (() -> Void)?

    /// The 28 voices shipped in the official voice bank (verified on CI).
    static let knownVoices: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica",
        "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenfir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    // MARK: Model set (ONNX engine)

    /// Quantized Kokoro (~86 MB) — the kokoro-onnx/PocketPal default choice.
    static let onnxModelURL = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model_q8f16.onnx")!
    static let onnxTokenizerURL = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/tokenizer.json")!
    /// Voice bank: 28 style vectors shared by every Kokoro voice.
    static let voicesURL = URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!

    // MARK: Kitten model set (second neural engine)

    /// KittenTTS nano 0.1 quantized — 15M params, ~24 MB, CPU-only English.
    static let kittenModelURL = URL(string: "https://huggingface.co/onnx-community/kitten-tts-nano-0.1-ONNX/resolve/main/onnx/model_quantized.onnx")!
    static let kittenVoicesURL = URL(string: "https://huggingface.co/KittenML/kitten-tts-nano-0.1/resolve/main/voices.npz")!

    nonisolated static var kittenDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kitten")
    }

    nonisolated static var kittenModelFileURL: URL {
        kittenDirectory.appendingPathComponent("model.onnx")
    }

    nonisolated static var kittenVoicesFileURL: URL {
        kittenDirectory.appendingPathComponent("voices.npz")
    }

    nonisolated static func kittenFilesAreValid() -> Bool {
        let fm = FileManager.default
        guard let modelSize = (try? fm.attributesOfItem(atPath: kittenModelFileURL.path))?[.size] as? Int64,
              modelSize > 15_000_000 else { return false }
        guard let voicesSize = (try? fm.attributesOfItem(atPath: kittenVoicesFileURL.path))?[.size] as? Int64,
              voicesSize > 4_000 else { return false }
        return true
    }

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

    nonisolated static var voicesFileURL: URL {
        onnxDirectory.appendingPathComponent("voices.npz")
    }

    nonisolated static func onnxFilesAreValid() -> Bool {
        let fm = FileManager.default
        guard let modelSize = (try? fm.attributesOfItem(atPath: onnxModelFileURL.path))?[.size] as? Int64,
              modelSize > 40_000_000 else { return false }
        guard let voicesSize = (try? fm.attributesOfItem(atPath: voicesFileURL.path))?[.size] as? Int64,
              voicesSize > 10_000_000 else { return false }
        // tokenizer.json is tiny (~3.5 KB) — validate by parsing it the same
        // way the engine does, not by size. (A >10 KB size check once
        // rejected every successful download.)
        guard let data = try? Data(contentsOf: onnxTokenizerFileURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let vocab = (json["model"] as? [String: Any])?["vocab"] as? [String: Int],
              vocab.count > 100 else { return false }
        return true
    }

    /// ~101 MB payload; require headroom of roughly 1.5× (PocketPal lesson).
    nonisolated static let requiredFreeBytes: Int64 = 150_000_000
    /// Generous idle timeout — the GitHub media CDN can stall for minutes.
    nonisolated static let requestTimeout: TimeInterval = 120
    nonisolated static let resourceTimeout: TimeInterval = 7200
    nonisolated static let downloadAttempts = 3

    init() {
        Self.migrateLegacyMetalFiles()
        if Self.onnxFilesAreValid() {
            state = .ready
            Log.shared.info("ModelManager: model already present")
        } else {
            state = .notDownloaded
        }
        if Self.kittenFilesAreValid() {
            kittenState = .ready
            Log.shared.info("ModelManager: Kitten model already present")
        } else {
            kittenState = .notDownloaded
        }
    }

    // MARK: Legacy layout migration

    /// v0.6 and earlier kept the voice bank in Documents/Kokoro/ next to a
    /// 327 MB Metal safetensors that no engine uses any more. Move the voice
    /// bank into the ONNX directory (no re-download) and delete the rest.
    nonisolated private static func migrateLegacyMetalFiles() {
        let fm = FileManager.default
        let legacyDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kokoro")
        let legacyVoices = legacyDir.appendingPathComponent("voices.npz")
        let legacyModel = legacyDir.appendingPathComponent("kokoro-v1_0.safetensors")

        if fm.fileExists(atPath: legacyVoices.path),
           !fm.fileExists(atPath: voicesFileURL.path) {
            try? fm.createDirectory(at: onnxDirectory, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: legacyVoices, to: voicesFileURL)
                Log.shared.info("ModelManager: migrated voice bank from the retired Metal-engine layout")
            } catch {
                Log.shared.error("ModelManager: voice bank migration failed (\(error.localizedDescription)) — it will re-download")
            }
        }
        if fm.fileExists(atPath: legacyModel.path) {
            try? fm.removeItem(at: legacyModel)
            Log.shared.info("ModelManager: removed the retired Metal model (freed ~327 MB)")
        }
        // Remove the old directory if nothing is left in it.
        if fm.fileExists(atPath: legacyDir.path),
           (try? fm.contentsOfDirectory(atPath: legacyDir.path))?.isEmpty == true {
            try? fm.removeItem(at: legacyDir)
        }
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var kittenIsReady: Bool {
        if case .ready = kittenState { return true }
        return false
    }

    /// Downloads the Kitten set (~24 MB model + 10 KB voices).
    func startKittenDownload() {
        if case .downloading = kittenState { return }
        guard !kittenIsReady else { return }

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64,
           free < 60_000_000 {
            let message = "Not enough free space for the Kitten model (need ~60 MB, have \(free / 1_000_000) MB)"
            kittenState = .failed(message)
            Log.shared.error("ModelManager: \(message)")
            return
        }

        kittenState = .downloading(progress: 0)
        Log.shared.info("ModelManager: starting Kitten model download (~24 MB)")

        Task.detached { [weak self] in
            do {
                try await self?.download(
                    from: Self.kittenModelURL,
                    to: Self.kittenModelFileURL,
                    expectedBytes: 23_792_492,
                    progressRange: 0.0...0.99,
                    publishingTo: { [weak self] value in self?.reportKittenProgress(value) }
                )
                try await self?.download(
                    from: Self.kittenVoicesURL,
                    to: Self.kittenVoicesFileURL,
                    expectedBytes: 10_294,
                    progressRange: 0.99...1.0,
                    publishingTo: { [weak self] value in self?.reportKittenProgress(value) }
                )
                await MainActor.run {
                    guard let self else { return }
                    if Self.kittenFilesAreValid() {
                        self.kittenState = .ready
                        Log.shared.info("ModelManager: Kitten download complete")
                        self.onReady?()
                    } else {
                        self.kittenState = .failed("Downloaded Kitten files failed validation")
                        Log.shared.error("ModelManager: Kitten files failed validation after download")
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.kittenState = .failed(error.localizedDescription)
                    Log.shared.error("ModelManager: Kitten download failed: \(error)")
                }
            }
        }
    }

    func deleteKittenModels() {
        try? FileManager.default.removeItem(at: Self.kittenDirectory)
        for base in [Self.kittenModelFileURL, Self.kittenVoicesFileURL] {
            try? FileManager.default.removeItem(at: base.appendingPathExtension("part"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("resumeData"))
        }
        kittenState = .notDownloaded
        Log.shared.info("ModelManager: Kitten models deleted")
    }

    private func reportKittenProgress(_ value: Double) {
        if case .downloading = kittenState {
            kittenState = .downloading(progress: value)
        }
    }

    /// Downloads the model set (~86 MB model + ~15 MB voices + 4 KB tokenizer).
    func startDownload() {
        if case .downloading = state { return }
        guard !isReady else { return }

        // Disk preflight — fail fast with a clear message instead of dying
        // 80 MB into the download (PocketPal lesson: estimate × ~1.5).
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64,
           free < Self.requiredFreeBytes {
            let message = "Not enough free space: need ~\(Self.requiredFreeBytes / 1_000_000) MB, have \(free / 1_000_000) MB"
            state = .failed(message)
            Log.shared.error("ModelManager: \(message)")
            return
        }

        state = .downloading(progress: 0)
        Log.shared.info("ModelManager: starting model download (~101 MB)")

        Task.detached { [weak self] in
            do {
                try await self?.download(
                    from: Self.onnxModelURL,
                    to: Self.onnxModelFileURL,
                    expectedBytes: 86_033_585,
                    progressRange: 0.0...0.8,
                    publishingTo: { [weak self] value in self?.reportProgress(value) }
                )
                try await self?.download(
                    from: Self.voicesURL,
                    to: Self.voicesFileURL,
                    expectedBytes: 14_629_684,
                    progressRange: 0.8...0.97,
                    publishingTo: { [weak self] value in self?.reportProgress(value) }
                )
                try await self?.download(
                    from: Self.onnxTokenizerURL,
                    to: Self.onnxTokenizerFileURL,
                    expectedBytes: 3_497,
                    progressRange: 0.97...1.0,
                    publishingTo: { [weak self] value in self?.reportProgress(value) }
                )
                await MainActor.run {
                    guard let self else { return }
                    if Self.onnxFilesAreValid() {
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
        try? FileManager.default.removeItem(at: Self.onnxDirectory)
        for base in [Self.onnxModelFileURL, Self.voicesFileURL, Self.onnxTokenizerFileURL] {
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
    ///
    /// `expectedBytes` is the known remote size: some CDN responses carry no
    /// Content-Length (totalBytesExpected == -1), which would leave the
    /// progress bar at 0% for the whole transfer — fall back to it then.
    nonisolated private func download(
        from source: URL,
        to destination: URL,
        expectedBytes: Int64,
        progressRange: ClosedRange<Double>,
        publishingTo sink: (@MainActor (Double) -> Void)?
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

                delegate.onProgress = { written, total in
                    let denominator = total > 0 ? total : expectedBytes
                    guard denominator > 0 else { return }
                    let fraction = min(1.0, Double(written) / Double(denominator))
                    let value = progressRange.lowerBound
                        + (progressRange.upperBound - progressRange.lowerBound) * fraction
                    Task { @MainActor in sink?(value) }
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

    /// PocketPal lesson: 100+ MB of model files should not ride iCloud backups.
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
