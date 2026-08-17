# PLAN V1.2 — execute top to bottom (written 2026-08-17 by the senior model)

> **WHO YOU ARE:** You are the next agent working on this repo. This plan is a
> complete work order. Follow the steps IN ORDER, exactly as written. Do not
> refactor working code the steps don't touch. Do not restart STT or
> translation (permanently dropped by user decision). When CI fails, fix and
> push again — never leave the branch red.
>
> **Repo:** `~/.zcode/workspace/default/speechnotes-ios` (GitHub:
> `thesagezm/speechnotes-ios`, public). You MAY push directly (creds + `gh` CLI
> are authenticated on this PC). Build loop: edit → `git add -A && git commit
> -m "<message>" && git push` → watch CI with `./Scripts/watch_ci.sh <full-sha>`
> (run in background, exit 0 = green). If it fails: `gh run view --log-failed`
> or check-run annotations via `gh api`. HEAD at plan time: `9ba9633`, CI green,
> released as `v1.1.0`.
>
> **STATUS MARKERS:** Each step header carries `[ ]` (todo) / `[x] commit …`
> (done). The senior model began executing this plan on 2026-08-17 — check
> `git log --oneline` and the markers before doing anything, and keep markers
> current as you complete steps.
>
> **User feedback this plan answers (2026-08-17, verbatim intent):**
> 1. "i cant switch the orientation of the screen" — enable rotation.
> 2. "the voice control bar at the bottom (play speed voice) was freezing a lot
>    in the middle of the screen instead of at the bottom" — fix the stranded
>    bar. (Note: the v1.1 read-along/"none highlighting" change is LOVED —
>    keep it; only the occasional bar freeze remains.)
> 3. "for the landscape view rather than make the voice control bar at the top
>    put it either to the left or right — to make the ui continue to look
>    clean" — landscape editor puts controls in a RIGHT-side vertical rail.
> 4. "optimise it… make the app smoother and faster" — targeted perf pass
>    (diagnosed below; engines are NOT the problem, the view layer is).
>
> **Verify anchor code (not line numbers) before editing** — lines drift as
> steps complete.

---

## Diagnosis (why the bar freezes, what's slow) — read this first

**Bar stuck mid-screen:** `NoteEditorView.controlsBar` is a plain `VStack`
child sitting BELOW `TextEditor`. When the keyboard appears/disappears
(especially an interrupted interactive keyboard dismissal — swiping the
keyboard down mid-drag), SwiftUI's keyboard-avoidance layout can leave that
bottom sibling's frame computed with stale geometry: the bar visually detaches
and floats mid-screen until the next big layout pass. The fix is to anchor the
bar with `.safeAreaInset(edge: .bottom)` — inset content is positioned by the
container's safe-area rects (recomputed by UIKit on keyboard frame changes),
which does not exhibit the stranded-frame bug. `MiniPlayerBar` ALREADY uses
`safeAreaInset` (see its `MiniPlayerModifier`) and does not have this bug —
this plan brings the editor bar to the same pattern.

**Perf (all verified by reading the code, not guesses):**
- `NoteEditorView.speechText` runs `MarkdownText.plainText(draft)` (a full
  regex walk of the ENTIRE note) on EVERY body render when Render Markdown is
  on. Body re-renders fire on: every chunk-progress update (every ~2–5 s of
  speech), every player state change, AND every speed-slider tick (~30 ticks
  per drag). This is the "occasional freezing during speech" on long notes.
- `draftStats`/`draftWordCount` also walk the whole draft per render.
- `SpeechPlayer.rateMultiplier`'s `didSet` writes `UserDefaults` on EVERY
  slider tick.
- `NotesListView.preview(of:)` walks the FULL text of every note (split, join,
  split, join) for every row on every list render — list re-renders happen on
  search keystrokes and any `SpeechPlayer` @Published change (the player is an
  environment object at the TabView root).
- The engines (ONNX/Kitten/Supertonic/System) are all correctly off-main-thread
  with chunk-level progress — LEAVE THEM ALONE (guardrail).

---

## STEP 1 — Enable landscape orientation `[x done 2026-08-17]`

**File:** `project.yml`

In `info.properties`, `UISupportedInterfaceOrientations` currently lists only
`UIInterfaceOrientationPortrait`. Replace with:

```yaml
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
```

No upside-down portrait — standard iPhone convention. The Info.plist is
GENERATED from this block (there is no checked-in plist file), so this one
edit is the whole change. Everything else in the app is standard SwiftUI and
adapts automatically.

**Commit:** `v1.2.0 step 1: enable landscape orientation`

---

## STEP 2 — Editor controls: safeAreaInset anchor + landscape side rail `[x done 2026-08-17]`

**File:** `App/Sources/Views/NoteEditorView.swift`

This is the freeze fix AND the landscape UX. One coherent restructure:

### 2a. Orientation awareness + new body layout

Add the environment property near the other `@Environment` declarations:

```swift
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// iPhone landscape = vertically compact; portrait = regular.
    private var isLandscape: Bool { verticalSizeClass == .compact }
```

