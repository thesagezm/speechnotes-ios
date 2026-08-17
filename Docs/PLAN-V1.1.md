# PLAN V1.1 — execute top to bottom (written 2026-08-17 by the senior model)

> **WHO YOU ARE:** You are the next agent working on this repo. This plan is a
> complete work order. Follow the steps IN ORDER, exactly as written. Do not
> refactor working code that the steps don't touch. Do not restart STT or
> translation (permanently dropped by user decision). When a step says "delete
> X", delete it. When CI fails, fix and push again — never leave the branch red.
>
> **Repo:** `~/.zcode/workspace/default/speechnotes-ios` (GitHub:
> `thesagezm/speechnotes-ios`, public). You MAY push directly (creds + `gh` CLI
> are authenticated on this PC). Build loop: edit → `git add -A && git commit
> -m "<message>" && git push` → watch CI with `./Scripts/watch_ci.sh <full-sha>`
> (run in background, exit 0 = green). If it fails: `gh run view --log-failed`
> or the check-run annotations via `gh api`. Current HEAD at plan time:
> `f2d451d`, CI green, released as `v1.0.0-pre`.
>
> **User feedback this plan answers (2026-08-17, verbatim intent):**
> 1. TTS stops shortly after switching to another app — must keep playing.
> 2. Remove the read-along text highlighter + auto-scroll — inaccurate, can't
>    keep up with the reading.
> 3. Editor top bar is crowded (delete, eye, share, speaker icons, no room for
>    the title) and the title cannot be edited — fix both.
> 4. Engine quality reality: Supertonic BEST, Kitten WORSE THAN SYSTEM. Order
>    the engine picker worst→best and make labels say the truth.
> 5. Markdown rendering collapses into one paragraph, doesn't respect lines,
>    rendering is "crowded" — make it properly block-rendered with spacing.
>
> **Verify your line numbers before editing** — they were exact at `f2d451d`
> but drift as you complete earlier steps. Grep for the anchor strings quoted
> in each step.

---

## STEP 1 — Background playback fix (root cause: missing `UIBackgroundModes`)

**File:** `project.yml`

The app's Info.plist (generated from `project.yml` → `info.properties`) does
NOT declare the `audio` background mode. Without it iOS suspends the app a few
seconds after it goes to the background: the currently scheduled audio buffers
finish playing ("it would for a bit") and then everything stops. All four
engines already configure `AVAudioSession` correctly (`.playback` category,
`.spokenAudio` mode) — the ONLY missing piece is the plist entitlement.

**Edit:** in `project.yml`, inside `info.properties` (the block starting
`CFBundleDisplayName: Speechnotes`, around line 43), add:

```yaml
        UIBackgroundModes:
          - audio
```

Indentation must match the sibling keys (`CFBundleDocumentTypes` etc. are at
the same depth). This is the entire code change.

**Why this is safe:** `UIBackgroundModes` is an Info.plist capability, not a
signing entitlement — unsigned LiveContainer IPAs don't strip it. LiveContainer
merges the guest app's Info.plist keys at install time; audio background mode
is a supported key.

**Commit:** `v1.1.0 step 1: declare audio background mode so speech continues when app is backgrounded`

**Device verification (for the user, after release):** start speech → switch
to another app / lock the screen → speech must continue. If it STILL stops
inside LiveContainer specifically, that's a LiveContainer integration caveat —
fallback is installing the same IPA directly through SideStore (it signs
properly). Do not chase engine bugs for this symptom; the engine code is
correct.

---

## STEP 2 — Engine picker: order worst→best, honest labels

**Files:** `App/Sources/Services/SpeechPlayer.swift`,
`App/Sources/Views/SettingsView.swift`

User verdict on quality: **Kitten < Apple system < Kokoro < Supertonic.**

### 2a. Reorder + relabel the enum

In `SpeechPlayer.swift` (~line 8) the picker iterates
`SpeechPlayer.EngineKind.allCases`, so the DECLARED CASE ORDER is the display
order. `rawValue` is the case NAME string, so reordering cases does NOT affect
stored preferences — safe. Replace the whole enum block with:

