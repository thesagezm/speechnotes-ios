# Web article import — the formatting pipeline

v1.8.x. Companion to `WebArticleService.swift` (the passes), `App/Resources/JS/html-to-markdown.js`
(the walker) and the ShareExtension target (the share sheet).

## Why articles used to import as one flat paragraph

The extraction always ran Readability correctly — but consumed only
`parsed.textContent`, which is the article with every structure stripped to
newline-separated prose. Headings, lists, blockquotes, tables and — the
worst loss — the article's own hyperlinks never survived the trip, no
matter how well the note rendered.

## The pipeline now

1. **Fetch** — the passes: DIRECT (URLSession + Readability on the fetched
   HTML), BYPASS (BPC userscript in an ephemeral webview), RENDERED (plain
   webview navigation for JS shells), LEGACY (tag-strip, last fallback).
   The BYPASS pass runs for EVERY import while the toggle is on (default,
   Appearance → Web Import): the plain fetch cannot see past a wall that
   kept its markers out of the HTML, so every article goes fetch → BPC and
   the better result wins (`bypassResultWins`: the bypass text must beat
   the direct one by 150 chars, or the direct one must be a stub). On
   clean pages the two agree and the direct result stands.
2. **Extract** — Readability produces `textContent` (the fallback, and the
   paywall heuristic's length signal) and `content`. NOTE: `content` is an
   HTML STRING in @mozilla/readability (the default serializer is
   `el.innerHTML`) — the extraction JS re-parses it with DOMParser before
   walking. Handing the string straight to the walker once produced zero
   markdown on every real page (the mock suite passed because its fake
   parse returned a node).
3. **Walk** — `html-to-markdown.js` (injected at document end, like
   Readability itself) flattens that DOM to the GFM subset the app
   renders/speaks: headings (shifted down one level — the note's first
   line IS the headline), paragraphs, `<br>` line breaks, links
   (http(s)-resolved against the page base, `javascript:`/`mailto:`/
   relative-with-no-base degrade to text), bold/italic/strike, inline
   code, fenced code blocks (language class on `<pre>` or `<code>`),
   nested lists + GFM task checkboxes, blockquotes, pipe tables, `---`,
   images — `data-src`/`data-lazy-src`/`data-original` before a placeholder
   `src`, `srcset`/`data-srcset` largest-candidate fallback, `<picture>`
   resolved to ONE image (the `<img>` inside, else a `<source>` srcset) —
   junk paragraphs dropped whole ("Advertisement", caption toggles), figure
   captions as italics, definition lists as bold-term paragraphs. Markdown
   significators in the article's own text are backslash-escaped, and a
   leading heading equal to the article title is dropped (the note's title
   line already carries it).

   A walker bug can only cost formatting, never the article: the Swift
   side keeps the markdown only when it plausibly covers the same text
   (`markdown.count >= max(40, text.count / 3)`), else imports the plain
   textContent.
4. **Import** — `fetched.markdown ?? fetched.text` becomes the note body
   (URL shares, clipboard links, drag & drop, the scheme, local .html
   files). The first article import flips `renderMarkdown` on **only if
   the user never touched the setting** — an explicit off stays off.
   TTS/read-along strip the sigils through `MarkdownText.plainText` as
   with any markdown note.

## Why imports used to hang, then fail

`WKWebView.evaluateJavaScript` has NO internal timeout. A page suspended
in the background (app backgrounded mid-import) never answers the
extraction call, the pipeline never returned, and `isFetchingArticle`
stayed true — every later import was refused with "Already fetching an
article…" until relaunch. The extraction now races the JS answer against
a claim-guarded continuation (WebKit's completion handler and a detached
timeout, exactly one resume wins), so every import terminates: fetch 20s
timeout, settle caps, 15s extraction bound.

## The share sheet (native installs only)

The `ShareExtension` target (bundle `com.speechnotes.ios.Share`) appears
for pages (public.url) and text. It holds no data of its own and needs no
App Group (free-account SideStore provisioning): it hands off through the
`speechnotes://import?url=…` / `speechnotes://…?text=` schemes the app has
handled since v1.4. The open goes `NSExtensionContext.open` first, then
the responder-chain `openURL:`; when neither works the sheet says so and
copies the payload for "⋯ → New note from clipboard".

LiveContainer cannot host extensions — inside LC the app simply never sees
the share sheet, and the extension-free channels (clipboard, drag & drop,
scheme, BookDrop, Open-In) remain the ways in. Embedded `.appex` copies
are ignored there; CI's framework verify step only inspects the main
binary, so the extension does not disturb the LiveContainer contract.

## Testing the walker

`Scripts/test-html-to-markdown.js` runs the walker against a minimal DOM
mock (the exact API surface it touches) — 53 assertions covering
headings/level-shift, title dedupe, inline markup, escaping, link
resolution classes, lists (nested, ordered, task), quotes, fences,
tables, images, dropped chrome, whitespace discipline. CI runs it in the
logic-tests job (`node Scripts/test-html-to-markdown.js`); locally any
Node ≥ 18:

```
node Scripts/test-html-to-markdown.js
```

The mock deliberately mirrors only `nodeType`, `nodeName`, `childNodes`,
`nodeValue`, `getAttribute`, `hasAttribute` and `textContent` — if the
walker starts needing more DOM surface than that, extend the mock, not
the walker's assumptions.
