import Foundation
import SpeechLogic
import WebKit

// MARK: - Errors

/// File-scope so the webview session can name it; the extractor re-exports it
/// as `PaperoExtractor.PaperoError` for callers.
public enum PaperoExtractorError: LocalizedError, Sendable {
    case loadFailed(String)
    case engineError(String)
    case emptyResult
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let detail): return "The PDF extractor could not load: \(detail)"
        case .engineError(let detail): return "The PDF extractor failed: \(detail)"
        case .emptyResult: return "The PDF extractor found no text in this document."
        case .cancelled: return "The PDF extraction was cancelled."
        }
    }
}

/// Runs papero's layout engine on a PDF, on the device, with no network.
///
/// ## Why a webview
///
/// papero is a Python package; the only part an iOS app can embed is its
/// browser build (`web/assets/engine.js`) — a documented port of the same
/// layout analysis, running on pdf.js. The app already runs a WKWebView for
/// the EPUB reader, so this is a second one, but it is never shown: it loads,
/// serves the document, and is torn down when the extraction ends.
///
/// ## Why a page window at a time
///
/// The engine takes a document's whole byte array. A 266 MB book resident in
/// a webview's JavaScript heap is exactly the memory profile that made this
/// app unkillable before, so the driver walks the document in bounded page
/// windows, appends each window's markdown, and lets the previous window's
/// bytes go. It also gives progress on a long import and makes cancellation
/// land on a window boundary instead of mid-page.
///
/// ## Failure
///
/// Every way this can fail surfaces as a thrown `PaperoError`, and the caller
/// decides what it means: `.automatic` falls back to PDFKit, `.papero` reports.
public actor PaperoExtractor {

    public typealias PaperoError = PaperoExtractorError

    public struct Result: Sendable {
        /// Papero's markdown: headings, tables, lists and formulas in
        /// document order, with page furniture removed.
        public let markdown: String
        /// UTF-16 offset into `markdown` where each extracted page begins,
        /// so the reader can scroll the PDF to the page that is sounding.
        public let pageOffsets: [PdfPageOffset]
        public let pageCount: Int
        /// The engine's own "this looks scanned" verdict. A scanned page set
        /// has no text layer to reconstruct, so papero's accuracy buys
        /// nothing there — `.automatic` uses this to skip straight to the
        /// built-in path instead of grinding through every page.
        public let likelyScanned: Bool
        public let elapsed: TimeInterval
    }

    /// Pages per window: small enough that a window's bytes stay modest,
    /// large enough that per-page overhead does not dominate.
    static let pagesPerWindow = 8

    /// A window on a dense page is slow; generous, but bounded.
    static let windowTimeout: TimeInterval = 240
    /// The shell loads pdf.js; that is quick, but not instant on a cold start.
    static let loadTimeout: TimeInterval = 30

    private var session: Session?
    private var cancelled = false

    public init() {}

    public func isRunning() -> Bool { session != nil }

    /// Extracts `url` in page windows.
    ///
    /// - Parameters:
    ///   - pageRange: the pages to extract, 1-based and inclusive, when the
    ///     caller knows them (a book chapter is a contiguous range). `nil`
    ///     means the whole document, taken in page-count windows.
    ///   - progress: called after each window with pages done / total.
    public func extract(
        pdf url: URL,
        pageRange: ClosedRange<Int>? = nil,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Result {
        guard session == nil else {
            throw PaperoError.engineError("an extraction is already running")
        }
        let started = Date()
        let session = Session(pdfURL: url)
        self.session = session

        do {
            defer { Task { await session.shutdown() } }
            return try await run(session: session, pageRange: pageRange, started: started, progress: progress)
        } catch {
            self.session = nil
            throw error
        }
    }

    private func run(
        session: Session,
        pageRange: ClosedRange<Int>?,
        started: Date,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)?
    ) async throws -> Result {
        try await session.prepare()
        if cancelled { throw PaperoError.cancelled }

        var windows: [String] = []
        var offsets: [PdfPageOffset] = []
        var scanned = false
        var total = pageRange?.count ?? 0
        var done = 0

        let windowsToRun: [ClosedRange<Int>]
        if let pageRange {
            windowsToRun = stride(from: pageRange.lowerBound, to: pageRange.upperBound, by: Self.pagesPerWindow)
                .map { $0...min($0 + Self.pagesPerWindow - 1, pageRange.upperBound) }
        } else {
            // No range given: extract everything in one window and take the
            // document's true length from the engine's own answer.
            windowsToRun = [1...Int.max]
        }

        for window in windowsToRun {
            if cancelled { throw PaperoError.cancelled }
            let spec: String? = window.upperBound == Int.max ? nil : Self.pageSpec(window)
            let message = try await session.runWindow(spec: spec)
            let markdown = message["markdown"] as? String ?? ""
            if !markdown.isEmpty {
                // Offsets are per window, so they shift by what came before.
                // The final join trims each window and separates with a
                // blank line, so the base has to be computed the same way.
                let base = windows.reduce(0) {
                    $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count + 2
                }
                for entry in message["pageOffsets"] as? [[String: Any]] ?? [] {
                    guard let page = entry["page"] as? Int, let offset = entry["offset"] as? Int else { continue }
                    offsets.append(PdfPageOffset(page: page, utf16Offset: base + offset))
                }
                windows.append(markdown)
            }
            scanned = scanned || (message["likelyScanned"] as? Bool ?? false)
            if let reported = message["pageCount"] as? Int, reported > 0, pageRange == nil {
                total = reported
            }
            if window.upperBound != Int.max {
                done = min(window.upperBound, total)
            } else {
                done = total
            }
            progress?(done, total)
        }

        let markdown = windows
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !markdown.isEmpty else { throw PaperoError.emptyResult }
        let result = Result(
            markdown: markdown,
            pageOffsets: offsets,
            pageCount: total,
            likelyScanned: scanned,
            elapsed: Date().timeIntervalSince(started)
        )
        self.session = nil
        return result
    }

    /// Stops the running extraction at the next window boundary.
    public func cancel() {
        cancelled = true
        Task { await session?.shutdown() }
    }

    static func pageSpec(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound)-\(range.upperBound)"
    }
}

