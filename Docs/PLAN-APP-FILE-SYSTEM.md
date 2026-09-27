# Open design question — the Files-app document store (raised 2026-09-27)

The user's question, in their words: *"why doesnt speechnotes have like an
app file system with the files app... to store documents and audiobook...
etc instead of whatever this is... when i sideload with sidestore"*.

## What today's model costs

Books live in `Documents/Books/<uuid>/` — copied in at import, invisible to
the Files app. That choice is deliberate (documented in `BooksStore.swift`):
one manifest per book, never one big file, and the copy means the archive /
m4b / pdf is read repeatedly without a security-scope handshake each time.

Consequences the user is feeling:

1. **Import is a full file copy.** A 3 GB 'Harry Potter' m4b is 3 GB of
   copy on tap. With an on-disk document folder the app could open in
   place (AVURLAsset / PDFKit / ZipReader all read from any URL) and the
   copy disappears — the single biggest import cost in the app.
2. **Storage is invisible.** Settings → Storage counts bytes the user
   cannot browse, move, or delete from the Files app.
3. **Two copies of everything on the device** — their Downloads copy and
   ours — and deleting one does not free the other.

## What a Files-backed store changes

| Piece | Today | Files-backed |
|---|---|---|
| Import | full copy into `Books/<uuid>/` | bookmark (`startAccessingSecurityScopedResource`) or copy into the shared `Documents/` folder |
| Reading | app-private URL | same URL, plus any file the user drops in |
| Storage | computed by walking the directory | visible in the Files app; deletions there just work |
| TTS chapter cache | `Books/<uuid>/text/NNNN.txt` | still app-private (a rebuildable cache; don't move it) |
| Mini-player / playback | `AVAudioPlayer(contentsOf:)` on the app URL | same call, a security-scoped URL |

## Why it is not in this session's fixes

It is a design change with a real cost: security-scoped resource bookmarks
must be persisted per book and re-acquired on every read (including from
background tasks), which is exactly the class of bug that produced the
round-5 `.audio` extension failure and the round-7 audiobook metadata
emptiness. Doing it right means a migration of the existing shelf — every
manifest needs an `originalBookmark` field, and a shelf of already-copied
books must keep playing from the copy until the user opts in.

## Recommendation for the next cycle

Land it in three steps, each independently useful:

1. **Share an on-disk folder first** (`UISupportsDocumentBrowser` +
   `LSSupportsOpeningDocumentsInPlace`): Speechnotes appears in Files, the
   user can drop books in, and the importer offers "add from Files" as an
   in-place alternative to the copy. Nothing else changes.
2. **Bookmarks for in-place books**, with the copy kept as the fallback
   whenever a bookmark cannot be acquired.
3. **Migration of the existing shelf** behind an explicit per-book action
   ("move to Files app"), never automatic.

Steps 1–2 are a day of work and would have prevented the 3 GB copy the
user just waited through. Step 3 is the one to defer.
