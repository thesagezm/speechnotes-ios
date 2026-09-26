import Foundation
import SpeechLogic
import UIKit

/// Applies a parsed .jex archive to the app's stores: notebooks first (notes
/// reference them by id), then notes (rewriting `../resources/<id>.<ext>`
/// image links into `speechnotes://note-image/...` after importing each
/// image through NoteImageStore), then a report of what happened.
///
/// Round-trip identity: ids that ARE reconstitutable UUIDs (this app's own
/// exports) keep their identity ONLY while no live note holds them — a
/// re-import duplicates on purpose (importing an old archive should bring
/// those notes back, not silently no-op), but a same-id export+import keeps
/// stable ids so cross-references stay coherent.
@MainActor
enum JexImporter {

    struct Outcome: Equatable {
        var notebooksCreated: Int = 0
        var notesCreated: Int = 0
        var imagesImported: Int = 0
        var notesSkipped: Int = 0
        /// Notebooks whose name already existed (merged into the existing one).
        var notebooksMerged: Int = 0
    }

    /// Imports one .jex file. Throws on anything that means "this is not a
    /// usable JEX"; a successful parse imports as much of the archive as it
    /// can and reports the counts.
    @discardableResult
    static func importArchive(
        at url: URL,
        into notes: NotesStore,
        notebooks: NotebooksStore
    ) throws -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportErrorProxy.read(error.localizedDescription)
        }
        let archive: JexImport.Archive
        do {
            archive = try JexImport.parse(data)
        } catch let error as JexImport.ImportError {
            throw ImportErrorProxy.parse(error.description)
        } catch {
            throw ImportErrorProxy.parse(error.localizedDescription)
        }
        return try apply(archive, into: notesStore, notebooksStore: notebooks)
    }

    @discardableResult
    static func importArchive(
        data: Data,
        into notesStore: NotesStore,
        notebooksStore: NotebooksStore
    ) throws -> Outcome {
        let archive: JexImport.Archive
        do {
            archive = try JexImport.parse(data)
        } catch let error as JexImport.ImportError {
            throw ImportErrorProxy.parse(error.description)
        } catch {
            throw ImportErrorProxy.parse(error.localizedDescription)
        }
        return try apply(archive, into: notesStore, notebooksStore: notebooksStore)
    }

    @discardableResult
    static func apply(
        _ archive: JexImport.Archive,
        into notesStore: NotesStore,
        notebooksStore: NotebooksStore
    ) throws -> Outcome {
        var outcome = Outcome()

        // ---- Notebooks (Joplin ids -> app UUIDs, existing names merge) ----
        var notebookIDMap: [String: UUID] = [:]
        for imported in archive.notebooks where !imported.id.isEmpty {
            // Same name already exists? Reuse it — importing twice must not
            // grow a second "Inbox".
            if let existing = notebooksStore.notebooks.first(where: {
                $0.name.caseInsensitiveCompare(imported.title) == .orderedSame
            }) {
                notebookIDMap[imported.id] = existing.id
                outcome.notebooksMerged += 1
                continue
            }
            guard let created = notebooksStore.create(name: imported.title) else {
                // Blank/uncreatable name — its notes land in Unfiled.
                continue
            }
            notebookIDMap[imported.id] = created.id
            outcome.notebooksCreated += 1
        }

        // ---- Resources (id -> stored image under the note being built) ----
        // NoteImageStore keys images by NOTE, so each note imports the
        // resources its body references; the map survives one note.
        var resourcesByID: [String: JexImport.ImportedResource] = [:]
        for resource in archive.resources {
            resourcesByID[resource.id] = resource
        }

        // ---- Notes ----
        for imported in archive.notes {
            let body = imported.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                outcome.notesSkipped += 1
                continue
            }

            // Identity: reuse the exported UUID when it is free.
            var noteID = JexImport.uuid(fromJoplinId: imported.id) ?? UUID()
            if notesStore.allNotes.contains(where: { $0.id == noteID }) {
                noteID = UUID()
            }

            // Rewrite image links: ../resources/<id>.png → local stored image.
            var markdown = body
            var imageTargets: [String: String] = [:]
            for (resourceID, link) in imported.resources {
                guard let resource = resourcesByID[resourceID] else { continue }
                let target = NoteImageStore.importImageData(
                    resource.data,
                    pathExtension: resource.fileExtension,
                    noteId: noteID
                )
                guard let target else { continue }
                imageTargets[resourceID] = target
                // Replace every occurrence of the Joplin link form.
                markdown = markdown.replacingOccurrences(
                    of: link,
                    with: target,
                    options: .literal
                )
            }
            outcome.imagesImported += imageTargets.count

            let note = notesStore.createNote(
                id: noteID,
                notebookId: imported.notebookId.flatMap { notebookIDMap[$0] }
            )
            var mutable = note
            mutable.text = markdown
            // Joplin carries the title separately from the body; the first
            // line of the body is not necessarily a heading. Use the Joplin
            // title when present, else let the app derive it.
            if let title = imported.title.nilIfBlank, title != note.title {
                mutable.explicitTitle = title
            }
            mutable.createdAt = imported.createdAt
            mutable.updatedAt = imported.updatedAt
            notesStore.update(mutable)
            outcome.notesCreated += 1
        }

        Log.shared.info(
            "JexImporter: \(outcome.notesCreated) notes, \(outcome.notebooksCreated) notebooks " +
            "(\(outcome.notebooksMerged) merged), \(outcome.imagesImported) images, " +
            "\(outcome.notesSkipped) skipped"
        )
        return outcome
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The reader-facing import error, so the UI never surfaces raw JSON/tar
/// jargon.
enum ImportErrorProxy: Error, LocalizedError {
    case read(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .read(let detail):
            return "The file couldn't be read: \(detail)"
        case .parse(let detail):
            return "Not a Joplin .jex archive: \(detail)"
        }
    }
}
