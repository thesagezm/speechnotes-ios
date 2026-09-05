import Foundation
import UIKit
import SpeechLogic

/// Image-insertion helper: routes every image source (Photos picker, paste
/// board, drag-and-drop, URL download) through `NoteImageStore` so the
/// markdown ends up with a `speechnotes://note-image/<hash>.<ext>` target
/// instead of base64 or a remote URL. Dedupe by content hash means the same
/// image dropped into two notes costs one disk file (per note — different
/// note IDs have separate directories).
@MainActor
final class MarkdownImageInserter {
    private let noteId: UUID
    /// Last error surfaced to the UI (network failure, missing scheme, etc).
    private(set) var lastError: String?

    init(noteId: UUID) { self.noteId = noteId }

    /// Insert an image from `Data` + extension (Photos picker, clipboard,
    /// drag-and-drop). Hashing/re-encoding/disk write run off the main thread
    /// (multi-MB clipboard photos used to freeze typing). Routes through
    /// `importImageData` so HEIC and oversized photos are re-encoded.
    /// Returns the markdown fragment to insert at the caret.
    @discardableResult
    func store(data: Data, ext: String, alt: String) async -> String? {
        lastError = nil
        let noteId = noteId
        let target = await Task.detached(priority: .userInitiated) {
            NoteImageStore.importImageData(data, pathExtension: ext, noteId: noteId)
        }.value
        guard let target else {
            lastError = "Couldn't save the image."
            return nil
        }
        return "![\(alt)](\(target))"
    }

    /// Insert an image from a remote URL. Downloads the bytes once, caches
    /// them, and inserts the local target. Falls back to the raw URL if the
    /// download fails so the image still shows up when offline next time.
    @discardableResult
    func storeFromURL(_ url: URL, alt: String) async -> String {
        lastError = nil
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let ext = NoteImageStore.sanitiseExtension(url.pathExtension.isEmpty ? "png" : url.pathExtension)
            let noteId = noteId
            let target = await Task.detached(priority: .userInitiated) {
                NoteImageStore.importImageData(data, pathExtension: ext ?? "png", noteId: noteId)
            }.value
            if let target {
                return "![\(alt)](\(target))"
            }
        } catch {
            lastError = error.localizedDescription
        }
        // Offline fallback: keep the raw URL in the markdown so it still
        // renders when the user has network again. AsyncImage in the preview
        // will fetch it on demand.
        return "![\(alt)](\(url.absoluteString))"
    }
}
