# Reader-mode extension notes — what was studied, what was folded in, what was left behind

Companion to `App/Sources/Services/WebArticleService.swift` (the passes),
`Packages/SpeechLogic/Sources/SpeechLogic/ReaderModeExtraction.swift` (the
plan) and `Docs/WEB-ARTICLE-IMPORT.md` (the formatting pipeline).

## The studied repo

`github.com/kushagrasinghx/reader-mode-extension` @ `d6b677f` — MIT, a small
Chrome extension whose README calls it "a clean and distraction-free Chrome
Extension" that pulls the article out with Mozilla's Readability and shows
it in a new tab, "just like Safari browser". It was read for two reasons:
the importer already runs Readability, so the interesting question was what
a READER MODE does around Readability that the importer did not; and its
`reader.html` / `reader.css` pair is the canonical "distraction-free"
layout every reader-mode extension converges on.

Root files: `README.md`, `background.js`, `contentScript.js`, `icon.png`,
`manifest.json`, `preview.png`, `readability.js`, `reader.css`,
`reader.html`, `reader.js`.

### The trap in the repo: its `readability.js` is a STUB

The extension ships a file called `readability.js` that is **not** Mozilla's
Readability. It is a ~15-line stand-in (24 lines with the blank ones) whose
entire `parse()` is:

- take `document.querySelector("article")`, else fall back to the body;
- take `document.title` as the title;
- take the first 100 characters as the excerpt;
- report `byline: null`.

There is no scoring, no cleaning, no traversal, no candidate comparison. A
reader that vendored THAT file would "work" on a page that ships an
`<article>` element and fall apart on every page that does not — which is
most of the long tail of publishers. **The real algorithm in that repo lives
in `contentScript.js`**, which clones the document, strips the chrome, and
calls the REAL `Readability` (loaded from a CDN) on the clone.

The lesson for this codebase is worth stating plainly: *the file name is
not the algorithm.* Our importer has always used the genuine
`@mozilla/readability` (vendored, `App/Resources/JS/`); this round verified
that the thing being copied was the surrounding STRATEGY, not a parser.

### What `contentScript.js` actually does

1. **Clone** the current document (`document.cloneNode(true)`) — the live
   page is never touched.
2. **Remove the chrome by SELECTOR** from the clone: `nav`, `footer`,
   `#footer`, `.footer`, `#sidebar`, `.sidebar`, `.navigation`, `.nav`,
   `.menu`, `.mw-sidebar`, `.mw-portlet`, `.portal`, `#mw-navigation`,
   `#siteSub`, `#p-navigation`, and then the noisy FORM furniture —
   `input`, `textarea`, `form`, `button`, `select` — plus `img` and
   `aside`.
3. **Extract** with Readability on the cleaned clone; on failure it alerts
   and stops.
4. **Open a new tab** on the extension's own `reader.html`, handing the
   title and the extracted HTML over in the query string; `reader.css` and
   `reader.js` render it in the clean layout.

**What it does NOT do: paywall handling.** There is no bypass, no cookie
jar, no archive copy, no heuristic. The extension assumes the page it is on
is readable. For an app whose whole point is importing articles that the
publisher has walled off, that is the single biggest gap between the two
projects — and the reason the ideas below were folded in as *pre-processing
for a pipeline we already have*, not as a replacement for it.

## What was folded in

### 1. The selector-based PRE-STRIP (the chrome comes off before the scoring)

Readability is a SCORING algorithm. Scoring can be persuaded: a sticky
header, a "related articles" rail, a comment widget or a footer full of
links can out-score the story, and the import then carries the furniture
instead of the article. The extension's answer — delete the furniture from
the clone BEFORE the scoring runs — is exactly right, and it is cheap.

Ours: `ReaderModeExtraction.chromeSelectors` (the same selector list),
removed from the clone by `stripChrome()` in the extraction script, on
BOTH paths — the article fast path and the scored path. The removal walks
the node list backwards so the removals do not skip their siblings.

