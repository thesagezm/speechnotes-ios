# Speechnotes iOS — Master Plan v1.4: Powerful Markdown × Powerful TTS

> **HANDOVER v15 (2026-09-03 — STT REVERTED, TTS+MARKDOWN FOCUS).** The v2.0
> STT detour is over. `main` was reset to **v1.3.0 (`37a5598`)** and rebuilt
> from there. Everything STT lives on the `archive/stt-v2` branch (remote) —
> including WhisperKit wiring, dictation UI, audio import. **This doc is the
> executable work order: read it FIRST, follow it top to bottom.** The
> code-generation shopping list is §7 — the user generates code for those
> sections, ZCode integrates and gets CI green.

## 0. What just happened (the revert, recorded)

- **Reset point:** `main` → `37a5598` (v1.3.0, build 24 — last known green).
- **Archived:** branch `archive/stt-v2` = tip of the STT era (`6da512e`) plus
  the one uncommitted MarkdownPreviewView tweak. Nothing was lost; it is on
  the remote. Do **not** merge from it — cherry-pick only.
- **Salvaged onto the new base** (2 commits, both conflict-resolved by hand):
  1. `47c080a` → `98ca99e` "Fix background TTS + mini-player stuck
     mid-screen" — NowPlayingCenter, GlobalMiniPlayerOverlay, playback
     bookmark persistence (`persistPlaybackBookmark` /
     `resumeIfBookmarkPending`). This is pure TTS gold; the STT tab it
     referenced was dropped during conflict resolution.
  2. `8431b58` + 3 package fixes → `5603cc3…fbc3547` — markdown editor:
     formatting bar, slash menu, images, links. **Lesson: these commits were
     pushed red** (5 failing CI runs in a row) — the "fix" commits after
     `8431b58` broke what it got right. We re-picked the original plus only
     the package-level fixes, then repaired the app layer ourselves.
- **Integrated (this cycle, `7003350`):** the user-generated markdown engine
  v2 — unified scanner, regex cache, tables/tasks/nesting/reference links/
  escapes; NoteImageStore import/thumbnails/prune; new tests. App layer
  rewritten to match (MarkdownPreviewView, editor wiring, image inserter
  fixes). Version → 1.4.0 (26).
- **Hard rules (unchanged from v1.3):** zero `project.yml` changes beyond the
  version bump; never restructure NoteEditorView wholesale (v1.2.2 lesson —
  additive, new files for new screens); no new package pins; **CI green or it
  didn't happen** — never push red; portrait-only (LiveContainer).

## 1. Mission

A speech-first notes app: **write in powerful markdown, listen in comfort.**
Two pillars, in priority order:

1. **TTS is the product.** Every note is meant to be *heard*: reliable
   background playback, resume where you stopped, navigation while
   listening, control from the lock screen.
2. **Markdown is the input format.** The editor must make structured notes
   fast (formatting bar, slash menu, images, tables, checkboxes), and the
   reading view must make them beautiful — while the TTS layer always knows
   exactly what to say and where it is.

STT/dictation is **out of scope** (archived). If it ever returns, it comes
back from `archive/stt-v2` as a plugin-style module, never wired into core.

## 2. Architecture (what exists now)

```
App/Sources/
├── Engine/        SpeechEngine protocol + Kokoro(ONNX)/Kitten/Supertonic/System
├── Services/      SpeechPlayer (playback+bookmark), NotesStore, ModelManager,
│                  NowPlayingCenter, ImportService, LogStore, Haptics,
│                  MarkdownImageInserter
├── Models/        Note, VoiceCatalog
└── Views/         NotesListView, NoteEditorView, MarkdownPreviewView,
                   MarkdownFormattingBar, FlowLayout, ImagePicker,
                   MiniPlayerBar, GlobalMiniPlayerOverlay, settings sheets
Packages/SpeechLogic/   ← ALL pure logic, CI-tested
├── MarkdownText        blocks+plainText from ONE scanner (v2)
├── MarkdownSlashMenu   detect/filter/apply (fuzzy, wrap, prefix-aware)
├── NoteImageStore      speechnotes:// image cache (import/thumb/prune)
├── SentenceChunker     streaming playback chunking
├── WAVWriter, KittenTokenizer
```

Key data flow (unchanged, now scanner-unified):

```
draft (markdown)
  ├─ MarkdownText.blocks()    → preview UI (headings/lists/tables/images)
  └─ MarkdownText.plainText() → SpeechPlayer → SentenceChunker → engine
        (read-along highlights index into THIS string — one source of truth)
```

## 3. The v1.4 roadmap

