import Foundation

/// The vendored reader engines' bundle assets, served over `bookscheme://shell/…`
/// by both webviews that need them: the book reader's scheme handler
/// (BookWebView.Coordinator) and the document importer's hidden parse webview
/// (DocumentParseService).
///
/// Two engines share this table:
///
/// * the epub.js shell (index.html + reader.js) for EPUBs and the
///   office-normalized books, and
/// * the foliate-js engine (foliate.html + sn-shell-ios.js + the vendored
///   readest-fork modules, MIT — see Resources/foliatejs/LICENSE) for the
///   headless document family: it parses the book's ORIGINAL file in the
///   webview, nothing is converted.
///
/// Path allow-list: the shell hosts serve ONLY these names from the bundle.
/// The historical version served ANY bundle resource by path — combined with
/// allowScriptedContent:true and CORS:* that was an exfiltration path for
/// malicious EPUBs. (Resources sit flat in the bundle root — xcodegen
/// flattens the group tree — so a `vendor/zip.js` module import resolves by
/// basename.)
enum FoliateAssets {
    static let epubShell: Set<String> = [
        "index.html", "reader.js", "epub.min.js", "jszip.min.js",
    ]
    static let foliateShell: Set<String> = [
        "foliate.html", "sn-shell-ios.js",
        "view.js", "paginator.js", "epubcfi.js", "progress.js",
        "overlayer.js", "text-walker.js", "section-chunks.js",
        // The pre-paginated renderer: view.js imports it dynamically for a
        // book whose rendition is "pre-paginated" (a KF8 MOBI with
        // fixedLayout=true). Without it the import 404s and view.open()
        // throws — the book cannot open at all.
        "fixed-layout.js", "construct-style-sheets-polyfill.js",
        "mobi.js", "fb2.js", "sn-txt.js", "sn-docbook.js",
        "sn-html.js", "sn-rtf.js", "zip.js", "fflate.js",
    ]

    /// The bundled bytes for a shell-host resource name, with its mime. nil
    /// for any name outside the allow-list.
    static func serve(_ name: String) -> (data: Data, mime: String)? {
        let base = (name as NSString).lastPathComponent
        guard epubShell.contains(base) || foliateShell.contains(base) else { return nil }
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        guard let url = bundleURL(stem, ext) else { return nil }
        guard var data = try? Data(contentsOf: url) else { return nil }
        // The foliate shell page carries the shell module INLINE: an external
        // <script type="module" src> never executes on this WebKit's
        // custom-scheme pages (the Linux reader measured the same on
        // WebKitGTK and splices its module the same way), while an inline
        // module importing the same files runs fine.
        if base == "foliate.html",
           let template = String(data: data, encoding: .utf8),
           let moduleURL = bundleURL("sn-shell-ios", "js"),
           let module = try? String(contentsOf: moduleURL, encoding: .utf8),
           template.contains("<!-- sn-shell-module -->"),
           let spliced = template
            .replacingOccurrences(
                of: "<!-- sn-shell-module -->",
                with: "<script type=\"module\">\n" + module + "\n</script>"
            )
            .data(using: .utf8) {
            data = spliced
        }
        let mime: String
        switch ext {
        case "html": mime = "text/html"
        case "js": mime = "text/javascript"
        default: mime = "application/octet-stream"
        }
        return (data, mime)
    }

    /// Bundle lookup that survives the two layouts xcodegen can produce: a
    /// group tree flattens `foliatejs/` into the bundle root (the epubjs
    /// resources' proven shape), while a folder reference keeps the
    /// directory — try both before giving up.
    private static func bundleURL(_ stem: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: stem, withExtension: ext)
            ?? Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "foliatejs")
            ?? Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "foliatejs/vendor")
            ?? Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "vendor")
    }
}
