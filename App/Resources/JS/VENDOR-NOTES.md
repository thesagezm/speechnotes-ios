# Vendored JavaScript for web/HTML article import

Everything the article-import webview injects is bundled here — the import
path works fully offline, no CDN, per the app's offline rule. (Fetching the
ARTICLE itself is of course a network operation; nothing around the
extraction pipeline phones home.)

| File | Source | Version | License |
|---|---|---|---|
| `readability.js` | https://cdn.jsdelivr.net/npm/@mozilla/readability@0.5.0/Readability.js (mozilla/readability) | 0.5.0 | Apache-2.0 (banner kept in file) |
| `bpc.en.user.js` | https://gitflic.ru/project/magnolia1234/bypass-paywalls-clean-filters/blob/raw?file=userscript/bpc.en.user.js | 4.4.7.4 | MIT (per its own header) |
| `bpc_func.js` | https://gitflic.ru/project/magnolia1234/bypass-paywalls-clean-filters/blob/raw?file=userscript/bpc_func.js | 4.4.7.2-era (matches 4.4.7.x) | MIT (same project) |

Downloaded and vendored 2026-10-24, byte-identical to upstream so a future
refresh is a plain diff. `bpc.en.user.js` declares `@require bpc_func.js` —
a userscript manager would fetch it; the app injects both manually, in
order (GM shim → `bpc_func.js` → `bpc.en.user.js`) at document start, which
is why `bpc_func.js` lives beside it here.

The BPC pair is the userscript (Greasemonkey-API) form of Bypass Paywalls
Clean by magnolia1234. Its only privileged API is `GM.xmlHttpRequest`;
`WebArticleService` provides that one function through a native bridge
(`webkit.messageHandlers.bpcFetch` → URLSession → callback). Nothing else
is shimmed — the script's cookie/localStorage work runs in the page's own
ephemeral WKWebView data store.

To update: drop fresh copies into `Documents/BypassPaywalls/` (visible in
Files as "On My iPhone → Speechnotes → BypassPaywalls") — they override the
bundled ones without a rebuild. Keep both files' versions in lockstep
(4.4.7.x userscript wants the 4.4.7.x func library).
