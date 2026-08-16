import Foundation

/// Downloads and owns the Kokoro model files (Documents/KokoroOnnx/):
/// uint8 ONNX model (~177 MB) + voice bank (~15 MB) + tokenizer (~4 KB).
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
    @Published private(set) var supertonicState: State

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

    /// Kokoro uint8 weight-only quant (~177 MB) — fp32 activations, one
    /// quality tier above dynamic int8/q8f16, comfortably under the 300 MB
    /// budget. (Next rung would be fp16 ~163 MB, unverified on ORT CPU.)
    static let onnxModelURL = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model_uint8.onnx")!
    static let onnxTokenizerURL = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/tokenizer.json")!
    /// Voice bank: 28 style vectors shared by every Kokoro voice.
    static let voicesURL = URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!

    // MARK: Kitten model set (second neural engine)

    /// KittenTTS mini 0.8 — 80M params (Kokoro's size class), int8 ONNX
    /// ~78 MB, CPU-only English. Contract identical to nano 0.1 (same
    /// inputs, style dim 256, tokenizer, 24 kHz); voices.npz now carries a
    /// [400, 256] style matrix per voice — the engine's reference
    /// row-selection already handles multi-row banks.
    static let kittenModelURL = URL(string: "https://huggingface.co/KittenML/kitten-tts-mini-0.8/resolve/main/kitten_tts_mini_v0_8.onnx")!
    static let kittenVoicesURL = URL(string: "https://huggingface.co/KittenML/kitten-tts-mini-0.8/resolve/main/voices.npz")!

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
        // Thresholds reject the old nano-0.1 set (~24 MB model, ~10 KB
        // voices) so the mini-0.8 upgrade re-downloads.
        guard let modelSize = (try? fm.attributesOfItem(atPath: kittenModelFileURL.path))?[.size] as? Int64,
              modelSize > 60_000_000 else { return false }
        guard let voicesSize = (try? fm.attributesOfItem(atPath: kittenVoicesFileURL.path))?[.size] as? Int64,
              voicesSize > 1_000_000 else { return false }
        return true
    }

    // MARK: Supertonic model set (third neural engine)

    /// Supertone supertonic-3 — flow-matching TTS, 31 languages, 10 voice
    /// styles (M1–M5 male, F1–F5 female). ~399 MB total across 4 ONNX
    /// sessions + config + unicode indexer + style JSONs. CPU-only via the
    /// vendored Helper (App/Sources/Engine/Supertonic/Helper.swift, MIT).
    static let supertonicBaseURL = URL(string: "https://huggingface.co/Supertone/supertonic-3/resolve/main")!

    static let supertonicVoices: [String] = ["M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5"]

    /// (file name, size in bytes from HF, lower progress bound) — downloaded
    /// in this order into Documents/Supertonic/onnx.
    nonisolated static let supertonicOnnxFiles: [(name: String, bytes: Int64, from: Double)] = [
        ("duration_predictor.onnx", 3_700_147, 0.00),
        ("text_encoder.onnx", 36_416_150, 0.01),
        ("vector_estimator.onnx", 256_534_781, 0.10),
        ("vocoder.onnx", 101_424_195, 0.75),
        ("tts.json", 8_253, 0.99),
        ("unicode_indexer.json", 277_676, 0.993),
    ]

    nonisolated static var supertonicDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Supertonic")
    }

    nonisolated static var supertonicOnnxDirectory: URL {
        supertonicDirectory.appendingPathComponent("onnx")
    }

    nonisolated static var supertonicStylesDirectory: URL {
        supertonicDirectory.appendingPathComponent("voice_styles")
    }

    nonisolated static func supertonicStyleFileURL(voice: String) -> URL {
        supertonicStylesDirectory.appendingPathComponent("\(voice).json")
    }

    nonisolated static func supertonicFilesAreValid() -> Bool {
        let fm = FileManager.default
        func size(_ url: URL) -> Int64? {
            (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64
        }
        // The heavy session is the memory gate — require near-complete files.
        guard size(supertonicOnnxDirectory.appendingPathComponent("vector_estimator.onnx")) ?? 0 > 200_000_000,
              size(supertonicOnnxDirectory.appendingPathComponent("vocoder.onnx")) ?? 0 > 90_000_000,
              size(supertonicOnnxDirectory.appendingPathComponent("text_encoder.onnx")) ?? 0 > 30_000_000,
              size(supertonicOnnxDirectory.appendingPathComponent("duration_predictor.onnx")) ?? 0 > 3_000_000,
              size(supertonicOnnxDirectory.appendingPathComponent("tts.json")) ?? 0 > 1_000,
              size(supertonicOnnxDirectory.appendingPathComponent("unicode_indexer.json")) ?? 0 > 100_000
        else { return false }
        for voice in supertonicVoices {
            guard size(supertonicStyleFileURL(voice: voice)) ?? 0 > 100_000 else { return false }
        }
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
        // Threshold rejects the old q8f16 model (~86 MB) so the uint8
        // upgrade re-downloads.
        guard let modelSize = (try? fm.attributesOfItem(atPath: onnxModelFileURL.path))?[.size] as? Int64,
              modelSize > 120_000_000 else { return false }
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

    /// ~192 MB payload; require headroom of roughly 1.5× (PocketPal lesson).
    nonisolated static let requiredFreeBytes: Int64 = 290_000_000
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
        if Self.supertonicFilesAreValid() {
            supertonicState = .ready
            Log.shared.info("ModelManager: Supertonic model already present")
        } else {
            supertonicState = .notDownloaded
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

    var supertonicIsReady: Bool {
        if case .ready = supertonicState { return true }
        return false
    }

    /// Downloads the Supertonic set (~399 MB total, 16 files).
    func startSupertonicDownload() {
        if case .downloading = supertonicState { return }
        guard !supertonicIsReady else { return }

        // PocketPal lesson: estimate × ~1.5 headroom.
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64,
           free < 600_000_000 {
            let message = "Not enough free space for Supertonic (need ~600 MB, have \(free / 1_000_000) MB)"
            supertonicState = .failed(message)
            Log.shared.error("ModelManager: \(message)")
            return
        }

        supertonicState = .downloading(progress: 0)
        Log.shared.info("ModelManager: starting Supertonic download (~399 MB)")

        Task.detached { [weak self] in
            do {
                // ONNX files + configs, each mapped to its progress slice.
                for index in 0..<Self.supertonicOnnxFiles.count {
                    let file = Self.supertonicOnnxFiles[index]
                    let upper = index + 1 < Self.supertonicOnnxFiles.count
                        ? Self.supertonicOnnxFiles[index + 1].from
                        : 0.994
                    try await self?.download(
                        from: Self.supertonicBaseURL.appendingPathComponent("onnx/\(file.name)"),
                        to: Self.supertonicOnnxDirectory.appendingPathComponent(file.name),
                        expectedBytes: file.bytes,
                        progressRange: file.from...upper,
                        publishingTo: { [weak self] value in self?.reportSupertonicProgress(value) }
                    )
                }
                // All 10 voice styles (~0.29 MB each) share the final slice.
                for (index, voice) in Self.supertonicVoices.enumerated() {
                    let lower = 0.994 + 0.006 * Double(index) / Double(Self.supertonicVoices.count)
                    let upper = 0.994 + 0.006 * Double(index + 1) / Double(Self.supertonicVoices.count)
                    try await self?.download(
                        from: Self.supertonicBaseURL.appendingPathComponent("voice_styles/\(voice).json"),
                        to: Self.supertonicStyleFileURL(voice: voice),
                        expectedBytes: 292_000,
                        progressRange: lower...upper,
                        publishingTo: { [weak self] value in self?.reportSupertonicProgress(value) }
                    )
                }
                await MainActor.run {
                    guard let self else { return }
                    if Self.supertonicFilesAreValid() {
                        self.supertonicState = .ready
                        Log.shared.info("ModelManager: Supertonic download complete")
                        self.onReady?()
                    } else {
                        self.supertonicState = .failed("Downloaded Supertonic files failed validation")
                        Log.shared.error("ModelManager: Supertonic files failed validation after download")
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.supertonicState = .failed(error.localizedDescription)
                    Log.shared.error("ModelManager: Supertonic download failed: \(error)")
                }
            }
        }
    }

    func deleteSupertonicModels() {
        try? FileManager.default.removeItem(at: Self.supertonicDirectory)
        var cleanup: [URL] = Self.supertonicOnnxFiles.map {
            Self.supertonicOnnxDirectory.appendingPathComponent($0.name)
        }
        cleanup += Self.supertonicVoices.map { Self.supertonicStyleFileURL(voice: $0) }
        for base in cleanup {
            try? FileManager.default.removeItem(at: base.appendingPathExtension("part"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("resumeData"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("resumeSource"))
        }
        supertonicState = .notDownloaded
        Log.shared.info("ModelManager: Supertonic models deleted")
    }

    private func reportSupertonicProgress(_ value: Double) {
        if case .downloading = supertonicState {
            supertonicState = .downloading(progress: value)
        }
    }

    /// Downloads the Kitten set (~78 MB model + ~3.3 MB voices).
    func startKittenDownload() {
        if case .downloading = kittenState { return }
        guard !kittenIsReady else { return }

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64,
           free < 130_000_000 {
            let message = "Not enough free space for the Kitten model (need ~130 MB, have \(free / 1_000_000) MB)"
            kittenState = .failed(message)
            Log.shared.error("ModelManager: \(message)")
            return
        }

        kittenState = .downloading(progress: 0)
        Log.shared.info("ModelManager: starting Kitten model download (~82 MB)")

        Task.detached { [weak self] in
            do {
                try await self?.download(
                    from: Self.kittenModelURL,
                    to: Self.kittenModelFileURL,
                    expectedBytes: 78_268_016,
                    progressRange: 0.0...0.99,
                    publishingTo: { [weak self] value in self?.reportKittenProgress(value) }
                )
                try await self?.download(
                    from: Self.kittenVoicesURL,
                    to: Self.kittenVoicesFileURL,
                    expectedBytes: 3_278_902,
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

    /// Downloads the model set (~177 MB model + ~15 MB voices + 4 KB tokenizer).
    func startDownload() {
        if case .downloading = state { return }
        guard !isReady else { return }

        // Disk preflight — fail fast with a clear message instead of dying
        // 100 MB into the download (PocketPal lesson: estimate × ~1.5).
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64,
           free < Self.requiredFreeBytes {
            let message = "Not enough free space: need ~\(Self.requiredFreeBytes / 1_000_000) MB, have \(free / 1_000_000) MB"
            state = .failed(message)
            Log.shared.error("ModelManager: \(message)")
            return
        }

        state = .downloading(progress: 0)
        Log.shared.info("ModelManager: starting model download (~192 MB)")

        Task.detached { [weak self] in
            do {
                try await self?.download(
                    from: Self.onnxModelURL,
                    to: Self.onnxModelFileURL,
                    expectedBytes: 177_464_632,
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
        // Sidecar recording which remote the resume data belongs to — after
        // a model-version swap, resuming stale bytes from the OLD url would
        // corrupt the new download undetectably.
        let resumeSourceURL = destination.appendingPathExtension("resumeSource")
        let resumeMatchesSource = (try? String(contentsOf: resumeSourceURL, encoding: .utf8))
            .map { $0 == source.absoluteString } ?? false

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
                    if let resumeData = try? Data(contentsOf: resumeDataURL),
                       !resumeData.isEmpty,
                       resumeMatchesSource {
                        Log.shared.info("ModelManager: continuing partial download")
                        session.downloadTask(withResumeData: resumeData).resume()
                    } else {
                        if !resumeMatchesSource {
                            try? FileManager.default.removeItem(at: resumeDataURL)
                        }
                        try? source.absoluteString.write(to: resumeSourceURL, atomically: true, encoding: .utf8)
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
