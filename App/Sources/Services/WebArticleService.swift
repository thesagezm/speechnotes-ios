import Foundation
import WebKit
import SpeechLogic

/// One extracted web article — what a shared URL becomes before it lands
/// in a note. `route` names the pass that produced it, for the log and the
/// import toast.
struct WebArticle {
    let title: String
    let byline: String?
    let siteName: String?
    let excerpt: String?
    let text: String
    /// The same article as GFM markdown (Readability's content DOM walked
    /// by html-to-markdown.js): headings, emphasis, lists, quotes, tables
    /// and — the point — the page's own hyperlinks, which textContent
    /// flattens away. nil when the walker produced nothing usable; callers
    /// fall back to `text`.
    let markdown: String?
    let sourceURL: URL

    enum Route: String {
        /// URLSession fetch, readability on the fetched HTML — the fast
        /// path most pages take.
        case fetchedHTML = "direct"
        /// Offscreen webview navigation, JS on (app-shell pages whose
        /// article only exists after render).
        case rendered
        /// Offscreen webview navigation with the BPC userscript injected —
        /// the paywall pass.
        case bypass
        /// The pre-Readability tag-strip (ImportService.legacyWebsiteText),
        /// wrapped so a legacy import lands in the same note shape.
        case legacyStripped = "legacy"
    }
    let route: Route

    /// Strict shared-text → URL normalization used by the Notes importer.
    /// The parser lives in SpeechLogic; this wrapper keeps the share-sheet
    /// and clipboard call sites on this module's WebArticle type.
    static func url(in text: String) -> URL? {
        SpeechLogic.WebArticle.url(in: text)
    }
}

/// URL → article text, in three passes of increasing cost:
///
/// 1. DIRECT — plain URLSession fetch (Safari-ish UA), then Readability on
///    the fetched HTML inside a headless WKWebView (`loadHTMLString`). Most
///    pages finish here in one round-trip and its result stands whenever the
///    bypass pass doesn't beat it.
/// 2. BYPASS — a fresh EPHEMERAL webview navigation with the Bypass Paywalls
///    Clean userscript (shim + bpc_func.js + bpc.en.user.js, vendored in
///    App/Resources/JS) injected at document start. Runs for EVERY import
///    while the toggle is on (default): on clean pages it reproduces the
///    same article, on walled ones its cookie/localStorage surgery and
///    archive fallbacks (archive.ph et al. through the GM bridge) recover
///    the full text, and `bypassResultWins` picks the better result. The
///    fresh store is the "clear cookies" half of BPC's recipe.
/// 3. RENDERED — plain webview load for JS app shells when the bypass
///    toggle is off (or the scripts are missing) and the fetch found
///    nothing.
///
/// The service is used from background import tasks; WKWebView work is
/// hopped to the main actor internally (creation, delegate callbacks,
/// evaluateJavaScript all arrive on main — the settle loop reads state on
/// main only). Every await is bounded: the fetch by its request timeout,
/// the settle by its cap, and the final extraction JS by a claim-guarded
/// continuation race (Webkit's evaluateJavaScript has NO internal timeout,
/// so a backgrounded import must be able to abandon it).
final class WebArticleService {

    struct Options {
        /// Run the BPC bypass pass on every import (still honors the global
        /// toggle inside `PaywallBypass`).
        var allowBypass = true
        /// Try the plain rendered pass before giving up (JS app shells).
        var allowRenderedFallback = true
    }

    static let shared = WebArticleService()

    /// Same caps the historical website importer used: a page beyond this
    /// is an app shell or a download, not an article. fileprivate — the
    /// harness class in this file shares them.
    fileprivate static let maxPageBytes = 3 * 1024 * 1024
    fileprivate static let maxTextChars = 200_000

