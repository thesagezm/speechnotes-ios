# PLAN: Recycle Bin / Deleted Notes Recovery

> **Author:** agent handoff for next session
> **Status:** DESIGN ONLY — not started. Read, critique, then implement in order.
> **Scope:** Add "Recently Deleted" recovery to v1.3+ (after landscape is solved).

---

## Problem

- User deletes a note by accident (swipe → Delete, or `…` menu → Delete).
- Current flow: `NotesStore.delete(noteId:)` → immediate `UserDefaults` write → gone forever.
- No undo, no grace period, no recovery. Speech Note (Linux) has a trash; iOS Notes has "Recently Deleted".

---

## Requirements (user-stated, lightweight)

1. **Deleted notes go to a "Recently Deleted" section** — not instant purge.
2. **30-day TTL** (match iOS Notes) or **until manual empty** — pick one, keep it simple.
3. **Recover action** → note returns to main list with original `createdAt`/`updatedAt`.
4. **Permanent delete action** → really gone.
5. **UI entry point** — a "Recently Deleted" row in the notes list (like iOS) or a tab/section. No new tabs.
6. **Persisted across app restarts** — survives kill/relaunch.
7. **Zero engine/audio impact** — NotesStore only.

---

## Non-requirements (explicit)

- No cloud sync, no cross-device.
- No "recover all" batch action (v1).
- No per-note retention policy UI.
- No separate "Trash" model type — reuse `Note` with a `deletedAt` field.

---

## Data Model Change

```swift
// App/Sources/Models/Note.swift
struct Note: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var explicitTitle: String?
    // NEW:
    var deletedAt: Date?           // nil = active; set = in recycle bin
}
```

- `deletedAt` is **nil for active notes**, **timestamp when deleted**.
- Encoding/decoding stays `Codable` — backward compatible (old JSON lacks key → `nil`).
- `NotesStore.notes` computed property filters: `notes.filter { $0.deletedAt == nil }`.
- New property: `deletedNotes: [Note] { notes.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! } }`.

---

## NotesStore Changes

```swift
// App/Sources/Services/NotesStore.swift
final class NotesStore: ObservableObject {
    @Published private var allNotes: [Note] = []  // includes deleted
    // @Published var notes: [Note] { allNotes.filter { $0.deletedAt == nil } }  // computed

    func delete(noteId: UUID) {
        guard var note = allNotes.first(where: { $0.id == noteId }) else { return }
        note.deletedAt = Date()
        update(note)  // writes through to persistence
    }

    func recover(noteId: UUID) {
        guard var note = allNotes.first(where: { $0.id == noteId }),
              note.deletedAt != nil else { return }
        note.deletedAt = nil
        note.updatedAt = Date()
        update(note)
    }

    func purge(noteId: UUID) {
        allNotes.removeAll { $0.id == noteId }
        flushNow()
    }

    func emptyRecycleBin() {
        allNotes.removeAll { $0.deletedAt != nil }
        flushNow()
    }

    // Auto-purge on launch (30-day TTL):
    func pruneExpiredDeleted() {
        let cutoff = Date().addingTimeInterval(-30*24*3600)
        let before = allNotes.count
        allNotes.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
        if allNotes.count != before { flushNow() }
    }
}
```

- `pruneExpiredDeleted()` called once in `init()` after loading.
- No timer — runs on next launch; good enough.

---

## UI Changes

### 1. NotesListView — "Recently Deleted" Section

```swift
// Inside NotesListView.body, after the main list:
if !notes.deletedNotes.isEmpty {
    Section("Recently Deleted (\(notes.deletedNotes.count))") {
        ForEach(notes.deletedNotes) { note in
            DeletedNoteRow(note: note)
        }
    }
}
```

### 2. DeletedNoteRow (new view)

```swift
struct DeletedNoteRow: View {
    let note: Note
    @EnvironmentObject var notes: NotesStore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title ?? "Untitled")
                    .font(.subheadline)
                Text("Deleted \(note.deletedAt!, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button { notes.recover(noteId: note.id) } label: {
                    Label("Recover", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    notes.purge(noteId: note.id)
                } label: {
                    Label("Delete Permanently", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
```

### 3. Empty Recycle Bin Button (optional, in section footer or toolbar)

```swift
ToolbarItem(placement: .bottomBar) {
    if !notes.deletedNotes.isEmpty {
        Button("Empty Recycle Bin", role: .destructive) {
            notes.emptyRecycleBin()
        }
    }
}
```

---

## Migration / Backward Compatibility

- Existing JSON on disk has no `deletedAt` → decodes as `nil` → all notes active.
- First launch on v1.3+: `pruneExpiredDeleted()` is a no-op (no deleted notes yet).
- No schema version bump needed — `Codable` handles missing key gracefully.

---

## Test Plan (CI + Device)

**Unit tests (new `Tests/RecycleBinTests/`):**
1. `delete → note moves to deletedNotes`
2. `recover → note returns to notes, deletedAt = nil`
3. `purge → note removed from allNotes`
4. `emptyRecycleBin → all deletedNotes gone`
5. `pruneExpiredDeleted → only notes older than 30 days removed`
6. Decode old JSON (no `deletedAt`) → all active

**Device checklist:**
1. Swipe-delete a note → appears in "Recently Deleted"
2. Tap "Recover" → back in main list, content intact
3. Tap "Delete Permanently" → gone
4. "Empty Recycle Bin" clears section
5. Kill app, relaunch → deleted notes persist
6. Edit a recovered note → `updatedAt` updates, `createdAt` preserved

---

## Rollout Order

| Step | Commit | Description |
|------|--------|-------------|
| 1 | Add `deletedAt` to `Note` + `NotesStore` helpers | Model + store logic only; no UI |
| 2 | `NotesListView` section + `DeletedNoteRow` | Read-only list of deleted |
| 3 | Recover / Purge actions in row menu | Interactive |
| 4 | "Empty Recycle Bin" toolbar button | Bulk action |
| 5 | `pruneExpiredDeleted()` in `NotesStore.init` | TTL enforcement |
| 6 | Unit tests + CI job | Gate |

---

## Guardrails

- **Do not** add a new tab — section in existing list only.
- **Do not** touch `SpeechPlayer`, engines, or audio code.
- **Do not** add a separate "Trash" model — reuse `Note` with `deletedAt`.
- **Do not** over-engineer TTL: 30-day constant, prune on launch, no timer.
- **Do not** change `Note` equality/hash (id-based stays).
- **Do not** add batch recover v1 — single-note only.

---

## Open Questions (decide before Step 1)

1. **TTL: 30 days or manual-only?** iOS Notes = 30 days. Speech Note (Linux) = manual. Default to 30 days; one-line change if user wants manual-only.
2. **Section header style:** plain `Section("Recently Deleted")` or collapsible? Start plain.
3. **Toolbar button vs. row swipe actions:** row menu keeps it simple; toolbar "Empty" is optional. Start with row menu only.

---

## Future (v1.4+)

- Batch recover / batch permanent delete.
- Per-note "days remaining" badge.
- iCloud sync of recycle bin (if NotesStore ever gets cloud).
- Search inside deleted notes.

---

**End of plan.** Implement in order; each step should CI-green before the next.