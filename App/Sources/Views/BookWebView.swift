import SwiftUI
import WebKit
import SpeechLogic

/// The EPUB rendering surface (Plan B's "eyes"): ONE WKWebView per reader
/// presentation running the vendored epub.js, with everything served from a
/// custom `bookscheme://` scheme so the reader is fully offline.
///
/// Native -> JS goes through `evaluateJavaScript` on the webview handed to
/// `onWebViewReady`; JS -> native through the `reader` message channel
/// (relocated / toc / error). TTS text extraction will reuse this bridge.
struct BookWebView: UIViewRepresentable {
    let book: Book
    let startChapter: Int
    let startTheme: String
    let startFontSize: Int
    /// epub.js CFI restored from the manifest — wins over `startChapter` when
    /// present so reopening lands mid-chapter, not at the chapter top (M20).
    let startCFI: String?
    /// (chapterIndex, fractionWithinChapter, totalChapters, cfi)
    var onRelocated: (Int, Double, Int, String?) -> Void
    var onTOC: ([BookTocEntry]) -> Void
    var onError: (String) -> Void
    /// Hands the live WKWebView to the parent so it can evaluate commands.
    var onWebViewReady: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "bookscheme")
        config.userContentController.add(context.coordinator, name: "reader")

        let webView = WKWebView(frame: .zero, configuration: config)
        // Transparent so the page background (theme-controlled in reader.js)
        // is the only background — no white flash around themed pages.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.parent = self

        if let url = Self.shellURL(book: book, chapter: startChapter, theme: startTheme, fontSize: startFontSize, cfi: startCFI) {
            webView.load(URLRequest(url: url))
        }
        // Async: setting parent @State synchronously inside makeUIView would
        // trip SwiftUI's state-during-view-update guard.
        DispatchQueue.main.async { [onWebViewReady] in
            onWebViewReady(webView)
        }
        return webView
    }

    /// Nothing to refresh: reading position and appearance flow into the
    /// webview through evaluateJavaScript commands, not through view updates.
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    /// The shell page + query-encoded book path. The EPUB is served under
    /// the SAME shell origin (bookscheme://shell/book/…) because a fetch
    /// across two custom-scheme hosts is cross-origin between opaque
    /// origins and WebKit blocks it ("TypeError: Load failed" — the first
    /// device build's failure).
    static func shellURL(book: Book, chapter: Int, theme: String, fontSize: Int, cfi: String?) -> URL? {
        var components = URLComponents(string: "bookscheme://shell/index.html")
        var items = [
            URLQueryItem(name: "bookPath", value: "/book/\(book.id.uuidString)/original.epub"),
            URLQueryItem(name: "chapter", value: String(chapter)),
            URLQueryItem(name: "theme", value: theme),
            URLQueryItem(name: "fontSize", value: String(fontSize)),
        ]
        if let cfi, !cfi.isEmpty {
            items.append(URLQueryItem(name: "cfi", value: cfi))
        }
        components?.queryItems = items
        return components?.url
    }

    // MARK: - Coordinator: scheme handler + message bridge

    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
        var parent: BookWebView?
        /// Scheme tasks currently being served. `stop` removes the task, and
        /// every didReceive/didFinish/didFail below checks membership first —
        /// calling into a stopped task raises NSException, which is exactly
        /// what happened when the reader closed mid-load of a big book.
        ///
        /// Synchronized: mutated on `start`/`stop` (main) AND read on ioQueue
        /// (isLive) — the old unsynchronized Set was a data race (TSan crash).
        private var liveTasks = Set<ObjectIdentifier>()
        private let liveTasksLock = NSLock()
        /// File reads run off the main thread; deliveries hop back to main.
        private let ioQueue = DispatchQueue(label: "com.speechnotes.bookscheme", qos: .userInitiated)

        // Classes get no memberwise init — one must be explicit.
        init(parent: BookWebView?) {
            self.parent = parent
        }

        // MARK: WKURLSchemeHandler

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let parent else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            let taskID = ObjectIdentifier(urlSchemeTask)
            liveTasksLock.lock()
            liveTasks.insert(taskID)
            liveTasksLock.unlock()
            ioQueue.async { [weak self] in
                self?.serve(url: url, task: urlSchemeTask, taskID: taskID)
            }
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            // The serve loop checks liveTasks between chunks and bails —
            // delivering data to a stopped task is an NSException.
            let id = ObjectIdentifier(urlSchemeTask)
            liveTasksLock.lock()
            liveTasks.remove(id)
            liveTasksLock.unlock()
        }

        private func isLive(_ taskID: ObjectIdentifier) -> Bool {
            liveTasksLock.lock()
            defer { liveTasksLock.unlock() }
            return liveTasks.contains(taskID)
        }

        /// Streams the resolved route in bounded chunks. All task deliveries
        /// happen on the main thread (where `start` arrived) and only while
        /// the task is still live.
        private func serve(url: URL, task: WKURLSchemeTask, taskID: ObjectIdentifier) {
            enum Source {
                case data(Data, String)
                case stream(FileHandle, Int64, String)
            }
            let source: Source
            do {
                switch url.host {
                case "shell":
                    let path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
                    if path.hasPrefix("/book/") {
                        let (handle, size) = try Self.openBookFile(path: path)
                        source = .stream(handle, size, "application/epub+zip")
                    } else {
                        let name = String(path.dropFirst())
                        guard let (resourceData, mime) = Self.bundleResource(name) else {
                            throw URLError(.fileDoesNotExist)
                        }
                        source = .data(resourceData, mime)
                    }
                case "book":
                    // Path is /<UUID>/original.epub — parse the UUID and serve
                    // only from that book's own directory.
                    let parts = url.path.split(separator: "/")
                    guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else {
                        throw URLError(.badURL)
                    }
                    let (handle, size) = try Self.openBookFile(path: url.path)
                    source = .stream(handle, size, "application/epub+zip")
                default:
                    throw URLError(.unsupportedURL)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard self?.isLive(taskID) == true else { return }
                    self?.liveTasksLock.lock()
                    self?.liveTasks.remove(taskID)
                    self?.liveTasksLock.unlock()
                    task.didFailWithError(error)
                }
                return
            }

            switch source {
            case .data(let data, let mime):
                let response = Self.httpResponse(url: url, data: data, mime: mime)
                DispatchQueue.main.async { [weak self] in
                    guard self?.isLive(taskID) == true else { return }
                    self?.liveTasksLock.lock()
                    self?.liveTasks.remove(taskID)
                    self?.liveTasksLock.unlock()
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                }
            case .stream(let handle, let size, let mime):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mime,
                        "Access-Control-Allow-Origin": "*",
                        "Content-Length": String(size),
                    ]
                ) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: Int(size), textEncodingName: nil)
                DispatchQueue.main.async { [weak self] in
                    guard self?.isLive(taskID) == true else {
                        handle.closeFile()
                        return
                    }
                    task.didReceive(response)
                }
                let chunkSize = 1 << 18 // 256 KB
                var offset: Int64 = 0
                var failed = false
                while offset < size {
                    guard isLive(taskID) else {
                        handle.closeFile()
                        return
                    }
                    handle.seek(toFileOffset: UInt64(offset))
                    let chunk = handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty {
                        failed = true
                        break
                    }
                    // Deliver on main — but NOT with .sync, which serializes IO
                    // against the main thread and deadlocks if main ever blocks
                    // on ioQueue. Async delivery; the next chunk read waits for
                    // this delivery to land (in-order guarantee from WebKit).
                    DispatchQueue.main.async { [weak self] in
                        guard self?.isLive(taskID) == true else { return }
                        task.didReceive(chunk)
                    }
                    offset += Int64(chunk.count)
                }
                handle.closeFile()
                DispatchQueue.main.async { [weak self] in
                    guard self?.isLive(taskID) == true else { return }
                    self?.liveTasksLock.lock()
                    self?.liveTasks.remove(taskID)
                    self?.liveTasksLock.unlock()
                    if failed {
                        task.didFailWithError(URLError(.cannotOpenFile))
                    } else {
                        task.didFinish()
                    }
                }
            }
        }

        /// Opens the EPUB of the book named by a /book/<uuid>/original.epub
        /// path — only ever from that book's own directory. Returns the
        /// handle and its byte size; the caller streams it (no whole-file
        /// RAM copy — a 50 MB book used to be fully materialized here).
        private static func openBookFile(path: String) throws -> (FileHandle, Int64) {
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "book",
                  UUID(uuidString: String(parts[1])) != nil else {
                throw URLError(.badURL)
            }
            let url = BooksStore.bookDirectory(UUID(uuidString: String(parts[1]))!)
                .appendingPathComponent("original.epub")
            let handle = try FileHandle(forReadingFrom: url)
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            return (handle, Int64(size))
        }

        /// HTTP-flavoured response so fetch/XHR see status + CORS headers
        /// (plain URLResponse carries neither).
        private static func httpResponse(url: URL, data: Data, mime: String) -> URLResponse {
            let headers = [
                "Content-Type": mime,
                "Access-Control-Allow-Origin": "*",
                "Content-Length": String(data.count),
            ]
            return HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        }

        private static func bundleResource(_ name: String) -> (Data, String)? {
            // Path allow-list: the shell host only serves the vendored epub.js
            // glue from the bundle. The old code served ANY bundle resource by
            // path — combined with allowScriptedContent:true and CORS:* that
            // was an exfiltration path for malicious EPUBs.
            let allowed: Set<String> = ["index.html", "reader.js", "epub.min.js", "jszip.min.js"]
            guard allowed.contains(name) else { return nil }
            let (base, ext) = splitName(name)
            guard let url = Bundle.main.url(forResource: base, withExtension: ext) else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            let mime: String
            switch ext {
            case "html": mime = "text/html"
            case "js": mime = "text/javascript"
            default: mime = "application/octet-stream"
            }
            return (data, mime)
        }

        private static func splitName(_ name: String) -> (String, String) {
            guard let idx = name.lastIndex(of: ".") else { return (name, "") }
            return (String(name[name.startIndex..<idx]), String(name[name.index(after: idx)...]))
        }

        // MARK: WKScriptMessageHandler ("reader" channel)

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "reader",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.handleMessage(type: type, body: body)
            }
        }

        @MainActor private func handleMessage(type: String, body: [String: Any]) {
            guard let parent else { return }
            switch type {
            case "relocated":
                let index = (body["index"] as? NSNumber)?.intValue ?? 0
                let fraction = (body["fraction"] as? NSNumber)?.doubleValue ?? 0
                let total = (body["total"] as? NSNumber)?.intValue ?? 0
                let cfi = body["cfi"] as? String
                parent.onRelocated(index, fraction, total, cfi)
            case "toc":
                guard let items = body["items"] as? [[String: Any]] else { return }
                let entries = items.compactMap { item -> BookTocEntry? in
                    guard let label = item["label"] as? String,
                          let href = item["href"] as? String else { return nil }
                    return BookTocEntry(label: label, href: href, spineIndex: nil)
                }
                parent.onTOC(entries)
            case "error":
                parent.onError(body["message"] as? String ?? "Unknown reader error")
            default:
                break
            }
        }
    }
}
