# PLAN V1.2-REAL — the actual feature release (SHIPS AS VERSION 1.3.0)

> **WHO YOU ARE:** You are the next agent working on this repo. You may be a
> less capable model than the one that wrote this plan — that is exactly why
> this file is this detailed. Follow the steps IN ORDER. Do not improvise
> architecture. Do not refactor code the steps don't touch. When CI fails,
> fix and push again — never leave the branch red.
>
> **Repo:** `~/.zcode/workspace/default/speechnotes-ios` (GitHub:
> `thesagezm/speechnotes-ios`, public). You MAY push directly (creds + `gh`
> CLI are authenticated on this PC). Build loop: edit → `git add -A && git
> commit -m "<message>" && git push` → watch CI with
> `./Scripts/watch_ci.sh <full-sha>` (run it in the background; exit 0 =
> green). If it fails: `gh run view --log-failed` or check-run annotations.
>
> **WHAT THIS RELEASE IS:** The user calls it "v1.2" but versions 1.2.0
> (withdrawn — black-screened on device), 1.2.1 and 1.2.2 are already tagged
> on the remote. Numbers must only move forward, so this feature release
> **ships as `v1.3.0`, build 24**. Do NOT reuse 1.2.x numbers.
>
> **USER-REQUESTED FEATURES (verbatim intent, 2026-08-19):**
> 1. **Recycle Bin** — deleted notes are recoverable, not gone forever.
> 2. **Visible Storage tab** — exported WAV files listed and playable in-app.
> 3. **TTS pause + resume-from-where-I-stopped** — pressing play again
>    continues from the last position instead of restarting at the beginning.
> 4. **A separate Settings tab** with sections: Speech settings; Appearance
>    (accent color, light/dark mode); Storage (clear cache, unused files,
>    deleting voices/models); Import more voices (link/show downloadable
>    ONNX-runtime TTS voices under 500 MB); About page (developer: TheSageZM).
>
> **HEAD at plan time:** `678f020` (v1.2.2), CI green, working tree has three
> uncommitted doc changes (see STEP 0).

---

## 0. HARD RULES — read before touching anything

These come from real, paid-for failures. Every one of them is documented in
`Docs/BUILD-FAILURES-V1.2.md` and the master plan handover v12.

1. **NEVER change `project.yml`'s `info.properties` block.** No orientation
   keys, no plist additions, nothing. The v1.2.0 black-screen inside
   LiveContainer was caused by TWO plist lines (landscape orientation keys).
   This release is 100% code-only. The ONLY permitted `project.yml` edit is
   the version bump in STEP E. After every step, `git diff HEAD~1 -- project.yml`
   must show either nothing or (STEP E only) version numbers.
2. **One logical change per commit, CI green between steps.** Never stack a
   metadata change and a code change in one release.
3. **Do not touch the engines' audio pipelines** (`OnnxKokoroEngine` /
   `KittenEngine` / `SupertonicEngine` scheduling, chunking, buffer code)
   except the two precisely-scoped edits in STEP B2 and STEP D4 below, which
   include exact code.
4. **Do not bump package pins.** KokoroSwift 1.0.11 / MLX 0.30.2 /
   MLXUtilsLibrary 0.0.6 / ORT 1.24.2 / MisakiSwift 1.0.6 are frozen.
5. **STT and translation are PERMANENTLY DROPPED** (user decision, twice).
6. **Read-along highlighting/autoscroll stays REMOVED** (v1.1 removal is
   user-loved).
7. **Keep every SwiftUI `body` small** — see "Type-checker survival guide"
   (section 11). The 19-failure type-checker war of v1.2.0 started with one
   big view body.
8. **Verify anchors by symbol name, not line numbers** — lines drift as steps
   complete.
9. **Do not invent download URLs.** Only URLs already proven in
   `ModelManager.swift` (in production) and the GitHub browse-links in
   Appendix A. Anything else must be `curl -I`-verified before it goes in code.
10. **Never delete or rewrite a file this plan doesn't name.** If an anchor
    doesn't match, re-read the file and adapt minimally.
11. **Do NOT restructure `NoteEditorView`'s body or containers.** v1.2.2
    (`678f020`) exists precisely because the v1.2 editor restructure
    (NavigationStack wrapper + `safeAreaInset` controls anchor) **crashed on
    note open on device** — the shipped fix was restoring the exact v1.1
    view. The controls bar occasionally floating mid-screen is a KNOWN,
    ACCEPTED issue for this release. Do not re-attempt the safeAreaInset
    "fix"; this plan adds exactly one Menu item to that file and nothing
    else (STEP B3).

---

## 1. Current architecture map (what's what, as of HEAD `678f020`)

```
speechnotes-ios/
├── project.yml                     XcodeGen spec. Generates the project + Info.plist.
│                                   MARKETING_VERSION 1.2.2 / CURRENT_PROJECT_VERSION 23.
│                                   iOS 18.0, Swift 5 mode, portrait-only plist.
├── .github/workflows/build.yml     CI ("Build IPA"): jobs = Logic tests (SpeechLogic
│                                   swift test), Kitten spike (continue-on-error),
│                                   Supertonic spike (continue-on-error), Build
│                                   unsigned IPA (the gate — must be green).
├── Scripts/watch_ci.sh             CI watcher: ./Scripts/watch_ci.sh <full-sha>, exit 0 = green
├── Packages/SpeechLogic/           Local SPM package, pure logic, CI-tested:
│                                   SentenceChunker (Chunk: text/offset/length/endOffset, UTF-16),
│                                   MarkdownText, WAVWriter
├── App/Sources/
│   ├── SpeechnotesApp.swift        @main. TabView (Notes, Logs). Injects NotesStore +
│   │                               SpeechPlayer as environmentObjects. scenePhase hook
│   │                               calls notes.flushNow() on background.
│   ├── Models/Note.swift           Note {id, explicitTitle?, text, createdAt, updatedAt}
│   │                               + custom decode (tolerates old JSON) + title derivation
│   ├── Models/VoiceCatalog.swift   Static voice descriptors for Kokoro/Kitten/Supertonic +
│   │                               Note.wordCount / estimatedListenMinutes extensions
│   ├── Services/NotesStore.swift   @MainActor ObservableObject. @Published notes array,
│   │                               JSON file Documents/notes.json, coalesced 1s saves,
│   │                               flushNow(), delete(noteId:)/delete(atOffsets:)
│   ├── Services/SpeechPlayer.swift @MainActor ObservableObject — THE playback brain.
│   │                               EngineKind enum (kitten/system/kokoroOnnx/supertonic),
│   │                               engine swapping via rebuildEngine(), togglePlay(),
│   │                               auditions, WAV export, rateMultiplier (debounced
│   │                               persistence), progress 0…1 @Published, state machine
│   ├── Services/ModelManager.swift @MainActor singleton. Downloads/validates/deletes the
│   │                               three model sets into Documents/{KokoroOnnx,Kitten,
│   │                               Supertonic}. Resumable URLSession downloads with
│   │                               .part/.resumeData/.resumeSource sidecars.
│   ├── Services/ImportService.swift .txt/.md/.pdf import + clipboard
│   ├── Services/LogStore.swift     In-app log buffer (Logs tab)
│   ├── Services/Haptics.swift      Haptics.tap/press/success/warning
│   ├── Engine/SpeechEngine.swift   Protocol: name, onStateChanged, onProgress(0…1),
│   │                               speak(_:rateMultiplier:), pause(), resume(), stop()
│   ├── Engine/OnnxKokoroEngine.swift  Kokoro on ONNX Runtime CPU. Sentence-chunked
│   │                               streaming (chunkMaxChars=160, 3 chunks ahead),
│   │                               voices.npz → voicesFlat[key+".npy"], pause pauses
│   │                               AVAudioPlayerNode, renderWAV → Documents/Exports/
│   │                               Note-<timestamp>.wav
│   ├── Engine/KittenEngine.swift   Same contract; own voices.npz; 8 voices
│   ├── Engine/SupertonicEngine.swift  Same contract; 10 styles × 31 languages
│   ├── Engine/SystemEngine.swift   AVSpeechSynthesizer. pause at .word. NEVER calls
│   │                               onProgress today (fixed in STEP B2)
│   └── Views/
│       ├── NotesListView.swift     Notes tab. Search/sort/sections/swipes/import/menu
│       ├── NoteEditorView.swift    Editor. KEEP BODY LEAN (type-checker history!)
│       ├── MiniPlayerBar.swift     safeAreaInset mini player + .miniPlayer() modifier
│       ├── SettingsView.swift      "Speech Settings" SHEET (from editor menu) — engine
│       │                           picker, voice, model download cards, system voice
│       ├── VoicePickerSheet.swift  Voice picker with auditions (scope: kokoro/kitten/
│       │                           supertonic)
│       ├── LogsView.swift, MarkdownPreviewView.swift, ShareSheet.swift
```