Change `body`'s top-level `VStack` so it contains ONLY `titleField` + the
editor content (delete `controlsBar` from the VStack), then anchor the
controls adaptively:

```swift
        VStack(spacing: 0) {
            titleField
            if renderMarkdown && showPreview {
                markdownPreview
            } else {
                TextEditor(text: $draft)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .onChange(of: draft) { _ in
                        scheduleDraftSync()
                        updateSpeechCaches()
                    }
            }
        }
        .safeAreaInset(edge: isLandscape ? .trailing : .bottom, spacing: 0) {
            if isLandscape {
                landscapeRail
            } else {
                controlsBar
            }
        }
```

(All existing modifiers — `.toolbar`, `.confirmationDialog`, `.sheet`s,
`.alert`, `.onAppear`, `.onDisappear`, `.onChange(of: player.shareURL)` —
attach AFTER the `.safeAreaInset`, exactly where they are today.)

### 2b. Portrait `controlsBar` — keep visuals, fix the background

Keep the existing `controlsBar` implementation (voice chip, progress capsule,
HStack of play/stop/slider/label) but change its final background modifier
from `.background(.bar)` to:

```swift
        .background(.bar.ignoresSafeArea(edges: .bottom))
```

so the material paints under the home indicator now that the bar is inset
content. `controlsBar` no longer needs its `.padding(.top, 8)` (the
safeAreaInset `spacing: 0` + its own bottom padding suffice) — keep paddings
as they are if the result looks right; visual parity with v1.1 is the goal.

### 2c. Landscape rail (new)

Add `landscapeRail` — a vertical control strip pinned to the trailing edge:
voice button, play/pause, stop, then (after a spacer) the speed slider rotated
vertical + its label, with a thin vertical progress strip on the rail's
leading edge. Full implementation (this exact code works):

```swift
    // MARK: - Landscape side rail

    /// Landscape layout: controls live in a vertical rail on the trailing
    /// edge (user request — controls on the side, not the top, keeps the
    /// reading surface tall and clean). Portrait keeps the bottom bar.
    private var landscapeRail: some View {
        HStack(spacing: 10) {
            railProgressStrip
            railControls
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: 78)
        .background(.bar.ignoresSafeArea(edges: .bottom))
    }

    /// Thin vertical progress strip on the rail's leading edge — the
    /// landscape twin of the portrait bar's progress capsule, filling
    /// bottom-up.
    @ViewBuilder
    private var railProgressStrip: some View {
        if let progress = player.progress, player.state == .speaking {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 3)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.accentColor, .purple],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 3, height: max(4, proxy.size.height * progress))
                }
            }
            .frame(width: 3)
        } else {
            Divider()
        }
    }

    private var railControls: some View {
        VStack(spacing: 10) {
            Button {
                showingVoicePicker = true
            } label: {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change voice")

            Button {
                Haptics.tap()
                player.togglePlay(speechText, note: currentNote)
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.accentColor, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    if player.state == .generating {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: playIcon)
                            .font(.body.bold())
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 46, height: 46)
            }
            .disabled(playButtonDisabled)

            if player.state == .speaking || player.state == .paused || player.state == .generating {
                Button {
                    Haptics.press()
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
            }

            Spacer(minLength: 0)

            Text(String(format: "%.2f×", player.rateMultiplier))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            // Vertical slider: lay the slider out horizontally at the slot's
            // HEIGHT, then rotate the visual 90° counter-clockwise around its
            // center (hit-testing follows the rotation). Min lands at the
            // bottom — slower down, faster up.
            GeometryReader { proxy in
                Slider(value: $player.rateMultiplier, in: 0.5...2.0, step: 0.05)
                    .rotationEffect(.degrees(-90))
                    .frame(width: proxy.size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(width: 34, height: 110)
        }
    }
```

**If the rotated slider misbehaves on device** (wrong hit area / size):
replace it with a compact −/+ stepper around the `%.2f×` label
(`Button { player.rateMultiplier = min(2.0, player.rateMultiplier + 0.05) }`
etc.). Document the swap in the handover if you do.

