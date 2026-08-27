import Foundation
import OSLog
import WhisperKit

/// On-device model catalog + download manager for Whisper STT models.
/// Mirrors the shape of `ModelManager` for TTS: a published state machine
/// (`notDownloaded` / `downloading(progress)` / `failed(message)` / `ready`),
/// disk preflight, and delete.
///
/// Downloads are delegated to WhisperKit (`argmaxinc/whisperkit-coreml` on
/// Hugging Face), which fetches CoreML bundles — NOT the ggml `ggml-*.bin`
/// files the pre-Phase-4 catalog targeted. Catalog `sizeBytes` values are
/// approximate CoreML install sizes used for display and the disk preflight.
@MainActor
final class WhisperModelManager: ObservableObject {

    static let shared = WhisperModelManager()

    /// Curated default catalog (Amical-style: tiny → base → small → large-v3-turbo,
    /// plus `.en` variants for English-only small models).
    static let catalog: [WhisperModel] = [
        WhisperModel(
            id: "tiny",
            displayName: "Tiny",
            sizeBytes: 77_700_000,
            englishOnly: false,
            speed: 5, accuracy: 2
        ),
        WhisperModel(
            id: "tiny.en",
            displayName: "Tiny (English only)",
            sizeBytes: 77_700_000,
            englishOnly: true,
            speed: 5, accuracy: 3
        ),
        WhisperModel(
            id: "base",
            displayName: "Base",
            sizeBytes: 148_000_000,
            englishOnly: false,
            speed: 4, accuracy: 3
        ),
        WhisperModel(
            id: "base.en",
            displayName: "Base (English only)",
            sizeBytes: 148_000_000,
            englishOnly: true,
            speed: 4, accuracy: 3
        ),
        WhisperModel(
            id: "small",
            displayName: "Small",
            sizeBytes: 488_000_000,
            englishOnly: false,
            speed: 3, accuracy: 4
        ),
        WhisperModel(
            id: "small.en",
            displayName: "Small (English only)",
            sizeBytes: 488_000_000,
            englishOnly: true,
            speed: 3, accuracy: 4
        ),
        WhisperModel(
            id: "large-v3-turbo",
            displayName: "Large v3 Turbo",
            sizeBytes: 1_540_000_000,
            englishOnly: false,
            speed: 3, accuracy: 5
        ),
        WhisperModel(
            id: "large-v3",
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
    private var inFlightDownloads: Set<String> = []

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

    /// WhisperKit installs CoreML bundles under this directory (it resolves
    /// to Documents/argmaxinc/whisperkit-coreml/ inside the app sandbox).
    /// The sentinel `<variant>.bin` file is our "model is downloaded"
    /// marker so the settings UI can show ✓ even before the engine has
    /// finished loading.
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
        guard !inFlightDownloads.contains(id) else { return }   // no concurrent downloads
        guard let variant = Self.variantForId[id] else {
            states[id] = .failed("Unknown model variant.")
            return
        }

        // Disk preflight — bail with a clear message if the user won't fit
        // the model plus a safety margin. CoreML bundles differ from ggml
        // sizes — use ~1.5× headroom on the catalog size.
        let need = Int64(Double(model.sizeBytes) * 1.5) + 100_000_000
        if Self.freeDiskBytes() < need {
            states[id] = .failed("Not enough free space — need ~\(model.sizeBytes / 1_000_000) MB.")
            return
        }

        inFlightDownloads.insert(id)
        states[id] = .downloading(0)
        Task { @MainActor in
            do {
                let progressCallback: @Sendable (Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        self?.states[id] = .downloading(progress.fractionCompleted)
                    }
                }
                try await WhisperKit.download(variant: variant, progressCallback: progressCallback)
                self.inFlightDownloads.remove(id)
                self.states[id] = .ready
                self.logger.info("WhisperKit model ready: \(variant)")
                if WhisperModelManager.variantForId[self.activeModelId] == variant {
                    NotificationCenter.default.post(name: .whisperModelReady, object: variant)
                }
            } catch {
                self.inFlightDownloads.remove(id)
                self.states[id] = .failed(error.localizedDescription)
                self.logger.error("WhisperKit download failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload(id: String) {
        // WhisperKit's download API has no public cancel hook; clear the
        // state so the user can retry.
        if case .downloading = states[id] {
            states[id] = .notDownloaded
        }
    }

    func delete(id: String) {
        cancelDownload(id: id)
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
}

struct WhisperModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeBytes: Int64
    let englishOnly: Bool
    let speed: Int
    let accuracy: Int

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

extension Notification.Name {
    static let whisperModelReady = Notification.Name("WhisperModelManager.modelReady")
}
