# PROGRESS LOG — SpeechNotes Upgrade Cycle

Format: newest first. Every critique round, merge, and escalation lands here.

---

**Slide-deck port M1 started: SlideDeckKit (XML + colors + full preset geometry) lands green** (branch `batch-c-d-session`, 2026-11-11):
- **New package target `SlideDeckKit`** (Package.swift: product + target, zero
  dependencies — the deck stack must not drag COpus/cmark into its importers)
  carrying the DeckCraft port (github.com/storytold/deckcraft @ a0eeb34,
  MIT/Apache-2.0) approved in HANDOVER-SLIDE-DECKS.md. Three commits: XML DOM +
  colours (`42254fe`, CI run 43084191092), preset geometry (`676f4a5`, CI run
  43097929997).
- **XML.swift** — the bounded XML DOM from pptx/src/xml.rs, with the scanner
  hand-rolled over UTF-8 bytes because quick-xml semantics must hold exactly: a
  literal CR/CRLF folds to LF while a `&#13;` reference stays a CR (XML 1.0
  §2.11 — the reason Foundation's XMLParser was rejected), attribute values
  normalize literal whitespace but keep reference-resolved whitespace,
  attributes match by local name (xmlns decls never match), depth 256 / 4M
  nodes bounded, truncated docs fold up, bare `&` is literal text. XNode is
  deliberately NOT `indirect`: recursion passes only through XEl.children
  (an Array, heap-backed) — the exact shape of the Rust `Vec<Node>`, no per-node
  boxing; CI confirmed it compiles as written.
- **First-draft bugs caught by re-reading against the Rust before CI** (this
  repo has no local toolchain; CI is the loop): missing Foundation imports;
  CDATA/comment detection compared the needle at the `!` byte instead of the
  `<` and could never match; `attach`/`pushText` mutated `stack.last` through
  an immutable binding (XEl is a struct — index-based mutation instead); a
  start element dropped for hitting a limit let its end tag pop its PARENT off
  the stack and re-parent siblings — the over-limit subtree is now skipped
  whole via a skip-depth counter, matching the Rust reader's all-or-nothing
  intent. CI found only two test-file slips (Rust-style `u8` literal suffixes,
  an XEl comparison); the library itself compiled first pass on both runs.
- **Color.swift** — sRGB `Rgba`, the twelve scheme slots + phClr, the DrawingML
  transform set (linear-light tint/shade, HSL lum/sat/hue mod+off, alpha
  family, comp/inv/gray, channel mods), preset colour names. Editor surface
  (picker grid, standard-colour rows, 190-name preset enumeration) not ported.
- **Preset geometry, the full read-path surface** — Geom.swift (kurbo
  stand-ins DPoint/DVec/DRect/DAffine, GeomPath with `toSVG()` byte-matching
  kurbo's format — shortest round-trip, plain decimal, Rust `Display` rules;
  adaptive flattening for bounds/area/point-distance; EMU↔pt; Xfrm; kurbo
  0.13.1's Arc→cubic approximation ported bit-for-bit so arc-heavy shapes emit
  the reference's exact control points), PresetCatalog.swift (184-entry
  CATALOG + defaults, mitredByDefault, isLineLike), PresetShapes.swift (Pb
  builder + the whole build() switch: corner rects, stars, pie/chord/arc, sun/
  moon, cloud arcTo tables, equation shapes, block arrows, flowcharts incl.
  multidocument's outline-where-visible, ribbons, scrolls, action buttons,
  connectors), PresetShapesExtra.swift (callouts, curved/circular arrows,
  ellipse ribbons, gears, funnel, swoosh). Handles and glue sites dropped
  (editor-only, per the approved decision). The viewer renders preset shapes
  as ONE `outline().toSVG()` — verified against sn-doc's shape_svg consumer.
- **Tests ported from the Rust geometry suites** (PresetTests.swift): every
  catalog preset builds within bounds at five sizes; hostile adjusts
  (NaN/inf/±1e12/±Double.max ×8) never break a build; ECMA-376 fixed-shape
  coordinates; PowerPoint-outline reference points for ~30 shapes (equation
  shapes, sun, waves, stars, moon, cloud, braces, callouts, curved/circular
  arrows, gears, swoosh, ribbons) — distances over a 1e-4 flattened outline;
  arc-spec direction semantics (the DrawingML visual→parametric mapping);
  areas; EMU roundtrip; Rust-Display number formatting. XMLColorTests pins the
  scanner contract (CR distinction, attribute normalization, local-name
  lookup, bounds, truncation folding, UTF-16 parts) and the colour math.
- **Next (M1 continues):** model types + resolve.rs port (`Model.swift`,
  `Resolve.swift`, `Theme.swift`, `Style.swift`, `DMLText.swift`, `Table.swift`,
  `ChartModel.swift`, `Defaults.swift`, `NumFmt.swift`) → Zip.swift (own copy
  of the zip reader, per decision) → pptx read (OPC/CFB sniffer/read modules)
  → ODP → slides.rs resolution → in-memory pptx/odp fixtures. Nothing from the
  app target touched yet.

---

**Web import: flat-paragraph root cause found + fixed, bypass on every import, hang-proof pipeline** (branch `batch-c-d-session`, 2026-11-10):
- **Why EVERY article imported flat (no headings/links/images):** the
  vendored Readability 0.5.0 returns `parsed.content` as an HTML STRING
  (its default serializer is `el.innerHTML`), but the extraction JS handed
  it to the markdown walker as if it were a DOM node — `.documentElement`/
  `.body` on a string are undefined, the walker saw a string with no
  childNodes, and emitted `''` on every page. The Swift cover-rule then
  discarded the empty markdown, so every import fell back to textContent.
  Verified live against Guardian/Ars/NYT/Wired/Apple (0 markdown chars
  everywhere, pre-fix). Fix: re-parse `content` with DOMParser before
  walking (Docs/WEB-ARTICLE-IMPORT.md documents the contract). The mock
  suite never caught it because its fake parse() returned a node.
- **Walker image fixes (live-verified: Guardian hero, Ars hero, Wired
  hero + avatar, NYT hero + caption now all import):** Wired's
  `P > SPAN > PICTURE > IMG` died at `case PICTURE: return ''` — the img
  inside was never reached; `<picture>` now resolves to ONE image (the
  `<img>` inside, else a `<source>` srcset). `data-src`/`data-lazy-src`/
  `data-original` go before a placeholder `src`; `srcset`/`data-srcset`
  fall back to the largest candidate. Junk paragraphs ("Advertisement",
  caption toggles, including link-wrapped `[SKIP ADVERTISEMENT](…)`) drop
  whole. Walker suite grew 46 → 53 assertions, all green.
- **Why imports could hang FOREVER (the "completely failing" report):**
  `evaluateJavaScript` has no internal timeout — a page suspended in the
  background never answers, the pipeline never returned, and
  `isFetchingArticle` stuck true, refusing every later import with
  "Already fetching an article…". The extraction now races the JS answer
  against a 15s claim-guarded continuation (WebKit's completion + a
  detached timeout, exactly one resume wins — a task-group race would
  drain the group and hang anyway). NotesListView also gains a
  legacy-tag-strip fallback before "saved the link".
- **BPC on EVERY import (default ON):** the heuristics no longer gate the
  bypass pass (a wall that kept its markers out of the HTML sails past
  them) — every import goes fetch → BPC, `bypassResultWins` picks the
  fuller text (+150-char margin or direct-stub). Toggle moved to
  Appearance → Web Import; the always-bypass domain list is GONE (user
  call: unnecessary). Heuristics stay as the log/diagnostic signal.
- **project.yml:** the duplicate `NSAppTransportSecurity` keys (one per
  feature since v1.6.1/1.8.0) let the web-import dict silently overwrite
  the BookDrop dict — merged into one dictionary carrying both
  `NSAllowsLocalNetworking` and `NSAllowsArbitraryLoads`.

---

**Phonon engine integration** (branch `batch-c-d-session`, 2026-11-10):
- **The engine**: Gradium's Phonon (31M-param English streaming TTS,
  Apache-2.0) via `onnx-community/phonon-31m-en-ONNX` — the app's 4th neural
  engine and the smallest (~192 MB vs Kokoro's 341 MB): one fp32 flow
  transformer (causal, KV-cached, 8 unrolled AR frames per call) + a
  STATELESS Mimi codec decoder, Unigram tokenizer with byte fallback, and
  precomputed voice embeddings (no audio encoder — no cloning, no G2P).
- **The hub docs lie.** The README documents an older export (`flow_lm.onnx`
  names, a stateful per-frame decoder, `text_ids`/`voice_latents`/`latent`
  input names) and the transformers.js PR #1811 driver targets that OLD
  export — PR closed, unmerged; main has no Phonon support. The current
  tree exports `model.onnx` + external data with different input names
  (`input_ids`, `audio_prompt_latents`, `attention_mask`, `position_ids`,
  per-layer `past_key_values.{0..5}.{key,value}`, noise `[1,8,32]`) and the
  contract was therefore pinned **empirically** by running the actual fp32
  graphs with Python ORT 1.24.2 (the exact version the app vendors) before
  any Swift: `Docs/PHONON-PORT.md` carries the full recipe. Load-bearing
  discoveries the docs would never have given: attention_mask must be
  `past_kv + P + 7` long (each unrolled frame slices it); the BOS latent is
  prepended IN-GRAPH so `input_ids` is text-only; `audio_latents` out is
  CUMULATIVE (denormalized — the decoder takes it directly) while
  `present.audio_latents` is the normalized history fed straight back; the
  voice `.bin` is [1,512,125] and needs a TRANSPOSE (a reshape silently
  mangles the conditioning — the first EOS run went catatonic at −5 until
  this was fixed); the decoder's rotary ceiling limits one decode call to
  ~500 latents (the engine windows at 400); the KV feedback keeps the
  latent K/Vs and drops the re-run prompt block.
- **Validation**: with the pinned recipe the reference sentence reaches EOS
  (logit > 4.0), decodes 24 kHz PCM, RTF ≈ 0.27 CPU on the Linux box.
  `Tests/PhononSpike` (new CI job, informative like the others) re-runs the
  SAME recipe in Swift against the vendored SPM binary — the com.microsoft
  contrib ops (GroupQueryAttention, RotaryEmbedding, QuickGelu) are the
  load-bearing question that only that binary answers.
- **Tokenizer**: `SpeechLogic.PhononTokenizer` — the hub's 191-step
  normalizer chain is GENERATED data (`PhononNormalizerTable.swift`, via
  `Scripts/gen-phonon-normalizer.py`; Rust `\uXXXX` escapes translated to
  ICU `\x{...}`), then Metaspace + a byte-lattice Unigram Viterbi (byte
  fallback only where no piece matches — HF's lattice rule). 14/14 fixtures
  verified against the reference `tokenizers` implementation (fixture =
  the hub tokenizer.json, expected ids generated from it). The audio
  control tokens (<|audio_bos|> 4/5/6) are excluded from matching so user
  text can never inject them.
- **App wiring**: `PhononEngine` (StreamingTTSPlaybackCore shape, per-sentence
  fresh KV state, voice cache single-slot); `EngineKind.phonon` (picker
  order: system, kokoro, phonon, supertonic — labeled compact English, no
  quality claim); ModelManager Phonon set (26 curated voice bins: default +
  12 en-us + 13 en-gb from voices.jsonl); settings/storage/voice-picker
  surfaces; `phonon-fp32` Benchmark tier for the device RTF round. Single-
  slot memory rule applies (sessions release on engine switch + 5-min idle
  unload). fp32-only v1: q4 needs MatMulNBits proven on the vendored ORT;
  fp16 stays banned (every engine's fp16 sibling has NaN'd on ORT CPU).
  CoreML EP banned (a 6-layer KV-cache transformer is exactly the graph
  class whose EP parity Kokoro proved broken — round-3 stands).
- **Known limitation, documented in the settings footer**: the speed slider
  does nothing for Phonon (the flow export baked its duration conditioning
  into a constant — no speed input). Currency (`€5.50` reads in dollars)
  and emails (`@` skipped) inherit the hub's documented text-prep gaps.
  Device round: by-ear quality + RTF vs Kokoro, benchmark tier ready when
  there is time.
- **CI outcome (9 rounds, 7ab6aba — logic tests + app archive + phonon
  spike all green; one EPUB-spike job lost to runner capacity, an infra
  flake unrelated to the changes):** the compile rounds caught what the
  prototype missed — `String(bytes:encoding:)` takes String.Encoding;
  `session.run(outputNames:)` is a Set; a bare `init()` on an NSObject
  subclass needs `override`; the engine's tensor plumbing had lived only
  in the spike; HF's Prepend skips EMPTY strings (whitespace-only text →
  `[]`, verified against the reference). Two REAL contract finds the spike
  proved on the vendored binary: the cumulative `audio_latents` row count
  follows the latent-history feedback (+8/call) while KV grows +7 (the
  prompt never lands there) — two counters the engine must not confuse;
  and EOS crossing is noise-dependent (same sentence: crossed at call 20/26
  with one seed, never crossed with another) → the engine runs the hub's
  frame budget ×1.5 and logs when even that truncates. Memory: the decoder
  costs ~2.7 MB RSS per latent (400-latent window = +1.1 GB — jetsam
  territory), so the window is 160 and real chunks decode in ONE call.
  Spike finals: load +178 MB, RTF 0.309 (macOS runner), rms 0.0397 —
  audible; the A14 numbers come from the device round.

---

**E-Ink appearance mode** (branch `batch-c-d-session`, 2026-11-10):
- **One new mode, app-wide effects.** Settings → Appearance → Theme gains
  "E-Ink" (4th segment beside System/Light/Dark): paper white, ink black,
  square edges, hairline borders — no glass/materials, no gradients, no
  color, no animation or transitions anywhere. The accent picker does not
  matter while the mode is on (ink is ink) and its hue returns the moment
  the mode is left.
- **Plumbing** (`AppTheme.swift`, new `Views/EInkSupport.swift`,
  `SpeechnotesApp.swift`): `AppearanceMode.eink` forces the light scheme;
  `isEInk` rides the environment (`\.isEInk`) for inline view swaps; the
  root applies `.transaction { animation = nil }` (every SwiftUI animation
  snaps) + `.grayscale(1.0)` (every hardcoded tint drains) +
  `.buttonBorderShape(.rectangle)`; `EInk.applyChrome(enabled:)` flattens
  the UIKit tab/nav bars to opaque paper with 1pt ink hairlines and calls
  `UIView.setAnimationsEnabled(false)` (push/pop, sheets, keyboard — the
  UIKit-level motion SwiftUI can't reach). Called at app init so relaunch
  into the mode doesn't flash stock chrome.
- **Notes section (the flagship)**: notebook chips go square (active =
  solid ink block, inactive = paper + hairline); the list renders flat
  full-width rows with hairline separators (`.einkListStyle()`); swipe
  tints go ink; pin/star lose orange/yellow for black; the slash menu,
  formatting bar and markdown preview (quotes, code blocks, tables) square
  off and print-style.
- **Shared one-liners** so the sweep didn't bury files in if/else:
  `.einkPaper { regular }` (square paper tile + hairline),
  `.einkInk { regular }` (solid ink block), `.einkCard(radius:style:)`
  (rounded card squares off), `.einkClip(cornerRadius:)` (square content
  clip). ~30 view files swept: mini-players and bubbles (material pills →
  paper slabs, ring trims → ink), playback rail (portrait + landscape),
  toast, books shelf, stats cards/heatmap/chart, reading goals, pomodoro
  (timer card, banner), storage gallery, onboarding, PDF reader chrome,
  web-article surfaces.
- **EPUB reader** gets its own `eink` page theme (reader.js THEMES:
  `#ffffff`/`#000000` — pure ink, full contrast, nothing softened) plus
  the sheet entry and the chrome/page color maps.
- **Honest limits**: system sheets/alerts/keyboard keep iOS's rounded
  chrome (light + grayscale only); the "generating" spinner still spins;
  PDF reader page surface untouched (PDFKit). All animations die at the
  root transaction — no view logic changed, so leaving the mode restores
  the stock look bit-for-bit.

---

**Web article formatting + native share sheet** (branch `batch-c-d-session`,
2026-11-10):
- **Root cause of the flat-paragraph imports** (`Docs/WEB-ARTICLE-IMPORT.md`):
  extraction consumed only Readability's `textContent` — structure was
  stripped before the note ever saw it. The renderer stack below (cmark-gfm
  `MarkdownPreviewView`, `MarkdownText.plainText` for TTS) was already
  complete; nothing fed it.
- **The walker** (`App/Resources/JS/html-to-markdown.js`): Readability's
  `parsed.content` DOM → the app's GFM subset, injected beside readability.js
  at document end. Headings shift down one (the note's first line IS the
  headline, which the walker also de-dupes), links resolve http(s)-only
  against the live page base, sigils in prose are escaped, data:/tracking
  images and JS/mailto links degrade to text. A walker bug costs formatting
  only — the Swift side keeps markdown solely when it plausibly covers the
  same text, else falls back to plain. 46-assertion mock-DOM suite
  (`Scripts/test-html-to-markdown.js`) runs in CI's logic-tests job.
- **Import paths** prefer `markdown ?? text` (URL shares, clipboard, drag &
  drop, scheme, local .html); the first article import opts
  `renderMarkdown` ON only when the user never touched the setting.
- **ShareExtension target** (`com.speechnotes.ios.Share`, project.yml +
  `ShareExtension/Sources/ShareViewController.swift`): the share sheet the
  native install never had. Pages (public.url) and text; hands off via
  `speechnotes://import?url=/text=` (no App Group — free-account SideStore
  provisioning stays intact); `NSExtensionContext.open` → responder-chain
  `openURL:` → honest fallback (copy + clipboard-importer instructions).
  LiveContainer ignores the embedded `.appex` and keeps its extension-free
  channels. Extension version fields derive from the app's build settings
  (`$(MARKETING_VERSION)`) so release bumps stay a two-file edit.

---

**Phase 3 baseline CAPTURED (first device numbers in repo history)** (branch `batch-c-d-session`, 2026-11-09/10):
- Six 5-minute sustained-synthesis sessions ran on the device (iPhone13,4,
  iOS 27.0, app 1.8.1/47, thermal `serious` throughout — no cooldown); raw
  CSV+JSON archived in `Docs/benchmarks/2026-11-09/`, results in
  `TTS_BASELINE.md` §8. Headlines: Kokoro fp32 sustained RTF 0.553 hot,
  drifting +30 % inside 5 min, 0.683 mean with the throttle signature after
  ~25 min of prior synthesis; **Supertonic High faster AND flat (0.527,
  0.49→0.53)**; compact int8 SLOWER than fp32 (0.812); 4 threads cost +14 %
  vs 6; Kokoro tokens 101–179 → Phase-2 buckets collapse to {128, 192};
  chars/audio-s measured 19.5 (Kokoro, vs the 15 assumed) / 12.7 (Supertonic).
- Harness defect found by the very first runs: the sampler timer and the
  stop flag both sat on the serial queue the synthesis loop occupied —
  resource columns absent from these exports, stop never fired mid-loop.
  Fixed (dedicated sampler queue + NSLock + thread-safe stop). Per the user's
  2026-11-10 decision: **no re-run** — the CPU %/footprint/memory-budget
  numbers stay open until the first Core ML build reports them in-app.

**Hybrid CPU+ANE plan, Phases 1–3** (branch `batch-c-d-session`, 2026-11-09):
- **Phase 1 postmortem** (`Docs/POSTMORTEM-KOKORO-ACCELERATION.md`): the git
  history contains NO literal Core ML attempt for Kokoro — the "Core ML failed"
  memory compresses the MLX/Metal engine (ran at RTF ≈ 0.5, died of jetsam:
  unbounded GPU-cache + buffer growth, 342 MB fp32 resident; removed v0.7.0)
  and the quantized-tier graveyard (uint8 corrupt via QLinearMatMul graph
  rewrite; fp16 NaN on ORT CPU, CI 34008548349; int8 92 MB clean and shipped).
  WhisperKit/CoreML STT worked. Failure classes (a)/(b)/(c) mapped; hypotheses
  H1–H4 carried forward with falsification vehicles.
- **Phase 2 placement** (`Docs/PHASE2-OP-INVENTORY-PLACEMENT.md`): both ONNX
  graphs parsed from the user's local model store (Kokoro fp32 byte-exact to
  the CI pin). Kokoro: 49 op types, 6× bi-LSTM(256) + 1 STFT + sampling glue
  stay CPU in every variant; the istftnet decoder holds 193 MB (60 %) of
  weights — the ANE prize; choice = try ORT CoreML EP first, manual decoder
  split as fallback. Supertonic ×4: pure ConvNeXt+attention, ZERO hostile ops
  → direct coremltools MLProgram fp16 conversion. Buckets {64…510} tokens,
  pre-warm + `SpecializationStrategy=FastPrediction`, int8/palettization only
  behind the uint8-forensics-style parity gate. **H1a ANSWERED twice**: ORT's
  Apple pod release settings pass `--use_coreml`, AND the downloaded
  `pod-archive-onnxruntime-c-1.24.2.zip` ios-arm64 binary contains the full
  `CoreMLExecutionProvider` (GetCapability/Compile, MLComputeUnits,
  ModelCacheDirectory, `setSpecializationStrategy:` selector) — the EP ships
  in the SPM binary the app already links. **RAM question answered**: no
  runtime API; `com.apple.developer.kernel.increased-memory-limit` exists but
  free-profile signing strips it (SideStore #1616) and under LiveContainer it
  must ride on the LC host; the controllable lever is dirty memory (fp16,
  single-slot, idle-unload, memory-warning shedding, MLX removal — catalog
  1.11), now measured via `os_proc_available_memory` + phys_footprint.
- **Phase 3 harness** (`Docs/PHASE3-BENCHMARK-HARNESS.md`, code in
  `App/Sources/Benchmark/` + `SpeechLogic/BenchmarkMath.swift` + benchmark
  seams on both engines): sustained-synthesis Benchmark Mode — fixed original
  corpus (sha256-stamped), per-chunk CSV (tokens/steps, gen/audio/RTF,
  footprint, available, CPU %, thermal) + session JSON (provenance, RTF
  temporal quartiles + throttle signature, CPU-seconds, battery start/end,
  thermal transitions), share-sheet export. Settings → Diagnostics →
  Benchmark mode; "run at next launch" replaces launch args on device;
  `-BenchmarkAutoStart` for CI. Engine knobs: tier (fp32/int8/super-high/
  super-balanced), duration, ORT thread override (new `benchmarkIntraOpThreads`
  seam; Supertonic's sessions previously had NO thread cap — ORT default —
  now overridable via a default-parametered vendored `loadTextToSpeech`).
  Silent audio loop holds background assertion for screen-off runs. Pure
  math + CSV in SpeechLogic with tests (BenchmarkMathTests). **The baseline
  device run on the current CPU build is the next action** — protocol in the
  doc; no Core ML work proceeds before its numbers exist.

---

**Web article import + Bypass Paywalls Clean** (branch `batch-c-d-session`, 2026-10-24):
- **Shared URLs are articles now, not tag soup.** `WebArticleService`
  (new): fetch with a Safari UA → Mozilla Readability 0.5.0 (vendored,
  Apache-2.0) on the fetched HTML inside a headless WKWebView → note with
  title/byline/source footer. JS app shells get a plain rendered pass.
- **Paywalls route through BPC.** `PaywallHeuristics` (SpeechLogic, new,
  9 unit tests in the CI `swift test` job) gates it: high-precision wall
  markers (soft-wall copy, `isAccessibleForFree:false` JSON-LD,
  news-corp `gateway-partial`, og:description-vs-stub truncation). On a
  hit — or an always-bypass domain, or a failed fetch — the page loads in
  a fresh ephemeral webview with the userscript form of Bypass Paywalls
  Clean by magnolia1234 vendored (`bpc.en.user.js` v4.4.7.4 + its
  `@require` companion `bpc_func.js`, MIT). Its one privileged API,
  `GM.xmlHttpRequest`, bridges to URLSession via
  `webkit.messageHandlers.bpcFetch`; everything else (cookie/localStorage
  surgery, archive fallbacks) runs in-page on the clone-at-extract DOM.
  Settle window counts bridge traffic, so BPC's post-load archive fetches
  finish before extraction.
- **Script refresh without a rebuild:** drop updated
  `bpc.en.user.js`/`bpc_func.js` into On My iPhone → Speechnotes →
  BypassPaywalls (Files-app visible) — they override the bundled pair.
  Settings → Web import carries the toggle, the always-bypass domain
  list, and the loaded script's version/origin.
- **Local .html files** import through the same Readability path (no
  fetch), DocumentBook's flattener as fallback. The note Files picker now
  offers every document format `canImport` accepts (docx/pptx/odt/rtf/
  html/mobi/azw3/… — the picker previously greyed them out even though
  Open-In delivered them).
- Import UX: "Fetching article…" toast for the multi-second pipeline;
  legacy regex stripper demoted to last-ditch fallback; bare-URL note
  still never lets a share vanish.
- Version 1.8.0/44. **Device test pending** (paywall sites + a couple of
  JS-shell pages); CI green required before any sideload.

---

**Audiobooks + session robustness** (branch `batch-c-d-session`, 2026-09-21):
- **No retry.** `generateWithRetry` is deleted from the streaming core. A chunk
  that throws is logged once (with its index out of the total), sounded with
  `BeepPlayer.playSkipTone()` and stepped over — for playback and WAV export
  alike. This is the R8 anti-pattern (AP7, "error handling worse to experience
  than the error") finally closed by removing the retry rather than tuning it.
- **`SpeechSanitizer`** (SpeechLogic, new): `clean()` strips what a reader
  cannot pronounce — C0/C1 controls, zero-width and bidi controls, variation
  selectors, private-use glyphs — and normalises whitespace. Two rules the CI
  loop forced: replace rather than delete (`exam\u{00AD}ple` must not become
  `example`), and U+2028/U+2029 plus a lone CR are line breaks, not spaces.
  Wired into `MarkdownText.plainText`, `XhtmlText.extract`,
  `PdfText.normalize`, every note/book speak path through the new `SpeechText`
  helper, `ImportService`, and the chapter cache write.
- **`AudiobookChapters`** (SpeechLogic, new): reads `chpl` inside `moov` and
  ID3v2.3/2.4 `CHAP` frames, bounded (an 8 MB head slice, never the whole
  file). `Book` gains `.audio`, `BookAudioReaderView` + `AudioBookPlayer` play
  it with no `SpeechPlayer` involvement, its own lock-screen surface, and
  chapter resume.
- Chunker hardening: a piece under 4 UTF-16 units with nothing to say is glued
  onto the piece before it. Nothing is dropped — the reconstruct invariant
  (chunks concatenate to the original) is what the read-along and resume index.
- **CI loop history worth recording:** six red runs, every failure a real
  defect rather than a typo — `Set<Unicode.Scalar>` array literals reject Int;
  a dangling helper call; a fixture that wrapped `chpl` raw instead of as a
  box; piece-dropping that broke reconstruct; U+2028 treated as a space; a
  lone CR joining two lines; `[weak self]` in a struct. Full writeup in
  `Docs/PLAN-AUDIOBOOKS.md`.
- **Device test pending.** CI green (logic tests + unsigned IPA + all four
  spikes); nothing merged to `sage-upgrades` and no release.

---

**Batch 5 — Accessibility sweep** (branch `fix/a11y-labels`, merged @ `4d83a3e`):
- MarkdownFormattingBar's 13 icon buttons labeled; MiniPlayerBar play/stop; PlayerControlsBar play/stop/read-along + rate slider label + value.
- No visual change; VoiceOver goes from "button" ×13 to named controls.
- CI: green (34293436652).

---

## Cycle summary

6 batches → all ≥8/10 critique, all CI green, zero escalations:

| Batch | Scope | Merge | CI run |
|---|---|---|---|
| 0 | TTS pipeline regressions (quit-bug, retry-storm, live-rate, load-latch, audio session init) | 4d7286e | 34242349583 ✅ |
| 1 | BooksStore race, zip-bomb bound, image-sniff brand, SystemEngine epoch | f9e56bd | 34248407439 ✅ |
| 2 | Sleep timer, lock-screen subtitle + cover | b3455b5 | 34289888739 ✅ |
| 3 | Joplin JEX export + 6 unit tests | 78ff6e3 | 34291148672 ✅ |
| 3b | Note share as MD/TXT/PDF | c1b8a7f | 34292710925 ✅ |
| 4 | EPUB mid-chapter CFI restore (M20) | cd0b6f8 | 34292066132 ✅ |
| 5 | A11y labels | 4d83a3e | 34293436652 ✅ |

## Deferred (documented for next cycle)
- True playback queue (replaces onNaturalFinish chain) — scope, not a stuck task.
- Per-chapter % on lock screen — content isn't seconds-addressable.
- In-book search, highlight model, translation — sequenced after CFI restore shipped.
- `AVSpeechSynthesisProvider` system-voice extension — high complexity, high value; needs its own phase.
- M22 ModelManager HEAD-size check; M25 Supertonic Helper force-unwraps.

## 2026-09-08 (late) — Batches delivered and merged

**Batch 0 — TTS pipeline regressions** (branch `fix/playback-pipeline-regressions`, merged to `sage-upgrades` @ `4d7286e`):
- Retry storm fixed: 3 retries + 0.5 s silence → 1 retry + skip. No more 30–90 s dead air per bad chunk.
- Player no longer traps on engine switch: new speak floods the old pacing gate.
- Live rate changes (M14): speed slider reaches the next chunk without restart.
- Load latch fixed (M16): transient load failures no longer brick the engine until relaunch.
- Audio session lazy init (kills OSStatus -50 spam on cold start).
- CI: green (34242349583).

**Batch 1 — Data-layer races** (branch `fix/books-store-race`, merged @ `f9e56bd`):
- M18 BooksStore last-writer-wins (monotonic seq + drop stale write).
- M23 ZipReader 100 MB safety cap.
- M24 Image sniffing distinguishes HEIC from MP4 by brand.
- M15 SystemEngine epoch guard.
- CI: green (34248407439).

**Batch 2 — Sleep timer + lock screen** (branch `feat/playback-queue-sleep-lock`, merged @ `b3455b5`):
- Sleep timer (5/15/30/60 min + "end of chapter" for books). End-of-chapter swallows the natural finish and keeps the bookmark so resume lands past the end.
- Lock-screen subtitle ("Ch N — Title") + cover art ride out via `SpeechPlayer.NowPlayingPayload`, so the between-chapter "Loading…" state doesn't blank the metadata.
- Critique: 9/10 (no per-chapter % on lock screen — deferred; content isn't seconds-addressable).
- CI: green (34289888739).

**Batch 3 — Joplin JEX export** (branch `feat/note-export-jex`, merged @ `78ff6e3`):
- `SpeechLogic.JexExport` — pure-Swift ustar writer; `<noteId>.md` entries with metadata footer (`type_: 1`), `<notebookId>.md` with `type_: 2`, `<resourceId>.md` + `resources/<id>.<ext>` for images (`type_: 4`).
- Independent reimplementation per Joplin format docs — no AGPL code.
- 6 unit tests in `JexExportTests` (tar framing, entry names, type_-last invariant, orphan-note drop, resource round-trip, UTC ISO).
- Settings → Backup → "Export notes to Joplin (.jex)".
- CI: green (34291148672).

**Batch 3b — Note share formats** (branch `feat/note-share-formats`, merged @ `c1b8a7f`):
- Editor overflow menu: Share as Markdown (raw source), Share as plain text (`MarkdownText.plainText`), Share as PDF (UIMarkupTextPrintFormatter + UIPrintPageRenderer).
- Reuses the share sheet that WAV export already presents.
- CI: green (34292710925).

**Batch 4 — EPUB mid-chapter restore** (branch `feat/epub-cfi-restore`, merged @ `cd0b6f8`):
- epub.js reader now publishes the CFI on every relocation and accepts `?cfi=` at shell-load (preferred over the chapter index when present).
- `BookPosition.cfi: String?` persists the CFI; legacy manifests decode cleanly.
- Reopening a book mid-chapter now restores the exact spot, including across font-size changes and rotations (M20 / 4.7 prerequisite).
- CI: green (34292066132).

**Batch 5 — Accessibility sweep** (branch `fix/a11y-labels`, CI running):
- MarkdownFormattingBar's icon-only buttons labeled (bold/italic/strike, H1/H2, lists, quote, code, rule, link, image) — VoiceOver no longer reads "button" 13 times.
- MiniPlayerBar play/stop labeled; PlayerControlsBar play/stop/read-along + slider labeled.
- No visual change.

---

## Escalated items

None. (Batch 2's skip of a true playback queue is a scope decision, not a
stuck task — deferred to a later round once CFI work lands, at which point a
proper queue becomes both needed and testable.)

## References
- `FEATURE_BACKLOG.md` — full prioritized list from the 8 reference repos.
- `INTEGRATION_PLAN.md` — phase plan, dependency graph, license fence.
- `UPGRADE_AUDIT.md` — codebase map + open findings.

## [2026-09-10 ~11:20Z] Batch A — Phase 0 deliverables + instrumentation
- Pushed: `070d38f` (docs commit pending: TTS_REGRESSION_AUDIT.md, this log, CRITIC_REVIEWS.md)
- CI: logic-tests ✅ 52s · build-ipa ✅ 6m57s — run 34468296292, all 6 jobs green (third consecutive sub-7-min build; the 45-min premise is retired, see TTS_BASELINE §7)
- Critic Round 2: Score 8/10 (approved). Round 1: 6/10.
- Issues found: Round 1 B1–B6 (stall watchdog false positives, timer leak, gap misclassification, metrics on critical path, commit-message overclaim); Round 2 N1–N6 — including two defects introduced by Round 1 itself (stall-tick reset gating, clearance-gate volume)
- Issues fixed: all of B1–B4, N1–N6. B5 recorded in CRITIC_REVIEWS.md (immutable commit message). B6 accepted as designed.
- Next action: commit the three docs, then Batch B (resume resurrection — prime-after-read in both branches, debounce→throttle, resumeIfBookmarkPending markdown fix, readAlongPiecesTask assignment + generation bump in the fast path)
- TTS baseline impact: **slower by~10⁻⁵ of measured work** (the one exception to the no-regression-by-removal rule, accounted line-by-line in TTS_BASELINE §6, with the thinning that keeps a 1300-chunk chapter at ~64 log lines)
- O5 decision recorded: README stays at v1.5.0 — 1.5.1/31 is a diagnostic build number, and the release procedure (README refresh + tag + fast-forward) is reserved by constraint
- O7 deferred to Batch C: PlaybackMetrics testability needs SpeechLogic reachability or an app test target; rides with the chunker contract tests

## [2026-09-30] v1.7.2 — Reader appearance, Stats, BookDrop, office formats

Batches pushed to `sage-upgrades` per batch; every batch rode its own CI run
(several CI-fix rounds: `@MainActor` isolation on StatsCenter,
`XMLParser.parserError`, `SHA256.Digest`/static-member quirks — CI is the
compiler, there is no local Swift toolchain on the Linux box).

**Batch A — Reader appearance v2** (`76bc0d1`):
- Page flow: Scroll/Pages switch (epub.js flow is fixed at rendition
  creation → the shell webview rebuilds; position survives via
  lastKnownCFI, one relocation fresher than the manifest).
- Auto-scroll: rAF loop in reader.js, advances chapters at the bottom
  (dwell-guarded), speed slider, resumes across flow reloads.
- Typography: font family (book/serif/sans/mono), line height, paragraph
  + letter spacing, scrolled-only margins, respect-book-styles switch;
  one merged theme registered+selected per apply; true-black theme.
- Appearance rides the shell URL at creation and one
  `readerAppearance({...})` JSON command afterwards (`ReaderAppearance`
  owns both encodings).

**Batch B — Stats tab** (`51393f2`):
- `StatsStore` (SpeechLogic): per-day/per-subject/per-kind folded JSON
  rows; windowed queries, streak, active days; UTC-calendar injection for
  deterministic tests.
- Recording: reading time from the epub/PDF readers (scenePhase-aware);
  listening time derived from the players' published state via
  `StatsCenter` (TTS slot for read-aloud books + notes, audio slot for
  audiobook files) — zero hooks inside the playback engines.
- `StatsTabView`: 4th tab — Fitness-style header cards, Swift Charts bars
  (Reading vs Listening split; week/month-pannable/year), an 18-week
  heatmap, per-subject cards with covers and progress. iOS-native theming
  throughout (deliberately not Anx's Material look).

**Batch C — BookDrop** (`f3f9d81` + fixes):
- LocalSend protocol v2.2 RECEIVER: register / prepare-upload / upload /
  cancel with per-file tokens, sha256 verification, one session at a
  time, 5-min timeouts. Receive-only — no multicast entitlement needed
  (senders find us via /24 unicast scan hitting /register).
- `LocalSendHTTPServer` on NWListener, port fallback 53317-53327, bodies
  spill to disk past 8 MB; probe-and-heal on every foreground (Readest's
  zombie-listener lesson: 500 ms loopback connect, stop FIRST then start).
- Routing: books → Books importer, .jex → JEX importer; toasts + history.
  BooksStore promoted to app-level env object so BookDrop imports appear
  live on the shelf. Settings → Integrations → BookDrop.
- `Docs/BOOKDROP.md` = porting brief for the Linux/Android receivers.

**Batches D/E/F — office formats, normalize-to-EPUB** (`4e6bf40`,
`cb5f38a`, `7af0092`):
- DOCX, ODT, PPTX, ODP, legacy DOC all normalize to a real EPUB at import
  (`ZipWriter` + `DocumentEpubConverter`): the existing reader, TOC and
  TTS spine pipeline consume them unchanged. Chapters = heading 1-2
  sections (documents) or slides (presentations); headless text chunks
  at 150 paragraphs.
- Legacy .doc: self-contained CFB reader + FIB/piece-table text
  extraction, best-effort by design — exotic docs fail loudly with a
  convert-to-docx message.
- Note-import twin: office files extract to plain-text notes too.
- Tests: fixtures BUILT in-test (ZipWriter for docx/odt/pptx; a
  structurally-real hand-built CFB for .doc) and validated by parsing the
  emitted EPUB back through the app's own EpubParser.

**Explicitly not done (this round):** per-book appearance overrides
(global-only for now), BookDrop PIN gate (auto-accept toggle exists),
speaker-notes extraction from PPTX, BookDrop for Linux/Android (ported
separately per Docs/BOOKDROP.md).

**Version:** 1.7.2 / 39 (project.yml 4-field bump + NSLocalNetworkUsageDescription).

## [2026-10-08] Notes-surface bug batch — orientation, rail round trip, play glyph, emoji

Commit `289cb6b` on `batch-c-d-session` (CI run 37766970471). Four device
reports on NOTES (books untouched), each root-caused from source:

1. **Orientation freeze/slow + minimize→maximize padding distortion — ONE
   cause.** The editor held `editorContent` at two different tree POSITIONS
   (HStack child in landscape, VStack child in portrait); positional
   structural identity meant every rotation REMOUNTED the editor/preview:
   full synchronous re-parse of a long rich note (the freeze) plus every
   @State geometry reset mid-transition. The landscape HStack also made the
   rail's column a width NEGOTIATION between flexible children (preview's
   scrollable tables/code compete); a bad claim survived in @State,
   GeometryReader centered the over-wide result ("screen moved right, rail
   off the edge"), and it persisted across rotation into portrait until the
   editor unmounted — why going back to the list "reverts everything".
   Books were clean because webview/PDFKit take the width offered.
   Fix: content at ONE position; portrait bar via `safeAreaInset(.bottom)`;
   rail an overlay SIBLING; content pads its trailing edge by the SAME
   `hostColumnWidth` the rail pins (promise, not negotiation).

2. **Landscape play/pause glyph stops changing.** Rail inputs were host-
   evaluated snapshots; taps that only moved player state never re-ran the
   host body, so the glyph froze while audio worked. `PlaybackRail.observesPlayer`
   (editor sets it) gives the rail its own `@EnvironmentObject SpeechPlayer`
   — live glyph/progress/session/voice chip, paused shows play.fill like
   the portrait bar. Book readers keep host-passed values (per-chapter
   narrowing).

3. **Emoji missing (keycaps 1️⃣, circles 🔴, more).** Note-creation paths
   stored `SpeechSanitizer.clean` output as the NOTE BODY — and clean strips
   emoji-presentation scalars (correct for speech, silent data loss for
   storage). New `SpeechSanitizer.displaySafe`: keeps emoji + FE0F + ZWJ +
   combining keycap, still strips control bytes/soft hyphens/bidi/PUA.
   All 3 storage paths switched (ImportService, NotesListView.addNote,
   JexImporter); speech paths unchanged (re-derived at play time). 4 new
   tests pin the speech-vs-storage split.

4. **ReadAlongView inset + preview table width** went stale on layout-only
   reflows (probe updated only via the update cycle; magic 500pt test).
   Read-along keeps clear air only (width > height, recomputed per body);
   host pads the column. Preview probe gains `.task(id: width)` so tables
   re-measure in the rail reflow's own transaction.

## [2026-10-08 PM] Preview edge-shift REGRESSION — table probe feedback loop

Commit `92eaebb` on `batch-c-d-session` (CI run 37787051212). Device report on
the `289cb6b` build: preview content shoved to the leading edge in BOTH
orientations, trailing padding gone, rotation no longer clears it. Editor
fine, preview only. v1.7.2 (`ee04b30`) was clean — divergence began with the
GFM tables.

**Root cause — the width probe fed its own overflow back into layout.** Since
the GFM tables landed, the container-width probe sat at the TOP of the content
VStack as a bare `Color.clear`. `Color.clear` adopts ANY proposal, including a
corrupt one: a table that laid out too wide pushed the VStack wider, the probe
measured the overflow, the column math built a table to MATCH it, and the
wider table pushed the VStack wider still — a self-consistent loop that
pinned the document to the leading edge. `289cb6b`'s `.task(id: width)`
amplifier re-committed the corrupt measurement even when the update cycle
didn't fire, making it terminal. v1.7.2 was immune BY TOPOLOGY: its probe rode
`.background()` of the table's own ScrollView — background children never
influence the size of the view they measure. Second enabler: the GFM wrapper
added the pan ScrollView only when the (corruptible) math said "overflows", so
a mis-sized table rendered bare and pushed the document; v1.7.2 always
wrapped its Grid in the pan ScrollView.

**Fix (GFM tables kept):** probe back on the table's pan-scroll frame,
background-only, no task amplifier; pan ScrollView UNCONDITIONAL (overflow
pans within the table's bounds, the document cannot be pushed). The
`overflows` flag stays in the cached layout as a diagnostic only.

**Why books/editor were never affected:** the editor renders raw text (no
table layout at all); the book readers host webview/PDFKit, which take the
width they are offered.

## v1.7.4 — the five reported issues, then what the device log added (2026-10-09)

Tagged `v1.7.4` (43). CI run 37854780413 all green; both device rounds
passed. Commits 6bf785f → d8b0ee0 on `batch-c-d-session`.

**Round 1 — the five reported issues.**
(1) mobi/Kindle outlines + covers had three layers: every store `.azw/.azw3`
is Huff/CDIC ('DH') compressed and the reader REJECTED them at import, so
those books never imported at all — `HuffCdicReader.swift` (KindleUnpack
port, validated against a real 7.6 MB LWW title, 437 records / 6052-entry
dictionary with recursive entries); KF8 chapters now cut at the book's XHTML
FLOW boundaries (the old h1/h2 rule made 430 junk chapters out of a
reference title with 165 h1s + 265 h2s — flow-split gives its own 25); and
the cover is the EXTH 201-declared record (the first image was a 243×65
publisher logo; the real 517×372 cover sat 97 records later).
(2) Opus fidelity: RFC 7845 output gain applied (libopus doesn't), the
5.1→stereo downmix peak-attenuated instead of hard-clamped (the clamp was
the audible fuzz), and `AVAudioUnitTimePitch` BYPASSED at rate 1.0 — a
phase vocoder smears every buffer even at unity, which was the "something
is lost" report. Non-unity rates and config-change repairs still route
through it.
(3) System-voice pauses: the 1.7.3-era fix bounded chunk-EDGE pauses; the
new report was Apple's same unbounded pause INSIDE chunks. Mid-chunk blank
lines collapse to one comma; same-mark punctuation runs compact (`...`→`.`),
`?!` passes. Read-along unaffected.
(4) Supertonic Balanced: 6 of 8 flow steps, ~3/4 of High's time, most of
its quality — the intermediate the user asked for.
(5) Voice picks persist: a picker tap auditioned the voice AND queued a
restore, so the pick snapped back when the sample ended. Taps now COMMIT
(audition(commit: true)); the waveform button stays listen-only.

**Round 2 — the device log's additions.**
(1) The 1.7 GB full-cast Opus book died at load with `NSPOSIXErrorDomain
Code=12`: the reader held the whole file plus copies. Lazy streams landed:
`OggReader.readLazy(url:)` maps the file and keeps granules + byte ranges
(~80 MB for 2.07 M packets); `OpusPacketStream.payload(of:)` reads slices on
demand; the decoder has ONE payload access path; page-spanning packets
stitch-materialize (bounded by Opus's 127 KB packet cap). readLazy == read
pinned by tests on the real fixtures.
(2) ONE Kokoro engine row; the fp32/uint8 tier is the "Kokoro quality"
dial (stored `kokoroTier`, applied via `rebuildKokoroTier()`). Every stored
spelling carries over (kokoroOnnx/kokoroSmall/kitten/soprano). The
Supertonic section's double title is unified.
(3) Full-cast ambience: surrounds −6→−3 dB (ITU Lo/Ro upper bound), LFE
−12→−6 dB — beds clearly audible behind the narration, peak-attenuation
still guarding the louder sum.
(4) `Documents/Data/Application/...` in device paths is LiveContainer's
guest layout under the host's Documents — NOT an app bug.
(5) Model sources verified live on Hugging Face: fp32 325.5 MB + uint8
177.5 MB, both 200 OK (`onnx-community/Kokoro-82M-v1.0-ONNX`).

**The uint8 gate, re-scoped.** The CI spike asserted uint8-vs-fp32
correlation > 0.9 — a property the B4 forensics PROVED impossible for the
shipped graph (oracle bit-deterministic; onnx.quantize rewrote two MatMuls).
A permanently-red gate hides the next real regression, so
`testQuantizedRenderMatchesFP32` became `testQuantizedRenderEvidence`:
renders both tiers, prints the full metric set, asserts the shipping bar
(finite, audible, length-stable), keeps both WAVs. Original thresholds stay
in history at 60b75f6 for a future re-quantization.

**CI traps this batch (6 rounds):** a `maxcode` local shadowed the `maxcode`
ladder array; a `return` merged onto the next line; `Data(records)` wrapped
a `[Data]` (must concatenate); `OpusLib.gain` needed to be a stored
property; the Kokoro quality Section had to leave the `body` Form (type-check
timeout + `$binding` scope); the MP4 timescale-normalize map fed an
optional payload to the eager Packet init.

## 2026-10-24 — Pomodoro timer (1.8.0/45) + web-import diagnosis handoff

**Pomodoro (commits 8cc4e4c, 49c8cce, d7bd9c7 — CI GREEN, run 40125347834).**
A Stats-tab subsection directly under Goals: idle state mirrors the goals
empty card; running it shows a phase ring + countdown + Pause/Skip/Claim/
Stop. Config subpage (sheet) with three modes: **Structured** (time limit
or finish time, N evenly-spread breaks, absolute window — skips never move
the finish), **Flowmodoro** (5 min focus banks 1 min break, claimable at
3 min, pot resets on claim), **classic Pomodoro** (per-block/per-break
minute tuning — the only mode with it). Mandatory 2–5 min prep opens every
mode. Engine (`SpeechLogic/PomodoroEngine.swift`) is pure wall-clock math:
the Codable session reconciles kills/suspension from `Date()` alone
(19 engine tests). App side: `PomodoroStore` (JSON state, day-folded focus
log, one pending phase notification) and the **gentle top-of-app banner**
(user ask: "not a punch in my face") — thin material card, tap-to-dismiss,
fires on last minute / block done / break's over / session complete /
flow-claim; `.pomodoroBanner()` at the app root also owns the 1 s tick.
Version stayed **1.8.0, build 45 only** — the user groups features into
releases; MARKETING_VERSION is theirs to bump.

**Web-article import — user report: "shared a site, it never worked" (open).**
Pipeline traced end-to-end (share sheet → `onOpenURL` in NotesListView →
`importWebsite` → `ImportService.websiteText` → `WebArticleService`:
direct fetch+Readability → BPC bypass pass → rendered fallback →
legacy tag-strip → bare-URL note). Every stage logs with a "WebArticle:"
prefix. Ranked suspects: (1) readability.js missing from the built bundle
— would nil every pass and always fall back to the bare-link note;
(2) `onOpenURL` never firing (no "Fetching article…" toast at all);
(3) per-site failures only (403s, JS shells). Diagnosis needs the device:
Settings → Logs, filter "WebArticle", plus which symptom the user sees
(no toast / bare-link note / toast then nothing). Unresolved — next
session picks it up from `memory/web-article-import-diagnosis.md`.

**Device-feedback batch (2026-10-25 — five reports, one pass).**
1. **Pomodoro card** (PomodoroViews): running state rebuilt as a
   full-width ROUNDED-RECTANGLE progress card (fill grows with the phase,
   countdown + phase pill centered inside) — the circular ring read
   "round" and off-center; the rectangle centers itself by construction.
   No renames, version untouched.
2. **Stale-UI trio**: delete/favourite didn't refresh the notes list (the
   memoized sections key on `notes.version`, and `softDelete`,
   `setFavorite`, `recover`, `move`, `clearNotebook` never bumped it —
   pin did, which is why pin alone worked); the Kokoro High/Compact
   checkmark never moved (picker read a non-publishing UserDefaults
   computed prop — now `@AppStorage("kokoroTier")`); plus a real
   swapped-args bug in the v1.7.4 Kokoro migration (`set("kokoroTier",
   forKey: "compact")` — migrated compact users opened on High).
3. **Books minimise**: `BookPlayerBar` (EPUB + PDF portrait) and the
   audiobook portrait transport collapse to a slim pill via one shared
   `bookBarMinimized` AppStorage — the editor bar's chevron pattern.
4. **JEX root cause found — Joplin's own layout, verified against its
   source (`BaseItem.serialize`/`unserialize`, node-tar)**: (a) our props
   block ended with a trailing newline; Joplin scans lines from the END
   and stops at the first blank line, so it parsed ZERO props →
   "Missing required property: type_" → the WHOLE import aborts;
   (b) the title must ride the FIRST BODY LINE (`title\n\nbody\n\nprops`)
   — a metadata `title:` prop is ignored/overwritten and a note without
   the title line loses its first two body lines; (c) node-tar matches
   the exact magic+version bytes `ustar\0` + `00`, ours wrote version
   zeros. Exporter now writes the canonical layout; importer parses it
   (old app archives still import); new test simulates Joplin's
   unserializer strictly over every entry.
5. **BookDrop phone side verified against the Linux twin** (wire
   compatible both directions — report in memory). One real bug fixed:
   two same-named files in one session overwrote each other and the
   survivor was routed twice (Linux fixed this with per-fileId names);
   iOS now tracks landed names per fileId with readable -2 suffixes, and
   cancel is restricted to the session's own sender IP.
Version stays **1.8.0/45** per the release policy; device retest of the
JEX import in real Joplin is the open check.

**Books minimised transport, round 2 (2026-10-25 device feedback).**
User: "the bar showing controls for next and previous chapter as well the
chapter number and pages persist above the minimised bar... i want this gone
when i minimise... maybe just the next and previous controls can be folded
into the minimised bar - allow it to have opacity like the one in notes...
and use the extra gained space to display more of the book... basically make
it exactly the same as in notes maybe with just the addition of next and
previous control in minimised bar". Root cause of round 1's miss: the
readers stack the chapter/page bar ABOVE the playback bar, so collapsing
only the playback bar left the navigation bar standing. Now: a NEW shared
`MinimizedBookTransport` pill (the Notes shape — ultraThinMaterial rounded
rect, floating over the content) carries play/pause, PREV/NEXT chapter,
the percentage and the expand chevron; the EPUB/PDF/audiobook chapter or
page bars are GONE while minimised (a chapterless PDF keeps its page bar —
it has no playback bar, hence no minimise button), and the freed space goes
back to the reading surface. One `bookBarMinimized` key for all three
readers. Handover: `Docs/HANDOVER-BOOKS-MINIMIZED-TRANSPORT.md`.
Joplin import confirmed working by the user on device; the rest of the
2026-10-25 batch (pomodoro rectangle, stale-UI trio, BookDrop fixes) also
reported good. Version stays 1.8.0/45.

**Maths + books chapter-nav, finished (2026-10-26).** Two handovers
landed on this branch with code written but unverified — one for the
books chapter navigation + resume/start discordance, one for the notes
maths rendering + TTS word forms. This round verified both, fixed what
the handovers left open, and got CI green.

*Maths (the one red test):* `speakList` joined node outputs with NO
separator, so the big operator's separate limit nodes welded together —
"i" + "=" + "1" came out as "iequals1" instead of "i equals 1". Every
node boundary now gets a separator and the whitespace pass collapses the
runs it leaves. That fixes the whole class of bug (any node boundary),
not just this operator.

*Maths (the open items):* (a) the insert affordance — there was no way
to insert maths without typing "$" by hand, so the formatting bar gets a
formula button and the slash menu gets `/math` and `/mathblock`; both
insert the DELIMITED form and leave the body selected to type over.
(b) the export form — a shared PDF or text file is a document the
recipient READS, so it now carries the glyphs ("E = mc²"), not the
engine's words ("E equals mc to the power of 2"). The speech path is
untouched: the engine still hears words.

*Books (the EPUB resume fix the handover called likeliest to fail):* the
mid-chapter position write was a DEBOUNCE, not a throttle — every
relocation cancelled the pending write and started a new one. `relocated`
fires on every scroll tick, so a reader who kept scrolling never reached
the write at all: the exact spot was lost precisely when the reader was
moving through the book. It is now a throttle with a trailing write, and
the position is also flushed on `scenePhase == .background` (onDisappear
does not fire when the app is backgrounded — that is the exit the reader
makes when they put the phone down).

*Verification:* CI on `batch-c-d-session` — the app archive builds (so
the books/EPUB/PDF code compiles for the first time), and the
SpeechLogic suite runs. The earlier red run was exactly one failure, the
maths test above. Version stays **1.8.0/45** per the release policy; the
device round on the user's own book (the compiled OBGYN notes PDF) is
still the open check.

**Two device bugs + the maths/books round closed (2026-10-26, `49a34ea`).**
After the maths + books handovers were integrated and CI went green
(488 SpeechLogic tests, 0 failures; the app archive builds), the user
reported two more bugs.

1. **Landscape play/pause glyph never changed.** The glyph was derived
   from `sessionActive && progress != nil` — and progress is nil until
   the engine's FIRST chunk reports in (and is cleared again whenever
   the engine reports 0). So the button could read "play" while the
   audio was already running; the clicks registered, the glyph did not
   move. The glyph is now a function of the player's SPEAKING state
   alone, which is the portrait PlayerControlsBar's rule. The rail takes
   the speaking state as its own input, because `sessionActive` counts
   paused and generating as live and those must show "play", not
   "pause".
2. **Goals never reached 100%.** The PDF progress was
   `(pageIndex + fraction) / pageCount`, and the fraction is always 0
   for a PDF (the reader is on a page, not inside one) — so the formula
   could not reach 1.0: the last page of a 100-page book read as 99%,
   which is the user's "97/96/98%" report. The page the reader is ON
   counts now. The EPUB side had the same shape (epub.js reports the
   within-chapter fraction as 0 for a chapter shorter than one
   viewport, so the last chapter read as unfinished). StatsTabView now
   uses the same `GoalMath.fraction` the goals use, so the two views
   cannot show different numbers for one book.

**Open, handed over:** a "keep screen on" setting (the user asked for it
as the app went to sleep). Nothing exists today — there is no
`isIdleTimerDisabled` anywhere in the app. The next agent's brief, with
the decisions to make and the traps (restore on disappear, one decision
for all reading surfaces), is in
`Docs/HANDOVER-SCREEN-ON-AND-FINAL.md`. Version stays 1.8.0/45.

**Books TTS: play starts at the viewed page, and the Contents jump moves the
speech in read-along (2026-10-26, `583acdb`).** The user's round decoded:
(a) in reader mode (= the read-along surface) TOC taps only moved the hidden
viewer, so nothing happened — they now move the SPEECH to the chosen chapter
(`BookPlaybackController.jumpToChapter`, superseding in place so the
read-along text follows and auto-advance stays armed), for PDF and EPUB;
(b) a fresh play starts where the reader IS — the PDF page mapped through
the chapter's page-offset sidecar, the EPUB webview's scroll fraction —
while a meaningful stored bookmark still wins ("page 1 is not really a
bookmark": a start-of-chapter position counts as no position). Bookmark
stop/start semantics untouched per the user. Full mechanics, decisions and
device checklist in `Docs/HANDOVER-BOOKS-TTS-POSITION-AND-READALONG-TOC.md`.
CI dispatched manually for `583acdb` (run 40395811218); device round pending.

**v1.8.0 released (2026-10-27, build 46 — the user's go).** The whole release
grouping shipped: books readers transparency + wide-table panning, TTS
play-from-page + landing chapter jumps, the shared minimised pill, maths
rendering + spoken words, Pomodoro on Stats (claim gate at 3 banked break
minutes), Keep Screen On, BookDrop everywhere (hotspot scan, port-stability
state machine, launch-OFF, 401 recovery), web article import + BPC, JEX
exports real-Joplin-clean + Joplin E2E crypto, mobi/OCR/m4b from the 1.7.x
line. Onboarding refreshed at release time: still five pages, the
"Start with a note" page folded into welcome, a Pomodoro & Stats page added.
The juice bubbles got their own per-frame clock (the card's 1 Hz tick was
stepping them — the "not smooth" report), four slightly larger streams with
sway, and the paused freeze preserved via the schedule's `paused:`.
README brought to v1.8.0 reality (Kokoro Compact ~92 MB dynamic int8, not
~177 MB; Soprano credit removed — no engine; epub.js credited; layout/CI
sections match the tree). Release notes: `Docs/RELEASE-V1.8.0.md`.

**Parity round 3 harvested; Phase 5 EP variant flagged in (2026-11-10,
`ed50e7a`).** Round 3 (run 42718617400, success) settled both placements:
Supertonic's whole 4-model chain through the ORT CoreML EP is numerically
PERFECT vs the CPU oracle (Pearson 1.0000, rel-RMS 0.0007, exact length,
CoreML active on all four sessions) → it ships via the EP, no conversion
pipeline; Kokoro's EP is BANNED under every unit configuration — the A2
localization proved the failure (Pearson 0.6305) is identical with the EP
pinned to CPUAndGPU (ANE excluded, provider-proof logged), so it is the
EP's CoreML conversion itself, not ANE-fp16; the GPU-pinned experiment is
dead and Kokoro stays CPU. Placement doc §4/§8 updated (`4ba0ff0`). H1b
answered: ORT 1.24.2's ObjC binding exposes
`appendCoreMLExecutionProviderWithOptionsV2` (MLComputeUnits dict) through
the umbrella header. The Supertonic CoreML-EP engine variant is now behind
runtime flags: `loadTextToSpeech(useCoreML:)` appends the EP with
MLComputeUnits=All (the exact runner-proven config; append failure
degrades to CPU), Benchmark Mode gains the
supertonic-high/balanced-coreml tiers for the EP-vs-CPU device
comparison, and normal playback gets a "Render with Core ML
(experimental)" settings toggle — default OFF, one build,
runtime-selectable. Acceptance stays gated on the device round: RTF ≤
CPU tiers or thermal/footprint win, no audible difference, thermal never
past serious. Also this session: the parallel web-import workstream's
finished feature committed separately (`05cc552`) — its new ShareExtension
target is GATED build-only (embed: false) because LiveContainer hosts no
app extensions; enabling embed needs the user's say-so + an LC smoke
test. CI: manual dispatch run 42723938178 on `ed50e7a` (compile oracle;
one round budgeted).

**Phase 5 follow-up: full CoreML EP option set + compiled-model cache
(2026-11-10, same day).** The EP variant's provider options now spell out
the full ANE-facing config from the Phase-2 placement plan: MLProgram
format (what the runner gate proved) + all compute units (NPU eligible) +
ModelCacheDirectory in the purgeable caches dir — only the first-ever run
per input shape pays ANE specialization compile. RequireStaticInputShapes
and FastPrediction deliberately left off (documented in Helper.swift why).
User decision this round: NO benchmark session now — they will judge the
EP variant's speed themselves by ear/feel; the Benchmark Mode EP tiers
remain the formal acceptance instrument for when there IS time. Kokoro
gets no EP code (round-3 parity ban stands).

**Phonon repeat spiral root-caused: the KV feedback sliced the cache
head-major-blind (2026-11-10, this session).** The device report: TTS and
the voice audition start fine for ~two words, then repeat/stutter/whisper
into "long sick syllables" — on every run. Diagnosis, with the whole
pinning workspace still alive in `/tmp/phonon` (models, venv, the Python
mirror `final.py`/`contract.py`, the hub's torch `PocketTTSGenerationMixin`
reference): (1) the Python pin's own rendered WAVs (`out-hello.wav` 17.9 s,
`out-fox.wav` 87 s for 3.5/10 s sentences) turned out to be an artifact of
`final.py` appending the CUMULATIVE `audio_latents` per call (`lat[-8:, :]`
slices the batch axis) — the engine appends correctly, so that red herring
was retired; (2) 46 x86 ORT runs (10-12 seeds × 3 feedback variants,
sentence AND 217-char chunk scale) render CLEAN with sharp EOS crossings —
the recipe is not the catastrophe; (3) a graph trace of `model.onnx` pinned
the true semantics: `position_ids` covers only the NEW `P+7` positions
(`Slice_29 = position_ids[0:P]`, frames at `[P+k]`), the fed-back KV keeps
its baked RoPE, and `Slice_8` takes `[-1:]` of `[bos | history]` — only the
LAST latent feeds the prompt block's input slot; (4) the app engine and the
spike BOTH sliced the KV feedback with a contiguous float prefix
(`values[0..<(keepHead * heads * dim)]`), but the cache is
`[1, heads, seq, dim]` — HEAD-major, rows strided: call 1 fed back
head-7-only garbage-aligned rows, call 2+ attended poisoned context. That
is the repeat spiral, device-only (the app's engine runs nowhere but the
device), and it explains CI's marginal EOS ("crossed 20/26 with one seed,
never with another" — misread as noise variance; healthy runs spike sharply
at 12-20 calls, which is what x86 shows). Fix: the feedback copy walks the
heads (`[0, past) ++ [past+P-1, presentTotal)` per head — the prompt block's
input-slot row is kept, so the KV now grows +8/call == the latent history
and `arange(past_kv, …)` lands on the exact reference timeline; the
"slot" variant, 0/12 degenerate in the sweep). Engine gains a finiteness
guard on the new latents (`PhononEngineError.corruptLatents` — the
numeric-divergence signal) and logs the per-chunk eos peak + call; the
spike mirrors the fixed recipe; `Docs/PHONON-PORT.md` documents the
semantics + the layout trap. Audition text through the fixed recipe on
x86: 8/8 seeds clean (10.2-12.2 s, self-sim ≤ 0.18, eos peak 6.1-9.3).
OPEN: the device round — one audition + one sentence; if still wrong,
Settings → Logs → filter "PhononEngine" (per-chunk eos peak line + the
NaN guard discriminate AR degeneration from runtime corruption).

**Phonon positions fixed to the reference recipe: the re-run prompt rows stop riding
the timeline (2026-11-11).** The device report after the KV-feedback fix: "much much
better, but after 4 words repetitions or artifacts or some whispering" — calls 2-3
(4 words ≈ 20-25 frames). This session verified the handover's #1 suspect against
GROUND TRUTH READ FROM THE REPO (not re-derived), then shipped the ~3-line fix.
Ground truth, three independent sources, all agreeing: `qnn/runner/phonon.cpp`
(Gradium's official QNN export driver — the closest thing to an export contract)
bakes the voice KV at 0..V-1 and the text prefill ONCE at V..V+T-1, then runs ONE
latent row per call at `pos = cache length` (`*buf_.pos = pos; …; pos++`) on the
contiguous absolute timeline 0,1,2,…, cache never trimmed; `transformer.rs:736-745`
pins RoPE offset = `current_end` (FlowLm; trim is Mimi-only); `synth.rs:1233/1319` +
`flow_lm.rs:296` prompt the text once per chunk, one `StepInput::Bos/Latent` row per
step. `ios/PhononTTS/Phonon.swift` is a thin FFI wrapper — no per-call driving to
override anything. Our graph forces a prompt-block re-run per call (HF export
format), but `position_ids` values may be NON-CONTIGUOUS (Slice_29 = [0:P], frames
at [P+k] — proven last session), so the shipped contiguous
`arange(past_kv, past_kv+P+7)` was the one structural error: the re-run voice+text
rode the moving timeline, freezing its attention distances at call-1 values (the
prompt appears adjacent forever instead of receding as the latent history grows)
and changing its K/V every call — exactly the after-~4-words degradation.
PHONON-PORT.md's "unavoidable deviation" claim was removed as WRONG AND BACKWARDS:
the reference's prompt never recedes — it is cached once at fixed positions forever.
Fix (engine + spike mirror): `position_ids = concat(arange(0, P-1),
arange(P + past_kv - 1, P + past_kv + 7))` — voice+text at their true absolute
positions on every call, input slot at `P+past_kv-1` (bos at V+T = P-1, then +1 per
latent), frames after; call 1 (past_kv = 0) degenerates to the old contiguous form.
x86 A/B (`/tmp/phonon-diag/position_recipe_ab.py`; same pre-generated noise tape fed
to BOTH arms, position_ids the only variable): call-1 latents BIT-IDENTICAL, diverge
from call 2 (onset matches the device symptom); layer-0 re-run prompt-row KV drift
across calls 9.2-10.0 (shipped) → **0.000e+00 bitwise (recipe)** — the fed-back
cache now replicates the reference's baked cache, which is a stronger parity result
than any metric separation, so the handover's optional Rust/torch parity gate was
skipped; zero-noise determinism probe confirms the same signature. Renders (8 seeds
× audition + 217-char chunk): 0/8 degenerate on both arms — no regression — and the
recipe is mildly better: EOS crosses earlier (18-19 vs 25-31 calls on the long
text) with sharper peaks and natural-band durations (mean 14.1 s vs 18.6 s), i.e.
EOS timing was drifting late under the corrupted geometry. CI: dispatched build.yml
run 42923777452 on `1b232f5` (batch-c-d-session). OPEN: device round — the ear is
the acceptance bar; if artifacts persist, Settings → Logs → filter "PhononEngine"
(per-chunk eos-peak + frame counts discriminate AR degeneration from runtime
corruption). Secondary threads parked from the handover: per-chunk
thermalState/memory logging for the late-session RTF degradation (2.7), untouched.