### Phase A — DONE: revert + salvage + markdown v2 (this cycle)

See §0. Next release tag: **v1.4.0** once a device test passes.

### Phase B — Editor experience (markdown pillar)

Goal: typing markdown feels like a rich editor, not raw syntax.

- **B1. Selection-aware editor.** The #1 editor gap: `TextEditor` doesn't
  report selection on iOS 18, so the formatting bar and slash menu are
  caret-blind (they operate at end-of-text). Replace the editor's
  `TextEditor` with a `UITextView`-backed `UIViewRepresentable`
  (`MarkdownEditorView`) that reports selection live. **Spec in §7.1.**
- **B2. Slash menu UI.** `MarkdownSlashMenu` v2 (fuzzy, prefix-aware,
  wrap-selection) is integrated and tested but has NO UI. Build
  `SlashMenuOverlay` shown above the keyboard while the filter matches;
  apply via the full `apply(caret:selection:)` entry point. **Spec §7.2.**
- **B3. Formatting bar completion.** Add todo (`- [ ] `) and table buttons;
  heading button cycles H2→H3→off. Small, on top of B1's selection plumbing.
- **B4. Link/image polish.** Wire the link *edit* sheet (long-press link in
  preview → editor callback); image long-press → remove/replace; drag &
  drop images into the editor via `NoteImageStore.importImageData`.
- **B5. Note duplication.** Duplicate action in NotesList: copy note +
  `NoteImageStore.copyImages(from:to:)`.

### Phase C — TTS power (speech pillar)

Goal: the best listening experience of any notes app.

- **C1. Block-aware listening.** `MarkdownText.blockRanges(in:)` — map each
  block to its character range in `plainText` output. Powers: tap a
  paragraph/list item in the preview → speak from there; "next/previous
  block" skip buttons in the controls bar; progress bar shows *block*
  position ("paragraph 3 of 12"). **Spec §7.3.**
- **C2. Listening controls.** Skip ±30 s (or ±block from C1) buttons flanking
  the play button; sleep timer (5/15/30/60 min, fades out); playback speed
  presets (1×, 1.25×, 1.5×, 2×) in a long-press menu on the rate readout.
- **C3. Queue & auto-advance.** "Play all" in NotesList: speak note after
  note, mini-player shows the note title, tap = jump into that note.
- **C4. Bookmark UX.** The persisted bookmark (from `98ca99e`) gets a
  "Continue where you left off" banner on note open: sentence position,
  time-ago, one-tap resume.

### Phase D — Reading & output polish

- **D1. Read-along highlighting** stays index-exact (single scanner makes
  this trustworthy); verify against tables/tasks (they now produce speech
  text differently).
- **D2. Export markdown → PDF** (rendered preview → `UIGraphicsPDFRenderer`),
  alongside existing WAV/text export.
- **D3. Preview niceties:** checkbox tap in preview toggles `- [ ]`/`- [x]`
  in the draft; searchable reading view; share rendered note as image.

### Phase E — Quality

- **E1.** CI discipline: every push green; logic tests grow with every
  package change (markdown v2 added ~15 — keep that ratio).
- **E2.** Perf: thumbnail generation off-main (Task.detached) once device-
  tested; cached `blocks()` in preview for long notes (same pattern as
  `cachedSpeechText`).
- **E3.** Device test checklist per release (see §6).

## 4. Rules for generated code (READ BEFORE GENERATING)

1. **iOS 18.0 deployment target, SwiftUI, Swift 5 language mode.** No iOS
   26-only APIs (that killed the first markdown attempt: `TextRange`
   selection binding). When unsure, v1.3's code is the oracle.
2. **LiveContainer constraints:** portrait-only, static linking, no new SPM
   deps. `project.yml` untouched except the version line.
3. **All pure logic goes in `Packages/SpeechLogic`** (public API, tested);
   UI stays in `App/Sources/Views`. No logic in views beyond formatting.
4. **Never push red.** If you generate a file, keep it self-contained and
   name every symbol it expects to call — integration failures so far were
   all dangling references (`EnvironmentValuesHolder`, `editingLink`,
   `fragment` self-reference, escaped `\\(interpolation)`).
5. Match existing style: comments explain *why*, `Haptics.tap()` on buttons,
   `.foregroundStyle(.secondary)` over `.foregroundColor(.gray)`, `enum`
   namespaces for pure logic, small views composed from private vars.

## 5. Versioning & release

- Next: **v1.4.0 (build 26)** — markdown v2 + salvaged background playback.
- Tag + GitHub Release after the user's device test passes (launch, edit,
  preview, listen, background, mini-player, export).
