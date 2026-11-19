import Foundation
import WebKit
import SpeechLogic

/// The headless document importer's parse engine: a hidden WKWebView running
/// the SAME vendored foliate-js modules the reader uses (DocumentParseService
/// and the foliate reader are one parser — mobi.js decompresses the
/// Mobipocket/Kindle family, fb2.js the FictionBook, the RTF/HTML/txt
/// builders the rest). That is the whole point: the chapters the manifest
/// records, the text the TTS reads and the sections the reader shows are one
/// chaptering, so chapter indexes can never drift between speaking and
/// reading — the Linux reader's exact architecture, where the importer and
/// the view both run on foliate's parse.
///
/// The service loads foliate.html in `mode=parse` off `bookscheme://` (the
/// shell module dispatches there) and walks the parsed book section by
/// section, serializing each section's document to XHTML. The files land in
/// the book's doc/ directory under the SAME names the pre-foliate pipeline
/// used (doc/chapter-N.html — the TTS chapter reader's contract), so
/// everything downstream of the import keeps working unchanged.
///
/// RAM discipline (this runs while the user watches the import spinner): the
/// book's bytes are streamed to the webview from a FileHandle — no Swift-side
/// copy — and sections cross the bridge ONE at a time (prepareSection posts
/// when its string is ready; takeSection hands it over and drops it), so at
/// most one chapter's XHTML exists on either side of the bridge beyond the
/// webview's own working set. The webview (and its whole WebContent process)
/// is released the moment the walk ends.
///
/// Isolation matches the repo's other headless-webview pass
/// (WebArticleService.HeadlessArticlePass): the class itself is plain, the
/// async walk is @MainActor (a WKWebView must be created and driven on the
/// main thread), and the WebKit delegate callbacks run on main at runtime.
final class DocumentParseService: NSObject {
    enum ParseError: LocalizedError {
        case engineUnavailable
        case timeout
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .engineUnavailable: return "the document engine could not start"
            case .timeout: return "the document took too long to read"
            case .malformed(let message): return message
            }
        }
    }

    /// Everything the import path needs from the parse. `sectionFiles` is one
    /// XHTML file per foliate section, in section order — the manifest spine
    /// ("chapter-0", …) and the TTS text source are derived from this list.
    struct Result {
        var title: String?
        var author: String?
        var sectionCount: Int
        var toc: [BookTocEntry]
        var coverData: Data?
        var sectionFiles: [(path: String, data: Data)]
    }

    /// The parse page's metadata report (window.__snParse.meta()).
    private struct ParseMeta: Decodable {
        var title: String?
        var author: String?
        var language: String?
        var sectionCount: Int
        var toc: [TocRow]?

        struct TocRow: Decodable {
            var label: String?
            var href: String?
            var index: Int?
            var depth: Int?
        }
    }

    /// Parses the document at `sourceURL` (any .document family extension).
    /// The URL is streamed by the scheme handler — pass the ORIGINAL file on
    /// disk, never an in-memory copy.
    static func parse(fileExtension: String, sourceURL: URL) async throws -> Result {
        let service = DocumentParseService(fileExtension: fileExtension, sourceURL: sourceURL)
        return try await service.run()
    }

    private let fileExtension: String
    private let sourceURL: URL
    /// The one webview this service owns, created in `run`.
    private var webView: WKWebView?
    /// Out-of-order message buffer: the shell posts freely (the 45 s
    /// watchdog, parse milestones); a step that is not waiting yet must not
    /// lose a message that arrived early.
    private var bufferedMessages: [[String: Any]] = []
    private var waiters: [(types: Set<String>, continuation: CheckedContinuation<[String: Any], Never>)] = []
    /// Total budget for the whole walk — the JS watchdog catches a stuck
    /// boot at 45 s, this catches a stuck walk.
    private let deadline = Date().addingTimeInterval(180)
    /// File reads run off the main thread; deliveries hop back to main (the
    /// BookWebView scheme handler's exact pattern — reading a 50 MB book on
    /// the main thread is the freeze the spinner exists to cover).
    private let ioQueue = DispatchQueue(label: "com.speechnotes.docparse", qos: .userInitiated)
    /// Scheme tasks still being served; every delivery checks membership —
    /// calling into a stopped task raises NSException.
    private var liveTasks = Set<ObjectIdentifier>()
    private let liveTasksLock = NSLock()

    private func isLive(_ taskID: ObjectIdentifier) -> Bool {
        liveTasksLock.lock()
        defer { liveTasksLock.unlock() }
        return liveTasks.contains(taskID)
    }

    private init(fileExtension: String, sourceURL: URL) {
        self.fileExtension = fileExtension
        self.sourceURL = sourceURL
    }

    @MainActor private func run() async throws -> Result {
        defer { teardown() }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: "bookscheme")
        config.userContentController.add(self, name: "reader")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000), configuration: config)
        // Never on screen: the parse page renders nothing (mode=parse skips
        // the view), so no window/attachment is needed.
        webView.isHidden = true
        self.webView = webView

        var components = URLComponents(string: "bookscheme://shell/foliate.html")
        components?.queryItems = [
            URLQueryItem(name: "mode", value: "parse"),
            URLQueryItem(name: "format", value: fileExtension),
            URLQueryItem(name: "src", value: "/parse/current"),
        ]
        guard let url = components?.url else { throw ParseError.engineUnavailable }
        webView.load(URLRequest(url: url))

        // The shell posts `parseReady` when the book object is up (and
        // `error` for a failed boot — DRM, malformed container, a .pdb that
        // is really some other Palm format).
        let ready = try await nextMessage(accepting: ["parseReady", "error"])
        switch ready["type"] as? String {
        case "parseReady": break
        case "error":
            throw ParseError.malformed(ready["message"] as? String ?? "the document could not be parsed")
        default:
            // "teardown" — the wait was cancelled (the deadline gave up).
            throw ParseError.timeout
        }

        // The metadata report — title/author/TOC. `meta()` is synchronous:
        // the shell resolved the TOC (async href resolution) before exposing
        // __snParse.
        let metaJSON = try await evaluate("window.__snParse.meta()")
        guard let metaString = metaJSON as? String,
              let meta = try? JSONDecoder().decode(ParseMeta.self, from: Data(metaString.utf8)) else {
            throw ParseError.malformed("the document's metadata could not be read")
        }

        var files: [(path: String, data: Data)] = []
        files.reserveCapacity(meta.sectionCount)
        for index in 0..<meta.sectionCount {
            try checkDeadline()
            // One section per round trip — prepareSection posts parseSection
            // when the string is ready; takeSection hands it over and drops
            // it (one chapter's XHTML in the heap at a time). The sequence
            // expression tails a serializable value: prepareSection returns
            // a Promise, which evaluateJavaScript cannot serialize (the
            // completion posts the message instead).
            _ = try await evaluate("window.__snParse.prepareSection(\(index)); 'kicked'")
            let message = try await nextMessage(accepting: ["parseSection"])
            guard message["type"] as? String == "parseSection" else {
                throw ParseError.timeout
            }
            guard message["ok"] as? Bool == true else {
                throw ParseError.malformed(message["message"] as? String ?? "a chapter could not be read")
            }
            let html = try await evaluate("window.__snParse.takeSection()")
            // An empty section still gets its file: the spine is the
            // section list, 1:1 — a gap would shift every later chapter.
            let text = (html as? String) ?? ""
            files.append((path: "chapter-\(index).html", data: Data(text.utf8)))
        }

        // The cover — mobi/fb2 carry one in the file; the rest fall back to
        // the synthesized tile downstream. Small enough for one message.
        _ = try await evaluate("window.__snParse.prepareCover(); 'kicked'")
        let coverMessage = try await nextMessage(accepting: ["parseCover"])
        guard coverMessage["type"] as? String == "parseCover" else {
            throw ParseError.timeout
        }
        let coverData = (coverMessage["b64"] as? String).flatMap(Data.init(base64Encoded:))

        let toc = (meta.toc ?? []).compactMap { row -> BookTocEntry? in
            guard let label = row.label, let href = row.href else { return nil }
            return BookTocEntry(
                label: label,
                href: href,
                spineIndex: row.index,
                depth: row.depth
            )
        }
        return Result(
            title: meta.title,
            author: meta.author,
            sectionCount: meta.sectionCount,
            toc: toc,
            coverData: coverData,
            sectionFiles: files
        )
    }

    @MainActor private func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        bufferedMessages.removeAll()
        // Any still-streaming scheme task must see itself dead — delivering
        // to a stopped task raises NSException.
        liveTasksLock.lock()
        liveTasks.removeAll()
        liveTasksLock.unlock()
        // Any still-parked waiter must not leak its continuation.
        for waiter in waiters {
            waiter.continuation.resume(returning: ["type": "teardown"])
        }
        waiters.removeAll()
    }

    @MainActor private func checkDeadline() throws {
        if Date() > deadline { throw ParseError.timeout }
    }

    // MARK: bridge helpers

    /// evaluateJavaScript with the completion surfaced as a thrown error — a
    /// dead or closed webview must fail the import, not hang it.
    @MainActor private func evaluate(_ script: String) async throws -> Any? {
        try checkDeadline()
        guard let webView else { throw ParseError.engineUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Waits for one of `types`. Buffered messages (posted while no step was
    /// waiting) match first.
    @MainActor private func nextMessage(accepting types: Set<String>) async throws -> [String: Any] {
        try checkDeadline()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let index = bufferedMessages.firstIndex(where: {
                    types.contains($0["type"] as? String ?? "")
                }) {
                    continuation.resume(returning: bufferedMessages.remove(at: index))
                    return
                }
                waiters.append((types, continuation))
            }
        } onCancel: {
            // The wait's task was cancelled — resume the parked continuation
            // with a teardown marker so nothing leaks.
            Task { @MainActor in
                self.failWaiters()
            }
        }
    }

    /// Resumes every parked waiter with a teardown marker. The callers map
    /// that to a timeout — a cancelled wait can only mean the walk gave up.
    private func failWaiters() {
        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.continuation.resume(returning: ["type": "teardown"])
        }
    }
}

