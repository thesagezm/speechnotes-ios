import Combine
import CryptoKit
import Foundation
import Network
import UIKit

/// One completed (or routed) transfer, for the BookDrop history list.
struct BookDropRecord: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let size: Int64
    let outcome: Outcome
    let at: Date

    enum Outcome: Equatable {
        case imported(String)
        case failed(String)
        case rejected
    }
}

/// The BookDrop receiver: a LocalSend protocol v2.2 peer that ACCEPTS
/// incoming transfers (Readest's "Nearby BookDrop" speaks the same protocol,
/// and so does the user's existing LocalSend app on PC — no new PC software).
///
/// Receive-only by design: iOS has no multicast entitlement, and a receiver
/// doesn't need it — LocalSend senders find peers by a /24 unicast scan
/// hitting the HTTP /register endpoint, which just requires our server to
/// be up on the LAN. See Docs/BOOKDROP.md for the protocol map and the
/// Linux/Android porting notes.
///
/// Concurrency: the HTTP handler runs on the server queue and hops to the
/// main actor for the endpoint logic (short: decode, hash, file rename);
/// imports continue async afterwards. All session state is therefore
/// MainActor-isolated and the protocol logic reads linearly.
@MainActor
final class LocalSendReceiver: ObservableObject {
    static let shared = LocalSendReceiver()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var lastError: String?
    @Published private(set) var history: [BookDropRecord] = []

    /// Extensions we accept, route and import today. Legacy DOC joins when
    /// its best-effort parser lands.
    static let acceptedExtensions: Set<String> = ["epub", "pdf", "m4b", "m4a", "mp4", "mp3", "jex", "docx", "odt", "pptx", "odp"]

    private let server = LocalSendHTTPServer()
    private var sessions: [String: Session] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Set by the app at launch: routes a landed file into the import
    /// pipeline (books store / JEX importer). Receives a file COPY in our
    /// own temp space — security scope is ours, no coordinates needed.
    /// MainActor: it touches the stores.
    var router: (@MainActor (URL) async -> Void)?

    // MARK: - Settings

    @Published var autoAccept: Bool {
        didSet { UserDefaults.standard.set(autoAccept, forKey: "bookDropAutoAccept") }
    }

