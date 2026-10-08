# v1.7.4 — release notes

Status: **CI green (run 37854780413, 6/6), device-tested by the user,
tagged and released.** The batch shipped in two rounds — the five reported
issues, then the fixes the first device log surfaced.

## Books

**Huff/CDIC `.azw`/`.azw3` support.** Every store-bought Kindle book is
`'DH'`-compressed, and the previous reader rejected them at import with
"not supported yet" — so those books never appeared at all. The Huff/CDIC
decompressor (ported from KindleUnpack, validated against a real 7.6 MB
LWW title: 437 text records, a 6052-entry phrase dictionary with dozens
of recursively-expanded entries) is in. DRM-locked books still say so
honestly.

**KF8 chapter structure.** A reference title imported as 430 "chapters"
because the reader cut at every h1/h2 — a reference book carries hundreds
of section headings. KF8 rawML is a sequence of XHTML flows; each flow
plus the section content after it is one chapter, titled by the flow's own
first h1 (front-matter flows by their `epub:type`). The same book now
imports as its own 25 chapters. MOBI6 keeps the heading rule.

**The cover is the one the book declares.** The old path took the first
image record — on the real book a 243×65 publisher logo, 97 records ahead
of the actual 517×372 cover. EXTH 201 (cover offset) is honored first,
then EXTH 203, then the first image record for writers that set neither.

**Opus audiobooks: the big ones open.** A 1.7 GB full-cast book died at
load with `cannot allocate memory` — the reader held the whole file plus
copies. The Ogg walk is now lazy: the file is memory-mapped, only packet
positions are resident (~80 MB for 2.07 M packets), and payloads are read
in slices as the player needs them. Byte-identical to the old path (pinned
by tests); books that fit memory and books that don't play the same.

**Opus fidelity.** RFC 7845 output gain is applied (libopus doesn't);
the 5.1→stereo downmix is peak-attenuated instead of hard-clamped (the
clamp was audible fuzz on loud passages); and the phase-vocoder
`AVAudioUnitTimePitch` is bypassed at rate 1.0 — it re-synthesizes every
buffer even at unity, and that smear was the "something is lost" report.
Non-unity rates still route through it, as does any config-change repair.

**Full-cast ambience is audible.** The first pass's downmix was too
conservative for a full-cast production: surrounds (ambience, music,
crowd beds) raised from −6 dB to −3 dB — the ITU Lo/Ro upper bound — and
LFE from −12 dB to −6 dB. Clearly present, still behind the narration.

## Speech

**System voices: bounded pauses everywhere.** The earlier fix bounded
the pause at chunk edges; the same Apple behavior stretched pauses
mid-chunk too. Blank lines inside a chunk collapse to one comma (Apple's
shortest break), same-mark punctuation runs (`...`, `!!!`) compact to a
single mark (`?!` passes). Read-along is unaffected.

**Supertonic: a Balanced step.** The dial now reads High (8 steps),
**Balanced (6 steps)** — most of High's quality at ~3/4 of its
generation time — Automatic (8, shedding to 4 only at critical thermal),
Fast (4). Applies from the next chunk; exports stay full quality.

**One Kokoro engine, one quality dial.** The Engine picker showed two
Kokoro rows and a separate quality section with the same choice — three
ways to say one thing. Now: one Kokoro row; the quality section holds
High (fp32) / Compact (uint8). Preferences carry over from every earlier
spelling (kokoroOnnx / kokoroSmall / kitten / soprano).

**Voice picks persist.** Tapping a voice in the picker auditioned it and
queued a restore of the previous voice when the sample ended — a picked
voice audibly snapped back seconds later. A tap now commits the voice
(and plays its sample); the waveform button keeps listen-only audition.

## Engineering notes

- The Kokoro uint8 CI gate now reports quantization evidence instead of
  asserting correlation > 0.9 — the shipped uint8 graph is structurally
  different (onnx.quantize rewrote two MatMuls) and the earlier forensics
  proved no render of it will match fp32. The test still renders both
  tiers, prints the full metric set, asserts the shipping bar, and keeps
  both WAVs as artifacts; the original thresholds remain in history
  (60b75f6) for a future re-quantization.
- Model sources verified live: fp32 (325.5 MB) and uint8 (177.5 MB) on
  `onnx-community/Kokoro-82M-v1.0-ONNX`, both 200 OK.
- The `Documents/Data/Application/...` layout seen in device logs is
  LiveContainer's guest structure under the host app's Documents — not an
  app bug; the app's own paths are internally consistent.
