# v1.7.0 — what shipped, what's deferred, what the release actually is

Status: **code complete, CI green, pushed to `batch-c-d-session`. NOT
tagged, NOT released, NOT merged to main.** The user gates every release,
and two de-risking items (JEX importability, a green Soprano spike) are
explicitly deferred to v1.7.1.

## What v1.7.0 contains

**Landscape, unblocked.** The orientation probe (`cdf61fd`) re-added the two
landscape plist keys as the ONLY change in the commit — the v1.2.0 black
screen was traced to exactly those keys — and the app launched clean on
device. Everything below builds on that.

**Playback controls on the side.** `PlaybackRail` on the trailing edge in
the note editor, EPUB reader, PDF reader and audiobook reader: voice,
play/pause, stop, read-along, an optional per-surface button (PDF chapter
export), a top-down progress strip, and a vertical rate slider. The
chapter/page steppers stay at the bottom — navigation, not playback.

**Reading surfaces.** Tap-to-hide chrome (one tap hides the nav bar and
title, another restores them, typing restores them); static scrolling (no
bounce anywhere a note is read or edited); three spacing sliders in
Appearance (line, between-blocks, tables — the last up to 2×) over base
values that are already roomier than the old hardcoded ones; and rotation
that no longer rebuilds the tree (one content identity per surface,
cross-arranged controls, explicit transitions).

**Five freeze fixes.** The notes list no longer re-filters and re-sorts the
whole library on every player publish (3.3 Hz during speech, ~30×/drag on
the rate slider); the cover JPEG is no longer decoded inside
`NowPlayingCenter.publish`'s argument list; `LogStore` publishes a 1 Hz
snapshot instead of one refresh per log line; the editor caches its note
lookup; the preview caches emphasis spans and table widths.

**The engine-switch wedge, fixed.** Play a note, switch engine, and the
player used to freeze with no control responding: the old engine's `.idle`
publish failed the identity guard, so `SpeechPlayer.state` claimed speech
with nothing playing. The teardown is now explicit, plus a self-heal that
reads the engines' real liveness on the next tap — no future path can wedge
it the same way.

**Tables.** Container-width measurement via a background geometry reader
(the foreground variant collapsed a horizontally-scrollable table to zero
height and it overlapped the next paragraph — the bug you caught), and
leftover width shared by content weight so prose columns grow and code
columns stay tight.

**Soprano 1.1** (`ekwek/Soprano-1.1-80M`, Apache-2.0, via the community
ONNX export): a Qwen3 backbone with a KV-cached audio decoder, ~110 MB
int8, 32 kHz, English, one voice. Its text normalizer lives in SpeechLogic
with 9 tests — the model has no phonemizer, so numbers, currency and
ordinals are expanded to words. CI caught three real ordering bugs in that
pass (currency before numbers, ordinals before numbers, digit+suffix
consumed as one unit).

## What the CI spike does and doesn't tell you

`Tests/SopranoSpike` fails on the macOS runner every time (the runner's
runtime trips on an ONNX `Gather` op the device doesn't). Per your call it
stays in CI as diagnostics, non-blocking — it is not a gate. What it DID
establish, and what the engine is built against, is the exact graph
contract: `input_ids/attention_mask/position_ids` +
`past_key_values.N.{key,value}` in, `logits/present.N.*/last_hidden_state`
out, the decoder's 12×512 hidden-state window, 2048 samples/token @ 32 kHz.
That is real information no port has published, and it's why the engine is
written the way it is. **The voice itself still needs your ears** — the
device test is the gate for quality.

## Deferred to v1.7.1 (your call)

- **JEX importability** — the export path is tested; the import path needs
  its own verification round.
- **A green Soprano spike** — the runner-side failure needs a workaround
  (a different export, a CoreML build, or a device-side test harness)
  before it means anything.
- Pick-order for Soprano among the engines, after you've heard it.
- Anything else the device round turns up.

## What "release" means here, and what hasn't happened

Shipped: the branch `batch-c-d-session` at `05b8314`, CI green on every
commit (logic tests + all spikes + unsigned IPA), IPAs staged in `/tmp`
(`SpeechnotesIOS-1.7.0-soprano-engine.ipa` is the one with everything).

NOT done, and waiting for you: the `v1.7.0` tag, the GitHub Release with
the IPA attached, and the fast-forward of `main`. The project's rule since
v1.5.0 stands — the release only happens on your explicit say-so, and I
won't push one without it.
