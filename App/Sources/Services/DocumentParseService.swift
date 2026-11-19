import Foundation
import WebKit
import SpeechLogic

/// The headless document ENGINE: a hidden WKWebView running the SAME
/// vendored foliate-js modules the reader uses (DocumentParseService and the
/// foliate reader are one engine — mobi.js decompresses the
/// Mobipocket/Kindle family, fb2.js the FictionBook, the RTF/HTML/txt
/// builders the rest). That is the whole point: the sections the manifest
/// records, the text the TTS reads and the sections the reader shows are one
/// chaptering, so section indexes can never drift between speaking and
/// reading — the Linux reader's exact architecture, where the importer and
/// the view both run on foliate's engine.
///
/// The service loads foliate.html in `mode=parse` off `bookscheme://` (the
/// shell module dispatches there) and asks the engine what the book IS —
/// its title, its author, how many sections it has and its own table of
/// contents. It does NOT extract the book's text: the reader renders the
/// ORIGINAL file in the same engine, and the text is pulled only when TTS
/// asks for a chapter (`sectionText`). The import therefore never writes a
/// second copy of the book.
///
/// RAM discipline (this runs while the user watches the import spinner): the
/// book's bytes are streamed to the webview from a FileHandle — no Swift-side
/// copy — and the webview (and its whole WebContent process) is released the
/// moment the walk ends.
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

    /// What the engine says about a book: its identity, its chaptering and
    /// its contents. No content — the reader renders the original file.
    struct ProbeResult {
        var title: String?
        var author: String?
        var sectionCount: Int
        var toc: [BookTocEntry]
        var coverData: Data?
    }

    /// The parse page's metadata report (window.__snParse.meta()).
    ///
    /// The shell FLATTENS the engine's metadata before it posts it (a
    /// Kindle book reports `language: ['en']`, an FB2 `language: 'en'`, and
    /// a title can be a list too) — every field here is a plain string or a
    /// number, because a field the manifest does not use must never be able
    /// to fail the decode and take the whole book down to the fallback
    /// renderer. `language` is deliberately NOT decoded: the manifest does
    /// not carry it, and an unused field is only a way to break the import.
    private struct ParseMeta: Decodable {
        var title: String?
        var author: String?
        var sectionCount: Int
        var toc: [TocRow]?

        struct TocRow: Decodable {
            var label: String?
            var href: String?
            var index: Int?
            var depth: Int?
        }
    }

    /// Asks the engine what the document at `sourceURL` is (any .document
    /// family extension): title, author, section count, the engine's own
    /// table of contents and its cover. The URL is streamed by the scheme
    /// handler — pass the ORIGINAL file on disk, never an in-memory copy.
    static func probe(fileExtension: String, sourceURL: URL) async throws -> ProbeResult {
        let service = DocumentParseService(fileExtension: fileExtension, sourceURL: sourceURL)
        return try await service.run()
    }

    /// The text of ONE section — the TTS-only path. The engine builds the
    /// section's document (decompressing it if the format needs that) and
    /// hands back its prose; nothing is written to the book's directory.
    static func sectionText(
        fileExtension: String,
        sourceURL: URL,
        index: Int
    ) async throws -> String? {
        let service = DocumentParseService(fileExtension: fileExtension, sourceURL: sourceURL)
        return try await service.runSectionText(index: index)
    }

    private let fileExtension: String
    private let sourceURL: URL
    /// The one webview this service owns, created in `run`.
    private var webView: WKWebView?
    /// Out-of-order message buffer: the shell posts freely (the 45 s
    /// watchdog, parse milestones); a step that is not waiting yet must not
    /// lose a message that arrived early.
    private var bufferedMessages: [[String: Any]] = []
    // The continuation is the THROWING variant (the walk can fail while a
    // message is parked) — a non-throwing declaration made the append a
    // type error CI caught.
    private var waiters: [(types: Set<String>, continuation: CheckedContinuation<[String: Any], Error>)] = []
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

    @MainActor private func run() async throws -> ProbeResult {
        defer { teardown() }
        try await boot()

        // The metadata report — title/author/TOC/section count. `meta()` is
        // synchronous: the shell resolved the TOC (async href resolution)
        // before exposing __snParse.
        let meta = try await readMeta()

        // The cover — mobi/fb2 carry one in the file; the rest fall back to
        // the synthesized tile downstream. Small enough for one message.
        let coverData = try await readCover()

        let toc = (meta.toc ?? []).compactMap { row -> BookTocEntry? in
            guard let label = row.label, let href = row.href else { return nil }
            return BookTocEntry(
                label: label,
                href: href,
                spineIndex: row.index,
                depth: row.depth
            )
        }
        return ProbeResult(
            title: meta.title,
            author: meta.author,
            sectionCount: meta.sectionCount,
            toc: toc,
            coverData: coverData
        )
    }

    /// One section's prose — the TTS path. The engine builds the section's
    /// document and returns its text; the reader is untouched.
    @MainActor private func runSectionText(index: Int) async throws -> String? {
        defer { teardown() }
        try await boot()
        // The shell's sectionText() is async (building the document
        // decompresses it for the Mobipocket family), so it stashes the
        // answer and posts it — evaluateJavaScript cannot await a Promise.
        _ = try await evaluate("window.__snParse.prepareSectionText(\(index)); 'kicked'")
        let message = try await nextMessage(accepting: ["parseSectionText"])
        guard message["type"] as? String == "parseSectionText" else {
            throw ParseError.timeout
        }
        guard message["ok"] as? Bool == true else {
            throw ParseError.malformed(message["message"] as? String ?? "the chapter could not be read")
        }
        return message["text"] as? String
    }

    /// Loads the parse page and waits for the engine to have the book.
    @MainActor private func boot() async throws {
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
            // The book's bytes live at /parse/current ON THIS PAGE'S OWN
            // HOST. A path-absolute URL keeps the page's authority, so the
            // shell's fetch lands on bookscheme://shell/parse/current — the
            // scheme handler's shell route serves it. (An absolute URL on a
            // second host would be a cross-origin fetch between opaque
            // origins, and WebKit blocks it.)
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
    }

    @MainActor private func readMeta() async throws -> ParseMeta {
        let metaJSON = try await evaluate("window.__snParse.meta()")
        guard let metaString = metaJSON as? String,
              let meta = try? JSONDecoder().decode(ParseMeta.self, from: Data(metaString.utf8)) else {
            throw ParseError.malformed("the document's metadata could not be read")
        }
        return meta
    }

    @MainActor private func readCover() async throws -> Data? {
        _ = try await evaluate("window.__snParse.prepareCover(); 'kicked'")
        let coverMessage = try await nextMessage(accepting: ["parseCover"])
        guard coverMessage["type"] as? String == "parseCover" else {
            throw ParseError.timeout
        }
        // `Data.init(base64Encoded:)` as an unapplied reference does not
        // resolve (failable init + defaulted options parameter) — the
        // closure form is the one that compiles.
        return (coverMessage["b64"] as? String).flatMap { Data(base64Encoded: $0) }
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
            // The book's bytes live on the PAGE'S OWN HOST: the parse page
            // is bookscheme://shell/foliate.html and asks for
            // /parse/current, which resolves to bookscheme://shell/parse/current
            // (a path-absolute URL keeps the authority). Serving it here —
            // not on a second host — keeps the fetch same-origin, which
            // WebKit requires between opaque custom-scheme origins.
            if url.path == "/parse/current" {
                streamBook(urlSchemeTask, url: url)
                return
            }
            let name = url.path.isEmpty || url.path == "/" ? "/foliate.html" : url.path
            guard let asset = FoliateAssets.serve(String(name.dropFirst())) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            deliver(urlSchemeTask, url: url, data: asset.data, mime: asset.mime)
        default:
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
        }
    }

    /// The ORIGINAL file, streamed from its own FileHandle: no Swift-side
    /// copy of the book ever exists.
    private func streamBook(_ urlSchemeTask: WKURLSchemeTask, url: URL) {
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