### 2. The ARTICLE-ROOT FAST PATH (a page that says where its article is)

A page that carries a real `<article>` (or `<main>`) has already told us
where the story is; running the scoring over it is wasted work and a chance
to get a different (worse) answer. The extension's stub makes this the
ONLY path it takes — and that is why it fails on pages without an
`<article>`.

Ours: a **fast path with a floor**, not a replacement. The candidate roots
are tried in preference order (`article`, `main`, `[role="main"]`,
`.post-content`, `.entry-content`, `.article-content`, `.article-body`,
`.story-body`), and a root is only trusted when it carries at least
`minArticleChars` (400) characters of text — a "related posts" box or an
empty app shell must not win over the story. The first candidate that
clears the floor wins; a page with no article root falls through to the
scored path exactly as before. The stub's `querySelector("article")` idea
survives, its "no floor, no fallback" behaviour does not.

The fast path returns the article as **MARKDOWN only** (`textFromMarkdown:
true`). The DOM's `textContent` runs the paragraphs together ("onetwo"),
while the markdown walker keeps the block structure; the plain text is
derived on the Swift side with `MarkdownText.plainText` — the same
machinery the notes use, so an imported article reads exactly like a typed
one.

### 3. The excerpt = first 100 characters

The stub's excerpt rule, and the extension's own reader layout, both treat
the first 100 characters as the preview. Ours takes the first 100
characters of the MARKDOWN (not of the flattened text), so the preview
shows the story's opening words rather than a mid-word cut.

### 4. One source of truth for the lists

The selector lists live in the PACKAGE (`ReaderModeExtraction`), not in
the page-side JavaScript, and the script reads them from
`ReaderModeExtraction.selectorsJSON` — a JSON blob injected into the
script. The page's chrome list and the Swift module's chrome list cannot
drift, because they are the same array. `Scripts/test-reader-mode-extraction.js`
extracts the JavaScript out of the Swift string literal and runs it against
a mock DOM, so the two sides are tested together.

## What was deliberately NOT copied

- **Dropping `img`.** The extension removes every image before the
  scoring. This importer does not: pictures are CONTENT, the markdown
  walker emits `![alt](src)`, and a photo essay imported without its
  photographs is not the article. Our strip list has no `img`.
- **Dropping `aside`.** The extension removes `aside` too. The walker
  already skips asides on its own (they are pull-quotes and sidebars, not
  the body), so stripping them twice buys nothing and risks a page whose
  story lives in an `<aside>`.
- **The new-tab reader layout.** The extension's whole point is to open a
  clean page in another tab. This app has no browser: the "reader mode"
  IS the note, rendered by `MarkdownPreviewView` and spoken by the engine.
  Porting `reader.html`/`reader.css` would have meant shipping a second
  document renderer for a surface that already exists.
- **The stub `readability.js`.** Never vendored, never consulted. The
  importer uses the genuine `@mozilla/readability`, and the only thing
  worth learning from the stub was the article-root idea — which is why
  the fast path is a fast path and not a parser swap.

## What the extension does that this app does NOT (yet)

- **Paywall handling — and this app has the better of it.** The bypass
  pass (BPC) runs for every import, clears the wall's cookies and re-reads
  the page in a webview with the userscript injected; `PaywallHeuristics`
  decides which pass wins, and the rule now includes the case the
  extension cannot have at all: a DIRECT result the heuristics flagged as
  a WALL is a teaser, so an equally long bypass result beats it.
- **A clean reading layout of the extracted HTML.** The extension renders
  the raw extracted DOM; this app renders GFM through the notes' own
  renderer, which is strictly richer (headings, lists, tables, maths,
  images, links — and a note the user can edit).

## The honest summary

The extension is a small, MIT-licensed Chrome extension with a stub
parser, a decent pre-strip list and a clean-tab layout. Its contribution
to this round was two ideas and a list: strip the chrome before the
scoring, and trust an article root when the page has one. Everything
else — the real extraction, the paywall passes, the markdown, the note —
the importer already had, and does better.
