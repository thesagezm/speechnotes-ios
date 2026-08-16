# Plan — UI Improvements (v0.7+)

> Written 2026-08-16 after v0.7.0 (Metal engine removed; Kokoro ONNX is the
> single neural engine; 28 voices; notes/editor/import/export/read-along all
> working). This plan is UI-only: no engine changes, no new downloads.
> Companion doc: `Docs/PLAN-NEW-VOICES.md` (Kitten + Supertonic engines).
>
> **STATUS (2026-08-16, v0.9.0):** UI-1, UI-2, UI-3 and UI-4 all implemented
> in one build: VoiceCatalog friendly names, searchable VoicePickerSheet with
> tap-to-audition + recents, notes list with previews/search/sort/sections/
> swipe-export/drag-&-drop, persistent MiniPlayerBar (list + logs, hidden in
> editor), editor redesign (gradient play button, voice chip → picker,
> keyboard Speak bar + word count/listen estimate), haptics, import overhaul
> (iCloud-aware coordinated reads, encoding battery, per-step logging,
> clipboard channel). Remaining from the known issues: intra-chunk highlight
> interpolation (UI-1's stretch goal) is NOT done — highlighting is still
> chunk-granular; voice smoothness now also has the bigger models lever
> (v0.9.0 ships Kokoro uint8 + Kitten mini-0.8).

## Current state (what we're building on)

| Screen | Today | Pain points |
|---|---|---|
| Notes list (131 ln) | NavigationStack list, title + date, import + new buttons, delete confirm | No text preview, no word count, no search, no sort |
| Editor (231 ln) | TextEditor autosave, big play/pause button, progress bar, read-along swap, export share, settings sheet, delete | Play controls basic; no scrub/seek; settings only reachable from editor |
| Settings (209 ln) | Engine picker, voice dropdown (2 groups), system voice dropdown, model download/delete | Voice names are codenames (`am_eric`); can't hear a voice before picking |
| Logs | Persistent log viewer + share | Fine for now |
| Read-along | NSTextStorage highlight + autoscroll | Works; styles are plain |

## Known issues (registered 2026-08-16, user-reported)

1. **Read-along highlight "misses words"** — highlighting is chunk-granular
   (jumps sentence-to-sentence as chunks are scheduled), so words inside a
   sentence never light up individually. Fix in UI-1/UI-3: interpolate the
   highlight within the current chunk using its known audio duration and
   char offsets (a DisplayLink-timed sweep), instead of one range per chunk.
2. **Voices "not extremely smooth"** — two contributors: q8 quantization
   (CPU model) and hard chunk-boundary joins. Candidate fixes, cheapest
   first: (a) 10–20 ms crossfade at chunk boundaries in the engines'
   buffer scheduling; (b) offer the fp32 ONNX model (~177 MB) as a quality
   option in Settings; (c) Supertonic engine (known for smooth output).

## Principles

1. **Voice-forward** — this app exists to make the phone talk nicely; voice
   choice is the hero setting, not a codename in a dropdown.
2. **Player that survives navigation** — speech continues while you browse
   notes (engine already streams; UI drops it on back-swipe today).
3. **Zero new dependencies** — SwiftUI only; everything below is stock.

## Phase UI-1 — Voice experience (the "eric" phase) — ~1 build

- **Friendly voice names**: map all 28 codenames → "Eric · US male",
  "Bella · US female", "Daniel · UK male"… shown everywhere (picker, editor
  subtitle). Keep codename as subtitle in the picker rows.
- **Voice picker redesign**: grouped `Menu` → searchable list sheet with
  sections US/UK × female/male, checkmark on selection, word-count-free.
- **Audition taps**: tapping a voice in the sheet speaks a fixed sample
  sentence ("The quick brown fox…") with that voice, inline mini progress.
  Implementation: `OnnxKokoroEngine` already swaps `voice` per-call — set
  `voice`, speak sample, restore. Guard: skip while a note is playing.
- **Recent voices**: persist last 3 used at top of the sheet.

**Acceptance**: user can find Eric by reading names, hear him before
committing, and the editor shows "Eric · US male" while idle.

## Phase UI-2 — Notes list upgrade — ~1 build

- Row preview: first ~80 chars of body, word count, relative date ("2h ago").
- Search bar (title + body, case-insensitive).
- Sort menu: edited / created / title.
- Empty state: friendly illustration text + "New note" + "Import" buttons.
- Swipe actions: delete (existing confirm) + export shortcut.

**Acceptance**: a 30-note list is scannable; search finds a note by a body
word; sort persists across launches.

## Phase UI-3 — Persistent mini-player — ~1-2 builds (biggest item)

- Compact player bar pinned above the tab bar / list bottom while
  `SpeechPlayer.state != .idle`, visible from list and editor:
  note title, play/pause, stop, chunk progress, current voice name.
- Tap → expands to full controls (speed slider, read-along jump).
- Survives navigation; stop on app background stays as-is (no background
  audio yet — separate roadmap item).
- Editor keeps its big button; both control the same `SpeechPlayer`.

**Acceptance**: start a long note, back out to the list, controls remain
usable; stopping from the bar stops audio.

## Phase UI-4 — Polish pass — ~1 build

- Haptics on play/stop/export success (`UIImpactFeedbackGenerator`).
- Dark mode audit: read-along highlight color, progress tint contrast.
- Dynamic Type spot-check (picker rows, player bar at XXL sizes).
- Keyboard accessory: "▶ Speak" + word count above keyboard in editor.
- App icon variants already fine; consider accent-color tint for progress.

**Acceptance**: no truncation at largest text size; haptics fire once per
action; highlight readable in both appearances.

## Suggested order

UI-1 (voices) → UI-2 (list) → UI-4 (polish) → UI-3 (mini-player, largest).
Each phase is one PR + one TestFlight-style install cycle.