```swift
    enum EngineKind: String, CaseIterable, Identifiable {
        // Declaration order = picker order, worst quality first (user-set).
        case kitten
        case system
        case kokoroOnnx
        case supertonic

        var id: String { rawValue }

        var label: String {
            switch self {
            case .kitten: return "Kitten — tiny, lowest quality"
            case .system: return "Apple system voice"
            case .kokoroOnnx: return "Kokoro — on-device neural, 28 voices"
            case .supertonic: return "Supertonic — best quality, multilingual"
            }
        }
    }
```

Keep every other reference to these cases in the file untouched — they switch
on `.kokoroOnnx`, `.kitten`, etc. by name, which still compiles after reorder.

### 2b. Update the Settings footer

In `SettingsView.swift`, the engine `Section` footer (~line 85) currently says
"Kokoro is the main engine (28 voices). Kitten is a smaller experimental pack
(8 voices). Supertonic adds 31 languages with 10 voices." Replace with:

```swift
                    Text("Listed worst to best. Supertonic sounds the best (10 voice styles, 31 languages). Kokoro is the solid default (28 voices). Apple's system voice beats Kitten, which is tiny and rough.")
```

### 2c. (Optional, do it) Reorder the model-download sections in Settings

`SettingsView.swift` currently orders sections: Supertonic model → Kitten
model → Kokoro model. Reorder the `Section` blocks (cut/paste whole sections)
to: **Supertonic → Kokoro → Kitten**, matching the quality order. Pure view
reordering, no logic changes.

**Commit:** `v1.1.0 step 2: engine picker ordered worst-to-best with honest quality labels`

---

## STEP 3 — Remove read-along highlighting + auto-scroll entirely

**Files:** delete `App/Sources/Views/ReadAlongTextView.swift`; edit
`App/Sources/Engine/SpeechEngine.swift`, all four engines,
`App/Sources/Services/SpeechPlayer.swift`,
`App/Sources/Views/NoteEditorView.swift`.

The highlighter is sentence-granular and drifts out of sync with the audio;
the user wants it gone. Everything `onSpokenRange`-related goes. `onProgress`
STAYS (the progress bar is wanted).

### 3a. Delete the view
```
git rm App/Sources/Views/ReadAlongTextView.swift
```
(XcodeGen globs `App/Sources`, so no project file edit is needed.)

### 3b. `SpeechEngine.swift` (~line 21)
Delete the `onSpokenRange` declaration AND its doc comment (3 lines +
property line):
```swift
    var onSpokenRange: ((Int, Int) -> Void)? { get set }
```

### 3c. Each engine
- `SystemEngine.swift`: delete `var onSpokenRange: ((Int, Int) -> Void)?`
  (~line 10) and the ENTIRE `willSpeakRangeOfSpeechString` delegate method
  (~lines 84–93, the one dispatching to `range?(characterRange.location, …)`).
- `OnnxKokoroEngine.swift`: delete `var onSpokenRange…` (~line 28) and the
  emission line `onSpokenRange?(spoken.offset, spoken.length)` (~line 381).
- `KittenEngine.swift`: same two deletions (~lines 27 and 395).
- `SupertonicEngine.swift`: same two deletions (~lines 23 and 275).
Leave the surrounding chunk bookkeeping (`spoken.offset`/`length` feed
progress too — check the nearby lines: only delete the `onSpokenRange?(…)`
call line itself, not the `let spoken = …` line if other code uses it; if
nothing else uses `spoken`, delete that too — the compiler will tell you via
an unused-variable warning, which is not an error).

### 3d. `SpeechPlayer.swift`
- Delete the `@Published private(set) var spokenRange: Range<Int>?` property
  and its comment (~lines 29–31).
- In `rebuildEngine()`'s `onStateChanged` closure, delete the line
  `self?.spokenRange = nil` (~line 227).
- Delete the whole `engine?.onSpokenRange = { … }` wiring block (~lines
  239–243).

### 3e. `NoteEditorView.swift`
- Delete `isReadAlongActive` (~lines 24–29 with its doc comment),
  the `private static let whitespace` line (~31),
  `displayText` (~lines 40–44 with comment),
  and `draftSpokenRange` (~lines 46–58 with comment).
