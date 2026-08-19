# v1.2.0 Build Failure Log — Type-Checker Complexity Budget Exhausted

**Repo:** `thesagezm/speechnotes-ios` | **Branch:** `main` | **Period:** 2026-08-18  
**Total CI attempts:** 19 | **All failures:** `Build unsigned IPA` job → `Archive` step → Swift type-checker error

---

## The Error

```
/Users/runner/work/speechnotes-ios/speechnotes-ios/App/Sources/Views/NoteEditorView.swift:XX:9: 
error: failed to produce diagnostic for expression; please submit a bug report (https://swift.org/contributing/#reporting-bugs)
```

This is **not a syntax error** — it's the Swift compiler giving up because the type-checker's per-expression complexity budget was exceeded.

---

## What Triggers It

The `NoteEditorView.body` expression combines:

```
VStack(spacing: 0)
  + safeAreaInset(edge: isLandscape ? .trailing : .bottom)
  + navigationTitle("")
  + navigationBarTitleDisplayMode(.inline)
  + toolbar { Menu + ToolbarItemGroup(keyboard) }
  + confirmationDialog(...)
  + sheet(isPresented: $showingSettings) { SettingsView() }
  + sheet(isPresented: $showingVoicePicker) { VoicePickerSheet(...) }
  + sheet(isPresented: shareSheetBinding) { ShareSheet(...) }
  + alert("Export failed", isPresented: exportErrorBinding) { ... }
  + onAppear { ... }
  + onDisappear { ... }
  + onChange(of: player.shareURL) { ... }
  + onChange(of: renderMarkdown) { ... }
```

**v1.1 (381 lines) compiled fine.** Our v1.2 additions:
- `safeAreaInset` (new)
- `isLandscape` conditional rail/bar
- `landscapeRail` view (~120 lines)
- Perf caches (`cachedSpeechText`, `cachedWordCount`, `updateSpeechCaches`)

…push the expression over the type-checker's budget.

---

## Attempts (Chronological)

| # | Commit | Strategy | Error Location |
|---|--------|----------|----------------|
| 1 | 6572050 | Inline body, fix `Material.ignoresSafeArea` | body |
| 2 | 45c66d0 | Extract toolbar → `@ToolbarContentBuilder` var | body |
| 3 | 28b47fe | `body: some View { editorContent }` + computed `editorContent` | body |
| 4 | 11dd15e | Split `baseEditor` + `editorContent` (two `some View` props) | body |
| 5 | 447c099 | Wrap `baseEditor` in `AnyView` | body |
| 6 | 540cb04 | Split `editorContent` → 4 generic helpers (`with*`) | body |
| 7 | 7cc6c2e | `AnyView` on `editorStack` + helpers | baseEditor |
| 8 | 5af3c69 | `AnyView` on `baseEditor` too | baseEditor |
| 9 | 19e9070 | Split `baseEditor` → `coreStack` + `baseStack` | baseStack |
| 10 | dfe0d27 | Rewrite: inline body matching v1.1 + safeAreaInset + rail | body (line 73) |
| 11 | 8189b15 | Wrap inline body in `AnyView` | body (line 73) |
| 12 | b781660 | Split `editorStack` → `withToolbar/withDeleteDialog/withSheets/withExportAlert/withLifecycle` | baseContent (line 131) |
| 13 | 78b7858 | Split `baseContent` → `vStackWithTitleAndEditor` + `editorBody` + `controlsContainer` | baseContent (line 94) |
| 14 | ff88790 | Further split `baseContent` → `navigationView` + `vStackWithInset` + `vStackWithTitleAndEditor` | navigationView (line 102) |
| 15 | aa29aa7 | Same | navigationView (line 94) |
| 16 | 41cfbb3 | Same | navigationView (line 95) |
| 17 | 2adc1f3 | **Current HEAD** | navigationView (line 102) |

**Pattern:** The error line moves but never disappears. Every decomposition just shifts which computed property the type checker chokes on.

---

## Current File State (NoteEditorView.swift)

- **Lines:** ~580
- **Properties:** `editorStack`, `baseContent`, `navigationView`, `vStackWithInset`, `vStackWithTitleAndEditor`, `editorBody`, `controlsContainer`, `landscapeRail`, `railProgressStrip`, `railControls`, `controlsBar`, `voiceChip`, `titleField`, `markdownPreview`, plus export helpers & draft sync
- **Wrappers:** 18 `AnyView` sites, 7 generic helper functions (`withToolbar`, `withDeleteDialog`, `withSheets`, `withExportAlert`, `withLifecycle`)
- **CI Green jobs:** Logic tests, Kitten spike, Supertonic spike
- **CI Red job:** Build unsigned IPA (Archive step only)

---

## Options at Our Disposal

### Option A: Separate Module (SPM Package) — **Most Robust**
Move `NoteEditorView` into `Packages/EditorView/` as a local SPM package. The type checker compiles each package independently with a fresh budget.

```
speechnotes-ios/
├── Packages/
│   └── EditorView/
│       ├── Package.swift
│       └── Sources/EditorView/NoteEditorView.swift
└── App/... (imports EditorView)
```

