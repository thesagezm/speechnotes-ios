import Foundation
import OSLog
import WhisperKit

/// On-device model catalog + download manager for WhisperKit STT models.
/// Everything routes through WhisperKit's own HuggingFace downloader; we
/// only keep the path it returns so "is this model present?" survives
/// app restarts (WhisperKit itself stores the bundle wherever its internal
/// HubApi decides — we can't derive that location, we have to remember it).
@MainActor
final class WhisperModelManager: ObservableObject {

    static let shared = WhisperModelManager()

    /// Curated default catalog (Amical-style: tiny → base → small →
    /// large-v3-turbo, plus .en variants for English-only small models).
    static let catalog: [WhisperModel] = [
        WhisperModel(id: "tiny",           displayName: "Tiny",                  sizeBytes:   77_700_000, englishOnly: false,  speed: 5, accuracy: 2),
        WhisperModel(id: "tiny.en",        displayName: "Tiny (English only)",   sizeBytes:   77_700_000, englishOnly: true,   speed: 5, accuracy: 3),
        WhisperModel(id: "base",           displayName: "Base",                  sizeBytes:  148_000_000, englishOnly: false,  speed: 4, accuracy: 3),
        WhisperModel(id: "base.en",        displayName: "Base (English only)",   sizeBytes:  148_000_000, englishOnly: true,   speed: 4, accuracy: 3),
        WhisperModel(id: "small",          displayName: "Small",                 sizeBytes:  488_000_000, englishOnly: false,  speed: 3, accuracy: 4),
        WhisperModel(id: "small.en",       displayName: "Small (English only)",  sizeBytes:  488_000_000, englishOnly: true,   speed: 3, accuracy: 4),
        WhisperModel(id: "large-v3-turbo", displayName: "Large v3 Turbo",        sizeBytes: 1540_000_000, englishOnly: false,  speed: 3, accuracy: 5),
        WhisperModel(id: "large-v3",       displayName: "Large v3",              sizeBytes: 3100_000_000, englishOnly: false,  speed: 1, accuracy: 5),
    ]

    /// Catalog id → WhisperKit variant name (whisperkittools uses an
    /// "openai_whisper-" prefix on disk; we hand the prefix to WhisperKit
    /// only via `WhisperKitConfig.model`, never through folder paths —
    /// the path lookup below scans actual repo dirs instead of guessing).
    nonisolated static let variantForId: [String: String] = [
        "tiny":            "tiny",
        "tiny.en":         "tiny.en",
        "base":            "base",
        "base.en":         "base.en",
        "small":           "small",
        "small.en":        "small.en",
        "large-v3-turbo":  "large-v3-turbo",
        "large-v3":        "large-v3",
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

    /// Free disk bytes on the volume that holds Documents.
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
        let loaded = Self.loadInstalledFolders()
        Self.foldersLock.lock()
        Self.foldersStore = loaded
        Self.foldersLock.unlock()

        // Restore the previously-active id only if its folder is still on
        // disk; otherwise fall back to the first actually-installed model.
        let userActive = UserDefaults.standard.string(forKey: "activeWhisperModelId") ?? "tiny"
        let firstInstalled = Self.catalog.first(where: { isInstalled($0) })?.id
        if isInstalled(id: userActive) {
            activeModelId = userActive
        } else if let fallback = firstInstalled {
            activeModelId = fallback
        }

        // Seed the per-model state machine from what we can verify on disk.
        for model in Self.catalog {
            states[model.id] = isInstalled(id: model.id) ? .ready : .notDownloaded
        }
        logger.info("Init complete: installed=\(self.installedModels.map(\.id).joined(separator: ",")) active=\(self.activeModelId)")
    }

    // MARK: - Folder persistence

    /// Persisted map of catalog id → on-disk folder WhisperKit actually
    /// wrote the model into. This is the ONLY reliable record: we record the
    /// URL `WhisperKit.download` returns at download time and reuse it.
    /// A plain lock + class-level storage keeps the property accessible from
    /// `nonisolated` statics (Swift forbids mutable nonisolated stored
    /// members on an actor-isolated class, hence the dance).
    nonisolated private static let installedFoldersKey = "whisperInstalledFolders"
    nonisolated private static let foldersLock = NSLock()
    nonisolated(unsafe) private static var foldersStore: [String: URL] = [:]
    nonisolated static var installedFolders: [String: URL] {
        foldersLock.lock()
        defer { foldersLock.unlock() }
        return foldersStore
    }

    /// Set + persist in one call. UserDefaults writes are cheap enough for
    /// once-per-download/scan; the side effect keeps the map consistent.
    nonisolated static func recordInstalledFolder(_ url: URL, forId id: String) {
        foldersLock.lock()
        foldersStore[id] = url
        let snapshot = foldersStore
        foldersLock.unlock()
        persist(snapshot)
    }