- Replace the body's top branch (~lines 96–105):
```swift
            if isReadAlongActive {
                ReadAlongTextView(text: displayText, spokenRange: draftSpokenRange)
            } else if renderMarkdown && showPreview {
                markdownPreview
            } else {
                TextEditor(text: $draft)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .onChange(of: draft) { _ in scheduleDraftSync() }
            }
```
with:
```swift
            if renderMarkdown && showPreview {
                markdownPreview
            } else {
                TextEditor(text: $draft)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .onChange(of: draft) { _ in scheduleDraftSync() }
            }
```
From now on the editor (or preview) simply stays on screen while speaking;
`speechText` is captured when playback starts so editing mid-speech is
harmless.

**Grep gate before committing:** `grep -rn "onSpokenRange\|spokenRange\|ReadAlongTextView\|isReadAlongActive\|draftSpokenRange\|displayText" App/ Packages/` must return NOTHING.

**Commit:** `v1.1.0 step 3: remove read-along highlighter + autoscroll (inaccurate, user request)`

---

## STEP 4 — Editor top bar: one menu, editable title

**Files:** `App/Sources/Models/Note.swift`, `App/Sources/Views/NoteEditorView.swift`.

Problem: leading trash + trailing eye/share/speaker crowd out the inline
title, and the title (derived from the first line) can't be edited.

### 4a. `Note.swift` — stored, optional, user-set title (backward compatible)

Replace the whole file with:

```swift
import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// User-set title. nil (or blank) → title derives from the first line of
    /// `text`, which is how every note worked before v1.1.
    var explicitTitle: String?
    var text: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, explicitTitle, text, createdAt, updatedAt
    }

    init() {}

    /// Decodes notes.json written by older versions (no explicitTitle key)
    /// and tolerates missing fields entirely.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        explicitTitle = try c.decodeIfPresent(String.self, forKey: .explicitTitle)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    var title: String {
        if let explicit = explicitTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return String(explicit.prefix(120))
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled note" : String(trimmed.prefix(60))
    }
}
```

Why the explicit `init() {}`: declaring `init(from:)` suppresses the
compiler-synthesized initializers, and `NotesStore.createNote()` calls
`Note()`. Encoding stays synthesized. `NotesStore` needs NO changes —
`JSONEncoder`/`JSONDecoder` pick up the custom `init(from:)` automatically,
and old JSON decodes with `explicitTitle = nil`.

### 4b. `NoteEditorView.swift` — title field + single trailing menu

**Add state** (next to `@State private var draft`):
```swift
    @State private var titleDraft: String = ""
```

**onAppear** (~line 190): add `titleDraft = currentNote?.explicitTitle ?? ""`
inside the existing `guard !didLoad` block after `draft = …`.

**saveDraft()** — replace with:
```swift
    private func saveDraft() {
        guard var note = currentNote else { return }
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        guard note.text != draft || note.explicitTitle != newTitle else { return }
        note.text = draft
        note.explicitTitle = newTitle
        notes.update(note)
    }
```
(Also make `scheduleDraftSync` fire for title edits: add
`.onChange(of: titleDraft) { _ in scheduleDraftSync() }` to the title field.)

**Toolbar** — delete ALL FOUR existing `ToolbarItem`s: the leading trash
(~112–119), the trailing eye (~120–131), the trailing `exportButton` item
(~132–134), the trailing speaker (~135–141). KEEP the
`ToolbarItemGroup(placement: .keyboard)`. In their place add ONE trailing
item:

```swift
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if renderMarkdown {
                        Button {
                            Haptics.tap()
                            showPreview.toggle()
                            if !showPreview { saveDraft() }
                        } label: {
                            Label(
                                showPreview ? "Edit note" : "Preview markdown",
                                systemImage: showPreview ? "pencil.circle" : "eye.circle"
                            )
                        }
                    }
                    Button {
                        Haptics.tap()
                        player.export(speechText)
                    } label: {
                        if case .running(let progress) = player.exportState {
                            Label("Exporting… \(Int(progress * 100))%", systemImage: "square.and.arrow.up")
                        } else {
                            Label("Export WAV", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(!canExport)
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Speech settings", systemImage: "speaker.wave.2")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete note", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
```

