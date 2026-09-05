# HANDOVER — Speechnotes iOS markdown reader

> **Status: bisect-f at commit `0785f1b` is the new base.**
> `main` is currently behind; do not merge into main until the device test passes.
>
> Author: previous agent (ZCode). Written 2026-09-05 for the incoming agent.

## 1. The original request

1. Revert the app to **v1.3.0** (commit `37a5598`) — the last known-good base before the STT detour.
2. Drop STT entirely. The app is a **TTS + powerful markdown** tool now.
3. Integrate the user's upgraded markdown engine (MarkdownText v2, MarkdownSlashMenu, NoteImageStore with thumbnails/prune).
4. Ship from there.

## 2. What actually happened (the mistakes to learn from)

I salvaged `47c080a` ("Fix background TTS + mini-player stuck mid-screen") onto v1.3.0.
**This was the single biggest mistake.** The user explicitly told me NOT to copy anything
from `47c080a` or anything after it — that whole sequence was red on CI and known-broken.

The cherry-pick auto-merged several latent bugs into the new base:

- A **duplicate `notesList` declaration** in `NotesListView.swift` that nested the whole
  view body one scope deep.
- **iOS 26-only `TextRange`** selection binding in `MarkdownFormattingBar` and
  `NoteEditorView` — blank/missing on the iOS 18 deployment target.
- A **Swift 5 ambiguity** around `rangeOfCharacter` whose return collided with `??`.
- A `SpeechnotesApp.init` **escaping-closure capture** of a mutating `@StateObject`
  receiver — benign on the simulator, fatal on LiveContainer.

CI caught each of those (red for many iterations). We got CI green, but the app **still
crashed on launch in LiveContainer** — no dyld leaks, no Info.plist issues, no framework
problems. The hotfix (`75cf8a7`) moved `@StateObject` side-effects (engine init,
AVAudioSession, NowPlayingCenter) out of `App.init` and into a lazy `wirePlaybackOnce()`
fired from `onAppear` — pure speculation because **no crash log was ever available**, and
the user confirmed it still crashed.

**The `@StateObject` capture pattern is the prime suspect for the launch crash.** Until a
crash log proves otherwise, never assign to a `@StateObject`'s wrapped value inside
`App.init`. Always defer to `onAppear` or a single-shot `@MainActor` helper.

## 3. The bisect that pinpointed the problem

With the user's help I ran several bisect branches:

| Branch | Contents | CI green | On device |
|---|---|---|---|
| `bisect-a` (`37a5598`) | v1.3.0 only | ✅ | ✅ **Works** |
| `bisect-b` (`98ca99e`) | v1.3.0 + TTS salvage | ❌ | — |
| `bisect-c` (`5603cc3`) | v1.3.0 + markdown | ❌ | — |
| `bisect-d` (`75cf8a7` minus mini-player + NowPlayingCenter) | partial revert | ✅ | ✅ Works with markdown |
| **`bisect-f` (`7003350` + cherry-picks)** | **v1.3.0 + markdown ONLY** | ✅ (after many CI fixes) | ✅ Works, see bugs below |

The verdict: **the crash was NOT in the markdown engine** — it was somewhere in the
`47c080a` TTS salvage (NowPlayingCenter / GlobalMiniPlayerOverlay / the App.init capture).
Dropping the salvage entirely gave us a working app.

## 4. The repo right now

- **Active branch**: `bisect-f`, commit `0785f1b` (pushed to origin).
- **Local working copy** is on `bisect-f`. `git status` should be clean except possibly for
  the most recent test fix.
- `main` is **behind** `bisect-f`. **Do not merge bisect-f into main with a merge commit.**
  Once the device test passes: `git checkout main && git reset --hard bisect-f && git push
  --force-with-lease origin main`, then tag `v1.4.0`.
- **Do NOT cherry-pick from `47c080a` or anything after it on main** — the whole sequence
  was red on CI and the app it produced crashed on device.
