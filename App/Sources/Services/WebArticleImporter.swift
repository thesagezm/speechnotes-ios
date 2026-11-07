import Foundation
import SpeechLogic

/// Fetches a web page over the network and extracts its reader text for the
/// note importer — the web half of `ImportService`.
///
/// This is the backend the share channels were always missing. The app can't
/// host a share extension (LiveContainer), so a shared article reaches it as
/// a URL through one of the extension-free channels — clipboard, drag & drop,
/// `speechnotes://…?url=`, or a forwarded `https://` open-URL — and until
/// now every one of those either stored the bare link as a note or errored.
/// The fetch is deliberately browser-like (redirects followed, desktop
/// Safari agent, generous timeout): metered news sites serve their full
/// first-payload HTML to a browser, and the reader extraction in
/// `WebArticle` turns that payload into the same prose a file import would.
///
/// Every step logs — the historical "import doesn't work" reports were
/// silent failures, and a device log that names the host, status and byte
/// count pinpoints the failure without a debugger.
enum WebArticleImporter {

    /// Hard cap on the response body. A normal article is well under 1 MB;
    /// beyond ~8 MB it's a bundle of inline scripts, and the extraction
    /// only reads the first `maxParseBytes` anyway (the tolerant tokenizer
    /// handles a cut tag). Bounds the memory spike on the LiveContainer
    /// process — the whole container jetsams together.
    private static let maxResponseBytes = 8 * 1_024 * 1_024
    private static let maxParseBytes = 4 * 1_024 * 1_024

    /// Keep the note a note: the PDF importer's cap, reused. A web page
    /// that extracts to a million characters is a directory page, not an
    /// article.
    private static let maxTextChars = 1_000_000

    /// Desktop Safari agent: some news sites serve stripped-down HTML to
    /// unknown clients, and the whole point is their full first payload.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Downloads `url` and extracts reader text. Returns nil (with a logged
    /// reason) when the fetch fails or the page has no extractable text —
    /// the caller decides what to do with the link.
    static func importArticle(from url: URL) async -> (title: String, text: String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            Log.shared.error("WebImport: not a web URL — \(url.absoluteString.prefix(120))")
            return nil
        }
        Log.shared.info("WebImport: fetching \(url.host ?? url.absoluteString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Log.shared.error("WebImport: fetch failed: \(error.localizedDescription)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.shared.info("WebImport: \(url.host ?? "?") → \(status), \(data.count) bytes")
        guard (200..<300).contains(status) else { return nil }

        let mime = (response.mimeType ?? "").lowercased()
        let title = url.host ?? "Web article"

        // Plain text: no reader pass, decode and go.
        if mime.contains("text/plain") {
            let text = HtmlBookParser.decode(data)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.shared.error("WebImport: text/plain body was empty")
                return nil
            }
            return (title, String(trimmed.prefix(maxTextChars)))
        }

        // Everything else goes through the HTML reader — xhtml, xml-ish
        // markup and the unlabelled responses that are really HTML.
        if mime.contains("json") || mime.contains("octet-stream")
            || mime.hasPrefix("audio/") || mime.hasPrefix("video/")
            || mime.hasPrefix("image/") || mime.contains("pdf") {
            Log.shared.error("WebImport: \(url.host ?? "?") served \(mime) — not a page")
            return nil
        }

        let parseData = data.prefix(maxParseBytes)
        guard let article = WebArticle.extract(html: Data(parseData)) else {
            Log.shared.error("WebImport: no extractable text in \(url.host ?? "?") (likely a JS-rendered shell)")
            return nil
        }
        let body = String(article.text.prefix(maxTextChars))
        Log.shared.info("WebImport: extracted \(body.utf16.count) chars from \(url.host ?? "?")")
        return (article.title ?? title, body)
    }
}