- v1.5 = Phase C complete. v1.6 = Phase D. No STT in any of them.

## 6. Device test checklist (per release, LiveContainer on iPhone 12 Pro Max / iOS 26)

1. Cold launch (no black screen — orientation keys stay gone).
2. Notes list → new note → format with bar + type `/` (once B2 lands).
3. Insert image (Photos + paste + URL), preview shows it, airplane-mode
   still shows local images.
4. Markdown preview: heading/list/table/task/quote/code render; tap back to
   edit; speak a task list ("To do:"/"Done:").
5. Long-note playback: start, background the app, lock screen controls
   (play/pause/seek), mini-player tap jumps to note, resume banner works.
6. Export WAV + share; Recycle Bin; Storage tab numbers.
7. Note with a 12 MP photo: preview stays smooth (thumbnails), Storage
   footprint excludes thumbnails.

## 7. Code-generation shopping list (user generates → ZCode integrates)

Ordered by value. Each item is a self-contained brief: generate **only**
these files/sections, keep every referenced symbol defined, no new deps.

### §7.1 — `App/Sources/Views/MarkdownEditorView.swift` (Phase B1) — HIGHEST

Replace `TextEditor` inside NoteEditorView's edit branch with a
UIViewRepresentable wrapping `UITextView`:

```swift
struct MarkdownEditorView: UIViewRepresentable {
    @Binding var text: String
    /// Live selection as utf-16 offsets (nil when unfocused). This is the
    /// format MarkdownSlashMenu + MarkdownFormattingBar want.
    @Binding var selection: Range<Int>?
    var onCaretMoved: (() -> Void)?   // drives slash-menu detect/filter
    var focused: FocusState<Bool>.Binding
}
```

Requirements:
- Delegate `textViewDidChange(_:)` → `text`; `textViewDidChangeSelection(_:)`
  → `selection = Range(utf16 offsets)` + `onCaretMoved`.
- Programmatic edits from formatting bar/slash menu must not double-fire or
  fight the text binding (compare before assigning; update selection after).
- Match v1.3 text metrics (`UIFont` `body`, same insets), autoscroll caret
  visible, `adjustsFontForContentSizeCategory`.
- Optional stretch: light syntax tinting for headings/fences via
  `NSAttributedString` — behind a setting, default off, never alters `text`.

### §7.2 — `App/Sources/Views/SlashMenuOverlay.swift` (Phase B2)

SwiftUI overlay driven by `MarkdownSlashMenu` (already integrated):

```swift
struct SlashMenuOverlay: View {
    let commands: [MarkdownSlashMenu.Command]   // from filter(prefix:)
    let onSelect: (MarkdownSlashMenu.Command) -> Void
    let onDismiss: () -> Void
}
```

- Presented in NoteEditorView when `detect(in:caretOffset:)` returns a valid
  trigger; shows up to 5 rows (symbol, label), selected row highlighted,
  keyboard: up/down/enter via `UIKeyCommand` or tap; re-filter on caret
  move; dismiss on space/backspace-past-slash/blur.
- On select: `MarkdownSlashMenu.apply(cmd, in: draft, trigger:, caret:,
  selection:)` → write returned draft + caret + selection back through
  MarkdownEditorView's bindings.

### §7.3 — Package: `blockRanges` (Phase C1) — TTS navigation foundation

In `Packages/SpeechLogic/Sources/SpeechLogic/MarkdownText.swift` add:

```swift
/// Character ranges (into plainText(_:) output) for each block, in order.
/// Enables tap-to-speak, block skip, and "paragraph 3 of 12".
public static func blockRanges(in markdown: String) -> [(block: MarkdownBlock, range: Range<Int>)]
```

Must be derived from the same scan as `plainText` (join offsets while
building), not regex-reconstructed. Plus `MarkdownTextTests` coverage:
offsets round-trip (`String(ranges[i])` inside plainText == speechText of
that block), task/table/image cases.

### §7.4 — `App/Sources/Views/PlaybackControls.swift` (Phase C2)

Extract + extend the editor's `controlsBar` into its own view (additive;
NoteEditorView keeps calling it): skip ±(block|seconds) buttons, sleep
timer menu, speed presets. SpeechPlayer additions must be additive (new
methods, no signature changes) so this stays a low-risk diff.

### §7.5 — Defer until B–C land

Link edit sheet plumbing (B4), duplicate-note action (B5), queue/play-all
(C3), PDF export (D2), checkbox toggle from preview (D3). Don't generate
these yet — their specs will firm up after B1/B2 integrate.