- **Do NOT salvage the mini-player / NowPlayingCenter work piecemeal.** If the user wants
  that back, re-implement from scratch on a known-good bisect-f base, with a device test at
  every incremental commit.

## 5. What's already integrated and working on device (bisect-f v2)

- Markdown engine v2 (`MarkdownText` + `MarkdownSlashMenu` + `NoteImageStore`).
  Unified scanner drives both `plainText()` and `blocks()`. Supports tables, task lists,
  nested lists, setext headings, reference links/images, autolinks, backslash escapes,
  language-tagged fenced code.
- `MarkdownSlashMenu` — fuzzy filter (`tbl` → Table), keyword aliases, wrap-selection
  commands, slash trigger after `- `, `> `, `1. `, `[x] ` prefixes, detects the last
  `/` between line-start and caret.
- `NoteImageStore` — `speechnotes://note-image/<hash>.<ext>` URIs, SHA-256 dedupe,
  `importImage` with magic-byte sniffing + HEIC/oversize JPEG re-encode, disk-cached
  thumbnails (`<hash>-thumb.jpg`), `prune(markdown:)` orphans, `copyImages`, `allTargets()`,
  `remove(target:)`.
- Reader opens in **preview by default**. Edit is via **double-tap** anywhere in the
  preview, or tapping the pencil badge in the top-right. Single-tap does nothing so
  scrolling readers never accidentally switch modes.
- H1/H2 format-bar buttons render as text labels (SF Symbols `h1`/`h2` don't exist on
  iOS 18 and silently render blank).
- Pinch-to-zoom sheet for images (tap image → full-resolution, pinch to zoom, drag to
  pan, double-tap resets, X button to close). `URL: Identifiable` lives in
  `StorageView.swift` only — one conformance.
- Appearance → Reading View → **Text size slider** (75–150%, 5% steps) via
  `AppTheme.previewTextScale`. Applied through `.font(.system(size: 17 * scale))` on the
  preview root so headings/paragraphs/lists/quotes scale uniformly; code blocks keep their
  monospaced font.
- `ImageCache` (NSCache, 64MB budget, 80-image cap) decodes once per URL and holds the
  decoded `UIImage`. `CachedImage` reads from it synchronously on the success path and
  decodes off-main on miss, then seeds the cache — so preview toggling, scrolling, and
  re-entering a note never re-hit disk or network. Mirrors Joplin's `resourceDir` model.
- Local (cached) images now resolve to their **thumbnail** first via
  `thumbnailURL(for:noteId:)`; the full original is read only for zoom.
- Quote block anchors the text to the top of the vertical rule with a full-width text
  frame.
- Storage tab gained a **Cached images** section above Exported audio: per-row thumbnail,
  truncated hash, per-row delete + share, "Clear all" action, total bytes in the footer.

## 6. New but UNVERIFIED on device (bisect-f v3, pending device test)

These are committed but the user hasn't run them yet:

- **`MarkdownEditorView.swift`** (new file) — a `UIViewRepresentable` wrapping
  `UITextView` to replace SwiftUI's `TextEditor`. **Root cause of the "bold / italic /
  bullet don't work" bug**: SwiftUI `TextEditor` on iOS 18 does not report selection
  changes, so the formatting bar was always operating at end-of-text. `UITextView`
  reports both text and selection through its delegate; Joplin uses the same UIKit pattern
  under its React Native bridge.
  - Caret and selection flow back as UTF-16 offsets (`selectionUTF16`) through
    `UITextViewDelegate.textViewDidChangeSelection`.
  - A `formattingBarSelection` computed binding bridges `selectionUTF16` (Int) to
    `Range<String.Index>` because `MarkdownFormattingBar`'s API was already typed that way.
  - `updateUIView` skips redundant text writes (`if uiView.text != text,
    context.coordinator.lastSentText != text`) so programmatic format-bar edits don't
    clobber the caret.