// MARK: - The webview session

/// One webview, one document. Main-actor throughout: WKWebView is a UIKit
/// type and its delegates are called on the main thread, so pretending
/// otherwise buys nothing.
@MainActor
private final class Session: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {

    /// Read by the IO queue, so it is deliberately nonisolated; the URL is
    /// a value type and nothing here mutates it.
    nonisolated private let pdfURL: URL
    private var webView: WKWebView?
    private var ready = false
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var windowWaiter: CheckedContinuation<[String: Any], Error>?

    /// Bundled engine files behind an allow-list. The EPUB reader learned this
    /// the hard way: serving any bundle resource to a page that can run
    /// scripts is an exfiltration path.
    nonisolated static let allowedResources: Set<String> = [
        "extract.html", "engine.js", "columns.js", "symbols.js",
        "texfonts.js", "mathtext.js", "pdf.min.mjs", "pdf.worker.min.mjs",
    ]

    nonisolated static let scheme = "paperoscheme"
    private let ioQueue = DispatchQueue(label: "com.speechnotes.papero.io", qos: .userInitiated)
    /// Scheme tasks are added on main and read from the IO queue, so the set
    /// cannot be an actor-isolated stored property — it lives behind its own
    /// lock, and `stop` removes the task because delivering to a stopped one
    /// raises an exception.
    nonisolated private let liveTasks = SchemeTaskRegistry()

    /// `nonisolated` so the owning actor can construct the session without
    /// hopping; nothing here touches main state.
    nonisolated init(pdfURL: URL) {
        self.pdfURL = pdfURL
    }

    func prepare() async throws {
        if ready { return }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        configuration.userContentController.add(self, name: "papero")
        // Pure computation over bytes we supply — nothing on this page has
        // any business reaching the network.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        self.webView = webView
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://app/extract.html")!))
        try await withTimeout(PaperoExtractor.loadTimeout) { try await self.waitForReady() }
    }

    func runWindow(spec: String?) async throws -> [String: Any] {
        guard let webView else { throw PaperoError.loadFailed("no extractor") }
        let specArgument = spec.map { "\"\($0)\"" } ?? "undefined"
        let script = "window.papero.extract(\"\(Self.scheme)://app/document.pdf\", \(specArgument))"
        return try await withTimeout(PaperoExtractor.windowTimeout) {
            try await self.waitForMessage(script: script, in: webView)
        }
    }