**Playback progress semantics (needed for STEP B):** neural engines report
`onProgress(charsScheduledSoFar / totalChars)` when a chunk is *scheduled*.
So a stored progress fraction maps to a UTF-16 character offset in the spoken
text. `SpeechPlayer` knows the full text it passed — that's all resume needs.

**Where exports go:** `Documents/Exports/Note-yyyy-MM-dd-HHmmss.wav`
(created by each engine's renderWAV; the share sheet offers it; nothing in
the UI lists them today — STEP C fixes that).

---

## STEP 0 — Commit the pending doc changes `[ ]`

`git status` shows modified `Docs/PLAN-V1.2.md`, `Docs/BUILD-FAILURES-V1.2.md`
and untracked `Docs/PLAN-RECYCLE-BIN.md`. Commit them untouched:

```
git add -A Docs && git commit -m "docs: v1.2 post-mortem updates + recycle-bin design draft"
git push && ./Scripts/watch_ci.sh <full-sha>   # docs-only, CI will be green
```

---

## STEP A — Recycle Bin (recover deleted notes) `[ ]`

Design: soft delete. `Note` gains `deletedAt: Date?`; the store keeps deleted
notes in the same array/file; the existing `notes` accessor filters them so
**every existing call site keeps working unchanged**. A "Recently Deleted"
screen lists binned notes with Recover / Delete Permanently / Empty All.
30-day retention, pruned on launch. `Docs/PLAN-RECYCLE-BIN.md` (committed in
STEP 0) is the earlier draft of this — THIS section is the authoritative,
anchor-accurate version; where they differ, follow this.

### A1. `App/Sources/Models/Note.swift` — add `deletedAt` `[ ]`

Add one stored property, one coding key, one decode line, and two helpers.
Full replacement for the file:

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
    /// Recycle bin: nil = active note; set = sitting in Recently Deleted,
    /// stamped with the moment it was binned. nil for every note decoded
    /// from pre-v1.3 JSON.
    var deletedAt: Date?

    /// How long binned notes are kept before automatic purge (iOS Notes parity).
    static let recycleRetentionDays = 30

    enum CodingKeys: String, CodingKey {
        case id, explicitTitle, text, createdAt, updatedAt, deletedAt
    }

    init() {}

    /// Decodes notes.json written by older versions (no explicitTitle /
    /// deletedAt keys) and tolerates missing fields entirely.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        explicitTitle = try c.decodeIfPresent(String.self, forKey: .explicitTitle)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
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

    /// Days left before this binned note is auto-purged (nil while active).
    var recycleDaysRemaining: Int? {
        guard let deletedAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
        return max(0, Note.recycleRetentionDays - days)
    }
}
```

(The explicit `CodingKeys` + `init(from:)` already existed for
backward-compat — this keeps that pattern.)

### A2. `App/Sources/Services/NotesStore.swift` — soft delete + recovery `[ ]`

Full replacement for the file. The key trick: the published array becomes
`allNotes` (including binned notes) and `notes` becomes a computed property
that filters — SwiftUI still re-renders correctly because mutating `allNotes`
fires `objectWillChange`, and every existing `notes.notes` call site (search,
sort, `currentNote`, `jumpToPlayingNote`, empty states) now simply never sees
deleted notes.

```swift
import Foundation

/// Holds all notes in memory and persists them as one JSON file in Documents.
/// Deleted notes are kept (flagged `deletedAt`) for Note.recycleRetentionDays
/// so the user can recover them from the Recently Deleted screen.
@MainActor
final class NotesStore: ObservableObject {
    /// Everything, including notes sitting in the recycle bin.
    @Published private(set) var allNotes: [Note] = []

    /// Active notes only — what the whole UI already reads as `notes.notes`.
    var notes: [Note] { allNotes.filter { $0.deletedAt == nil } }

    /// Binned notes, most recently deleted first.
    var deletedNotes: [Note] {
        allNotes
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("notes.json")
    }

    init() {
        load()
        pruneExpiredDeleted()
        Log.shared.info("NotesStore ready with \(notes.count) note(s), \(deletedNotes.count) in recycle bin")
    }

    @discardableResult
    func createNote() -> Note {
        let note = Note()
        allNotes.insert(note, at: 0)
        save()
        return note
    }

    func update(_ note: Note) {
        guard let index = allNotes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.updatedAt = Date()
        allNotes[index] = updated
        scheduleSave()
    }

    func delete(at offsets: IndexSet) {
        // Soft delete: resolve offsets against the CURRENT visible array.
        for index in offsets {
            guard index < allNotes.count else { continue }
            softDelete(noteId: allNotes[index].id)
        }
        save()
    }

    /// Soft-deletes by identity — the editor's delete button and the list's
    /// swipe action both land here. The note moves to Recently Deleted.
    func delete(noteId: UUID) {
        softDelete(noteId: noteId)
        save()
    }

    private func softDelete(noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }) else { return }
        guard allNotes[index].deletedAt == nil else { return } // already binned
        allNotes[index].deletedAt = Date()
    }

    /// Moves a binned note back into the active list, timestamps preserved.
    func recover(noteId: UUID) {
        guard let index = allNotes.firstIndex(where: { $0.id == noteId }),
              allNotes[index].deletedAt != nil else { return }
        allNotes[index].deletedAt = nil
        allNotes[index].updatedAt = Date()
        save()
    }

    /// Really deletes one binned note. No undo.
    func purge(noteId: UUID) {
        allNotes.removeAll { $0.id == noteId }
        save()
    }

    /// Really deletes every binned note. No undo.
    func emptyRecycleBin() {
        allNotes.removeAll { $0.deletedAt != nil }
        save()
    }

    /// Drops binned notes older than the retention window. Called once from
    /// init — good enough, no timer.
    private func pruneExpiredDeleted() {
        let cutoff = Date().addingTimeInterval(-Double(Note.recycleRetentionDays) * 24 * 3600)
        let before = allNotes.count
        allNotes.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
        if allNotes.count != before { save() }
    }

    // MARK: - Persistence

    /// Typing fires update() on every keystroke; encoding the whole store to
    /// JSON synchronously each keypress made the editor laggy on device.
    /// Disk writes are coalesced: one save, a second after the last change.
    private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Persists immediately, cancelling any pending coalesced save. Call when
    /// leaving the editor or entering the background — anything that could
    /// kill the process within the debounce window.
    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(allNotes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.shared.error("Failed to save notes: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            allNotes = try JSONDecoder().decode([Note].self, from: try Data(contentsOf: fileURL))
        } catch {
            Log.shared.error("Failed to load notes: \(error)")
        }
    }
}
```

Notes for the implementer:
- `Note.recycleRetentionDays` referenced before its declaration order in file
  is fine in Swift.
- Old JSON decodes with `deletedAt = nil` everywhere → zero migration.
- The editor's delete flow (`showingDeleteConfirm` → `notes.delete(noteId:)`)
  and the list swipe/onDelete flows now soft-delete automatically — no view
  changes needed for the delete path itself.

**Commit:** `v1.3.0 step A1+A2: soft-delete notes — Note.deletedAt + NotesStore recycle bin (recover/purge/empty/30-day prune)`

### A3. New file `App/Sources/Views/RecycleBinView.swift` `[ ]`

```swift
import SwiftUI

