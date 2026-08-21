import Foundation
import OSLog
import WhisperKit

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
    @Published var activeModelId: String = "tiny" {
        didSet { UserDefaults.standard.set(activeModelId, forKey: "activeWhisperModelId") }
    }

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
    nonisolated static func freeDiskBytes() -> Int64 {
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

        // WhisperKit downloads its models into a parallel folder structure
        // (coreml/<variant>/*.mlmodelc). The marker file <variant>.bin tells
        // us it considers the model installed — used here so .ready fires
        // when WhisperKit sees the model even before WhisperCppEngine has
        // loaded it.
        let userActive = UserDefaults.standard.string(forKey: "activeWhisperModelId") ?? "tiny"
        if let variant = Self.variantForId[userActive] {
            let marker = Self.whisperKitDirectory.appendingPathComponent("\(variant).bin")
            if FileManager.default.fileExists(atPath: marker.path) {
                activeModelId = userActive
            }
        }
        for model in Self.catalog {
            let marker = Self.whisperKitDirectory.appendingPathComponent("\(Self.variantForId[model.id] ?? model.id).bin")
            states[model.id] = FileManager.default.fileExists(atPath: marker.path) ? .ready : .notDownloaded
        }
    }

    /// WhisperKit caches its CoreML bundles under Documents/<repo>/<variant>/.
    /// We use the sentinel `<variant>.bin` file WhisperKit writes there as a
    /// "model is downloaded" marker so the settings UI can show ✓ even
    /// before the engine has finished loading.
    nonisolated static let whisperKitDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }()

    nonisolated static let variantForId: [String: String] = [
        "tiny": "tiny",
        "tiny.en": "tiny.en",
        "base": "base",
        "base.en": "base.en",
        "small": "small",
        "small.en": "small.en",
        "large-v3-turbo": "large-v3-turbo",
        "large-v3": "large-v3",
    ]

    // MARK: - State queries
    func isInstalled(_ model: WhisperModel) -> Bool {
        guard let variant = Self.variantForId[model.id] else { return false }
        let marker = Self.whisperKitDirectory.appendingPathComponent("\(variant).bin")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    func state(for id: String) -> DownloadState { states[id] ?? .notDownloaded }

    var installedModels: [WhisperModel] {
        Self.catalog.filter { isInstalled($0) }
    }

    // MARK: - Download
    /// Downloads the model through WhisperKit's own downloader so the
    /// resulting bundle lives in the same `argmaxinc/whisperkit-coreml/`
    /// tree WhisperKit expects. WhisperKit.download returns a progress
    /// closure we forward into `states[id]`.
    func startDownload(id: String) {
        guard let model = Self.catalog.first(where: { $0.id == id }) else { return }
        if case .downloading = states[id] { return }
        guard let variant = Self.variantForId[id] else {
            states[id] = .failed("Unknown model variant.")
            return
        }

        // Disk preflight — bail with a clear message if the user won't fit
        // the model plus a safety margin (100 MB).
        let need = model.sizeBytes + 100_000_000
        if Self.freeDiskBytes() < need {
            states[id] = .failed("Not enough free space — need ~\(model.sizeBytes / 1_000_000) MB.")
            return
        }

        states[id] = .downloading(0)
        Task { @MainActor in
            do {
                let progressCallback: @Sendable (Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        self?.states[id] = .downloading(progress.fractionCompleted)
                    }
                }
                try await WhisperKit.download(variant: variant, progressCallback: progressCallback)
                self.tasks[id] = nil
                self.progressObservers[id]?.invalidate()
                self.progressObservers[id] = nil
                self.states[id] = .ready
                self.logger.info("WhisperKit model ready: \(variant)")
                if WhisperModelManager.variantForId[self.activeModelId] == variant {
                    NotificationCenter.default.post(name: .whisperModelReady, object: variant)
                }
            } catch {
                self.states[id] = .failed(error.localizedDescription)
                self.logger.error("WhisperKit download failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload(id: String) {
        // WhisperKit's download API has no public cancel hook; clear the
        // state so the user can retry.
        tasks[id] = nil
        progressObservers[id]?.invalidate()
        progressObservers[id] = nil
        if case .downloading = states[id] {
            states[id] = .notDownloaded
        }
    }

    func delete(id: String) {
        cancelDownload(id: id)
        resumeData[id] = nil
        // Delete the WhisperKit-installed bundle.
        let variant = Self.variantForId[id] ?? id
        let variantDir = Self.whisperKitDirectory.appendingPathComponent(variant, isDirectory: true)
        try? FileManager.default.removeItem(at: variantDir)
        let marker = Self.whisperKitDirectory.appendingPathComponent("\(variant).bin")
        try? FileManager.default.removeItem(at: marker)
        states[id] = .notDownloaded
        if activeModelId == id {
            // Reset to tiny if the user deletes the active model.
            activeModelId = "tiny"
        }
    }

    /// Returns a description of the model's loaded state — useful for
    /// showing the user which Whisper variant is currently active and
    /// whether WhisperKit has confirmed it's on disk.
    var activeModelDescription: String {
        let variant = Self.variantForId[activeModelId] ?? activeModelId
        let marker = Self.whisperKitDirectory.appendingPathComponent("\(variant).bin")
        let installed = FileManager.default.fileExists(atPath: marker.path)
        return installed ? variant : "\(variant) (not on disk)"
    }

    // URLSession callbacks are nonisolated; we hop to the main actor to
    // mutate state. The session is owned by self but the delegate's calls
    // come in on a background queue.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // Synchronous move INSIDE the callback to avoid the temp-file race
        // that nukes the file once didFinishDownloadingTo returns. The
        // destination folder is also main-actor-isolated, so resolve once
        // here (FileManager.default.urls is nonisolated) rather than on the
        // manager.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Whisper", isDirectory: true)
        let dest = dir.appendingPathComponent(downloadTask.response?.suggestedFilename ?? id)
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

// URLSessionTask already has `progress: Progress` from Foundation — no
// extension needed. The `task.progress` KVO works directly.

extension Notification.Name {
    static let whisperModelReady = Notification.Name("WhisperModelManager.modelReady")
}