**Behavior notes:**
- `MiniPlayerBar` (list/logs screens) is already `safeAreaInset`-anchored and
  unaffected; it stays a bottom bar in landscape (it's ~56 pt tall — fine).
- The keyboard accessory bar (`ToolbarItemGroup(placement: .keyboard)`) is
  unchanged and still works in both orientations.
- In landscape with the keyboard up, the rail is on the trailing edge and the
  keyboard toolbar carries Speak — no conflict.

**Commit:** `v1.2.0 step 2: anchor editor controls with safeAreaInset (fixes bar stranded mid-screen) + landscape side rail`

---

## STEP 3 — Performance pass (smoother speech + slider + typing) `[x done 2026-08-17]`

### 3a. `NoteEditorView.swift` — cache the whole-text walks

`speechText` and `draftWordCount` must stop being computed properties that
walk the entire draft on every render. Add state + one update function:

```swift
    /// Whole-draft walks (markdown strip, word count) re-ran on EVERY body
    /// render — per progress tick, per slider tick — which froze long notes
    /// mid-speech. Now recomputed only when the draft (or markdown setting)
    /// actually changes.
    @State private var cachedSpeechText: String = ""
    @State private var cachedWordCount: Int = 0

    private func updateSpeechCaches() {
        cachedSpeechText = renderMarkdown ? MarkdownText.plainText(draft) : draft
        cachedWordCount = draft.split(whereSeparator: \.isWhitespace).count
    }
```

- Replace the `speechText` computed property's body with
  `cachedSpeechText` (keep the property so call sites don't change; update
  its doc comment to say it's the cached value).
- Replace `draftWordCount`'s body with `cachedWordCount`.
- Call `updateSpeechCaches()` in `.onAppear` (inside the existing
  `guard !didLoad` block, after `draft = …`) and add
  `.onChange(of: renderMarkdown) { _ in updateSpeechCaches() }` next to the
  TextEditor's onChange (the draft onChange already calls it — added in step
  2a).

### 3b. `SpeechPlayer.swift` — debounce speed persistence

`rateMultiplier`'s `didSet` writes `UserDefaults` on every slider tick.
Replace the property with:

```swift
    @Published var rateMultiplier: Double {
        didSet {
            guard rateMultiplier != oldValue else { return }
            ratePersistTask?.cancel()
            ratePersistTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                UserDefaults.standard.set(self.rateMultiplier, forKey: "rateMultiplier")
            }
        }
    }
    private var ratePersistTask: Task<Void, Never>?
```

(Init-time assignment doesn't fire `didSet`, so nothing else changes. Worst
case if the app is killed within 0.5 s of a drag: the pref reverts to its last
settled value — acceptable.)

### 3c. `NotesListView.swift` — cap the preview scan

`preview(of:)` walks the FULL note text per row per render. Cap the input —
the preview can only ever show ~120 characters:

```swift
    /// First ~120 characters of the body (everything after the title line),
    /// whitespace-normalized. The scan is capped: rows re-render on every
    /// player publish, and whole-text walks were measurable with long notes.
    private func preview(of note: Note) -> String {
        let source = note.text.count > 800 ? String(note.text.prefix(800)) : note.text
        let body = source
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(body.prefix(120))
    }
```

**Commit:** `v1.2.0 step 3: perf — cache speech text/word count, debounce rate persistence, cap list preview scans`

---

## STEP 4 — Version bump, CI, release `[> in progress 2026-08-17]`

1. `project.yml` settings block: `MARKETING_VERSION: "1.2.0"`,
   `CURRENT_PROJECT_VERSION: "21"`.
2. Commit: `v1.2.0: bump version`. Push. Watch CI:
   `./Scripts/watch_ci.sh <full-sha>` — exit 0 = green. On failure:
   `gh run view --log-failed`, fix, push, repeat.
3. Release (same flow as v1.1.0):
   ```
   gh run list --limit 1
   gh run download <run-id> -n SpeechnotesIOS -D /tmp/v120
   cd /tmp/v120 && unzip SpeechnotesIOS.zip
   gh release create v1.2.0 --title "v1.2.0" --notes "Landscape support with side control rail, editor control bar anchored (no more bar stranded mid-screen), performance pass during speech/slider/list." --prerelease
   gh release upload v1.2.0 /tmp/v120/SpeechnotesIOS.ipa
   ```
4. Update the handover block at the top of
   `~/.zcode/workspace/default/SPEECHNOTES-IOS-PLAN.md` (HANDOVER v11): what
   shipped, the commit, and the device-test checklist below. Keep the status
   markers in THIS file in sync too.

## User device-test checklist (report back to the agent)

1. Rotate the phone anywhere in the app — everything follows, nothing breaks.
2. Editor in portrait: controls bar stays GLUED to the bottom through
   keyboard show/hide (type, dismiss, swipe the keyboard down mid-animation,
   start/stop speech) — it must never float mid-screen again.
3. Editor in landscape: controls are a clean rail on the RIGHT (voice on top,
   play, stop while speaking, speed slider running vertically at the bottom,
   progress climbing the rail's left edge while speaking).
4. During a long note's speech: no stutter around chunk boundaries; dragging
   the speed slider is smooth.
5. Regression sweep: play/pause/stop, WAV export, markdown preview (portrait
   + landscape), notes list search/sort/swipes, mini-player jump-to-note,
   engine/voice pickers.

## Guardrails (do NOT do these)

- Do not touch the engines' audio pipelines, ModelManager, CI jobs, or spike
  packages — steps 1–3 need none of that; engines are already off-main-thread.
- Do not reintroduce read-along highlighting/autoscroll (v1.1 removal is
  user-loved) or STT/translation.
- Do not bump package pins (KokoroSwift 1.0.11 / MLX 0.30.2 /
  MLXUtilsLibrary 0.0.6 / ORT 1.24.2 / MisakiSwift 1.0.6 are frozen).
- No broad refactors beyond the steps; if anchors drifted, re-read the file
  and adapt minimally.
- If the user reports the rotated vertical slider feels wrong, use the −/+
  stepper fallback in step 2c — do not ship a custom gesture slider.