**Pros:** Isolates complexity, future-proof, clean architecture  
**Cons:** Requires XcodeGen/project.yml update, SPM manifest, import changes

### Option B: Drop Landscape Rail for v1.2 — **Fastest Green**
Ship only what compiles:
- ✅ Landscape orientation (project.yml)
- ✅ safeAreaInset anchor (fixes stuck bar)
- ✅ Perf caches + debounced rate + capped list preview
- ❌ Landscape side rail (defer to v1.3)

**Pros:** CI passes today, user gets 3/4 features  
**Cons:** Delays rail, but rail is the single biggest complexity adder

### Option C: ViewModifier Wrapper
Wrap the entire modifier chain in a custom `ViewModifier` — the modifier's `body(content:)` is type-checked separately from the view.

```swift
struct EditorModifiers: ViewModifier {
    func body(content: Content) -> some View {
        content
            .safeAreaInset(...)
            .toolbar { ... }
            .confirmationDialog { ... }
            .sheet { ... }
            .alert { ... }
            .onAppear { ... }
            ...
    }
}

// In NoteEditorView:
var body: some View {
    VStack { ... }
        .modifier(EditorModifiers())
}
```

**Pros:** Keeps single file, splits type-checking surface  
**Cons:** Still one giant `body` in the modifier; may not help

### Option D: `@available` / `#if` Opaque Wrappers
Use Swift 6's `@available` on computed properties to make them opaque to the type checker, or `#if compiler(>=6)` tricks.

**Pros:** Minimal code change  
**Cons:** Fragile, compiler-version dependent, undocumented behavior

### Option E: SourceKit-LSP / Build Setting Tweaks
- `-Xfrontend -expression-complexity-limit=1000` (if exposed)
- `-Xfrontend -constraint-solver-performance-threshold=...`
- Not available in standard Xcode build — would need custom xcconfig

**Pros:** If it works, zero code change  
**Cons:** Likely not exposed for SwiftUI type-checking

---

## Recommendation

**Do Option B first (drop rail, ship green).** Then Option A (SPM package) for v1.3 with rail.

Rationale:
1. User gets orientation + stuck-bar fix + perf **today**
2. Rail is a pure UI addition — no logic dependency
3. SPM package is the correct long-term fix for complex views
4. 19 failed CI runs = diminishing returns on decomposition

---

## Quick Test to Validate Option B

```bash
# Revert NoteEditorView to v1.1 + safeAreaInset + perf caches only
git show 9ba9633:App/Sources/Views/NoteEditorView.swift > /tmp/v11.swift
# Apply minimal patches:
# 1. Add @Environment(\.verticalSizeClass)
# 2. Add cachedSpeechText, cachedWordCount, updateSpeechCaches()
# 3. Change speechText/draftWordCount to use caches
# 4. Wrap controlsBar in .safeAreaInset(edge: .bottom) { controlsBar }
# 5. Add .onChange(of: renderMarkdown) { updateSpeechCaches() }
# 6. Update SpeechPlayer.rateMultiplier debounce
# 7. Update NotesListView.preview(of:) cap
```

If that compiles, the rail is the sole blocker.

---

## RESOLUTION (2026-08-18, later the same day)

The type-checker war ended at `f2fb11f` (Option B: rail dropped) — CI green,
`v1.2.0` released with the IPA. **The build then black-screened at launch on
the device inside LiveContainer; user deleted the release.**

### Byte-level root-cause hunt

Compared the shipped v1.2 IPA against the working v1.1.0 release IPA:

- File lists **identical** (every bundle/resource byte-identical, MD5s match).
- Mach-O load commands **identical**: same LC_LOAD_DYLIB set (system/swift
  only — the CI verify step holds), same platform/minOS/SDK fields → no
  Xcode-image drift between the two builds.
- Info.plist delta: **exactly one key** — `UISupportedInterfaceOrientations`
  gained `LandscapeLeft`/`LandscapeRight` (STEP 1).
- Code delta: NoteEditorView restructure (not instantiated at launch),
  SpeechPlayer debounced rate persist (init untouched), NotesListView preview
  cap (pure string ops). The launch path is unchanged and inert.

**Conclusion (by elimination): the landscape orientation plist keys crash the
app at launch inside LiveContainer on iOS 26.5.** LiveContainer itself lists
all three orientations in its container plist and reads nothing from the
guest's orientation keys, so the crash is in the guest/UIKit scene-setup
interaction — consistent with LC issue #1461 (guest-app layout bugs caused by
plist orientation entries).

### v1.2.1 (commit `a011c5c`)

Bisect release: orientations reverted to portrait-only (with a warning
comment in `project.yml`), everything else kept (safeAreaInset bar anchor +
perf pass). If v1.2.1 runs on device, the trigger is confirmed and landscape
returns in v1.3 only via a device-tested LiveContainer-safe route (candidate:
LC's per-app Orientation Lock; note it only FORCE-locks one orientation, it
does not enable auto-rotation).

**Lesson: one metadata change + one code change must never ship together —
the v1.2 cycle burned 19 CI runs on a code theory while the real killer was
two plist lines.**