    func shutdown() {
        readyWaiter?.resume(throwing: PaperoError.cancelled)
        readyWaiter = nil
        windowWaiter?.resume(throwing: PaperoError.cancelled)
        windowWaiter = nil
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "papero")
            webView.stopLoading()
        }
        webView = nil
        ready = false
    }

    // MARK: Waiting

    private func waitForReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            if ready { continuation.resume(); return }
            readyWaiter = continuation
        }
    }

    private func waitForMessage(script: String, in webView: WKWebView) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            windowWaiter = continuation
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, let waiter = self.windowWaiter else { return }
                    self.windowWaiter = nil
                    waiter.resume(throwing: PaperoError.engineError(error.localizedDescription))
                }
            }
        }
    }

    /// A continuation nobody resumes is a hang, so every wait is raced
    /// against a deadline.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PaperoError.loadFailed("timed out after \(Int(seconds))s")
            }
            guard let first = try await group.next() else {
                throw PaperoError.loadFailed("no result")
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            readyWaiter?.resume()
            readyWaiter = nil
        case "result", "error":
            guard let waiter = windowWaiter else { return }
            windowWaiter = nil
            if type == "error" {
                waiter.resume(throwing: PaperoError.engineError(
                    payload["message"] as? String ?? "unknown"
                ))
            } else {
                waiter.resume(returning: payload)
            }
        default:
            break
        }
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        liveTasks.insert(id)
        let path = url.path.isEmpty || url.path == "/" ? "/extract.html" : url.path
        ioQueue.async { [weak self] in
            self?.serve(path: path, task: urlSchemeTask, id: id)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        liveTasks.remove(id)
    }

    nonisolated private func isLive(_ id: ObjectIdentifier) -> Bool {
        return liveTasks.contains(id)
    }

    nonisolated private func serve(path: String, task: WKURLSchemeTask, id: ObjectIdentifier) {
        if path == "/document.pdf" {
            let attributes = try? FileManager.default.attributesOfItem(atPath: pdfURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, let handle = try? FileHandle(forReadingFrom: pdfURL) else {
                fail(task, id, URLError(.fileDoesNotExist))
                return
            }
            stream(handle: handle, size: size, task: task, id: id)
            return
        }
        let name = String(path.dropFirst())
        guard let (data, mime) = Self.bundleResource(name) else {
            fail(task, id, URLError(.fileDoesNotExist))
            return
        }
        send(response: response(url: task.request.url, mime: mime, length: Int64(data.count), ranges: false),
             data: data, task: task, id: id)
    }

    /// Streams the PDF in chunks — never holding the whole file on this side
    /// either, which is the whole point of the windowed design.
    nonisolated private func stream(handle: FileHandle, size: Int64, task: WKURLSchemeTask, id: ObjectIdentifier) {
        send(response: response(url: task.request.url, mime: "application/pdf", length: size, ranges: true),
             data: nil, task: task, id: id)
        let chunk: Int = 1 << 20
        var sent: Int64 = 0
        while sent < size, isLive(id) {
            guard let bytes = try? handle.read(upToCount: chunk), !bytes.isEmpty else { break }
            sent += Int64(bytes.count)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isLive(id) else { return }
                task.didReceive(bytes)
            }
        }
        try? handle.close()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLive(id) else { return }
            task.didFinish()
        }
    }

    nonisolated private func response(url: URL?, mime: String, length: Int64, ranges: Bool) -> HTTPURLResponse {
        var headers = [
            "Content-Type": mime,
            "Content-Length": "\(length)",
            "Cache-Control": "no-store",
        ]
        if ranges { headers["Accept-Ranges"] = "bytes" }
        return HTTPURLResponse(url: url ?? URL(string: "\(Self.scheme)://app/")!,
                               statusCode: 200, httpVersion: "HTTP/1.1",
                               headerFields: headers)!
    }

    nonisolated private func send(response: HTTPURLResponse, data: Data?, task: WKURLSchemeTask, id: ObjectIdentifier) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLive(id) else { return }
            task.didReceive(response)
            if let data { task.didReceive(data) }
            task.didFinish()
        }
    }

    nonisolated private func fail(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLive(id) else { return }
            task.didFailWithError(error)
        }
    }

    nonisolated private static func bundleResource(_ name: String) -> (Data, String)? {
        guard allowedResources.contains(name) else { return nil }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        let mime: String
        switch ext {
        case "html": mime = "text/html; charset=utf-8"
        case "js", "mjs": mime = "text/javascript; charset=utf-8"
        default: mime = "application/octet-stream"
        }
        return (data, mime)
    }
}


/// The set of live scheme tasks, with its own lock: it is written on the main
/// thread and read on the extraction's IO queue, which is exactly the data
/// race the EPUB reader's registry documents.
private final class SchemeTaskRegistry: @unchecked Sendable {
    private var tasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    func insert(_ id: ObjectIdentifier) {
        lock.lock(); tasks.insert(id); lock.unlock()
    }

    func remove(_ id: ObjectIdentifier) {
        lock.lock(); tasks.remove(id); lock.unlock()
    }

    func contains(_ id: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks.contains(id)
    }
}
