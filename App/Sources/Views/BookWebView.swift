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
    /// (chapterIndex, fractionWithinChapter, totalChapters)
    var onRelocated: (Int, Double, Int) -> Void
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

        if let url = Self.shellURL(book: book, chapter: startChapter, theme: startTheme, fontSize: startFontSize) {
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

    /// The shell page + query-encoded book URL, all inside the custom scheme.
    static func shellURL(book: Book, chapter: Int, theme: String, fontSize: Int) -> URL? {
        var components = URLComponents(string: "bookscheme://shell/index.html")
        components?.queryItems = [
            URLQueryItem(name: "book", value: "bookscheme://book/\(book.id.uuidString)/original.epub"),
            URLQueryItem(name: "chapter", value: String(chapter)),
            URLQueryItem(name: "theme", value: theme),
            URLQueryItem(name: "fontSize", value: String(fontSize)),
        ]
        return components?.url
    }

    // MARK: - Coordinator: scheme handler + message bridge

    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
        var parent: BookWebView?

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

            // Route: bookscheme://shell/<file> -> bundle resource,
            //        bookscheme://book/<uuid>/original.epub -> the book file.
            let response: URLResponse
            let data: Data
            do {
                switch url.host {
                case "shell":
                    let name = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
                    guard let (resourceData, mime) = Self.bundleResource(name) else {
                        throw URLError(.fileDoesNotExist)
                    }
                    data = resourceData
                    response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
                case "book":
                    // Path is /<UUID>/original.epub — parse the UUID and serve
                    // only from that book's own directory.
                    let parts = url.path.split(separator: "/")
                    guard parts.count == 2,
                          let id = UUID(uuidString: String(parts[0])) else {
                        throw URLError(.badURL)
                    }
                    let fileURL = BooksStore.bookDirectory(id)
                        .appendingPathComponent("original.epub")
                    data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    response = URLResponse(url: url, mimeType: "application/epub+zip", expectedContentLength: data.count, textEncodingName: nil)
                default:
                    throw URLError(.unsupportedURL)
                }
            } catch {
                urlSchemeTask.didFailWithError(error)
                return
            }

            // Scheme-task responses must stay on the receiving thread; the
            // book file is one sequential read, chunked politely.
            urlSchemeTask.didReceive(response)
            let chunkSize = 1 << 18 // 256 KB
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                urlSchemeTask.didReceive(data.subdata(in: offset..<end))
                offset = end
            }
            if data.isEmpty {
                urlSchemeTask.didReceive(Data())
            }
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            // Synchronous serving finishes before stop can matter.
        }

        private static func bundleResource(_ name: String) -> (Data, String)? {
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
                parent.onRelocated(index, fraction, total)
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
