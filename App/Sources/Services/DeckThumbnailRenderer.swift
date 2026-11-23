import UIKit
import WebKit
import SlideDeckKit

/// The deck thumbnail: the FIRST slide, rasterized into the shelf's
/// cover.jpg.
///
/// Why: a deck ships no cover image of its own, so the shelf showed the
/// synthesized tile — the same gradient-with-a-"SLIDES"-badge for every
/// deck. The deck's own first slide IS the picture a reader expects on
/// the shelf, and the deck is already rendered by a WKWebView in the
/// reader, so the same document can be rasterized offscreen.
///
/// The render is EXACTLY the reader's rendering: the same CSS, the same
/// slide markup, the same `deck://media` scheme handler — so the
/// thumbnail shows the slide as the reader draws it, not an
/// approximation of it.
///
/// A thumbnail is a nicety, never a reason to fail an import: every
/// failure path returns nil and the shelf keeps the synthesized tile.
@MainActor
enum DeckThumbnailRenderer {

    /// The deck's first slide as JPEG bytes, or nil when the deck cannot
    /// be read or the render fails.
    static func firstSlideJPEG(bookDirectory: URL, format: BookFormat) async -> Data? {
        let sourceURL = bookDirectory.appendingPathComponent("original.\(format.fileExtension)")
        // The parse is the expensive part — it runs off main, exactly like
        // the reader's own load (BookSlidesView.loadDeck).
        let preview: DeckPreview? = await Task.detached(priority: .utility) { () -> DeckPreview? in
            guard let data = try? Data(contentsOf: sourceURL, options: .mappedIfSafe) else { return nil }
            guard let deck = try? DeckParser.parse(data), !deck.slides.isEmpty else { return nil }
            // The slide is drawn in POINTS, and CSS renders a point at 4/3
            // of a CSS pixel — the same factor the reader's fit script
            // uses. The zoom keeps the longest side inside the render
            // budget (a 13.3in deck is 1280 CSS points wide).
            let longSide = max(deck.w, deck.h) * 4 / 3
            let budget = 1200.0
            let zoom = longSide > budget ? budget / longSide : 1
            return DeckPreview(
                html: DeckHTML.slidePreviewHTML(deck, index: 0, zoom: zoom),
                media: deck.media,
                width: deck.w * 4 / 3 * zoom,
                height: deck.h * 4 / 3 * zoom
            )
        }.value
        guard let preview else { return nil }
        return await render(preview: preview)
    }

    /// The first slide, ready to rasterize: the document, the media it
    /// references and the size of the drawing surface.
    ///
    /// `@unchecked Sendable`: it crosses the detached parse back to the
    /// main actor, and everything it carries is a VALUE (the HTML string,
    /// the media bytes, two numbers) — `DeckMedia` simply never declared
    /// the conformance in the package.
    private struct DeckPreview: @unchecked Sendable {
        let html: String
        let media: [DeckMedia]
        let width: Double
        let height: Double
    }

    /// Rasterizes one slide document in an offscreen webview.
    private static func render(preview: DeckPreview) async -> Data? {
        let size = CGSize(width: max(1, preview.width), height: max(1, preview.height))
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            DeckMediaSchemeHandler(media: preview.media),
            forURLScheme: DeckHTML.mediaScheme
        )
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.isScrollEnabled = false

        webView.loadHTMLString(preview.html, baseURL: nil)
        guard await waitForLoad(webView) else { return nil }
        // The slide's pictures ride the scheme handler — give them a
        // moment to land before the snapshot, or the thumbnail loses the
        // deck's artwork.
        await waitForImages(webView)
        try? await Task.sleep(nanoseconds: 120_000_000)

        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(origin: .zero, size: size)
        // The shelf cell is ~100pt wide; 480 points of snapshot is plenty
        // and keeps the bitmap (and the JPEG) small.
        snapshotConfiguration.snapshotWidth = 480
        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: snapshotConfiguration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image else {
            Log.shared.info("DeckThumbnail: the snapshot came back empty")
            return nil
        }
        return jpeg(from: image)
    }

    /// Waits for the document to finish loading (bounded — a deck whose
    /// media never arrives must not hang the import).
    private static func waitForLoad(_ webView: WKWebView, timeout: TimeInterval = 10) async -> Bool {
        // The load starts asynchronously; give it a moment before asking
        // whether it is still running.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !webView.isLoading { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Waits until the slide's pictures have loaded (or gave up).
    private static func waitForImages(_ webView: WKWebView) async {
        for _ in 0..<20 {
            guard let pending = await evaluate(
                webView,
                "Array.from(document.images).filter(function (i) { return !i.complete; }).length"
            ) as? Int else { return }
            if pending == 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// One JavaScript evaluation, bridged to Swift.
    private static func evaluate(_ webView: WKWebView, _ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    /// The snapshot as JPEG bytes — flattened onto white first, because a
    /// JPEG has no alpha channel and a transparent snapshot would encode
    /// as black.
    private static func jpeg(from image: UIImage) -> Data? {
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        let flattened = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return flattened.jpegData(compressionQuality: 0.85)
    }
}

/// Serves the deck's own images to the webview: `deck://media/<index>/<name>`
/// (and the `…/fill` spelling a picture FILL uses) resolves to the parsed
/// deck's media entry at `<index>`.
///
/// Not private: the deck reader AND the thumbnail renderer both serve the
/// same URLs from the same media, and one handler keeps them identical.
final class DeckMediaSchemeHandler: NSObject, WKURLSchemeHandler {
    private let media: [DeckMedia]

    init(media: [DeckMedia]) {
        self.media = media
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        // deck://media/<index>/<name>
        let parts = url?.path.split(separator: "/").map(String.init) ?? []
        guard parts.first.flatMap(Int.init) != nil, !parts.isEmpty,
              let index = Int(parts[0]), index >= 0, index < media.count else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let entry = media[index]
        let data = Data(entry.data)
        let response = URLResponse(
            url: url ?? URL(string: "\(DeckHTML.mediaScheme)://media/\(index)")!,
            mimeType: entry.contentType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