    /// Settle windows: after the last navigation/bridge event, how long to
    /// let page JS (and BPC's reload/archive cycles) keep working before
    /// extracting. The bypass window is longer because BPC frequently
    /// reloads the page and fetches an archive copy after first paint.
    private static let settleQuiet: TimeInterval = 2.5
    private static let bypassSettleQuiet: TimeInterval = 4.0
    private static let settleCap: TimeInterval = 20
    private static let bypassSettleCap: TimeInterval = 40
    /// Hard bound on the final extraction JS call. WKWebView's
    /// `evaluateJavaScript` has NO internal timeout: if the app is
    /// backgrounded mid-import, page JS is suspended and the call can hang
    /// forever — the pipeline never returns, the "Fetching…" toast outlives
    /// the app, and every later import is refused with "Already fetching an
    /// article…". Abandoning the call after this bound (WebKit offers no
    /// cancellation; the webview is torn down right after) is what keeps
    /// backgrounded imports from wedging the importer permanently.
    fileprivate static let extractionTimeout: TimeInterval = 15

    private let fetchSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            // Plenty of CDNs 403 the default URLSession UA; a mobile
            // Safari one is what the page would have seen in a browser.
            // The bypass pass needs no special UA — BPC picks per-site UAs
            // for its own GM fetches.
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: config)
    }()

    // MARK: - Pipeline

    func article(from url: URL, options: Options = Options()) async -> WebArticle? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        let bypassAvailable = options.allowBypass && PaywallBypass.isEnabled && PaywallBypass.loadScripts() != nil

        var direct: WebArticle?

        if let html = await fetchHTML(url) {
            if let parsed = await parse(html: html, baseURL: url) {
                direct = parsed
                // Heuristics stay as the DIAGNOSTIC: they log WHY a page
                // looks walled. They no longer gate the bypass pass —
                // a wall that kept its markers out of the HTML sails
                // past them, and the bypass runs for every import anyway.
                let inspection = PaywallHeuristics.inspect(
                    html: html,
                    extractedTextLength: parsed.text.count
                )
                if inspection.paywalled {
                    Log.shared.info("WebArticle: paywall signals (\(inspection.reasons.joined(separator: "; "))) — \(url.absoluteString)")
                }
                if !inspection.paywalled, parsed.text.count >= 40 {
                    Log.shared.info("WebArticle: direct import (\(parsed.text.count) chars) — \(url.absoluteString)")
                }
            } else {
                Log.shared.info("WebArticle: readability found nothing in fetched HTML — \(url.absoluteString)")
            }
        }

        // BPC ON EVERY IMPORT (the default): the bypass pass runs for every
        // article, not only when the heuristics fired. On clean pages it
        // reproduces the same article and `bypassResultWins` keeps the
        // direct one; on walled ones its cookie/localStorage surgery and
        // archive fallbacks (GM.xmlHttpRequest bridge → archive.ph et al.)
        // recover the text the plain fetch could never see.
        if bypassAvailable {
            Log.shared.info("WebArticle: BPC pass starting — \(url.absoluteString)")
            if let bypassed = await render(url: url, bypass: true) {
                if Self.bypassResultWins(bypassed, over: direct) {
                    Log.shared.info("WebArticle: BPC pass won (\(bypassed.text.count) chars vs \(direct?.text.count ?? 0)) — \(url.absoluteString)")
                    return bypassed
                }
                Log.shared.info("WebArticle: BPC pass produced \(bypassed.text.count) chars — not better than direct, keeping direct")
            } else {
                Log.shared.info("WebArticle: BPC pass produced nothing — \(url.absoluteString)")
            }
        }

        if let direct { return direct }

        // Last resort for JS app shells: render the page WITHOUT any
        // userscript and extract from the live DOM. Reached when the bypass
        // toggle is off (or scripts missing) and the fetch found nothing —
        // and when a BPC pass itself extracted nothing from a shell page.
        if options.allowRenderedFallback, let rendered = await render(url: url, bypass: false) {
            Log.shared.info("WebArticle: rendered fallback import (\(rendered.text.count) chars) — \(url.absoluteString)")
            return rendered
        }
        return nil
    }

    /// A local .html/.htm file saved from a browser: same Readability
    /// extraction, no fetch. Falls back to nil — the caller keeps the
    /// DocumentBook (HtmlBookParser) route then.
    func article(fromLocalHTMLFile url: URL) async -> WebArticle? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard data.count <= Self.maxPageBytes else { return nil }
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return await parse(html: html, baseURL: nil)
    }

    /// DIRECT pass's comparison rule: the bypass result must beat the
    /// direct one by a real margin, not by navigation chrome noise.
    private static func bypassResultWins(_ bypassed: WebArticle, over direct: WebArticle?) -> Bool {
        guard let direct, direct.text.count >= 40 else { return bypassed.text.count >= 40 }
        return bypassed.text.count >= direct.text.count + 150
    }

    // MARK: - Fetch

    private func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await fetchSession.data(for: request) else {
            Log.shared.error("WebArticle: fetch failed — \(url.absoluteString)")
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            Log.shared.error("WebArticle: fetch status \(http.statusCode) — \(url.absoluteString)")
            return nil
        }
        guard data.count <= Self.maxPageBytes else {
            Log.shared.error("WebArticle: page too large (\(data.count) bytes) — \(url.absoluteString)")
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Passes

    /// Readability on HTML we already hold — the DIRECT pass. No page
    /// navigation. The real baseURL is set so Readability resolves the
    /// article's relative links; subresources the text never needed are
    /// not worth blocking on, and the settle window bounds the whole pass.
    private func parse(html: String, baseURL: URL?) async -> WebArticle? {
        let pass = await MainActor.run {
            HeadlessArticlePass(bypass: false, quiet: Self.settleQuiet, cap: Self.settleCap)
        }
        return await pass.extract(
            load: { webview in
                webview.loadHTMLString(html, baseURL: baseURL)
            },
            route: .fetchedHTML,
            sourceURL: baseURL
        )
    }

    /// A real navigation. `bypass: true` injects the BPC userscript stack
    /// into a fresh ephemeral webview.
    private func render(url: URL, bypass: Bool) async -> WebArticle? {
        let scripts: PaywallBypass.Scripts? = bypass ? PaywallBypass.loadScripts() : nil
        guard !(bypass && scripts == nil) else { return nil }
        let pass = await MainActor.run {
            HeadlessArticlePass(
                bypass: bypass,
                scripts: scripts,
                quiet: bypass ? Self.bypassSettleQuiet : Self.settleQuiet,
                cap: bypass ? Self.bypassSettleCap : Self.settleCap
            )
        }
        return await pass.extract(
            load: { webview in
                webview.load(URLRequest(url: url))
            },
            route: bypass ? .bypass : .rendered,
            sourceURL: url
        )
    }
}

