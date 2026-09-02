import Foundation
import CryptoKit

/// Local image cache for note-embedded images.
///
/// Notes store images with `speechnotes://note-image/<hash>.<ext>` URIs so
/// the markdown stays portable across devices and exports cleanly without
/// base64 bloat. The actual bytes live under
/// `Documents/note-images/<noteId>/<hash>.<ext>` — keyed by SHA-256 of the
/// raw bytes so two paste/picker/drop sources of the same image share one
/// file on disk.
///
/// Both raw file paths (when `currentDirectory` happens to be the on-disk
/// location) and downloaded bytes are routed through `store(data:ext:noteId:)`;
/// callers never write into the cache directory directly. Reads return the
/// `file://` URL or `Data` as needed.
enum NoteImageStore {

    /// Custom scheme we use in markdown image targets so notes can move
    /// across devices without breaking. `file://` would also work locally
    /// but breaks portability, and base64 bloat isn't worth it.
    internal static let scheme = "speechnotes"
    internal static let pathPrefix = "note-image"

    /// Resolves a markdown image target to an absolute on-disk `file://` URL
    /// if it's one of our cached images, else returns nil (caller treats it
    /// as a remote URL).
    static func resolveLocalURL(_ target: String, noteId: UUID) -> URL? {
        guard let (hash, ext) = parseLocalTarget(target) else { return nil }
        let path = directory(for: noteId).appendingPathComponent("\(hash).\(ext)")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Stores `data` under the SHA-256 hash. If a file with that hash +
    /// extension already exists it's reused (dedupe). Returns the
    /// `speechnotes://` target the markdown should embed.
    @discardableResult
    static func store(
        data: Data,
        ext: String,
        noteId: UUID,
        suggestedName: String? = nil
    ) -> String? {
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let cleanExt = sanitiseExtension(ext) ?? "bin"
        let dir = directory(for: noteId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let target = dir.appendingPathComponent("\(hash).\(cleanExt)")
        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                return nil
            }
        }
        return "\(scheme)://\(pathPrefix)/\(hash).\(cleanExt)"
    }

    /// Best-effort extension from a URL or filename. Defaults to "bin".
    static func sanitiseExtension(_ raw: String?) -> String? {
        guard var ext = raw?.lowercased(), !ext.isEmpty else { return nil }
        // Drop leading dots / query fragments.
        if ext.hasPrefix(".") { ext.removeFirst() }
        if let slash = ext.firstIndex(of: "/") { ext = String(ext[..<slash]) }
        if let q = ext.firstIndex(of: "?") { ext = String(ext[..<q]) }
        // Whitelist common image types so a malicious "ext" can't be turned
        // into a path-traversal segment.
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp":
            return ext == "jpeg" ? "jpg" : ext
        default:
            return "bin"
        }
    }

    /// `speechnotes://note-image/<hash>.<ext>` → (hash, ext).
    static func parseLocalTarget(_ target: String) -> (hash: String, ext: String)? {
        guard let url = URL(string: target),
              url.scheme == scheme,
              url.host == pathPrefix,
              let last = url.pathComponents.last,
              !last.isEmpty else { return nil }
        let parts = last.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Per-note directory under Documents/note-images/.
    static func directory(for noteId: UUID) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("note-images", isDirectory: true)
            .appendingPathComponent(noteId.uuidString, isDirectory: true)
    }

    /// Total bytes on disk for `noteId`. Used by Storage settings to budget
    /// the attachment footprint.
    static func footprint(for noteId: UUID) -> Int64 {
        let dir = directory(for: noteId)
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