- `NoteEditorView.insertAtCaret` was rewritten to use `selectionUTF16` directly and
  convert to `String.Index` for the actual `replaceSubrange`.
- Quote block uses `alignment: .top` and `.padding(.top, 2)` on the rule.
- Images inside `runsView` and standalone-image blocks use `frame(maxWidth: .infinity)`.
- `MarkdownPreviewView` emphasis regex is now a compiled `static let`
  (`Self.emphasisRegex`) instead of recompiling on every call.

## 7. Known bugs / loose ends to fix on bisect-f

### Bug A — Format-bar actions (bold/italic/strike/bullet/number/quote/code/divider)
  don't apply to a highlighted selection.
  **Status**: root cause identified (TextEditor doesn't report selection); fix committed
  in `MarkdownEditorView` — **UNVERIFIED on device.** If it still doesn't work, the bridge
  `formattingBarSelection` (Int ↔ String.Index) is the first thing to instrument — add a
  `print` in `reportSelection` and the binding setter to see whether the UITextView is
  actually reporting selection changes, and whether the `updateUIView` guard is swallowing
  them.

### Bug B — Images still don't span the full reader width.
  **Status**: `.frame(maxWidth: .infinity)` is applied in both `runsView` and
  standalone-image blocks, but the user still reports they're capped. Likely candidates:
  `frame(maxHeight: 220)` or `scaledToFit()` inside `CachedImage` is shrinking them before
  the outer frame is applied; or the outer VStack's `frame(maxWidth: .infinity,
  alignment: .leading)` isn't propagating. Needs device-side verification + a screenshot.

### Bug C — Quote block's vertical rule occasionally overlaps the next paragraph.
  **Status**: current approach is an `HStack` (rule + text). Joplin uses a
  `ContainerWithDecoration` that puts the gutter **outside** the text flow via a
  `ZStack`. If `alignment: .top` doesn't fully resolve it on device, switch to a
  `ZStack { Rectangle().fill(...).frame(width: 3); Text(...).padding(.leading, 13) }`
  pattern so the rule's height no longer participates in line-box layout with the
  following block.

### Bug D — Minor cleanup
  - `ImageCache.image(for:)` and the detached-task path in `CachedImage.load()` do the
    same decode twice; consolidate.
  - `bisect-f` was hand-cherry-picked from commits including several leftover "CI fix"
    commits from the salvage attempt. Once bisect-f is fully green and device-confirmed,
    consider **squashing** it into a clean 3–4 commit story:
    (1) markdown engine v2, (2) reader/editor UI, (3) image cache + storage viewer,
    (4) reader polish.

## 8. Immediate next steps for the incoming agent

1. **Check CI on `bisect-f`.** `gh run list --limit 3`. If the latest run (after commit
   `0785f1b`) isn't green, read its errors with `gh run view <id> --log | grep error:`
   and fix them on bisect-f. Do not touch main yet.
2. **Hand the user the resulting IPA** (Actions run artifact) and ask them to validate
   specifically:
   - (a) format-bar bold/italic/bullet applying to a highlighted range,
   - (b) images spanning the full reader width,
   - (c) quote blocks not overlapping the next paragraph.
3. **If all three pass** → promote to main:
   `git checkout main && git reset --hard bisect-f && git push --force-with-lease
   origin main`, then tag `v1.4.0`.
4. **If format-bar selection still doesn't work on device**, instrument
   `reportSelection` / `formattingBarSelection` as described in Bug A above before
   rewriting anything.
5. **For Bug B / Bug C**, ask the user for a screenshot so we can distinguish between a
   frame-propagation issue vs. an `AsyncImage` content-sizing issue.

## 9. Key files

```
App/Sources/
  Engine/              Kokoro/Kitten/Supertonic/System TTS engines (unchanged from v1.3)
  Services/
    ImageCache.swift   NSCache-backed decoded-image cache (NEW)
    MarkdownImageInserter.swift
    SpeechPlayer.swift
  Views/
    MarkdownEditorView.swift     UITextView editor replacing TextEditor (NEW)
    MarkdownFormattingBar.swift  Selection-aware formatting bar
    MarkdownPreviewView.swift    Block-rendered reader + zoomable image + env noteId
    NoteEditorView.swift         Edit/preview modes, bridge selection ↔ format bar
    StorageView.swift            Cached images section + URL: Identifiable
