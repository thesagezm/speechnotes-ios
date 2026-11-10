import Foundation

/// Settings + script loading for the Bypass Paywalls Clean (BPC) web-import
/// pass. The BPC pair (`bpc_func.js` + `bpc.en.user.js`, userscript form by
/// magnolia1234) is vendored in App/Resources/JS — see its VENDOR-NOTES.md.
///
/// BYPASS IS ON BY DEFAULT AND RUNS ON EVERY ARTICLE: the plain fetch cannot
/// see past a publisher wall that kept its markers out of the HTML, so the
/// heuristics no longer gate the pass — every import goes fetch → BPC and
/// the better result wins. A copy dropped into Documents/BypassPaywalls/
/// (visible in the Files app) overrides the bundled pair without a rebuild,
/// so the script can be refreshed when sites change — keep both files'
/// versions in lockstep.
enum PaywallBypass {

    static let enabledKey = "webImport.bypassPaywalls"

    /// Master toggle. Default ON: every import runs the BPC pass (clean
    /// pages cost a slower second pass; walled ones recover their full text
    /// with the script's own archive fallbacks — a user sharing a paywalled
    /// article wants the text on the first try, not after a settings trip).
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: - Scripts

    struct Scripts {
        /// The GM.xmlHttpRequest shim — injected FIRST, at document start.
        let shim: String
        /// bpc_func.js — the userscript's @require companion library.
        let library: String
        /// bpc.en.user.js — the site logic itself.
        let main: String
        /// Parsed from the main script's `@version` header.
        let version: String
        /// "drop-in" (Documents override) or "bundled".
        let origin: String
    }

    /// The one privileged API the userscript form of BPC needs. The native
    /// side answers `webkit.messageHandlers.bpcFetch`; everything else
    /// (cookie/localStorage surgery) runs in the page's own ephemeral
    /// WKWebView data store with no shim at all.
    static let gmShim = """
    (function () {
      var seq = 0;
      var pending = {};
      window.__bpcCb = function (id, ok, status, text) {
        var d = pending[id];
        if (!d) return;
        delete pending[id];
        try {
          if (ok && d.onload)
            d.onload({ status: status, responseText: text, response: text, finalUrl: '' });
          else if (!ok && d.onerror)
            d.onerror({ error: 'network' });
        } catch (e) {}
      };
      window.GM = window.GM || {};
      window.GM.xmlHttpRequest = function (d) {
        var id = 'bpc' + (++seq);
        pending[id] = d;
        try {
          window.webkit.messageHandlers.bpcFetch.postMessage({
            id: id,
            method: d.method || 'GET',
            url: d.url,
            headers: d.headers || {},
            data: d.data || null
          });
        } catch (e) {
          delete pending[id];
          if (d.onerror) { try { d.onerror({ error: 'no-bridge' }); } catch (e2) {} }
        }
      };
    })();
    """

    /// Loads the BPC pair, preferring a user drop-in over the bundled copy.
    /// nil (logged) when nothing loadable — the bypass pass then quietly
    /// skips instead of loading the page unprotected. Computed once per
    /// process: the pair is ~300 KB of disk reads, every import asks, and
    /// a drop-in only ever changes across launches.
    static func loadScripts() -> Scripts? { cachedScripts }

    private static let cachedScripts: Scripts? = {
        let documentsOverride = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BypassPaywalls")
        if let dir = documentsOverride,
           let main = try? String(contentsOf: dir.appendingPathComponent("bpc.en.user.js"), encoding: .utf8),
           let library = try? String(contentsOf: dir.appendingPathComponent("bpc_func.js"), encoding: .utf8),
           !main.isEmpty, !library.isEmpty {
            Log.shared.info("PaywallBypass: using drop-in scripts from Documents/BypassPaywalls")
            return Scripts(
                shim: gmShim,
                library: library,
                main: main,
                version: version(in: main) ?? "drop-in",
                origin: "drop-in"
            )
        }
        guard let mainURL = Bundle.main.url(forResource: "bpc.en", withExtension: "user.js"),
              let libURL = Bundle.main.url(forResource: "bpc_func", withExtension: "js"),
              let main = try? String(contentsOf: mainURL, encoding: .utf8),
              let library = try? String(contentsOf: libURL, encoding: .utf8),
              !main.isEmpty, !library.isEmpty else {
            Log.shared.error("PaywallBypass: bundled bpc scripts missing — bypass pass disabled")
            return nil
        }
        return Scripts(
            shim: gmShim,
            library: library,
            main: main,
            version: version(in: main) ?? "unknown",
            origin: "bundled"
        )
    }()

    /// `@version 4.4.7.4` out of the userscript header, for the Settings
    /// footer and the import log.
    static func version(in mainScript: String) -> String? {
        guard let range = mainScript.range(of: "@version") else { return nil }
        let line = mainScript[range.upperBound...].prefix(60)
        let value = line.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? ""
        let digits = value.prefix { $0.isNumber || $0 == "." }
        return digits.isEmpty ? nil : String(digits)
    }
}
