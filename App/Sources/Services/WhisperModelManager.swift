import Foundation
import OSLog

/// On-device model catalog + download manager for whisper.cpp ggml models.
/// Mirrors the shape of `ModelManager` for TTS: a published state machine
/// (`notDownloaded` / `downloading(progress)` / `failed(message)` / `ready`),
/// resumable downloads, atomic rename from `.part` to the final name, disk
/// preflight and `.resumeData` for `URLError` `-1001` recoveries.
///
/// Hosting: `ggerganov/whisper.cpp` on Hugging Face. URLs follow the
/// `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<filename>`
/// pattern. Sizes are approximate (Hugging Face's `ggml-*.bin`).
@MainActor
final class WhisperModelManager: ObservableObject {

    static let shared = WhisperModelManager()

    /// Curated default catalog (Amical-style: tiny → base → small → large-v3-turbo,
    /// plus `.en` variants for English-only small models).
    static let catalog: [WhisperModel] = [
        WhisperModel(
            id: "tiny",
            filename: "ggml-tiny.bin",
            displayName: "Tiny",
            sizeBytes: 77_700_000,
            englishOnly: false,
            speed: 5, accuracy: 2
        ),
        WhisperModel(
            id: "tiny.en",
            filename: "ggml-tiny.en.bin",
            displayName: "Tiny (English only)",
            sizeBytes: 77_700_000,
            englishOnly: true,
            speed: 5, accuracy: 3
        ),
        WhisperModel(
            id: "base",
            filename: "ggml-base.bin",
            displayName: "Base",
            sizeBytes: 148_000_000,
            englishOnly: false,
            speed: 4, accuracy: 3
        ),
        WhisperModel(
            id: "base.en",
            filename: "ggml-base.en.bin",
            displayName: "Base (English only)",
            sizeBytes: 148_000_000,
            englishOnly: true,
            speed: 4, accuracy: 3
        ),
        WhisperModel(
            id: "small",
            filename: "ggml-small.bin",
            displayName: "Small",
            sizeBytes: 488_000_000,
            englishOnly: false,
            speed: 3, accuracy: 4
        ),
        WhisperModel(
            id: "small.en",
            filename: "ggml-small.en.bin",
            displayName: "Small (English only)",
            sizeBytes: 488_000_000,
            englishOnly: true,
            speed: 3, accuracy: 4
        ),
        WhisperModel(
            id: "large-v3-turbo",
            filename: "ggml-large-v3-turbo.bin",
            displayName: "Large v3 Turbo",
            sizeBytes: 1_540_000_000,
            englishOnly: false,
            speed: 3, accuracy: 5
        ),
        WhisperModel(
            id: "large-v3",
            filename: "ggml-large-v3.bin",
            displayName: "Large v3",
            sizeBytes: 3_100_000_000,
            englishOnly: false,
            speed: 1, accuracy: 5
        ),
    ]

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double)
        case failed(String)
        case ready
    }

    @Published private(set) var states: [String: DownloadState] = [:]
    @AppStorage("activeWhisperModelId") var activeModelId: String = "tiny"

    private let logger = Logger(subsystem: "com.speechnotes.ios", category: "WhisperModels")
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservers: [String: NSKeyValueObservation] = [:]
    private var resumeData: [String: Data] = [:]
    private let session: URLSession

    /// Models live in `Documents/Whisper/`. Excluded from iCloud backup.
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisper", isDirectory: true)
    }

    static func modelURL(for id: String) -> URL? {
        guard let model = catalog.first(where: { $0.id == id }) else { return nil }
        return modelsDirectory.appendingPathComponent(model.filename)
    }

    /// Free disk bytes (Bytes free on the volume that holds Documents).
    static func freeDiskBytes() -> Int64 {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            return 0
        }
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 2
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        try? FileManager.default.createDirectory(
            at: Self.modelsDirectory, withIntermediateDirectories: true
        )
        var url = Self.modelsDirectory
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? url.setResourceValues(rv)

        for model in Self.catalog {
            states[model.id] = isInstalled(model) ? .ready : .notDownloaded
        }
    }

    // MARK: - State queries
    func isInstalled(_ model: WhisperModel) -> Bool {
        guard let url = Self.modelURL(for: model.id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func state(for id: String) -> DownloadState { states[id] ?? .notDownloaded }

    var installedModels: [WhisperModel] {
        Self.catalog.filter { isInstalled($0) }
    }

    // MARK: - Download
    func startDownload(id: String) {
        guard let model = Self.catalog.first(where: { $0.id == id }) else { return }
        if case .downloading = states[id] { return }

        // Disk preflight — bail with a clear message if the user won't fit
        // the model plus a safety margin (100 MB).
        let need = model.sizeBytes + 100_000_000
        if Self.freeDiskBytes() < need {
            states[id] = .failed("Not enough free space — need ~\(model.sizeBytes / 1_000_000) MB.")
            return
        }

        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(model.filename)") else {
            states[id] = .failed("Bad model URL.")
            return
        }

        states[id] = .downloading(0)

        let task: URLSessionDownloadTask
        if let data = resumeData[id] {
            task = session.downloadTask(withResumeData: data)
            resumeData[id] = nil
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = model.id

        let progressObs = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            Task { @MainActor in
                guard let self else { return }
                self.states[id] = .downloading(progress.fractionCompleted)
            }
        }
        progressObservers[id] = progressObs

        tasks[id] = task
        task.resume()
    }

    func cancelDownload(id: String) {
        if let task = tasks[id] {
            task.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor in
                    self?.resumeData[id] = data
                    self?.states[id] = .notDownloaded
                }
            })
        }
        progressObservers[id]?.invalidate()
        progressObservers[id] = nil
        tasks[id] = nil
    }

    func delete(id: String) {
        if let task = tasks[id] {
            task.cancel()
        }
        tasks[id] = nil
        progressObservers[id]?.invalidate()
        progressObservers[id] = nil
        resumeData[id] = nil
        if let url = Self.modelURL(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
        states[id] = .notDownloaded
    }

    // URLSession callbacks are nonisolated; we hop to the main actor to
    // mutate state. The session is owned by self but the delegate's calls
    // come in on a background queue.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // Synchronous move INSIDE the callback to avoid the temp-file race
        // that nukes the file once didFinishDownloadingTo returns.
        let dest = WhisperModelManager.modelsDirectory.appendingPathComponent(downloadTask.response?.suggestedFilename ?? id)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            logger.error("Whisper model move failed: \(error.localizedDescription)")
        }
        Task { @MainActor in
            self.tasks[id] = nil
            self.progressObservers[id]?.invalidate()
            self.progressObservers[id] = nil
            self.states[id] = .ready
            self.logger.info("Whisper model ready: \(id)")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        if let error = error as NSError? {
            // Preserve resume data for retry (-1001 / network drops)
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                Task { @MainActor in self.resumeData[id] = data }
            }
            Task { @MainActor in
                self.states[id] = .failed(error.localizedDescription)
                self.tasks[id] = nil
                self.progressObservers[id]?.invalidate()
                self.progressObservers[id] = nil
            }
        }
    }
}

struct WhisperModel: Identifiable, Hashable {
    let id: String
    let filename: String
    let displayName: String
    let sizeBytes: Int64
    let englishOnly: Bool
    let speed: Int
    let accuracy: Int

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// Conform URLSession tasks to be observable by KVO via .progress.
extension URLSessionTask {
    var progress: Progress { self }
}