// MARK: - WKURLSchemeHandler (the parse page's assets + the book's bytes)

extension DocumentParseService: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        switch url.host {
        case "shell":
            let name = url.path.isEmpty || url.path == "/" ? "/foliate.html" : url.path
            guard let asset = FoliateAssets.serve(String(name.dropFirst())) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            deliver(urlSchemeTask, url: url, data: asset.data, mime: asset.mime)
        case "parse":
            // /parse/current — the ORIGINAL file, streamed from its own
            // FileHandle: no Swift-side copy of the book ever exists.
            guard url.path == "/current" else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            guard let handle = try? FileHandle(forReadingFrom: sourceURL) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: 0)
            let taskID = ObjectIdentifier(urlSchemeTask)
            liveTasksLock.lock()
            liveTasks.insert(taskID)
            liveTasksLock.unlock()
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/octet-stream",
                    "Content-Length": String(size),
                ]
            ) ?? URLResponse(url: url, mimeType: "application/octet-stream", expectedContentLength: Int(size), textEncodingName: nil)
            DispatchQueue.main.async { [weak self] in
                guard self?.isLive(taskID) == true else {
                    handle.closeFile()
                    return
                }
                urlSchemeTask.didReceive(response)
            }
            // Chunked streaming off the main thread, in-order deliveries on
            // main — the webview's arrayBuffer build wants the bytes in
            // order, and the import spinner must never stall on file IO.
            ioQueue.async { [weak self] in
                let chunkSize = 1 << 20 // 1 MB
                var offset: Int64 = 0
                while offset < size {
                    guard self?.isLive(taskID) == true else {
                        handle.closeFile()
                        return
                    }
                    handle.seek(toFileOffset: UInt64(offset))
                    let chunk = handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    DispatchQueue.main.async {
                        guard self?.isLive(taskID) == true else { return }
                        urlSchemeTask.didReceive(chunk)
                    }
                    offset += Int64(chunk.count)
                }
                handle.closeFile()
                DispatchQueue.main.async { [weak self] in
                    guard self?.isLive(taskID) == true else { return }
                    self?.liveTasksLock.lock()
                    self?.liveTasks.remove(taskID)
                    self?.liveTasksLock.unlock()
                    urlSchemeTask.didFinish()
                }
            }
        default:
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        liveTasksLock.lock()
        liveTasks.remove(taskID)
        liveTasksLock.unlock()
    }

    private func deliver(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Access-Control-Allow-Origin": "*",
                "Content-Length": String(data.count),
            ]
        ) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

// MARK: - WKScriptMessageHandler (the shell's parse milestones)

extension DocumentParseService: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "reader",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        // A parked waiter whose accepted types include this one resumes the
        // protocol; everything else buffers for the step that wants it.
        if let index = waiters.firstIndex(where: { $0.types.contains(type) }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: body)
            return
        }
        bufferedMessages.append(body)
    }
}