    nonisolated static func removeInstalledFolder(forId id: String) {
        foldersLock.lock()
        foldersStore.removeValue(forKey: id)
        let snapshot = foldersStore
        foldersLock.unlock()
        persist(snapshot)
    }

    nonisolated private static func persist(_ folders: [String: URL]) {
        UserDefaults.standard.set(
            folders.mapValues { $0.path },
            forKey: installedFoldersKey
        )
    }

    nonisolated private static func loadInstalledFolders() -> [String: URL] {
        guard let raw = UserDefaults.standard.dictionary(forKey: installedFoldersKey) as? [String: String]
        else { return [:] }
        return raw.compactMapValues { URL(fileURLWithPath: $0) }
    }

    /// Scan the HuggingFace / WhisperKit caches for a folder whose name
    /// contains the variant string (whisperkittools prefixes variants, e.g.
    /// `openai_whisper-tiny/`). Covers pre-fix installs and any cross-version
    /// drift in WhisperKit's folder layout.
    nonisolated private static func bundledCacheDirs() -> [URL] {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return [
            docs.appendingPathComponent("huggingface", isDirectory: true),
            docs.appendingPathComponent("argmaxinc", isDirectory: true),
            appSupport.appendingPathComponent("huggingface", isDirectory: true),
            appSupport.appendingPathComponent("argmaxinc", isDirectory: true),
            caches.appendingPathComponent("huggingface", isDirectory: true),
        ]
    }

    /// The on-disk folder containing `variant`'s CoreML bundle (or nil if
    /// not installed). All "is installed?" checks funnel through here.
    nonisolated static func modelFolder(forId id: String) -> URL? {
        // 1. The exact URL WhisperKit returned at download time.
        if let recorded = installedFolders[id],
           FileManager.default.fileExists(atPath: recorded.path) {
            return recorded
        }

        // 2. Scan known caches for a subfolder whose name contains the variant.
        guard let variant = variantForId[id] else { return nil }
        for cacheRoot in bundledCacheDirs() {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let candidates = children + children.flatMap { child in
                (try? FileManager.default.contentsOfDirectory(
                    at: child,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
            }
            if let hit = candidates.first(where: {
                $0.lastPathComponent.contains(variant) &&
                (try? FileManager.default.contentsOfDirectory(atPath: $0.path).isEmpty) == false
            }) {
                recordInstalledFolder(hit, forId: id)   // learn once
                return hit
            }
        }
        return nil
    }

    // MARK: - State queries

    /// Total on-disk size of every installed Whisper model — shown in
    /// Settings → Storage.
    nonisolated static var installedFootprintBytes: Int64 {
        installedFolders.values.reduce(0) { $0 + ExportsStore.directorySize($1) }
    }

    func isInstalled(_ model: WhisperModel) -> Bool { isInstalled(id: model.id) }
    /// Bypasses the public struct so the init can run before any view exists.
    func isInstalled(id: String) -> Bool { Self.modelFolder(forId: id) != nil }

    func state(for id: String) -> DownloadState { states[id] ?? .notDownloaded }

    var installedModels: [WhisperModel] {
        Self.catalog.filter { isInstalled($0) }
    }

    // MARK: - Download

    func startDownload(id: String) {
        guard let model = Self.catalog.first(where: { $0.id == id }) else { return }
        if case .downloading = states[id] { return }
        guard !inFlightDownloads.contains(id) else { return }
        guard let variant = Self.variantForId[id] else {
            states[id] = .failed("Unknown model variant.")
            return
        }

        // Disk preflight.
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
                let modelFolder = try await WhisperKit.download(variant: variant, progressCallback: progressCallback)
                self.inFlightDownloads.remove(id)
                Self.recordInstalledFolder(modelFolder, forId: id)
                self.states[id] = .ready
                self.logger.info("WhisperKit model ready: \(variant) at \(modelFolder.path)")
                NotificationCenter.default.post(name: .whisperModelReady, object: id)
            } catch {
                self.inFlightDownloads.remove(id)
                self.states[id] = .failed(error.localizedDescription)
                self.logger.error("WhisperKit download failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload(id: String) {
        if case .downloading = states[id] {
            states[id] = .notDownloaded
        }
    }

    func delete(id: String) {
        cancelDownload(id: id)
        if let dir = Self.modelFolder(forId: id) {
            try? FileManager.default.removeItem(at: dir)
        }
        Self.removeInstalledFolder(forId: id)
        states[id] = .notDownloaded
        if activeModelId == id {
            activeModelId = Self.catalog.first(where: { isInstalled($0) })?.id ?? "tiny"
        }
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
