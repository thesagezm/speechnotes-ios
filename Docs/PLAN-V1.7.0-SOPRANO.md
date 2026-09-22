# v1.7.0 — landscape, spacing you can tune, and the Soprano engine

Status: **implemented, CI green; device test pending.** Branch
`batch-c-d-session`. The release commit (version 1.7.0/37 + README) is in;
the tag and GitHub Release wait for the device round.

This plan covers everything from the v1.6.1 probe through v1.7.0, in the
order it shipped. Every step has a device-test checklist.

## The orientation probe (v1.6.1)

The v1.2.0 black screen was traced by byte-level IPA diff to the two
landscape `UISupportedInterfaceOrientations` keys, which is why rotation had
been off since. `cdf61fd` re-added them as the ONLY change besides the
version bump — so a device black-screen has exactly one suspect. CI green
(run 35662428709), the packaged IPA verified to carry all three
orientations and to link only system frameworks.

**Result: the app launched.** Landscape was unblocked, and everything below
is built on that.

## Landscape UX — lateral playback controls (v1.6.2→1.7.0)

- `OrientationState.swift` — one shared landscape flag injected at the
  window root (iPhone-only target, so compact height ⇔ landscape).
- `PlaybackRail.swift` — the parameterized trailing rail: voice chip,
  play/pause (hourglass while generating), stop, read-along toggle, an
  optional surface-specific button (PDF per-chapter export), a progress
  strip on the rail's leading edge, and a vertical speed slider.
- Wired into the note editor, the EPUB reader, the PDF reader and the
  audiobook reader. The chapter/page steppers stay at the bottom — they are
  navigation, not playback.

### Three rounds of device feedback, all shipped

1. **Tap to hide the chrome.** One tap on a reading surface hides the nav
   bar + title, another brings them back. Typing also restores them (the
   toolbar is needed to format). Shared app-wide preference. A first version
   restored on caret placement, which cancelled the very tap that hid them —
   the restore moved to a real edit.
2. **Lateral tab rail — built, then removed by request.** The user asked for
   icons on the same side as the playback controls, then decided the bottom
   bar was fine. Removed; the playback rail stayed. The mini-player's
   landscape special-case went with it (one less thing changing on
   rotation).
3. **Static scrolling.** "Once I open a note it's too easy to move." Bounce
   off in the preview, the UITextView editor and the read-along view.
4. **Smooth rotation.** The jank was structural: each surface returned
   either `VStack { content; bar }` or `HStack { content; rail }`, and those
   are different view types, so SwiftUI rebuilt the tree on rotation and the
   content unmounted. All four surfaces now measure their own geometry,
   hold one ZStack with one content identity, and cross-arrange the controls
   under an explicit transition.

## Freeze fixes (the "UI is sticking" report)

Five per-tick costs, each root-caused first (all confirmed by reading the
code):

1. The notes list re-filtered + re-sorted + re-sectioned the whole library
   on every player publish (~3.3 Hz during speech, ~30×/drag on the rate
   slider) because `SpeechPlayer` is a root environment object.
   `NotesStore.version` (a mutation counter) + a memoized section list keyed
   on real inputs; a player tick alone now changes nothing.
2. The cover JPEG was decoded inside `NowPlayingCenter.publish`'s ARGUMENT
   list — the throttle drops the publish but not a decode that already
   happened to build the arguments (audit R18, still live). Now cached on
   the payload, re-decoded only when the path changes.
3. Every log line published `LogStore.entries`; playback logs 1-3 lines per
   second. A 1 Hz coalesced `snapshotVersion` now drives the Logs view, and
   `exportText` is cached against it.
4. `NoteEditorView.currentNote` was a `first(where:)` library scan per body
   evaluation — cached in `@State`, refreshed on store mutations.
5. The preview's emphasis regex and the table's per-word `boundingRect` ran
   for every visible block on every player tick — now bounded caches.

## The wedge: switching engines mid-playback (v1.6.6)