/// Recently Deleted: binned notes with recover / delete-permanently /
/// empty-all. Pushed onto the notes list's navigation stack.
struct RecycleBinView: View {
    @EnvironmentObject private var notes: NotesStore
    @State private var showingEmptyConfirm = false

    var body: some View {
        Group {
            if notes.deletedNotes.isEmpty {
                ContentUnavailableView(
                    "Recycle bin is empty",
                    systemImage: "trash.slash",
                    description: Text("Deleted notes stay here for \(Note.recycleRetentionDays) days before they're removed for good.")
                )
            } else {
                binList
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !notes.deletedNotes.isEmpty {
                    Button("Empty", role: .destructive) { showingEmptyConfirm = true }
                }
            }
        }
        .confirmationDialog(
            "Permanently delete all \(notes.deletedNotes.count) notes?",
            isPresented: $showingEmptyConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                notes.emptyRecycleBin()
                Haptics.press()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var binList: some View {
        List {
            ForEach(notes.deletedNotes) { note in
                binRow(note)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            notes.recover(noteId: note.id)
                            Haptics.success()
                        } label: {
                            Label("Recover", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            notes.purge(noteId: note.id)
                        } label: {
                            Label("Delete Now", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func binRow(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(.headline)
            Text(note.text.split(whereSeparator: \.isNewline).dropFirst()
                .joined(separator: " ").prefix(90))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let deletedAt = note.deletedAt {
                Text("Deleted \(deletedAt, format: .relative(presentation: .named)) · \(note.recycleDaysRemaining ?? 0) days left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
```

### A4. `App/Sources/Views/NotesListView.swift` — entry point `[ ]`

Three small edits (use symbol anchors, not line numbers):

1. Next to the other `@State` declarations add:
   ```swift
   @State private var showingRecycleBin = false
   ```
2. Inside `sortAndImportMenu`'s `Menu { … }`, after the "Import from Files…"
   button and before the clipboard `if`, add:
   ```swift
   Divider()
   Button {
       showingRecycleBin = true
   } label: {
       Label(
           "Recently Deleted\(!notes.deletedNotes.isEmpty ? " (\(notes.deletedNotes.count))" : "")",
           systemImage: "trash"
       )
   }
   ```
3. Attach a destination inside the `NavigationStack`, on the same `Group`
   that carries `.navigationDestination(for: UUID.self)` (one
   `navigationDestination(isPresented:)` alongside the existing
   value-based one is fine — they are different modifiers):
   ```swift
   .navigationDestination(isPresented: $showingRecycleBin) {
       RecycleBinView()
   }
   ```
   Do NOT add another `.sheet` — this project already hit the
   two-sheets-on-one-node SwiftUI trap (see the comment above the
   `sharingNote` sheet in this file).

**Commit:** `v1.3.0 step A3+A4: Recently Deleted screen + list menu entry`

### A5. Device test checklist for STEP A `[ ]`
- Swipe-delete a note → disappears from list, "Recently Deleted (1)" in menu.
- Recover via swipe → back in list, content + createdAt intact.
- Delete Now via swipe → gone from bin and list.
- Empty → confirmation → bin empties.
- Editor "…" → Delete note → lands in bin (not destroyed).
- Kill app, relaunch → bin contents survive; a note binned >30 days ago is
  gone (can't easily test 30 days — trust `pruneExpiredDeleted`, unit-eyeball
  the log line on launch).
- Search does NOT surface binned notes.

---

## STEP B — Pause/resume playback from where you stopped `[ ]`

**What exists today:** in-session pause/resume works (the play button
toggles pause; engines pause mid-audio). What does NOT exist: press stop (or
leave the note, or kill the app) → press play → **playback restarts from the
beginning**. That restart is the user's complaint.

**Design (engine-agnostic, zero changes to engine scheduling):**
- While a note speaks, `SpeechPlayer` tracks how many UTF-16 chars of the
  full text have been scheduled (it already receives chunk-granular
  progress; chars = progress × text length).
- On pause/stop/background/idle-mid-note it persists ONE bookmark (single
  UserDefaults slot): note id, chars done, text length, a STABLE hash of the
  text (Swift's `String.hashValue` is seeded per process — do NOT use it),
  and a timestamp.
- On play from idle, if the bookmark matches this note AND the text is
  unchanged AND the position is meaningful (≥40 chars in, not at the end),
  speech starts from the suffix beginning at the last sentence boundary
  at-or-before the saved offset — i.e. the interrupted sentence is re-spoken.
- The published progress bar is remapped so a resumed session's progress
  starts at the resume fraction and still reaches 100% at the true end.
- Reaching the end of a note clears the bookmark. Editing the text makes the
  hash mismatch → normal full playback (and the bookmark is overwritten).
- A "Restart from beginning" item appears in the editor's "…" menu whenever a
  resumable bookmark exists.
- Single-slot bookmark = no cleanup needed when notes are purged: a stale
  entry can never match a different note and is overwritten on next speak.

### B1. `App/Sources/Services/SpeechPlayer.swift` — bookmark + resume `[ ]`

Add these members near the other private state (below `preAuditionState`):

```swift
    // MARK: - Playback resume bookmark

    struct PlaybackBookmark: Codable {
        let noteId: UUID
        let charsDone: Int
        let textLength: Int
        let textHash: Int64
        let savedAt: Date
    }

    private static let bookmarkKey = "playbackBookmark"
    /// Set at speak start when a real note is playing; updated per tick.
    private var inFlightBookmark: PlaybackBookmark?
    /// Raw engine progress of the CURRENT speak call (0…1 over the text that
    /// was actually passed to the engine, which on a resume is the suffix).
    private var lastRawProgress: Double = 0
    /// Fraction of the full text already spoken when this speak call is a
    /// resume; published progress is remapped through this.
    private var resumeBaseFraction: Double = 0

    /// Stable (process-independent) hash — String.hashValue is seeded per
    /// launch and would invalidate bookmarks across restarts.
    nonisolated static func stableHash(_ s: String) -> Int64 {
        var h: Int64 = 5381
        for scalar in s.unicodeScalars {
            h = (h &* 33 &+ Int64(scalar.value)) & 0x7FFF_FFFF_FFFF_FFFF
        }
        return h
    }

    /// UTF-16 offset of the last sentence boundary at-or-before charsDone —
    /// resume re-speaks the interrupted sentence from its start.
    nonisolated static func resumeOffset(in text: String, charsDone: Int) -> Int {
        let units = Array(text.utf16)
        guard charsDone > 0, charsDone < units.count else { return -1 }
        let terminators: Set<UTF16.CodeUnit> = [
            UInt16(ascii: "."), UInt16(ascii: "!"), UInt16(ascii: "?"),
            UInt16(ascii: "\n"), 0x2026, 0x3002, 0xFF01, 0xFF1F, // … 。 ！ ？
        ]
        var i = min(charsDone, units.count - 1)
        while i > 0 {
            if terminators.contains(units[i]) { return i + 1 }
            i -= 1
        }
        return 0
    }

    /// Loads the stored bookmark if it's for this note, this exact text,
    /// recent (<30 days), and at a meaningful position.
    private func resumePlan(for noteId: UUID, fullText: String) -> (offset: Int, suffix: String)? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey),
              let mark = try? JSONDecoder().decode(PlaybackBookmark.self, from: data)
        else { return nil }
        let length = fullText.utf16.count
        guard mark.noteId == noteId,
              mark.textLength == length,
              mark.textHash == Self.stableHash(fullText),
              Date().timeIntervalSince(mark.savedAt) < 30 * 24 * 3600,
              mark.charsDone >= 40,
              mark.charsDone < length
        else { return nil }
        let offset = Self.resumeOffset(in: fullText, charsDone: mark.charsDone)
        guard offset > 0, offset < length else { return nil }
        let suffix = String(decoding: Array(fullText.utf16[offset...]), as: UTF16.self)
        guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (offset, suffix)
    }

    /// True when the editor should show "Restart from beginning".
    func hasResumeOption(for noteId: UUID, text: String) -> Bool {
        resumePlan(for: noteId, fullText: text) != nil
    }

    /// Call on background/suspension — the app hook already exists in
    /// SpeechnotesApp (scenePhase); STEP D3 wires this in.
    func persistPlaybackBookmark() {
        guard let mark = inFlightBookmark else { return }
        if let data = try? JSONEncoder().encode(mark) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    private func clearBookmark() {
        inFlightBookmark = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    /// Stop + speak the full text from the start, clearing any bookmark.
    func restartFromBeginning(_ text: String, note: Note?) {
        clearBookmark()
        stop()
        nowPlayingTitle = note?.title
        nowPlayingNoteId = note?.id
        resumeBaseFraction = 0
        lastRawProgress = 0
        if let note { primeBookmark(noteId: note.id, fullText: text) }
        engine?.speak(text, rateMultiplier: rateMultiplier)
    }

    private func primeBookmark(noteId: UUID, fullText: String) {
        inFlightBookmark = PlaybackBookmark(
            noteId: noteId,
            charsDone: 0,
            textLength: fullText.utf16.count,
            textHash: Self.stableHash(fullText),
            savedAt: Date()
        )
    }
```

Then THREE edits to existing code:

**(1) `togglePlay` — idle branch becomes resume-aware.** Replace the
existing `case .idle:` body (`nowPlayingTitle = note?.title` …
`engine?.speak(text, rateMultiplier: rateMultiplier)`) with:

```swift
        case .idle:
            nowPlayingTitle = note?.title
            nowPlayingNoteId = note?.id
            resumeBaseFraction = 0
            lastRawProgress = 0
            if let note {
                primeBookmark(noteId: note.id, fullText: text)
                if let plan = resumePlan(for: note.id, fullText: text) {
                    resumeBaseFraction = Double(plan.offset) / Double(max(1, text.utf16.count))
                    Log.shared.info("SpeechPlayer: resuming note at char \(plan.offset)/\(text.utf16.count)")
                    engine?.speak(plan.suffix, rateMultiplier: rateMultiplier)
                    return
                }
            }
            engine?.speak(text, rateMultiplier: rateMultiplier)
```

Note: `primeBookmark` is called before `resumePlan` deliberately — a fresh
bookmark object will be updated by ticks and eventually overwrite the stored
one (with the same content) if the user stops again.

**(2) `rebuildEngine` — remap progress + track chars + clear-on-finish.**
Replace the existing `engine?.onProgress` and the `if newState == .idle`
block inside `engine?.onStateChanged` with:

```swift
        engine?.onProgress = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.lastRawProgress = value
                let mapped = self.resumeBaseFraction
                    + (1 - self.resumeBaseFraction) * value
                self.progress = value > 0 ? min(1.0, mapped) : nil
                self.updateBookmarkChars(rawProgress: value)
            }
        }
```

and inside `onStateChanged`, replace `if newState == .idle { … }` with:

```swift
                if newState == .idle {
                    if self?.lastRawProgress >= 0.98 {
                        self?.clearBookmark()            // finished naturally
                    } else if self?.inFlightBookmark != nil {
                        self?.persistPlaybackBookmark()  // stopped part-way
                    }
                    self?.lastRawProgress = 0
                    self?.resumeBaseFraction = 0
                    self?.nowPlayingTitle = nil
                    self?.nowPlayingNoteId = nil
                    self?.finishAuditionIfActive()
                }
```

Add the tick helper next to the bookmark code:

```swift
    /// Raw engine progress maps back to absolute chars: on a resume the
    /// engine only ever saw the suffix.
    private func updateBookmarkChars(rawProgress: Double) {
        guard var mark = inFlightBookmark else { return }
        let suffixLength = max(1, mark.textLength - Int(Double(mark.textLength) * resumeBaseFraction))
        mark.charsDone = min(mark.textLength - 1,
                             Int((resumeBaseFraction * Double(mark.textLength))
                                 + rawProgress * Double(suffixLength)))
        mark.savedAt = Date()
        inFlightBookmark = mark
    }
```

**(3) `stop()` — keep the bookmark (stopping mid-note is exactly the case
the user wants to resume from). `engine?.stop()` alone stays as-is; do not
clear anything there.** The `.idle` state callback handles persistence.

Also add `import SpeechLogic` is NOT needed — resume uses no SpeechLogic
types (UTF-16 scan is local). Keep imports as they are.

### B2. `App/Sources/Engine/SystemEngine.swift` — report progress `[ ]`

The system engine never calls `onProgress`, so system-voice playback would
never build a bookmark. Add the delegate method inside the existing
`extension SystemEngine: AVSpeechSynthesizerDelegate` (it fires before each
spoken word-range; location+length ≈ chars spoken so far):

```swift
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let total = (utterance.speechString as NSString).length
        guard total > 0, characterRange.location + characterRange.length > 0 else { return }
        let fraction = Double(characterRange.location + characterRange.length) / Double(total)
        DispatchQueue.main.async { self.onProgress?(min(1.0, fraction)) }
    }
```

This is the ONLY engine-pipeline edit in STEP B. Neural engines already
report progress.

**Commit:** `v1.3.0 step B: persistent playback position — resume notes from where you stopped (SpeechPlayer bookmark + SystemEngine progress)`

### B3. `App/Sources/Views/NoteEditorView.swift` — Restart menu item `[ ]`

One addition inside the existing `Menu { … }` in the toolbar (after the
"Speech settings" button, before `Divider()`):

```swift
                    if player.hasResumeOption(for: noteId, text: speechText) {
                        Button {
                            Haptics.tap()
                            player.restartFromBeginning(speechText, note: currentNote)
                        } label: {
                            Label("Restart from beginning", systemImage: "gobackward")
                        }
                    }
```

Nothing else in this file changes — **keep this view's body lean**
(section 11). The play button already calls `togglePlay`, which now resumes
automatically.

**Commit:** `v1.3.0 step B3: editor 'Restart from beginning' menu item`

### B4. Device test checklist for STEP B `[ ]`
- Long note, play 30s, stop, press play → continues from the interrupted
  sentence (heard once already), progress bar starts around the old position
  and still reaches 100%.
- Pause → leave note → come back → play → resumes (pause state itself was
  already fine; this checks the bookmark persisted through the stop).
- Play to the very end → play again → starts from the beginning (bookmark
  cleared).
- Edit the text between stops → play → starts from the beginning (hash
  mismatch), no crash.
- Kill the app mid-playback, relaunch, open the note, play → resumes
  (bookmark persisted via the scenePhase hook wired in STEP D3; before D3,
  test stop-based resume only).
- System engine (Apple voice): same resume behavior now works.
- "Restart from beginning" appears when resumable, replays from 0.

---

## STEP C — Storage tab: exported WAVs, visible and playable `[ ]`

### C1. New file `App/Sources/Services/ExportsStore.swift` `[ ]`

```swift
import Foundation
import AVFoundation

struct ExportedAudio: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let sizeBytes: Int64
    let createdAt: Date
    var duration: TimeInterval?

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Scans Documents/Exports (written by the engines' renderWAV) and provides
/// delete/clear + storage-size helpers for the Storage tab.
@MainActor
final class ExportsStore: ObservableObject {
    @Published private(set) var exports: [ExportedAudio] = []

    static var exportsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports")
    }

    init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.exportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        var items: [ExportedAudio] = []
        for url in files where url.pathExtension.lowercased() == "wav" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            items.append(ExportedAudio(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                sizeBytes: Int64(values?.fileSize ?? 0),
                createdAt: values?.contentModificationDate ?? .distantPast,
                duration: nil
            ))
        }
        exports = items.sorted { $0.createdAt > $1.createdAt }
        loadDurations()
    }

    /// WAV header parse is cheap but not free — off-main, patch back in.
    private func loadDurations() {
        let snapshot = exports
        Task.detached(priority: .utility) { [weak self] in
            var durations: [URL: TimeInterval] = [:]
            for item in snapshot {
                if let player = try? AVAudioPlayer(contentsOf: item.url) {
                    durations[item.url] = player.duration
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.exports = self.exports.map {
                    var copy = $0
                    copy.duration = durations[$0.url]
                    return copy
                }
            }
        }
    }

    func delete(_ item: ExportedAudio) {
        try? FileManager.default.removeItem(at: item.url)
        exports.removeAll { $0.url == item.url }
    }

    /// Returns bytes freed (for the confirmation toast/log).
    @discardableResult
    func deleteAll() -> Int64 {
        let freed = totalBytes
        try? FileManager.default.removeItem(at: Self.exportsDirectory)
        exports = []
        return freed
    }

    var totalBytes: Int64 {
        exports.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Storage helpers (shared with Settings → Storage)

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Removes *.part / *.resumeData / *.resumeSource leftovers anywhere
    /// under Documents plus tmp contents. Returns bytes freed.
    nonisolated static func clearTemporaryFiles() -> Int64 {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var targets: [URL] = []
        if let dirs = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for dir in dirs {
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                targets += files.filter {
                    ["part", "resumeData", "resumeSource"].contains($0.pathExtension)
                }
            }
        }
        let tmp = fm.temporaryDirectory
        if let files = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            targets += files.map { tmp.appendingPathComponent($0.lastPathComponent) }
        }
        var freed: Int64 = 0
        for url in targets {
            freed += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? fm.removeItem(at: url)
        }
        return freed
    }
}
```

### C2. New file `App/Sources/Services/WavPlayer.swift` `[ ]`

Simple file player for exported audio — deliberately separate from the TTS
engines. Stop the SpeechPlayer before use (the view does that).

```swift
import Foundation
import AVFoundation

/// Plays exported WAV files. One file at a time; toggle play/pause; a 2 Hz
/// timer drives the published progress.
@MainActor
final class WavPlayer: ObservableObject {
    @Published private(set) var playingURL: URL?
    @Published private(set) var isPaused = false
    @Published private(set) var progress: Double?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func toggle(_ url: URL) {
        if playingURL == url {
            if isPaused { resume() } else { pause() }
            return
        }
        play(url)
    }

    private func play(_ url: URL) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
            playingURL = url
            isPaused = false
            startTicker()
        } catch {
            Log.shared.error("WavPlayer: failed to open \(url.lastPathComponent): \(error)")
        }
    }

    func pause() {
        player?.pause()
        isPaused = true
    }

    func resume() {
        player?.play()
        isPaused = false
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        isPaused = false
        progress = nil
        ticker?.invalidate()
        ticker = nil
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : nil
                if !player.isPlaying && !self.isPaused { self.stop() } // reached end
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}
```

### C3. New file `App/Sources/Views/StorageView.swift` `[ ]`

The Storage TAB. Body deliberately split into small subviews (section 11).

```swift
import SwiftUI

/// Storage tab: every exported WAV (playable in-app, shareable, deletable)
/// plus a storage-usage breakdown.
struct StorageView: View {
    @StateObject private var exports = ExportsStore()
    @StateObject private var wavPlayer = WavPlayer()
    @EnvironmentObject private var player: SpeechPlayer
    @State private var sharingURL: URL?

    var body: some View {
        NavigationStack {
            List {
                exportsSection
                usageSection
            }
            .navigationTitle("Storage")
            .refreshable { exports.refresh() }
            .onAppear { exports.refresh() }
            .sheet(item: $sharingURL) { url in
                ShareSheet(items: [url])
            }
        }
        .miniPlayer(visible: false, onTap: nil)
        .onDisappear { wavPlayer.stop() }
    }

    // MARK: - Exported audio

    private var exportsSection: some View {
        Section {
            if exports.exports.isEmpty {
                Label(
                    "No exports yet — use 'Export WAV' in a note's … menu.",
                    systemImage: "waveform"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                ForEach(exports.exports) { item in
                    exportRow(item)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                wavPlayer.stop()
                                exports.delete(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                sharingURL = item.url
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.indigo)
                        }
                }
            }
        } header: {
            Text("Exported audio")
        } footer: {
            if !exports.exports.isEmpty {
                Text("\(exports.exports.count) file(s) · \(ByteCountFormatter.string(fromByteCount: exports.totalBytes, countStyle: .file))")
            }
        }
    }

    private func exportRow(_ item: ExportedAudio) -> some View {
        Button {
            Haptics.tap()
            player.stop()            // TTS and WAV playback never overlap
            wavPlayer.toggle(item.url)
        } label: {
            HStack(spacing: 12) {
                playBadge(for: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(metaLine(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func playBadge(for item: ExportedAudio) -> some View {
        let isThis = wavPlayer.playingURL == item.url
        return ZStack {
            Circle()
                .fill(isThis ? Color.accentColor : Color.secondary.opacity(0.15))
            Image(systemName: isThis && !wavPlayer.isPaused ? "pause.fill" : "play.fill")
                .font(.footnote.bold())
                .foregroundStyle(isThis ? .white : .secondary)
        }
        .frame(width: 36, height: 36)
    }

    private func metaLine(for item: ExportedAudio) -> String {
        var parts = [item.createdAt.formatted(date: .abbreviated, time: .shortened), item.sizeLabel]
        if let duration = item.duration {
            parts.append(String(format: "%.0f:%02.0f", duration / 60, duration.truncatingRemainder(dividingBy: 60)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Usage breakdown

    private var usageSection: some View {
        Section {
            usageRow("Notes (notes.json)", NotesStoreSizeReader.notesBytes)
            usageRow("Kokoro model", ExportsStore.directorySize(ModelManager.onnxDirectory))
            usageRow("Kitten model", ExportsStore.directorySize(ModelManager.kittenDirectory))
            usageRow("Supertonic model", ExportsStore.directorySize(ModelManager.supertonicDirectory))
            usageRow("Exported audio", ExportsStore.directorySize(ExportsStore.exportsDirectory))
        } header: {
            Text("Storage used")
        } footer: {
            Text("Delete voice models in Settings → Storage. Everything is stored on-device; nothing is uploaded.")
        }
    }

    private func usageRow(_ label: String, _ bytes: Int64) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

/// Tiny helper so the view body doesn't do file IO inline.
private enum NotesStoreSizeReader {
    static var notesBytes: Int64 {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notes.json")
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
```

(`URL` conforms to `Identifiable` via `id = absoluteString`? — NO, it does
not. `sheet(item:)` needs Identifiable: add at the bottom of
StorageView.swift:

```swift
extension URL: Identifiable {
    public var id: String { absoluteString }
}
```

If the compiler complains that URL already conforms (a future SDK change),
delete the extension and key the sheet on a wrapper struct instead.)

### C4. `App/Sources/SpeechnotesApp.swift` — add the Storage tab `[ ]`

This file is fully rewritten in STEP D3 (settings tab + theme). To keep
commits honest, make the MINIMAL edit here: inside the `TabView { }`, between
`NotesListView()` and `LogsView()`:

```swift
                StorageView()
                    .tabItem { Label("Storage", systemImage: "internaldrive") }
```

**Commit:** `v1.3.0 step C: Storage tab — exported WAV browser with in-app playback, share, delete + storage usage breakdown`

### C5. Device test checklist for STEP C `[ ]`
- Export a WAV from a note (…" menu → Export WAV) → Storage tab lists it
  (name, date, size, duration after a beat).
- Tap row → plays; tap again → pauses; tap again → resumes the WAV (AVAudioPlayer
  resumes natively — this is file playback, unrelated to STEP B).
- Playing TTS then tapping a WAV stops TTS first; starting TTS while a WAV
  plays should also stop the WAV (verify; if not, the editor's play already
  calls engine speak which takes the session — acceptable for v1.3, note it).
- Swipe share → share sheet with the file; swipe delete → gone, footer count
  updates. Pull-to-refresh works.
- Usage rows show sensible sizes after downloading a model.
- Tab bar: Notes · Storage · Logs (Settings joins in STEP D).

---

## STEP D — Settings tab: Speech / Appearance / Storage / Import voices / About `[ ]`

### D1. New file `App/Sources/Services/AppTheme.swift` — accent + appearance `[ ]`

```swift
import SwiftUI

/// The user-chosen accent color (Settings → Appearance), stored by name in
/// UserDefaults ("accentColorName"). `Color.accentColor` still returns the
/// ASSET color regardless of .tint(), so gradients read from here instead.
enum AccentPalette {
    static let names: [(name: String, color: Color)] = [
        ("blue", .blue), ("purple", .purple), ("pink", .pink),
        ("red", .red), ("orange", .orange), ("green", .green),
        ("teal", .teal), ("mint", .mint), ("indigo", .indigo),
    ]

    static let defaultName = "blue"

    static func color(named name: String?) -> Color {
        names.first { $0.name == name }?.color ?? .blue
    }
}

enum AppTheme {
    /// Live accent (reads the preference each call — cheap).
    static var accent: Color {
        AccentPalette.color(named: UserDefaults.standard.string(forKey: "accentColorName"))
    }

    /// The play-button / progress gradient, tinted by the chosen accent.
    static func playGradient(start: UnitPoint = .topLeading, end: UnitPoint = .bottomTrailing) -> LinearGradient {
        LinearGradient(colors: [accent, accent.opacity(0.65)], startPoint: start, endPoint: end)
    }

    /// "system" | "light" | "dark" → ColorScheme?
    static func colorScheme(for preference: String?) -> ColorScheme? {
        switch preference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
```

Then replace the hardcoded gradients so the accent reaches them — FOUR
one-line sites, nothing else in those files:

- `NoteEditorView.swift` → `controlsBar` play button:
  `LinearGradient(colors: [.accentColor, .purple], …)` → `AppTheme.playGradient()`
- `NoteEditorView.swift` → `controlsBar` progress capsule:
  `LinearGradient(colors: [.accentColor, .purple], startPoint: .leading, endPoint: .trailing)` →
  `AppTheme.playGradient(start: .leading, end: .trailing)`
- `MiniPlayerBar.swift` → play button circle → `AppTheme.playGradient()`
- `MiniPlayerBar.swift` → progress strip → `AppTheme.playGradient(start: .leading, end: .trailing)`

### D2. `App/Sources/Views/SettingsView.swift` — restructure into sections `[ ]`

Target section order in the `Form` (this is a REORGANISATION of existing
code plus three new sections — copy existing blocks, don't rewrite them):

1. **APPEARANCE (new)** — see code below.
2. **Notes** — the existing "Render Markdown" section, unchanged.
3. **Speech** — the existing "Speech engine" section (engine picker +
   missing-model label), the existing voice-picker section, and the existing
   "System voice" section. Header "Speech".
4. **STORAGE** — the three existing model cards (Supertonic model / Kokoro
   model / Kitten model — download/progress/retry/delete rows) MOVE here
   unchanged, plus the new maintenance rows below.
5. **IMPORT VOICES (new)** — one row pushing `VoiceImportView`.
6. **ABOUT (new)** — see code below.

Add an `embedded` flag so the same view serves as tab root AND as the
editor's sheet:

```swift
struct SettingsView: View {
    /// true = presented as the editor's sheet (Done button shown);
    /// false = used as the Settings tab root.
    var embedded = true
    …
```

and wrap the Done item:

```swift
            .toolbar {
                if embedded {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
```

(Existing call sites `SettingsView()` keep the Done button — no edit needed
in NoteEditorView.)

New sections' code:

```swift
                // Appearance
                Section {
                    Picker("Appearance", selection: $appearancePreference) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)

                    accentSwatches
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Accent color tints buttons, sliders and the player. Appearance overrides the system light/dark setting for this app.")
                }
```

with the state + swatch row (keep the swatch row a separate subview):

```swift
    @AppStorage("appearancePreference") private var appearancePreference = "system"
    @AppStorage("accentColorName") private var accentName = AccentPalette.defaultName

    private var accentSwatches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accent color").font(.subheadline)
            HStack(spacing: 10) {
                ForEach(AccentPalette.names, id: \.name) { entry in
                    Button {
                        accentName = entry.name
                        Haptics.tap()
                    } label: {
                        ZStack {
                            Circle().fill(entry.color).frame(width: 30, height: 30)
                            if accentName == entry.name {
                                Circle().strokeBorder(.white, lineWidth: 2).frame(width: 30, height: 30)
                                Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 1).frame(width: 34, height: 34)
                                Image(systemName: "checkmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.name.capitalized)
                }
            }
        }
        .padding(.vertical, 2)
    }
```

Storage maintenance rows (append inside the Storage section, after the three
model cards):

```swift
                    Button(role: .destructive) {
                        showingClearExportsConfirm = true
                    } label: {
                        Label("Clear exported audio", systemImage: "waveform.slash")
                    }
                    .disabled(exportsTotalBytes == 0)

                    Button {
                        let freed = ExportsStore.clearTemporaryFiles()
                        Log.shared.info("Settings: cleared temporary files (\(freed) bytes)")
                        Haptics.success()
                    } label: {
                        Label("Clear temporary & unused files", systemImage: "broom")
                    }
```

with:

```swift
    @State private var showingClearExportsConfirm = false
    @State private var exportsTotalBytes: Int64 = 0
```

(and in `.onAppear`: `exportsTotalBytes = ExportsStore.directorySize(ExportsStore.exportsDirectory)`;
attach a `.confirmationDialog` for "Delete all exported audio
(ByteCountFormatter…)" → `ExportsStore().deleteAll()` — creating a temp
store instance is fine for a one-shot delete, or hoist a `@StateObject`.)
Simplest: make it `@StateObject private var exportsStore = ExportsStore()`
and use `exportsStore.totalBytes` / `exportsStore.deleteAll()` directly —
then no dialog-size staleness.

About section:

```swift
                Section {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Developer", value: "TheSageZM")
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/thesagezm/speechnotes-ios")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Speechnotes — an offline text-to-speech notes app. Built with Kokoro (Apache-2.0), KittenTTS, Supertone supertonic-3, ONNX Runtime, KokoroSwift and Misaki. All speech generation happens on this device.")
                }
```

with `private var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")" }`

`LabeledContent` is iOS 16+ — fine on iOS 18 target.

**Commit:** `v1.3.0 step D1+D2: appearance (accent + light/dark) and about; settings reorganised into speech/appearance/storage sections`

### D3. `App/Sources/SpeechnotesApp.swift` — Settings tab + theme at root `[ ]`

Full replacement (adds: RootView wrapper so @AppStorage drives `.tint` +
`.preferredColorScheme`, Settings tab, bookmark persistence on background):

```swift
import SwiftUI

@main
struct SpeechnotesApp: App {
    @StateObject private var notes = NotesStore()
    @StateObject private var player = SpeechPlayer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(notes)
                .environmentObject(player)
                // Saves are coalesced in NotesStore; the second the app could
                // be suspended is the one moment a pending write must not be
                // lost. Same moment persists the playback bookmark (STEP B).
                .onChange(of: scenePhase) { phase in
                    if phase != .active {
                        notes.flushNow()
                        player.persistPlaybackBookmark()
                    }
                }
        }
    }
}

/// Tab root, wrapped so accent/appearance @AppStorage values re-render it.
private struct RootView: View {
    @AppStorage("accentColorName") private var accentName = AccentPalette.defaultName
    @AppStorage("appearancePreference") private var appearancePreference = "system"

    var body: some View {
        TabView {
            NotesListView()
                .tabItem { Label("Notes", systemImage: "note.text") }
            StorageView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            SettingsView(embedded: false)
                .tabItem { Label("Settings", systemImage: "gearshape") }
            LogsView()
                .tabItem { Label("Logs", systemImage: "ladybug") }
        }
        .tint(AccentPalette.color(named: accentName))
        .preferredColorScheme(AppTheme.colorScheme(for: appearancePreference))
    }
}
```

**Commit:** `v1.3.0 step D3: Settings tab + root accent/appearance theming + bookmark persistence on background`

### D4. Import more voices `[ ]`

Honest scope, matching what the engines can actually load TODAY:

- **In-app import of Kokoro-format voice banks (.npz)** — files containing
  `<codename>.npy` style vectors. The engine already reads exactly this
  format; imported packs merge into `voicesFlat` and their codenames appear
  (and audition) in the Kokoro voice picker.
- **Curated links** to browse more ONNX voices on GitHub (each entry shows
  size where known; everything listed is < 500 MB per entry). These open in
  Safari — labeled honestly when the app can't load them yet (Piper needs a
  future engine; do NOT pretend otherwise).

**D4a. New file `App/Sources/Services/ImportedVoices.swift`:**

```swift
import Foundation

struct ImportedVoicePack: Identifiable {
    let id: URL
    let url: URL
    let name: String
    let sizeBytes: Int64
    /// npz keys minus ".npy" — the codenames this pack contributes.
    let codenames: [String]
}

/// Registry of user-imported Kokoro voice banks in Documents/ImportedVoices.
/// The engine merges these into its voice table at model-load time.
@MainActor
final class ImportedVoices: ObservableObject {
    static let shared = ImportedVoices()
    @Published private(set) var packs: [ImportedVoicePack] = []

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedVoices")
    }

    init() { refresh() }

    func refresh() {
        // NpyzReader comes from MLXUtilsLibrary — import it the same way
        // OnnxKokoroEngine.swift does (check its import block and mirror it).
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) else {
            packs = []
            return
        }
        packs = files.filter { $0.pathExtension.lowercased() == "npz" }.compactMap { url in
            guard let keys = NpyzReader.read(fileFromPath: url)?.keys else { return nil }
            let codenames = keys.filter { $0.hasSuffix(".npy") }
                .map { String($0.dropLast(4)) }
                .sorted()
            guard !codenames.isEmpty else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return ImportedVoicePack(
                id: url, url: url,
                name: url.deletingPathExtension().lastPathComponent,
                sizeBytes: Int64(size), codenames: codenames
            )
        }
    }

    /// Validates and installs a picked .npz. Throws with a human message.
    func install(from pickedURL: URL) throws {
        let codenames = (NpyzReader.read(fileFromPath: pickedURL)?.keys ?? [])
            .filter { $0.hasSuffix(".npy") }
        guard !codenames.isEmpty else {
            throw ImportError.notAVoicePack
        }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var destURL = Self.directory.appendingPathComponent(pickedURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destURL.path) {
            destURL = Self.directory.appendingPathComponent(
                "voices-\(Int(Date().timeIntervalSince1970)).npz"
            )
        }
        // Picked files arrive security-scoped in the Files picker flow; the
        // caller (fileImporter) already copied it into tmp — copy from there.
        try FileManager.default.copyItem(at: pickedURL, to: destURL)
        refresh()
        Log.shared.info("ImportedVoices: installed \(destURL.lastPathComponent) (\(codenames.count) voices)")
    }

    func delete(_ pack: ImportedVoicePack) {
        try? FileManager.default.removeItem(at: pack.url)
        refresh()
    }

    enum ImportError: LocalizedError {
        case notAVoicePack
        var errorDescription: String? {
            "That file isn't a voice pack — expected an .npz containing .npy style vectors (Kokoro format)."
        }
    }
}
```

NOTE for implementer: `NpyzReader` must be importable — mirror exactly the
imports at the top of `OnnxKokoroEngine.swift`. If the type isn't visible
outside the engine file for any reason, instead add a tiny static helper on
`OnnxKokoroEngine`: `static func voiceCodenames(inNpzAt url: URL) -> [String]`
and call that. Do NOT vendor or duplicate npz parsing.

**D4b. `OnnxKokoroEngine.swift` — merge imported packs (the 2nd of only two
engine edits):** inside `loadModelIfNeeded()`, immediately after
`voicesFlat = flat`, add:

```swift
            // User-imported Kokoro voice packs (Settings → Import voices).
            let importedDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ImportedVoices")
            if let packs = try? FileManager.default.contentsOfDirectory(at: importedDir, includingPropertiesForKeys: nil) {
                var merged = 0
                for pack in packs where pack.pathExtension.lowercased() == "npz" {
                    guard let extra = NpyzReader.read(fileFromPath: pack) else { continue }
                    for (key, array) in extra where key.hasSuffix(".npy") {
                        flat[key] = array.asArray(Float.self)
                        merged += 1
                    }
                }
                voicesFlat = flat
                if merged > 0 {
                    Log.shared.info("OnnxKokoroEngine: merged \(merged) imported voice(s)")
                }
            }
```

(adjust so `voicesFlat` ends up with base + imported keys; the snippet above
re-assigns it — make sure the final assignment happens once, after merging.)

Add a reload hook next to `pause/resume/stop`:

```swift
    /// Re-reads voice banks (base + imported). Only call while idle — the
    /// generation loop owns voicesFlat reads on engineQueue.
    func reloadVoices() {
        engineQueue.async { [weak self] in
            guard let self, self.state == .idle else { return }
            self.voicesFlat = [:]
            self.modelLoadAttempted = false
            self.loadModelIfNeeded()
        }
    }
```

`SpeechPlayer` gains a pass-through so the UI doesn't touch engines:

```swift
    /// After importing/deleting a voice pack (idle only).
    func reloadImportedVoices() {
        onnxEngine?.reloadVoices()
    }
```

**D4c. `VoiceCatalog.swift` — imported descriptors.** Add:

```swift
    /// Codenames contributed by user-imported packs (Kokoro engine only).
    static var importedKokoroCodenames: [String] {
        // Called from MainActor UI contexts only.
        MainActor.assumeIsolated {
            ImportedVoices.shared.packs.flatMap { $0.codenames }
        }
    }
```

and in `descriptors(for:)` change the Kokoro branch:

```swift
        case .kokoroOnnx:
            return kokoro + importedKokoroCodenames.map { codename in
                VoiceDescriptor(id: codename, displayName: codename, accent: "Imported", gender: "Voice")
            }
```

(If `MainActor.assumeIsolated` fights the compiler in Swift 5 mode, make
`descriptors(for:)` @MainActor — every caller is a view/player on main.)

**D4d. `VoicePickerSheet.swift`:** for `scope == .kokoro`, append an
"Imported" section after the built-in sections listing
`VoiceCatalog.importedKokoroCodenames` rows that audition/select exactly like
built-ins (reuse the existing row builder). Keep it one small `if` +
`ForEach` — do not restructure the file.

**D4e. New file `App/Sources/Views/VoiceImportView.swift`:**

```swift
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Import voices: install Kokoro-format .npz voice packs and
/// browse additional ONNX voices on GitHub.
struct VoiceImportView: View {
    @ObservedObject private var imported = ImportedVoices.shared
    @EnvironmentObject private var player: SpeechPlayer
    @State private var showingImporter = false
    @State private var importError: String?

    var body: some View {
        Form {
            importSection
            installedSection
            browseSection
        }
        .navigationTitle("Import voices")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "npz") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            Task { @MainActor in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        // fileImporter hands a tmp copy we can read directly.
                        try ImportedVoices.shared.install(from: url)
                        if player.state == .idle { player.reloadImportedVoices() }
                        Haptics.success()
                    } catch {
                        importError = error.localizedDescription
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                showingImporter = true
            } label: {
                Label("Import voice pack (.npz)…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Kokoro voice packs")
        } footer: {
            Text("An .npz file containing .npy style vectors in Kokoro format. Imported voices appear (and audition) in the Kokoro voice picker under 'Imported'. They work fully offline.")
        }
    }

    private var installedSection: some View {
        Section {
            if imported.packs.isEmpty {
                Text("No packs imported yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(imported.packs) { pack in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name).font(.subheadline)
                            Text("\(pack.codenames.count) voices · \(ByteCountFormatter.string(fromByteCount: pack.sizeBytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            ImportedVoices.shared.delete(pack)
                            if player.state == .idle { player.reloadImportedVoices() }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Installed packs")
        }
    }

    /// Honest, curated pointers — sizes per entry are all under 500 MB.
    /// Link rows open in Safari. Do NOT add download automation for these.
    private var browseSection: some View {
        Section {
            Link(destination: URL(string: "https://github.com/hexgrad/kokoro")!) {
                Label("Kokoro voices — github.com/hexgrad/kokoro", systemImage: "external.link")
            }
            Link(destination: URL(string: "https://github.com/rhasspy/piper")!) {
                Label("Piper voices — github.com/rhasspy/piper", systemImage: "external.link")
            }
            Link(destination: URL(string: "https://github.com/onnx-community")!) {
                Label("ONNX community models — github.com/onnx-community", systemImage: "external.link")
            }
        } header: {
            Text("More ONNX voices on GitHub")
        } footer: {
            Text("Browse additional ONNX TTS voices and packs on GitHub (each under 500 MB). Piper offers many language voices (~20–65 MB each) — a Piper engine slot is a possible future addition; until then those links are for browsing only.")
        }
    }
}
```

**D4f.** In `SettingsView`'s IMPORT VOICES section (from D2):

```swift
                Section {
                    NavigationLink {
                        VoiceImportView()
                    } label: {
                        Label("Import more voices", systemImage: "person.badge.plus")
                    }
                } header: {
                    Text("Voices")
                } footer: {
                    Text("Import Kokoro-format voice packs from Files, and browse more ONNX voices on GitHub.")
                }
```

(`SettingsView` already sits in a NavigationStack, so NavigationLink pushes.)

**Commit:** `v1.3.0 step D4: import Kokoro voice packs (.npz) + ONNX voice links + picker 'Imported' section`

### D5. Device test checklist for STEP D `[ ]`
- Settings tab present (gear), sections in order; Done button GONE in tab,
  still present when opened from the editor's "…" menu.
- Accent: pick green → buttons/sliders/play gradient follow immediately;
  relaunch persists.
- Appearance: Dark → app goes dark regardless of system; System tracks iOS.
- Storage: "Clear exported audio" empties the Exports dir (Storage tab
  updates); "Clear temporary & unused files" runs, log line appears.
- Model cards moved under Storage still download/delete correctly (delete
  Kokoro → engine falls back to system voice; re-download works).
- Import voices: import a valid Kokoro .npz → pack listed; Kokoro picker
  shows "Imported" section; audition plays; select + speak works; delete
  pack → voices gone after app relaunch.
- Import a non-voice .npz (e.g. re-zipped text) → clean error alert.
- About shows version 1.3.0 (24), Developer TheSageZM, working repo link.

---

## STEP E — Version bump, CI, release `[ ]`

1. `project.yml` → `MARKETING_VERSION: "1.3.0"`, `CURRENT_PROJECT_VERSION: "24"`.
   NOTHING else in that file changes (hard rule 1).
2. Commit: `v1.3.0: bump version`. Push. Watch: `./Scripts/watch_ci.sh <full-sha>`
   (background, exit 0 = green). On failure: `gh run view --log-failed`, fix,
   push, repeat. Expect possible failures only in the app build job — logic
   tests don't touch app code.
3. Release (same flow as v1.1.0/v1.2.x):
   ```
   gh run list --limit 1
   gh run download <run-id> -n SpeechnotesIOS -D /tmp/v130
   cd /tmp/v130 && unzip SpeechnotesIOS.zip
   gh release create v1.3.0 --title "v1.3.0" --notes "<see below>" --prerelease
   gh release upload v1.3.0 /tmp/v130/SpeechnotesIOS.ipa
   ```
   Release notes draft: "Recycle bin for deleted notes (30-day retention).
   Resume playback where you left off. New Storage tab: browse, play, share
   and delete exported WAVs, plus storage usage. New Settings tab: speech,
   appearance (accent color, light/dark), storage management, voice pack
   import (.npz) and about. Performance and stability from v1.2.x kept."
4. Sanity-check the IPA before telling the user (the v1.2.0 lesson):
   ```
   unzip -l SpeechnotesIOS.ipa | head -30          # Payload/Speechnotes.app present
   plutil -p Payload/Speechnotes.app/Info.plist 2>/dev/null | grep -i orientation
   ```
   The orientation list must show PORTRAIT ONLY. If anything else appears —
   STOP, do not ship, investigate.
5. Update the handover block at the top of `~/.zcode/workspace/default/
   SPEECHNOTES-IOS-PLAN.md` (HANDOVER v14): what shipped, the commit, the
   device-test checklist below. Keep this file's status markers current.
6. User device test checklist (FULL regression — v1.2.0 taught us this):
   - App LAUNCHES inside LiveContainer (first, always).
   - All of sections A5, B4, C5, D5.
   - Regression sweep: play/pause/stop all four engines; WAV export; markdown
     preview; notes list search/sort/swipes/import; mini-player jump-to-note;
     background playback (lock the phone mid-speech); rate slider mid-speech.

---

## 11. Type-checker survival guide (read before writing ANY SwiftUI)

v1.2.0 burned 19 CI runs on `failed to produce diagnostic for expression`.
Rules, in order of importance:

1. **Never write a long modifier chain.** Cap ~10–12 modifiers per body
   expression; the moment a view has toolbar + sheets + alerts + onAppear +
   safeAreaInset + navigation in ONE chain, split it.
2. **Extract subviews into computed properties** (`private var xSection:
   some View`) and small `private func row(_ item:) -> some View` helpers.
   Every view in this plan is already written that way — keep it that way.
3. **New screen = new file.** Never inline a new screen into an existing one.
4. **No `AnyView`** unless nothing else compiles (it was crutch city in the
   failed v1.2.0 attempts; the final lesson was that DECOMPOSITION, not type
   erasure, is the fix).
5. If CI shows `failed to produce diagnostic for expression`: find which
   view grew, split its biggest expression into two computed properties,
   push again. Do not rewrite the whole file.
6. `NoteEditorView.swift` is the historic hot spot — this plan adds exactly
   ONE menu item to it (B3). Keep it that way.

## 12. What NOT to do (summary)

- No `project.yml` changes except the version bump (STEP E).
- No new package pins; no package updates.
- No engine scheduling/buffer/audio-session rewrites (only B2's delegate and
  D4b's voice merge + reload, verbatim from this plan).
- No new tabs beyond Storage and Settings; no TabView reordering beyond
  D3's layout.
- No read-along highlighting, no STT, no translation.
- No reuse of version numbers 1.2.0–1.2.2; ships as 1.3.0 build 24.
- No unverified download URLs (Appendix A is the whitelist).
- No cloud/sync features; everything stays on-device.

## Appendix A — verified URLs (whitelist)

**In production (ModelManager.swift) — safe to keep using:**
- Kokoro uint8 model: `https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model_uint8.onnx` (~177 MB)
- Kokoro tokenizer: same repo, `tokenizer.json` (~3.5 KB)
- Kokoro voice bank (28 voices): `https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz` (~15 MB) — repo verified live 2026-08-19
- Kitten mini 0.8: `https://huggingface.co/KittenML/kitten-tts-mini-0.8/resolve/main/{kitten_tts_mini_v0_8.onnx,voices.npz}` (~82 MB)
- Supertonic 3: `https://huggingface.co/Supertone/supertonic-3/resolve/main/...` (16 files, ~399 MB)

**Browse-only links (used in VoiceImportView):**
- `https://github.com/hexgrad/kokoro` — official Kokoro (new voices land here)
- `https://github.com/rhasspy/piper` — Piper: many language voices, each
  ~20–65 MB ONNX. NEEDS a future engine to run in-app — links are for
  browsing; label honestly.
- `https://github.com/onnx-community` — community ONNX exports org

**Anything else:** `curl -sI <url>` first; if it's not a 200/302 from the
exact host above, do not ship it.

## Appendix B — quick reference: existing keys & constants

- UserDefaults keys in use: `rateMultiplier`, `engineKind`, `voice`,
  `kittenVoice`, `supertonicVoice`, `supertonicLang`, `systemVoiceIdentifier`,
  `notesSortOrder`, `renderMarkdown` (@AppStorage). New in this release:
  `playbackBookmark`, `accentColorName`, `appearancePreference`.
- Documents layout: `notes.json`, `Exports/`, `KokoroOnnx/`, `Kitten/`,
  `Supertonic/`, new: `ImportedVoices/`.
- ONNX engine chunking: `chunkMaxChars = 160`, `generationAheadLimit = 3`.
- CI gate job name: "Build unsigned IPA" (the last job; spikes are
  continue-on-error).

**END OF PLAN. Execute top to bottom. Keep status markers current.**