    private init() {
        autoAccept = UserDefaults.standard.object(forKey: "bookDropAutoAccept") as? Bool ?? true
        // The HTTP server hands every request straight to the endpoint
        // router below (nonisolated — it hops to the main actor itself).
        server.handler = { [weak self] request in
            guard let self else { return .status(500) }
            return self.handle(request)
        }
        // The Readest zombie-listener lesson, wired from day one: on every
        // return to foreground, probe the listener with a loopback connect
        // and rebuild it if iOS reclaimed the socket while suspended.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.probeAndHeal()
            }
        }
    }

    /// Whether the user's persisted toggle says BookDrop should be running
    /// (the Settings screen writes the same key through @AppStorage).
    var isEnabledInDefaults: Bool {
        UserDefaults.standard.bool(forKey: "bookDropEnabled")
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// Called at app launch: starts the server when the persisted toggle is
    /// on (deferred past the first frame by the caller).
    func applyPersistedEnabledState() {
        if isEnabledInDefaults {
            start()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        lastError = nil
        server.start { [weak self] port in
            guard let self else { return }
            self.isRunning = true
            self.port = port
        } onFailed: { [weak self] message in
            guard let self else { return }
            self.isRunning = false
            self.lastError = message
        }
    }

    func stop() {
        server.stop()
        isRunning = false
        port = 0
        for session in sessions.values { discardSession(session) }
        sessions.removeAll()
    }

    private func probeAndHeal() {
        guard isEnabledInDefaults else { return }
        server.verifyAlive { [weak self] alive in
            Task { @MainActor in
                guard let self else { return }
                if alive {
                    self.isRunning = true
                } else {
                    // Stop FIRST: start() on a still-registered listener
                    // returns the existing (dead) one — the exact trap
                    // Readest hit (their PR #6049).
                    self.stop()
                    if self.isEnabledInDefaults {
                        self.start()
                    }
                }
            }
        }
    }

    // MARK: - Identity

    private var deviceAlias: String {
        UIDevice.current.name
    }

    private var fingerprint: String {
        if let existing = UserDefaults.standard.string(forKey: "bookDropFingerprint") {
            return existing
        }
        let fresh = UUID().uuidString + UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "bookDropFingerprint")
        return fresh
    }

    private var deviceDTO: LocalSendDevice {
        LocalSendDevice(
            alias: deviceAlias,
            version: "2.2",
            deviceModel: nil,
            deviceType: "mobile",
            fingerprint: fingerprint,
            port: Int(port),
            protocolField: "http",
            download: false
        )
    }

    // MARK: - Request routing

    /// Entry from the server queue (nonisolated): block that queue while the
    /// main actor runs the endpoint. Endpoints are deliberately short — the
    /// only heavyweight step is the sha256 of a landed file, a once-per-file
    /// cost during a user-initiated transfer (mapped I/O + ~1 GB/s hash).
    nonisolated private func handle(_ request: LocalSendHTTPRequest) -> LocalSendHTTPResponse {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                handleOnMain(request)
            }
        }
    }

    private func handleOnMain(_ request: LocalSendHTTPRequest) -> LocalSendHTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/api/localsend/v2/register"), ("GET", "/api/localsend/v2/info"):
            return .json(deviceDTO)
        case ("POST", "/api/localsend/v2/prepare-upload"):
            return respondPrepareUpload(request)
        case ("POST", "/api/localsend/v2/upload"):
            return respondUpload(request)
        case ("POST", "/api/localsend/v2/cancel"):
            return respondCancel(request)
        default:
            return .notFound()
        }
    }

    private func respondPrepareUpload(_ request: LocalSendHTTPRequest) -> LocalSendHTTPResponse {
        // JSON endpoint — bodies belong in memory (spill threshold is 8 MB,
        // prepare bodies are a few KB).
        guard case .memory(let data) = request.body,
              let payload = try? JSONDecoder().decode(LocalSendPrepareUpload.self, from: data) else {
            return .badRequest()
        }
        guard autoAccept else { return .forbidden() }
        guard sessions.isEmpty else { return .conflict() } // one transfer at a time

        let accepted = payload.files.filter {
            LocalSendReceiver.acceptedExtensions.contains(fileExtension($0.value.fileName))
        }
        // Partial accept: omitted file ids count as rejected per spec.
        guard !accepted.isEmpty else { return .forbidden() }

        let session = Session(senderHost: request.remoteHost, files: accepted)
        sessions[session.id] = session
        armTimeout(session)
        return .json(LocalSendPrepareResponse(sessionId: session.id, files: session.tokens))
    }

    private func respondUpload(_ request: LocalSendHTTPRequest) -> LocalSendHTTPResponse {
        guard let sessionId = request.queryValue("sessionId"),
              let fileId = request.queryValue("fileId"),
              let token = request.queryValue("token"),
              let session = sessions[sessionId] else {
            return .badRequest()
        }
        // A third party must not inject files into someone's session.
        guard session.senderHost == nil || session.senderHost == request.remoteHost else {
            return .forbidden()
        }
        guard session.tokens[fileId] == token else {
            return .forbidden()
        }
        guard !session.receivedIds.contains(fileId) else {
            return .conflict() // duplicate upload of the same file
        }
        guard let meta = session.files[fileId] else {
            return .badRequest()
        }
        switch request.body {
        case .file(let url, let byteCount):
            guard byteCount == meta.size else { return .unsupported() }
            if let expected = meta.sha256, !expected.isEmpty,
               !Self.matchesSHA256(url: url, expected: expected) {
                return .unsupported() // 422: sha mismatch
            }
            return land(url: url, session: session, fileId: fileId, meta: meta)
        case .memory(let data):
            guard Int64(data.count) == meta.size else { return .unsupported() }
            if let expected = meta.sha256, !expected.isEmpty,
               digestHex(SHA256.hash(data: data)) != expected.lowercased() {
                return .unsupported()
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("localsend-body-\(UUID().uuidString)")
            guard (try? data.write(to: url, options: .atomic)) != nil else {
                return .status(500)
            }
            return land(url: url, session: session, fileId: fileId, meta: meta)
        }
    }

    /// Moves a verified body into the session dir (same volume → a rename)
    /// and routes when the last file lands.
    private func land(url: URL, session: Session, fileId: String, meta: LocalSendFileMeta) -> LocalSendHTTPResponse {
        let target = session.dir.appendingPathComponent(Self.safeFileName(meta.fileName, fallback: fileId))
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            return .status(500)
        }
        session.receivedIds.insert(fileId)
        if session.receivedIds.count >= session.files.count {
            complete(session)
        }
        return .status(200)
    }

    private func respondCancel(_ request: LocalSendHTTPRequest) -> LocalSendHTTPResponse {
        guard let sessionId = request.queryValue("sessionId"), let session = sessions[sessionId] else {
            return .badRequest()
        }
        discardSession(session)
        return .status(200)
    }

    // MARK: - Session plumbing

    private final class Session {
        let id = UUID().uuidString
        let senderHost: String?
        let dir: URL
        var files: [String: LocalSendFileMeta]
        var tokens: [String: String]
        var receivedIds: Set<String> = []

        init(senderHost: String?, files: [String: LocalSendFileMeta]) {
            self.senderHost = senderHost
            self.files = files
            self.dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("BookDrop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tokens = files.keys.reduce(into: [:]) { acc, key in
                acc[key] = UUID().uuidString
            }
        }
    }

    private func armTimeout(_ session: Session) {
        timeoutTasks[session.id]?.cancel()
        timeoutTasks[session.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.timedOut(sessionId: session.id)
        }
    }

    private func timedOut(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        let received = session.receivedIds.count
        let offered = session.files.count
        discardSession(session)
        if received > 0 {
            insertHistory(
                BookDropRecord(
                    name: "\(received) of \(offered) file\(offered == 1 ? "" : "s")",
                    size: 0,
                    outcome: .failed("Transfer timed out"),
                    at: Date()
                )
            )
        }
    }

    private func discardSession(_ session: Session) {
        timeoutTasks[session.id]?.cancel()
        timeoutTasks.removeValue(forKey: session.id)
        try? FileManager.default.removeItem(at: session.dir)
        sessions.removeValue(forKey: session.id)
    }

    /// All files landed — route each into the import pipeline, then clean.
    private func complete(_ session: Session) {
        let landed = session.files.values
            .filter { session.receivedIds.contains($0.id) }
            .map { Self.safeFileName($0.fileName, fallback: $0.id) }
        let dir = session.dir
        timeoutTasks[session.id]?.cancel()
        timeoutTasks.removeValue(forKey: session.id)
        sessions.removeValue(forKey: session.id)

        Task { [weak self] in
            for name in landed {
                let url = dir.appendingPathComponent(name)
                await self?.router?(url)
            }
            // The router consumes the files it handles; sweep anything left
            // over (rejected leftovers, failed imports) after a grace beat.
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Called by the router after a file reached its destination so history
    /// reflects the truth (imported / failed).
    func reportImport(name: String, size: Int64, outcome: BookDropRecord.Outcome) {
        insertHistory(BookDropRecord(name: name, size: size, outcome: outcome, at: Date()))
    }

    private func insertHistory(_ record: BookDropRecord) {
        history.insert(record, at: 0)
        if history.count > 20 {
            history.removeLast(history.count - 20)
        }
    }

    // MARK: - Helpers

    private func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    static func safeFileName(_ name: String, fallback: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        if base.isEmpty || base == "." || base == ".." {
            return "file-\(fallback)"
        }
        return base
    }

    private static func matchesSHA256(url: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return digestHex(SHA256.hash(data: data)) == expected.lowercased()
    }

    private static func digestHex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
