# Vendored JavaScript for the EPUB reader

Everything the in-reader webview loads is bundled here — the reader works
fully offline, no CDN, per the app's offline rule.

| File | Source | Version | License |
|---|---|---|---|
| `epub.min.js` | https://unpkg.com/epubjs@0.3.93/dist/epub.min.js (futurepress/epub.js) | 0.3.93 | FreeBSD (futurepress/epub.js LICENSE) |
| `jszip.min.js` | https://unpkg.com/jszip@3.10.1/dist/jszip.min.js (Stuart Knightley) | 3.10.1 | MIT or GPLv3 (banner kept in file) |

Downloaded and vendored 2026-09-06. The minified files carry their upstream
banner headers. If these are ever upgraded, re-download from the same pinned
versions and diff behavior against `Tests/EpubSpike` assumptions (spine/TOC
shape) plus the device checklist in `Docs/PLAN-V1.4.2-EBOOKS.md`.

`index.html` + `reader.js` are ours: the shell page and the glue that loads
the EPUB from the `bookscheme://` URL scheme, drives epub.js, and posts
relocated/TOC messages back to the native side.
