import SwiftUI
import WebKit
import SpeechLogic

/// The book rendering surface (Plan B's "eyes"): ONE WKWebView per reader
/// presentation, everything served from a custom `bookscheme://` scheme so
/// the reader is fully offline. Two modes by format:
///
/// * EPUB (and the office normalizations) — the vendored epub.js in the
///   `shell/index.html` glue, fetching the book's archive.
/// * The headless document family (.mobi/.azw3/.fb2/.rtf/…) — NATIVE pages:
///   the import persisted the parse under the book's `doc/` directory, the
///   scheme handler serves each spine page (`cover`, `chapter-N`) as the
///   top-level document, and the injected reader script (nativeReaderScript)
///   dresses it and reports position — the Linux reader's exact pipeline.
///
/// Native -> JS goes through `evaluateJavaScript` on the webview handed to
/// `onWebViewReady`; JS -> native through the `reader` message channel
/// (relocated / toc / error). TTS text extraction reuses the same spine.
struct BookWebView: UIViewRepresentable {
    let book: Book
    let startChapter: Int
    /// Full appearance state (theme, flow, typography, margins) — rides the
    /// shell URL so it applies at rendition creation.
    let appearance: ReaderAppearance
    /// epub.js CFI restored from the manifest — wins over `startChapter` when
    /// present so reopening lands mid-chapter, not at the chapter top (M20).
    let startCFI: String?
    /// (chapterIndex, fractionWithinChapter, totalChapters, cfi)
    var onRelocated: (Int, Double, Int, String?) -> Void
    var onTOC: ([BookTocEntry]) -> Void
    var onError: (String) -> Void
    /// Hands the live WKWebView to the parent so it can evaluate commands.
    var onWebViewReady: (WKWebView) -> Void
    /// Fired when the user taps the reading surface without hitting a link
    /// or a text selection. The tap is detected IN the page (reader.js):
    /// a WKWebView swallows SwiftUI gestures, so the reader's SwiftUI
    /// .onTapGesture never fired and a hidden title bar was unreachable.
    var onChromeTap: (() -> Void)? = nil
    /// Paginated-flow page-turn swipe, detected in the section iframe
    /// (reader.js) and relayed here. Payload is "next" | "prev".
    var onSwipe: ((String) -> Void)? = nil
    /// A chapter jump the webview could not carry out (the book was still
    /// opening, or the spine index does not exist). The reader corrects its
    /// own position instead of leaving the bar on a chapter the reader is
    /// not actually on.
    var onGoChapterFailed: ((Int, String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "bookscheme")
        config.userContentController.add(context.coordinator, name: "reader")
        // A NATIVE document book has no epub.js shell: each chapter page is
        // the top-level document, and the reader script rides in as a user
        // script at document start — every page load of this webview (each
        // chapter turn is a navigation) gets it, exactly like the Linux
        // reader's injected `__sn` script.
        if book.format.isDocument {
            config.userContentController.addUserScript(
                WKUserScript(
                    source: Self.nativeReaderScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        // Transparent so the page background (theme-controlled in reader.js)
        // is the only background — no white flash around themed pages.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.parent = self

        if let url = Self.shellURL(book: book, chapter: startChapter, appearance: appearance, cfi: startCFI) {
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
    ///
    /// A NATIVE document book has no shell page: the spine's own page IS the
    /// document (`bookscheme://book/<uuid>/cover` or `…/chapter-N`), dressed
    /// by the injected reader script. The query carries the position (the
    /// spine index to report, the scroll fraction to restore) and the
    /// appearance — chapter turns navigate with the same query, updated.
    /// There is no CFI: the native resume position is the chapter's scroll
    /// fraction, read from the book's manifest (the reader persists it on
    /// every jump and throttled mid-chapter).
    static func shellURL(book: Book, chapter: Int, appearance: ReaderAppearance, cfi: String?) -> URL? {
        if book.format.isDocument {
            let spine = book.spine ?? []
            guard !spine.isEmpty else { return nil }
            let clamped = min(max(0, chapter), spine.count - 1)
            var items = appearance.queryItems
            items.append(URLQueryItem(name: "chapter", value: String(clamped)))
            items.append(URLQueryItem(name: "total", value: String(spine.count)))
            items.append(URLQueryItem(
                name: "fraction",
                value: String(book.position?.chapterFraction ?? 0)
            ))
            var components = URLComponents(
                string: "bookscheme://book/\(book.id.uuidString)/\(spine[clamped])"
            )
            components?.queryItems = items
            return components?.url
        }
        var components = URLComponents(string: "bookscheme://shell/index.html")
        var items = appearance.queryItems
        items.append(URLQueryItem(name: "bookPath", value: "/book/\(book.id.uuidString)/original.epub"))
        items.append(URLQueryItem(name: "chapter", value: String(chapter)))
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
                    // Path is /<UUID>/original.epub (an epub.js book's
                    // archive) or /<UUID>/<virtualName> — a NATIVE document
                    // book's spine page ("cover", "chapter-N") or one of the
                    // images its pages reference ("img/<file>"). Served only
                    // from that book's own directory; a name that is not one
                    // of the parse's shapes, or that climbs out of doc/, is
                    // a 404, not a guess.
                    let parts = url.path.split(separator: "/")
                    guard parts.count >= 2,
                          let bookID = UUID(uuidString: String(parts[0])) else {
                        throw URLError(.badURL)
                    }
                    if parts.count == 2, parts[1] == "original.epub" {
                        let fileURL = BooksStore.bookDirectory(bookID).appendingPathComponent("original.epub")
                        let handle = try FileHandle(forReadingFrom: fileURL)
                        let size = Int64(try handle.seekToEnd())
                        try handle.seek(toOffset: 0)
                        source = .stream(handle, size, "application/epub+zip")
                    } else {
                        let virtualName = parts[1...].joined(separator: "/")
                        guard let fileURL = BooksStore.documentFileURL(bookID, virtualName: virtualName),
                              let mime = BooksStore.documentMime(forVirtualName: virtualName) else {
                            throw URLError(.fileDoesNotExist)
                        }
                        let handle = try FileHandle(forReadingFrom: fileURL)
                        let size = Int64(try handle.seekToEnd())
                        try handle.seek(toOffset: 0)
                        source = .stream(handle, size, mime)
                    }
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
                    return BookTocEntry(label: label, href: href, spineIndex: nil, depth: (item["depth"] as? NSNumber)?.intValue)
                }
                parent.onTOC(entries)
            case "error":
                parent.onError(body["message"] as? String ?? "Unknown reader error")
            case "chromeTap":
                parent.onChromeTap?()
            case "pageTurn":
                // Tap zones and swipes (both detected in the iframe) funnel
                // into the same next/prev action the old "swipe" message
                // drove.
                parent.onSwipe?(body["dir"] as? String ?? "next")
            case "swipe":
                parent.onSwipe?(body["dir"] as? String ?? "next")
            case "goChapterFailed":
                let index = (body["index"] as? NSNumber)?.intValue ?? 0
                parent.onGoChapterFailed?(index, body["reason"] as? String ?? "unknown")
            default:
                break
            }
        }
    }
}

// MARK: - Native document reader script

extension BookWebView {
    /// The reader script for NATIVE document books, injected at document
    /// start into every page the webview loads (each chapter IS a page —
    /// there is no epub.js shell). It is the iOS cut of the Linux reader's
    /// injected `__sn` script (sn-ui/src/epubview.rs VIEWER_SCRIPT), retargeted
    /// to speak the epub.js shell's bridge so `BookReaderView` drives both
    /// readers with the same commands and hears the same messages:
    ///
    /// * commands — `readerGoChapter(n)`, `readerNext/Prev`,
    ///   `readerAppearance({...})`, `readerAutoScroll(on, speed)`,
    ///   `readerAutoScrollSpeed(s)`, `readerGoToHref`, `readerDestroy`;
    /// * messages — `relocated {index, fraction, total}`, `chromeTap`.
    ///
    /// Appearance is the epub.js shell's own palette (reader.js THEMES —
    /// the same colors `BookReaderView.pageColor` bleeds behind the chrome),
    /// laid out calibre-style: the margins as padding on the document
    /// element, the base size on it too so the pages' em sizes scale, and
    /// paginated flow as CSS columns over the viewport (the Linux reader's
    /// exact mechanism, resize-drift re-land included).
    ///
    /// The one deliberate difference in the messages: a native page has no
    /// CFI, but the app's mid-chapter persistence keys on the CFI CHANGING
    /// (BookReaderView.scheduleCFIPersist). So the scroll fraction rides AS
    /// one — `doc@0.42` — inert on restore (the shell URL restores from the
    /// `fraction` query item, not the CFI) and real only to that throttle.
    static let nativeReaderScript: String = #"""
    (function () {
      if (window.__snNative) { return; }
      window.__snNative = true;

      // The generated chapter pages carry no viewport meta — without one
      // WebKit scales and the safe-area env() values are zero, so the
      // paginated page's last lines would park under the floating
      // transport. Injected once, at document start.
      if (!document.querySelector('meta[name="viewport"]')) {
        var meta = document.createElement('meta');
        meta.setAttribute('name', 'viewport');
        meta.setAttribute('content', 'width=device-width, initial-scale=1, viewport-fit=cover');
        (document.head || document.documentElement).appendChild(meta);
      }

      var params = new URLSearchParams(location.search);
      var STATE = {
        theme: params.get("theme") || "light",
        fontSize: parseInt(params.get("fontSize") || "100", 10),
        flow: params.get("flow") || "scrolled",
        font: params.get("font") || "book",
        lineHeight: parseFloat(params.get("lineHeight") || "1.6"),
        paraSpacing: parseFloat(params.get("paraSpacing") || "0"),
        letterSpacing: parseFloat(params.get("letterSpacing") || "0"),
        padding: parseInt(params.get("padding") || "16", 10),
        respectStyles: params.get("respectStyles") === "1",
        tapTurn: params.get("tapTurn") !== "0",
        swipeTurn: params.get("swipeTurn") !== "0",
        tapInverted: params.get("tapInv") === "1",
        chapter: parseInt(params.get("chapter") || "0", 10),
        total: parseInt(params.get("total") || "0", 10)
      };

      // --- spine addressing -------------------------------------------------
      // This page IS one spine item: "cover" (ordinal -1) or "chapter-K"
      // (ordinal K). The book's offset between ordinals and spine indexes is
      // constant, so a turn issued from any page can name every other one.
      var ordinal;
      var pathName = location.pathname.replace(/^\/+/, "");
      if (pathName === "cover") {
        ordinal = -1;
      } else {
        var match = /^chapter-(\d+)$/.exec(pathName);
        ordinal = match ? parseInt(match[1], 10) : STATE.chapter;
      }
      var ordinalOffset = STATE.chapter - ordinal;

      function navigateTo(index) {
        if (STATE.total > 0) { index = Math.max(0, Math.min(STATE.total - 1, index)); }
        if (index === STATE.chapter) { return; }
        STATE.chapter = index;
        var nextOrdinal = index - ordinalOffset;
        var query = new URLSearchParams(location.search);
        query.set("chapter", String(index));
        query.delete("fraction"); // a jump starts the new page at its top
        location.href = "/" + (nextOrdinal < 0 ? "cover" : "chapter-" + nextOrdinal)
          + "?" + query.toString();
      }

      // --- position reporting ------------------------------------------------
      function post(msg) {
        try { webkit.messageHandlers.reader.postMessage(msg); } catch (e) {}
      }
      function scrollMax() {
        var de = document.documentElement;
        if (STATE.flow === "paginated") {
          return Math.max(0, (de.scrollWidth || 0) - (window.innerWidth || 0));
        }
        return Math.max(0, (de.scrollHeight || 0) - (window.innerHeight || 0));
      }
      function scrollPos() {
        return STATE.flow === "paginated" ? (window.scrollX || 0) : (window.scrollY || 0);
      }
      function report() {
        var max = scrollMax();
        var fraction = max > 4 ? Math.min(Math.max(scrollPos() / max, 0), 1) : 0;
        // The fraction rides as the pseudo-CFI — see the extension comment.
        post({
          type: "relocated",
          index: STATE.chapter,
          fraction: fraction,
          total: STATE.total,
          cfi: "doc@" + fraction.toFixed(4)
        });
      }
      var scrollTimer = null;
      window.addEventListener("scroll", function () {
        if (scrollTimer) { return; }
        scrollTimer = setTimeout(function () {
          scrollTimer = null;
          report();
        }, 120);
      }, true);

      // --- appearance ---------------------------------------------------------
      // The epub.js shell's exact palette (reader.js THEMES/FONTS) so the
      // reader's pageColor bleed and the page read as one continuous sheet.
      var THEMES = {
        light: { background: "#ffffff", color: "#1a1a1a" },
        sepia: { background: "#f6efe2", color: "#3b3128" },
        dark: { background: "#121212", color: "#d8d4cf" },
        trueBlack: { background: "#000000", color: "#c9c9c9" },
        eink: { background: "#ffffff", color: "#000000" }
      };
      var FONTS = {
        serif: 'Georgia, "Iowan Old Style", "Palatino", serif',
        sans: '-apple-system, "Helvetica Neue", Arial, sans-serif',
        mono: '"SF Mono", Menlo, Consolas, monospace'
      };
      var styleEl = null;
      function applyAppearance() {
        var colors = THEMES[STATE.theme] || THEMES.light;
        var de = document.documentElement;
        // The page canvas is the theme's only background (the webview itself
        // is transparent — the reader's pageColor bleeds reads as the page).
        de.style.backgroundColor = colors.background;
        de.style.color = colors.color;
        if (document.body) {
          document.body.style.backgroundColor = "transparent";
          document.body.style.color = colors.color;
        }
        var css = [];
        if (STATE.flow === "paginated") {
          // The Linux reader's columns: one viewport-wide column per page,
          // the scroller horizontal. The shell stops ABOVE the bottom
          // safe-area inset so the page's last lines stay clear of the
          // floating transport — the epub.js shell's applyPadding rule.
          css.push("html{padding:0 !important;height:100% !important;overflow-x:auto !important;overflow-y:hidden !important;box-sizing:border-box !important;}");
          css.push("body{height:calc(100% - env(safe-area-inset-bottom)) !important;column-width:100vw !important;column-gap:0 !important;column-fill:auto !important;overflow:visible !important;}");
        } else {
          // Margins around the book: padding on the document element, the
          // way the Linux reader lays its margins (scrolled flow insets
          // itself through native scrolling — the scroll insets keep the
          // last lines above the chrome).
          css.push("html{padding:" + STATE.padding + "px !important;box-sizing:border-box !important;}");
        }
        if (!STATE.respectStyles) {
          // The base size sits on the document element so the pages' own em
          // sizes scale with it (calibre's mechanism). The reader's percent
          // maps onto epub.js's 16px base.
          css.push("html{font-size:" + Math.round(16 * STATE.fontSize / 100) + "px !important;}");
          if (FONTS[STATE.font]) { css.push("body{font-family:" + FONTS[STATE.font] + " !important;}"); }
          css.push("body{line-height:" + STATE.lineHeight + " !important;}");
          if (STATE.letterSpacing > 0) { css.push("body{letter-spacing:" + STATE.letterSpacing + "px !important;}"); }
          if (STATE.paraSpacing > 0) { css.push("body p{margin-bottom:" + STATE.paraSpacing + "em !important;}"); }
        }
        // Converted books carry wide tables that clip at the page edge —
        // the epub.js shell's responsive-table treatment (reader.js
        // injectTablePanning): a table pans horizontally inside the page.
        // The generated pages carry no competing CSS, so no !important.
        css.push("table{display:block;width:fit-content;max-width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch;}");
        css.push("table table{display:table;width:auto;max-width:none;overflow:visible;}");
        if (!styleEl) {
          styleEl = document.createElement("style");
          (document.head || de).appendChild(styleEl);
        }
        styleEl.textContent = css.join("\n");
      }

      // --- restore + report once laid out -------------------------------------
      // The fraction of this chapter the reader was last looking at (the
      // shell URL's "fraction" item — a jump navigates without it and lands
      // at the top).
      var restoredFraction = parseFloat(params.get("fraction") || "0");
      if (!isFinite(restoredFraction) || restoredFraction < 0) { restoredFraction = 0; }
      function land() {
        var max = scrollMax();
        if (!(restoredFraction > 0) || max <= 4) { report(); return; }
        var pos = restoredFraction * max;
        if (STATE.flow === "paginated") { window.scrollTo(pos, 0); }
        else { window.scrollTo(0, pos); }
        report();
      }
      applyAppearance();
      setTimeout(land, 60);
      window.addEventListener("load", function () {
        setTimeout(function () {
          // Image loads shift the scrollable height after the first landing —
          // re-land on the same fraction, but only if the reader has not
          // already scrolled somewhere of their own.
          var max = scrollMax();
          if (!(restoredFraction > 0) || max <= 4 || scrollPos() > 4) { report(); return; }
          var pos = restoredFraction * max;
          if (STATE.flow === "paginated") { window.scrollTo(pos, 0); }
          else { window.scrollTo(0, pos); }
          report();
        }, 120);
      });

      // A resize (rotation, chrome show/hide, the rail's collapse) re-zooms
      // nothing here but the columns re-flow — re-land on the page the
      // reader stood on, the Linux reader's resize-drift fix.
      var lastVw = window.innerWidth || 0;
      var resizeTimer = null;
      window.addEventListener("resize", function () {
        lastVw = window.innerWidth || 0;
        if (STATE.flow !== "paginated") { return; }
        if (resizeTimer) { clearTimeout(resizeTimer); }
        resizeTimer = setTimeout(function () {
          resizeTimer = null;
          var oldVw = lastVw || window.innerWidth || 1;
          var vw = window.innerWidth || 1;
          var page = Math.floor((window.scrollX || 0) / oldVw);
          var max = Math.max(0, document.documentElement.scrollWidth - vw);
          var x = Math.min(max, Math.max(0, page * vw));
          if (Math.abs((window.scrollX || 0) - x) > 1) { window.scrollTo(x, 0); }
        }, 80);
      });

      // --- paginated turns ------------------------------------------------------
      // One turn = one viewport of columns, clamped; crossing the chapter's
      // edge navigates to the neighbour page (the boundary epub.js crosses
      // on its own).
      function turn(delta) {
        if (STATE.flow !== "paginated") { return; }
        var vw = window.innerWidth || 1;
        var max = scrollMax();
        var x = scrollPos() + delta * vw;
        if (x > max + 2) { navigateTo(STATE.chapter + 1); return; }
        if (x < -2) { navigateTo(STATE.chapter - 1); return; }
        window.scrollTo(x, 0);
      }

      // --- links ----------------------------------------------------------------
      // The parse passes the book's own anchors through untouched, and a
      // dangling relative href would navigate this TOP-LEVEL page onto a
      // bookscheme 404 and blank it. Same policy as the Linux reader's
      // navigation handler: in-page fragments load, the desktop schemes
      // (http/https/mailto) load, everything else is refused.
      document.addEventListener("click", function (event) {
        var a = event.target && event.target.closest ? event.target.closest("a") : null;
        if (!a) { return; }
        var href = a.getAttribute("href") || "";
        if (href.charAt(0) === "#") { return; }
        var lower = href.toLowerCase();
        if (lower.indexOf("http://") === 0 || lower.indexOf("https://") === 0
          || lower.indexOf("mailto:") === 0) { return; }
        event.preventDefault();
      }, true);

      // --- gestures (the document IS the page — no iframe relay) ---------------
      // Taps on links and live text selections stay out of the chrome
      // toggle; in paginated flow the left/right thirds turn pages and the
      // middle toggles chrome (the epub shell's Anx layout).
      document.addEventListener("click", function (event) {
        var node = event.target;
        while (node && node !== document) {
          if (node.tagName === "A") { return; }
          node = node.parentElement;
        }
        var sel = document.getSelection && document.getSelection();
        if (sel && !sel.isCollapsed && String(sel).length > 0) { return; }
        if (STATE.flow === "paginated" && STATE.tapTurn) {
          var width = (document.documentElement && document.documentElement.clientWidth)
            || (document.body && document.body.clientWidth) || 0;
          if (width > 0) {
            var x = event.clientX;
            var leftZone = x < width / 3;
            var rightZone = x > (width * 2) / 3;
            if (leftZone || rightZone) {
              turn((STATE.tapInverted ? leftZone : rightZone) ? 1 : -1);
              return;
            }
          }
        }
        post({ type: "chromeTap" });
      }, false);

      var touch = { x: 0, y: 0, t: 0, onTable: false };
      function touchStartsOnTable(node) {
        while (node && node !== document) {
          if (node.tagName === "TABLE") { return true; }
          node = node.parentElement;
        }
        return false;
      }
      document.addEventListener("touchstart", function (event) {
        var t = event.changedTouches[0];
        if (t) {
          touch.x = t.clientX; touch.y = t.clientY; touch.t = Date.now();
          touch.onTable = touchStartsOnTable(t.target);
        }
      }, { passive: true });
      document.addEventListener("touchend", function (event) {
        if (STATE.flow !== "paginated") { return; }
        if (touch.onTable) { return; }
        if (!STATE.swipeTurn) { return; }
        var t = event.changedTouches[0];
        if (!t) { return; }
        var dx = t.clientX - touch.x;
        var dy = t.clientY - touch.y;
        if (Date.now() - touch.t > 600) { return; }
        if (Math.abs(dx) < 60 || Math.abs(dy) > 50) { return; }
        var sel = document.getSelection && document.getSelection();
        if (sel && !sel.isCollapsed && String(sel).length > 0) { return; }
        turn(dx < 0 ? 1 : -1);
      }, { passive: true });

      // --- auto-scroll (scrolled flow) --------------------------------------------
      // The epub.js shell's hands-free loop: rAF-driven scroll; at a
      // chapter's bottom it navigates to the next spine item and keeps
      // rolling (the dwell guard keeps tiny chapters from fast-forwarding).
      var AUTO = { on: false, speed: 40, last: 0, raf: 0, lastAdvance: 0 };
      function autoAdvance() {
        var now = performance.now();
        if (now - AUTO.lastAdvance < 800) { return; }
        AUTO.lastAdvance = now;
        if (STATE.total > 0 && STATE.chapter >= STATE.total - 1) { stopAutoScroll(); return; }
        AUTO.last = 0;
        navigateTo(STATE.chapter + 1);
      }
      function autoScrollFrame(ts) {
        if (!AUTO.on) { return; }
        if (AUTO.last) {
          var dt = Math.min((ts - AUTO.last) / 1000, 0.1);
          var max = scrollMax();
          if (max <= 4 || scrollPos() >= max - 2) {
            autoAdvance();
          } else {
            window.scrollTo(0, scrollPos() + AUTO.speed * dt);
          }
        }
        AUTO.last = ts;
        AUTO.raf = requestAnimationFrame(autoScrollFrame);
      }
      function stopAutoScroll() {
        AUTO.on = false;
        if (AUTO.raf) { cancelAnimationFrame(AUTO.raf); }
        AUTO.raf = 0;
        AUTO.last = 0;
      }

      // --- native -> reader commands (evaluateJavaScript) ------------------------
      window.readerGoChapter = function (index) {
        // A page is already loaded, so the command always runs; an
        // out-of-range index clamps into the book and the relocation the
        // navigation reports corrects the app's bar.
        navigateTo(index);
      };
      window.readerGoToHref = function (href) {
        // Native TOC rows carry spine indexes, so this is a defensive
        // fallback only: a "chapter-K" href resolves through the same
        // ordinal offset every other navigation uses.
        var m = /^chapter-(\d+)$/.exec(String(href || "").split("#")[0]);
        if (m) { navigateTo(parseInt(m[1], 10) + ordinalOffset); }
      };
      window.readerNext = function () { turn(1); };
      window.readerPrev = function () { turn(-1); };
      window.readerAppearance = function (json) {
        if (!json) { return; }
        var a = typeof json === "string" ? JSON.parse(json) : json;
        if (a.theme) { STATE.theme = a.theme; }
        if (typeof a.fontSize === "number") { STATE.fontSize = a.fontSize; }
        if (a.font) { STATE.font = a.font; }
        if (typeof a.lineHeight === "number") { STATE.lineHeight = a.lineHeight; }
        if (typeof a.paraSpacing === "number") { STATE.paraSpacing = a.paraSpacing; }
        if (typeof a.letterSpacing === "number") { STATE.letterSpacing = a.letterSpacing; }
        if (typeof a.margin === "number") { STATE.padding = a.margin; }
        if (typeof a.respectStyles === "boolean") { STATE.respectStyles = a.respectStyles; }
        if (typeof a.tapTurn === "boolean") { STATE.tapTurn = a.tapTurn; }
        if (typeof a.swipeTurn === "boolean") { STATE.swipeTurn = a.swipeTurn; }
        if (typeof a.tapInverted === "boolean") { STATE.tapInverted = a.tapInverted; }
        applyAppearance();
        report();
      };
      window.readerFontSize = function (pct) {
        if (typeof pct === "number") { STATE.fontSize = pct; applyAppearance(); }
      };
      window.readerTheme = function (mode) {
        if (mode) { STATE.theme = mode; applyAppearance(); }
      };
      window.readerAutoScroll = function (on, speed) {
        if (typeof speed === "number" && speed > 0) { AUTO.speed = speed; }
        if (STATE.flow === "paginated") { return; }
        if (on && !AUTO.on) {
          AUTO.on = true;
          AUTO.last = 0;
          AUTO.raf = requestAnimationFrame(autoScrollFrame);
        } else if (!on && AUTO.on) {
          stopAutoScroll();
        }
      };
      window.readerAutoScrollSpeed = function (speed) {
        if (typeof speed === "number" && speed > 0) { AUTO.speed = speed; }
      };
      window.readerDestroy = function () {
        stopAutoScroll();
      };
    })();
    """#
}