// MARK: - Headless webview pass

/// One offscreen WKWebView, its navigation delegate, and (for the bypass
/// pass) the `bpcFetch` bridge. Not a long-lived object: built per pass,
/// torn down when `extract` returns.
///
/// Settle model: every navigation event (start/finish/fail) and every GM
/// bridge round-trip bumps `lastActivity`. The poller declares the page
/// settled `quiet` seconds after the last event (BPC's reloads and archive
/// fetches keep it alive), or at `cap` hard-stops. Extraction then runs
/// Readability against a CLONE of the live DOM, so BPC's unhiding work is
/// captured but not mutated by the extraction itself.
private final class HeadlessArticlePass: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    private let webView: WKWebView
    private var lastActivity = Date()
    private var startedAt = Date()
    private var didFinishAnyNavigation = false
    private let quiet: TimeInterval
    private let cap: TimeInterval

    /// The Readability.js source is shared by every pass; load once.
    private static let readabilitySource: String? = {
        guard let url = Bundle.main.url(forResource: "readability", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty else {
            Log.shared.error("WebArticle: readability.js missing from bundle — article extraction degraded")
            return nil
        }
        return source
    }()

    /// The content-DOM → markdown walker (html-to-markdown.js). Loaded once;
    /// when missing, articles import as plain textContent — the pre-1.9
    /// behavior — instead of failing.
    private static let markdownWalkerSource: String? = {
        guard let url = Bundle.main.url(forResource: "html-to-markdown", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty else {
            Log.shared.error("WebArticle: html-to-markdown.js missing from bundle — articles import without formatting")
            return nil
        }
        return source
    }()

    init(bypass: Bool, scripts: PaywallBypass.Scripts? = nil, quiet: TimeInterval, cap: TimeInterval) {
        self.quiet = quiet
        self.cap = cap
        let config = WKWebViewConfiguration()
        // Fresh jar per pass — the "clear cookies" half of the BPC recipe
        // (metered walls), and no cross-import state at all.
        config.websiteDataStore = .nonPersistent()
        let controller = config.userContentController
        if let readability = Self.readabilitySource {
            controller.addUserScript(WKUserScript(
                source: readability,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        if let walker = Self.markdownWalkerSource {
            controller.addUserScript(WKUserScript(
                source: walker,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        if bypass, let scripts {
            // Order matters: the shim defines GM before bpc_func/bpc use
            // it; the userscript manager would honor @require the same way.
            for source in [scripts.shim, scripts.library, scripts.main] {
                controller.addUserScript(WKUserScript(
                    source: source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                ))
            }
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        // WKWebView COPIES the configuration at creation, so the bridge
        // registration (which passes `self`) attaches to the live copy's
        // controller — and both statements can only run after super.init().
        if bypass {
            webView.configuration.userContentController.add(self, name: "bpcFetch")
        }
        webView.navigationDelegate = self
    }

    // MARK: Extraction driver

    /// Runs `load`, waits for the page to settle, extracts, and always
    /// detaches the bridge (the content controller retains its handler —
    /// the pass would never deallocate otherwise). `sourceURL` is the
    /// article's real URL (loadHTMLString leaves webView.url at
    /// about:blank).
    func extract(load: (WKWebView) -> Void, route: WebArticle.Route, sourceURL: URL?) async -> WebArticle? {
        await MainActor.run { load(webView) }
        startedAt = Date()

        // Settle poll — state is only ever touched on main (delegate
        // callbacks, bridge), so each tick hops over to read it.
        while true {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { break }
            let settled = await MainActor.run { self.isSettled() }
            if settled { break }
        }

        let article = await readabilityExtract(route: route, sourceURL: sourceURL)
        await MainActor.run {
            self.webView.configuration.userContentController
                .removeScriptMessageHandler(forName: "bpcFetch")
            self.webView.configuration.userContentController.removeAllUserScripts()
            self.webView.navigationDelegate = nil
            self.webView.stopLoading()
        }
        return article
    }

    @MainActor private func isSettled() -> Bool {
        if Date().timeIntervalSince(startedAt) > cap { return true }
        guard didFinishAnyNavigation else {
            // Nothing finished yet — keep waiting (within the cap) for the
            // first paint; a failed provisional load also lands here and
            // rides out the cap.
            return Date().timeIntervalSince(lastActivity) > quiet * 2
        }
        return Date().timeIntervalSince(lastActivity) >= quiet
    }

    // MARK: Readability

    /// The in-page extraction: clone the DOM (BPC's unhides stay intact on
    /// the original), run Readability, and post the JSON back in one string
    /// — evaluateJavaScript's bridging chokes on nothing that way.
    @MainActor private func readabilityExtract(route: WebArticle.Route, sourceURL: URL?) async -> WebArticle? {
        guard Self.readabilitySource != nil else { return nil }
        let js = """
        (function () {
          if (typeof Readability === 'undefined')
            return JSON.stringify({ ok: false, error: 'readability-missing' });
          try {
            var clone = document.cloneNode(true);
            var parsed = new Readability(clone, { charThreshold: 80 }).parse();
            if (!parsed || !parsed.textContent || parsed.textContent.trim().length < 1)
              return JSON.stringify({ ok: false, error: 'unreadable' });
            // Content DOM → GFM markdown (html-to-markdown.js). Guarded so a
            // walker bug can only cost the formatting, never the article:
            // the payload still carries textContent as the fallback.
            //
            // Readability's default serializer returns `content` as an HTML
            // STRING (`el.innerHTML` — the @mozilla/readability contract on
            // every 0.3+ release, confirmed in our vendored 0.5.0). Handing
            // that string to the walker yields nothing (no childNodes), which
            // is why every article once imported flat. Re-parse it into a DOM
            // first; a future version returning a real node skips the parse.
            var markdown = '';
            try {
              if (typeof __snArticleToMarkdown === 'function' && parsed.content) {
                var contentRoot = parsed.content;
                if (typeof contentRoot === 'string') {
                  contentRoot = new DOMParser().parseFromString(contentRoot, 'text/html');
                }
                contentRoot = contentRoot.documentElement
                  || contentRoot.body
                  || contentRoot;
                markdown = __snArticleToMarkdown(contentRoot, document.baseURI, parsed.title || '') || '';
              }
            } catch (e) {
              markdown = '';
            }
            return JSON.stringify({
              ok: true,
              title: parsed.title || '',
              byline: parsed.byline || '',
              siteName: parsed.siteName || '',
              excerpt: parsed.excerpt || '',
              text: parsed.textContent || '',
              markdown: markdown
            });
          } catch (e) {
            return JSON.stringify({ ok: false, error: String(e) });
          }
        })()
        """
        // The race: JS answer vs. the hard bound — and the bound MUST win
        // even when the answer never comes. A task-group race would drain
        // the group on exit, i.e. wait for the hung JS task itself, so this
        // uses the completion-callback form of evaluateJavaScript with a
        // claim-guarded continuation: WebKit's completion and the detached
        // timeout both try to resume, exactly one of them wins. The late
        // completion of a suspended webview is dropped harmlessly — the
        // teardown below deallocates the webview either way.
        enum EvalOutcome {
            case value(Any?, Error?)
            case timedOut
        }
        /// Resume-exactly-once guard: WebKit's callback and the timeout
        /// task race from different threads.
        final class OnceClaim: @unchecked Sendable {
            private let lock = NSLock()
            private var claimed = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if claimed { return false }
                claimed = true
                return true
            }
        }
        let outcome: EvalOutcome = await withCheckedContinuation { continuation in
            let claim = OnceClaim()
            self.webView.evaluateJavaScript(js) { result, error in
                guard claim.claim() else { return }
                continuation.resume(returning: .value(result, error))
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(WebArticleService.extractionTimeout * 1_000_000_000))
                guard claim.claim() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
        guard case .value(let raw, let error) = outcome else {
            Log.shared.info("WebArticle: extraction JS hit the \(Int(WebArticleService.extractionTimeout))s bound — \(route.rawValue) pass")
            return nil
        }
        guard error == nil, let html = raw as? String,
              let data = html.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ExtractedArticle.self, from: data) else {
            Log.shared.info("WebArticle: extraction call failed on \(route.rawValue) pass\(error.map { ": \($0.localizedDescription)" } ?? "")")
            return nil
        }
        guard decoded.ok, let decodedText = decoded.text, !decodedText.isEmpty else {
            Log.shared.info("WebArticle: \(route.rawValue) extraction: \(decoded.error ?? "empty")")
            return nil
        }
        let text = Self.postprocess(decodedText)
        guard text.count >= 40 else {
            Log.shared.info("WebArticle: \(route.rawValue) pass produced only \(text.count) chars — treating as nothing")
            return nil
        }
        // The markdown is kept only when it plausibly covers the same
        // article: the walker flattens links/images into syntax but drops
        // nothing else, so a result far shorter than the text means the
        // conversion went sideways — fall back to plain text wholesale
        // rather than ship a truncated article.
        var markdown: String?
        if let rawMarkdown = decoded.markdown {
            let cleaned = Self.postprocessMarkdown(rawMarkdown)
            if !cleaned.isEmpty, cleaned.count >= max(40, text.count / 3) {
                markdown = cleaned
            } else {
                Log.shared.info("WebArticle: \(route.rawValue) markdown unusable (\(cleaned.count) chars vs \(text.count) text) — importing plain")
            }
        }
        return WebArticle(
            title: decoded.title ?? "",
            byline: (decoded.byline?.isEmpty ?? true) ? nil : decoded.byline,
            siteName: (decoded.siteName?.isEmpty ?? true) ? nil : decoded.siteName,
            excerpt: (decoded.excerpt?.isEmpty ?? true) ? nil : decoded.excerpt,
            text: text,
            markdown: markdown,
            sourceURL: sourceURL ?? webView.url ?? URL(string: "about:blank")!,
            route: route
        )
    }

    private struct ExtractedArticle: Codable {
        let ok: Bool
        var title: String?
        var byline: String?
        var siteName: String?
        var excerpt: String?
        var text: String?
        var markdown: String?
        var error: String?
    }

    /// Readability's textContent joins blocks with newlines; collapse the
    /// runs, drop blank-edge lines, cap the note-sized length.
    private static func postprocess(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        let lines = collapsed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n\n").prefix(WebArticleService.maxTextChars))
    }

    /// Markdown keeps its structure: same blank-run collapse and length cap
    /// as `postprocess`, but no per-line whitespace stripping — code fences
    /// and nested lists are whitespace-significant.
    private static func postprocessMarkdown(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return String(
            collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(WebArticleService.maxTextChars)
        )
    }

    // MARK: WKNavigationDelegate (main thread, per WebKit)

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastActivity = Date()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastActivity = Date()
        didFinishAnyNavigation = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastActivity = Date()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A JS reload (BPC's refreshCurrentTab) can abort the provisional
        // load mid-flight; treat it as activity, not terminal.
        lastActivity = Date()
    }

    // MARK: GM.xmlHttpRequest bridge (main thread)

    // In-flight bridge requests keep the settle window open: BPC's archive
    // fetches happen after first paint, and yanking the page out from
    // under them is why a naive "didFinish + sleep" lost articles.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        lastActivity = Date()
        guard message.name == "bpcFetch",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let urlString = body["url"] as? String,
              let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = (body["method"] as? String ?? "GET").uppercased()
        request.timeoutInterval = 15
        for (name, value) in (body["headers"] as? [String: String]) ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let data = body["data"] as? String, !data.isEmpty {
            request.httpBody = Data(data.utf8)
        }
        // Cookie-less ephemeral session — GM semantics: the page's cookie
        // jar is NOT attached to cross-origin xhr unless the script set
        // the header itself (which we honored above).
        let session = URLSession(configuration: .ephemeral)
        let pass = self
        let capturedID = id
        session.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 4 MB cap: archive pages and API payloads, never media.
            let capped = data.flatMap { $0.count <= 4 * 1024 * 1024 ? $0 : nil }
            let text = capped.map { String(decoding: $0, as: UTF8.self) } ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pass.deliverBridgeCallback(id: capturedID, ok: capped != nil, status: status, text: text)
                }
            }
        }.resume()
    }

    /// Delivers one GM.xmlHttpRequest answer into the page. MainActor by
    /// declaration AND by arrival (DispatchQueue.main) — the assumeIsolated
    /// hop above reconciles the two for the compiler no matter how the SDK
    /// annotates WKScriptMessageHandler and WKWebView.
    @MainActor private func deliverBridgeCallback(id: String, ok: Bool, status: Int, text: String) {
        webView.evaluateJavaScript(Self.bridgeCallbackJS(id: id, ok: ok, status: status, text: text)) { _, _ in }
    }

    /// JSON-escapes every argument — the response text is arbitrary HTML
    /// and must never be interpolated raw into the JS call.
    private static func bridgeCallbackJS(id: String, ok: Bool, status: Int, text: String) -> String {
        func js(_ value: String) -> String {
            String(data: (try? JSONEncoder().encode(value)) ?? Data("".utf8), encoding: .utf8) ?? "\"\""
        }
        return "window.__bpcCb && window.__bpcCb(\(js(id)), \(ok), \(status), \(js(text)))"
    }
}