User report: play a note, switch engine/voice before stopping, and nothing
responds. Root cause: `rebuildEngine()` opened with `engine?.stop()`, whose
`.idle` publish runs through the OLD engine's callback — and that callback's
identity guard has already failed, so the player's state stayed
`.speaking`/`.generating` with no audio. Stuck state means the mini-player
never hides, read-along never ends, and every play tap lands on
`case .speaking: engine?.pause()` — pausing an engine that never started.

Fix in two layers: `abandonLiveSession()` does the reset the player itself
(instead of hoping to observe the engine's idle), and a
`healStuckStateIfNeeded()` self-heal reads the engines' real
`hasLiveSession` at the top of `togglePlay`, so even a future path that
forgets the teardown can't wedge the player — the next tap heals it.

## Tables

The v1.6.0 "columns wrap" work had two follow-ups: the width budget was
computed from `UIScreen.main`, which over-allocates inside the reader's
padding (the "I can see two columns in the other reader" complaint), and a
first fix wrapped the table in a foreground `GeometryReader` — which
collapsed to zero height and made the table overlap the next paragraph.
The measuring reader is now a `.background` sibling (laid out at the size of
the view it sits under, so it cannot collapse it), and the leftover width
is shared by CONTENT WEIGHT rather than equally, so prose columns grow and
code columns stay tight.

## Soprano 1.1 (v1.7.0)

`ekwek/Soprano-1.1-80M` (Apache-2.0) via the community ONNX export
`KevinAHM/soprano-1.1-onnx` (Apache-2.0): a Qwen3 17-layer backbone with a
KV-cached audio decoder plus a Vocos decoder — 2048 samples/token @ 32 kHz,
English, one voice, ~110 MB int8.

- `SopranoTextNormalizer` (SpeechLogic + 9 tests): the model has no
  phonemizer, so numbers/currency/ordinals are expanded to words before
  tokenization. Three CI rounds on this file caught real bugs: currency
  must run before numbers (the numbers pattern was matching the digits
  inside "$5"), ordinals must run before plain numbers (the digits inside
  "1st"), and the ordinal pass must consume digit + suffix as one unit
  ("1st" → "onest").
- `SopranoEngine` — two ORT sessions on the existing
  `StreamingTTSPlaybackCore`, with the exact graph contract from the spike:
  `input_ids/attention_mask/position_ids` + `past_key_values.N.{key,value}`
  (empty on step 0) in, `logits/present.N.*/last_hidden_state` out, and the
  decoder's 12×512 hidden-state window. Temperature 0.3 / top_k 50 from the
  reference loop.
- ModelManager set, engine kind, picker scope, settings card, audition
  readiness, WAV export routing.

The CI spike (`Tests/SopranoSpike`) is diagnostics, not a gate — it has
failed on the runner every time and the model will be judged on device. What
it did establish, and what the engine is built against, is the I/O contract
above; that is real information no port has published.

## Version path

1.6.1/33 probe → 1.6.2/34 rails → 1.6.3/35 spacing + freeze fixes →
1.6.4/36 polish (immersive, tab rail, top-down progress) → 1.6.6/38 the
wedge fix → 1.6.9 rotation + tables → 1.7.0/37 Soprano + release.

## Device checklist

1. Launch in LiveContainer — no black screen (the v1.6.1 question).
2. Landscape: editor, EPUB, PDF, audiobook — rail on the trailing edge,
   play/pause/stop/read-along/rate all work, progress fills top-down.
3. Rotate during playback and while typing — smooth, content stays mounted.
4. Tap a reading surface — chrome hides; tap again — it returns; type —
   it returns.
5. Appearance → Spacing: move all three sliders, watch the preview and
   read-along follow; Reset restores.
6. Tables: a note with a wide table — columns share the width, long cells
   wrap, no overlap with the paragraph after.
7. The wedge repro: play → Settings → switch engine (any direction) →
   mini-player disappears, controls respond, a fresh play works.
8. Soprano: Speech Settings → download (~110 MB) → pick the engine → play a
   note with numbers in it ("42 apples at $5") → the normalizer should read
   them as words; audition; export a WAV.
9. Regression sweep: notes/books/settings, resume, read-along, background
   playback, lock-screen controls.