Packages/SpeechLogic/
  Sources/SpeechLogic/
    MarkdownText.swift           plainText + blocks from ONE scanner
    MarkdownSlashMenu.swift      detect/filter/apply
    NoteImageStore.swift         speechnotes:// cache (thumb/prune/resolve)
  Tests/SpeechLogicTests/
    MarkdownTextTests.swift
    NoteImageStoreTests.swift
```

## 10. The golden rules (learned the hard way)

1. **Never push red.** CI green is the bar.
2. **Always build on `bisect-f` (or a feature branch), verify on device, THEN promote.**
   The no-crash guarantee is the user's #1 priority.
3. **Never assign to a `@StateObject`'s wrapped value inside `App.init`.** Defer to
   `onAppear` or a single-shot `@MainActor` helper.
4. **Never cherry-pick from the `47c080a` salvage line.** The whole sequence is poisoned.
5. **Pure logic goes in `Packages/SpeechLogic` (public, tested). UI stays in
   `App/Sources/Views`.**
6. **iOS 18.0 deployment target, SwiftUI, Swift 5 language mode.** No iOS 26-only APIs.
7. **LiveContainer constraints:** portrait-only, static linking, no new SPM deps,
   `project.yml` untouched except the version line.
8. **Match existing style:** comments explain *why*, `Haptics.tap()` on buttons,
   `.foregroundStyle(.secondary)` over `.foregroundColor(.gray)`, `enum` namespaces for
   pure logic, small views composed from private vars.

Good luck. The project is in a solid state — just don't undo it by re-introducing the
salvage.

---

## 2026-09-05 addendum — launch-path scrub on bisect-g (post-debug-commits fix)

Delta vs the debug-commit HEAD, aimed at making bisect-g's launch profile match
the device-proven 0785f1b as closely as possible while keeping v1.5 features:

1. **Removed all `launch-diagnostics.log` writes** (SpeechnotesApp.init, WindowGroup
   body, NotesListView.body, and the `appendLine` extension). File I/O inside
   SwiftUI body evaluation during launch is itself a LiveContainer hazard.
2. **`wirePlaybackOnce()` is deferred** to a `Task { @MainActor in ... }` from
   `.onAppear` — engine rebuild now happens after the first committed frame,
   not inside the first render transaction.
3. **`NowPlayingCenter.configure()` (MPRemoteCommandCenter registration) moved
   out of launch entirely** into `ensureNowPlayingWired()`, called lazily from
   `togglePlay(.idle)` and `restartFromBeginning()` — i.e. on first REAL
   playback. Lock-screen controls still work; launch never touches the
   remote-command registry (which the LiveContainer host app owns).
4. **`resumeIfBookmarkPending()` skips the initial scene activation** — a fresh
   (< 5 min) bookmark replaying speech during launch would turn any
   mid-speech crash into a launch crash loop. App-switcher returns still
   auto-resume.

Not changed (audited, judged safe): `ModelManager.init` ran at launch in 0785f1b
too (proven on device); `removeQuantizedDownloads()` is pure `try?` FileManager
ops. `SpeechPlayer.init` only touches UserDefaults. `NoteRowView`/preview cache
are pure string work.

Next: CI build from bisect-g → install in LiveContainer → verify launch. If it
STILL crashes, stop guessing: capture a real crash log via Xcode → Devices →
device console (or Settings → Privacy → Analytics & Improvements → Analytics
Data → Speechnotes-*.ips on device) before touching code again.