Then DELETE the now-unused `exportButton` computed property (~lines 215–230)
— the menu renders the export state inline. Keep `canExport`,
`exportErrorMessage`, `exportErrorBinding`, `shareSheetBinding`, and the
`confirmationDialog` exactly as they are.

**Navigation title** — change `.navigationTitle(currentNote?.title ?? "Note")`
to `.navigationTitle("")` (the visible title now lives in the body; an empty
inline title keeps the back button layout calm).

**Body layout** — wrap the content so the title field sits above the editor.
Current structure is `VStack(spacing: 0) { …content…; controlsBar }`. Make it:

```swift
        VStack(spacing: 0) {
            titleField
            if renderMarkdown && showPreview {
                markdownPreview
            } else {
                TextEditor(text: $draft)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .onChange(of: draft) { _ in scheduleDraftSync() }
            }
            controlsBar
        }
```

with (shown even in preview mode — read-only there):

```swift
    /// Editable note title; blank falls back to the first-line-derived title.
    @ViewBuilder
    private var titleField: some View {
        Group {
            if renderMarkdown && showPreview {
                Text(titleDraft.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Untitled note" : titleDraft)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Title", text: $titleDraft)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .submitLabel(.done)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onChange(of: titleDraft) { _ in scheduleDraftSync() }
    }
```

**Commit:** `v1.1.0 step 4: declutter editor toolbar into one menu + editable note titles`

**Behavior notes:** list rows/search/sort keep working untouched — they read
`note.title`, which now prefers `explicitTitle`. Deleting via menu uses the
existing confirmation dialog. The keyboard bar (Speak + word stats) is
unchanged.

---

## STEP 5 — Markdown rendering: real block layout, line breaks respected

**Root cause of "collapses into one paragraph":** `NoteEditorView`'s
`markdownAttributed` calls `AttributedString(markdown: draft)` with NO
options, and the DEFAULT is `.inlineOnlyPreservingWhitespace` — block
structure (headings, lists, paragraph spacing) is never parsed. Bold/italic
work (inline), so it "renders" but reads as one dense blob. The fix is a
block-aware renderer that also treats single line breaks as visible breaks
(notes semantics — the user explicitly wants lines respected).

Three parts: a pure block parser in SpeechLogic (unit-tested in CI), a
SwiftUI preview view, and the editor swap. `MarkdownText.plainText` (speech
path) is ALREADY correct — do not touch it.

### 5a. `Packages/SpeechLogic/Sources/SpeechLogic/MarkdownText.swift`

Add inside `public enum MarkdownText` (after `plainText`, before the private
helpers) a public block model + parser:

```swift
    /// One block of a markdown document, for reading-view layout.
    public enum MarkdownBlock: Equatable {
        case heading(level: Int, text: String)
        /// May contain "\n" — single line breaks are CONTENT here.
        case paragraph(String)
        case bulletList(items: [String])
        case orderedList(items: [String])
        case quote(String)
        case code(String)
        case divider
    }

    /// Block structure for the reading view. Same scanning rules as
    /// `plainText` (fences, headings, thematic breaks, > quotes, -/*/+/ and
    /// "1." list markers) but inline syntax is left intact for the display
    /// layer to style. Consecutive non-blank lines form ONE paragraph joined
    /// by "\n" — line breaks stay visible.
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var codeLines: [String] = []
        var inFence = false

        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { result.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushLists() {
            if !bullets.isEmpty { result.append(.bulletList(items: bullets)) }
            bullets = []
            if !ordered.isEmpty { result.append(.orderedList(items: ordered)) }
            ordered = []
        }
        func flushAll() { flushParagraph(); flushQuote(); flushLists() }

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence {
                    flushAll()
                    inFence = true
                } else {
                    inFence = false
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                }
                continue
            }
            if inFence {
                codeLines.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if isThematicBreak(trimmed) {
                flushAll()
                result.append(.divider)
                continue
            }
            if let heading = stripHeading(trimmed), let level = headingLevel(trimmed) {
                flushAll()
                result.append(.heading(level: level, text: heading))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushLists()
                var line = trimmed
                while line.hasPrefix(">") {
                    line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                quote.append(line)
                continue
            }
            if let item = bulletItem(trimmed) {
                flushParagraph(); flushQuote()
                if ordered.isEmpty == false { flushLists() }
                bullets.append(item)
                continue
            }
            if let item = orderedItem(trimmed) {
                flushParagraph(); flushQuote()
                if bullets.isEmpty == false { flushLists() }
                ordered.append(item)
                continue
            }
            flushQuote(); flushLists()
            paragraph.append(trimmed)
        }
        if inFence { result.append(.code(codeLines.joined(separator: "\n"))) }
        flushAll()
        return result
    }

    /// Heading level (count of leading #'s), 1–6, else nil.
    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var count = 0
        for character in line {
            guard character == "#" else { break }
            count += 1
        }
        return (1...6).contains(count) ? count : nil
    }

    private static func bulletItem(_ line: String) -> String? {
        guard let first = line.first, first == "-" || first == "*" || first == "+",
              line.dropFirst().first == " " else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func orderedItem(_ line: String) -> String? {
        guard let match = line.range(of: #"^\d{1,9}[.)]\s+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[match.upperBound...])
    }
```

`isThematicBreak` and `stripHeading` already exist as private helpers in this
enum — reuse them, don't duplicate. Note `stripHeading` returns nil for a
non-heading line, so the `if let heading = stripHeading(trimmed), let level =`
guard is safe.

### 5b. Tests — `Packages/SpeechLogic/Tests/SpeechLogicTests/MarkdownTextTests.swift`

Append (match the existing test style):

```swift
    func testBlocksRespectSingleLineBreaks() {
        let blocks = MarkdownText.blocks("line one\nline two\n\nsecond paragraph")
        XCTAssertEqual(blocks, [
            .paragraph("line one\nline two"),
            .paragraph("second paragraph"),
        ])
    }

    func testBlocksHeadingsAndDivider() {
        let blocks = MarkdownText.blocks("# Title\n\ntext\n\n---\n\n### Sub")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("text"),
            .divider,
            .heading(level: 3, text: "Sub"),
        ])
    }

    func testBlocksGroupLists() {
        let blocks = MarkdownText.blocks("- a\n- b\n\n1. one\n2. two")
        XCTAssertEqual(blocks, [
            .bulletList(items: ["a", "b"]),
            .orderedList(items: ["one", "two"]),
        ])
    }

    func testBlocksCodeKeptVerbatim() {
        let blocks = MarkdownText.blocks("```\n**not bold**\n```")
        XCTAssertEqual(blocks, [.code("**not bold**")])
    }

    func testBlocksQuoteStripsMarkersButKeepsInlineSyntax() {
        let blocks = MarkdownText.blocks("> quoted **bold**")
        XCTAssertEqual(blocks, [.quote("quoted **bold**")])
    }
```

Run locally? You can't (Linux, Swift 5 vs their macOS runner) — CI's
`logic-tests` job runs them. Push and watch.

### 5c. New file `App/Sources/Views/MarkdownPreviewView.swift`

```swift
import SwiftUI
import SpeechLogic

/// Block-rendered markdown reading view: real heading sizes, paragraph
/// spacing, list bullets, quotes and code blocks — and single line breaks
/// stay visible (notes semantics). Inline styling (bold/italic/code/links)
/// comes from Foundation's inline markdown parser, per block.
struct MarkdownPreviewView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MarkdownText.blocks(markdown).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownText.MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 18 : 14)
                .padding(.bottom, 6)
        case .paragraph(let text):
            inlineText(text)
                .lineSpacing(4)
                .padding(.bottom, 14)
        case .bulletList(let items):
            listRows(items.map { ("•", $0) })
        case .orderedList(let items):
            listRows(items.enumerated().map { ("\($0.offset + 1).", $0.element) })
        case .quote(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.bottom, 14)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            )
            .padding(.bottom, 14)
        case .divider:
            Divider().padding(.vertical, 10)
        }
    }

    private func listRows(_ rows: [(marker: String, item: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.marker)
                        .foregroundStyle(.secondary)
                    inlineText(row.item).lineSpacing(3)
                }
            }
        }
        .padding(.bottom, 14)
    }

    /// Inline-only markdown parse — exactly what the default
    /// `AttributedString(markdown:)` does; on any parse failure the raw
    /// string shows verbatim.
    private func inlineText(_ string: String) -> Text {
        if let parsed = try? AttributedString(markdown: string) {
            return Text(parsed)
        }
        return Text(string)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        case 4: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}
```

### 5d. Wire it into `NoteEditorView`

Replace the private `markdownPreview` view (~lines 253–268, the ScrollView
holding `Text(markdownAttributed)` with its tap-to-edit gesture) with:

```swift
    private var markdownPreview: some View {
        MarkdownPreviewView(markdown: draft)
            .onTapGesture {
                Haptics.tap()
                showPreview = false
            }
    }
```

Delete the `markdownAttributed` computed property entirely (~lines 270–277)
— nothing else uses it.

**Commit:** `v1.1.0 step 5: block-rendered markdown preview (headings, spacing, respected line breaks)`

---

## STEP 6 — Version bump, CI, release

1. `project.yml` (~lines 66–67): `MARKETING_VERSION: "1.1.0"`,
   `CURRENT_PROJECT_VERSION: "20"`.
2. Commit: `v1.1.0: bump version`. Push. Watch CI:
   `./Scripts/watch_ci.sh <full-sha>` — exit 0 = green. On failure:
   `gh run view --log-failed`, fix, push, repeat. Expect the usual Swift
   paper cuts (a stray brace from a deletion, an unused variable). The
   `logic-tests` job covers the new MarkdownText tests.
3. Release:
   ```
   gh run list --limit 1                     # grab the green run id
   gh run download <run-id> -n SpeechnotesIOS -D /tmp/v110
   cd /tmp/v110 && unzip SpeechnotesIOS.zip  # → SpeechnotesIOS.ipa
   gh release create v1.1.0 --title "v1.1.0" --notes "Background playback, editable titles, decluttered editor, block-rendered markdown, engine picker ordered worst→best, read-along removed." --prerelease
   gh release upload v1.1.0 /tmp/v110/SpeechnotesIOS.ipa
   ```
   (If the artifact zip's inner filename differs, `unzip -l` first and upload
   the `.ipa`.)
4. Update the handover block at the top of
   `~/.zcode/workspace/default/SPEECHNOTES-IOS-PLAN.md`: mark v1.1.0 shipped,
   one line per change, and list the pending user-test checklist below.

## User device-test checklist (report back to the agent)

1. Play a note → switch apps / lock screen → **speech keeps playing**.
2. Open a note: top bar shows ONLY "…" on the right; title is visible and
   **editable**; edited title shows in the notes list.
3. "…" menu: Preview / Export WAV / Speech settings / Delete all work.
4. Markdown note → preview: headings sized, paragraphs spaced, **single line
   breaks visible**, lists bulleted, code blocks boxed. Not crowded.
5. During speech: NO yellow highlight, NO auto-scroll; progress bar, pause,
   stop, rate slider all still work.
6. Settings → Speech engine: order is Kitten → Apple → Kokoro → Supertonic
   with honest labels; previous engine choice survived the update.

## Guardrails (do NOT do these)

- No refactors beyond the deletions/replacements specified.
- Do not touch the engines' audio pipeline, ModelManager, CI jobs, or the
  spike packages — steps 1–5 need none of that.
- Do not reintroduce STT/translation work.
- Do not bump package pins (KokoroSwift 1.0.11 / MLX 0.30.2 /
  MLXUtilsLibrary 0.0.6 / ORT 1.24.2 / MisakiSwift 1.0.6 are frozen).
- If a step's line numbers don't match, trust the quoted anchor code over the
  numbers; if anchor code itself has drifted, re-read the file and adapt
  minimally.
