import Foundation
import CryptoKit
import ImageIO

/// Local image cache for note-embedded images.
///
/// Notes store images with `speechnotes://note-image/<hash>.<ext>` URIs so
/// the markdown stays portable. Bytes live under
/// `Documents/note-images/<noteId>/<hash>.<ext>`, deduped by SHA-256.
/// Thumbnails are cached as `<hash>-thumb.jpg` sidecars (excluded from
/// footprint). Import re-encodes oversized photos and HEIC to JPEG;
/// pruning drops files the markdown no longer references.
public enum NoteImageStore {

    public static let scheme = "speechnotes"
    public static let pathPrefix = "note-image"

    // MARK: - Core

    public static func resolveLocalURL(_ target: String, noteId: UUID) -> URL? {
        guard let (hash, ext) = parseLocalTarget(target) else { return nil }
        let path = directory(for: noteId).appendingPathComponent("\(hash).\(ext)")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    @discardableResult
    public static func store(
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

    public static func sanitiseExtension(_ raw: String?) -> String? {
        guard var ext = raw?.lowercased(), !ext.isEmpty else { return nil }
        if ext.hasPrefix(".") { ext.removeFirst() }
        if let slash = ext.firstIndex(of: "/") { ext = String(ext[..<slash]) }
        if let q = ext.firstIndex(of: "?") { ext = String(ext[..<q]) }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp":
            return ext == "jpeg" ? "jpg" : ext
        default:
            return "bin"
        }
    }

    public static func parseLocalTarget(_ target: String) -> (hash: String, ext: String)? {
        guard let url = URL(string: target),
              url.scheme == scheme,
              url.host == pathPrefix,
              let last = url.pathComponents.last,
              !last.isEmpty else { return nil }
        let parts = last.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    public static func directory(for noteId: UUID) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("note-images", isDirectory: true)
            .appendingPathComponent(noteId.uuidString, isDirectory: true)
    }

    /// Bytes on disk for `noteId` (thumbnails excluded).
    public static func footprint(for noteId: UUID) -> Int64 {
        let dir = directory(for: noteId)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasSuffix("-thumb.jpg") { continue }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Import (sniffing + re-encode)

    /// Import an image file (picker/drop path). Oversized photos and HEIC
    /// sources are re-encoded as JPEG for portability; small PNGs/GIFs keep
    /// their original bytes. Call off the main thread for big files.
    @discardableResult
    public static func importImage(
        at url: URL,
        noteId: UUID,
        maxDimension: CGFloat = 2400,
        recompressThreshold: Int = 800_000
    ) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return importImageData(
            data, pathExtension: url.pathExtension, noteId: noteId,
            maxDimension: maxDimension, recompressThreshold: recompressThreshold
        )
    }

    @discardableResult
    public static func importImageData(
        _ data: Data,
        pathExtension: String?,
        noteId: UUID,
        maxDimension: CGFloat = 2400,
        recompressThreshold: Int = 800_000
    ) -> String? {
        let ext = normalizedExtension(pathExtension, of: data)
        let heavy = ["png", "jpg", "jpeg", "heic", "heif", "webp", "tiff"]
        let wantsRecompress = ext == "heic" || ext == "heif" || data.count > recompressThreshold
        if heavy.contains(ext), wantsRecompress,
           let jpeg = reencodeJPEG(data, maxDimension: maxDimension) {
            return store(data: jpeg, ext: "jpg", noteId: noteId)
        }
        return store(data: data, ext: ext, noteId: noteId)
    }

    /// Magic-byte sniffing when the extension is missing/untrustworthy.
    static func sniffedExtension(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "jpg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "heic" } // "ftyp"
        return nil
    }

    static func normalizedExtension(_ raw: String?, of data: Data) -> String {
        if var ext = raw?.lowercased(), !ext.isEmpty {
            if ext.hasPrefix(".") { ext.removeFirst() }
            if let s = ext.firstIndex(of: "/") { ext = String(ext[..<s]) }
            if let s = ext.firstIndex(of: "?") { ext = String(ext[..<s]) }
            switch ext {
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp":
                return ext == "jpeg" ? "jpg" : ext
            default: break
            }
        }
        return sniffedExtension(data) ?? "bin"
    }

    /// JPEG re-encode, long edge capped at `maxDimension`.
    static func reencodeJPEG(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Thumbnails

    /// Cached ~`maxDimension`-px JPEG thumbnail for an embedded image
    /// (generated on first request, reused afterwards). Keeps the preview
    /// cheap for 12-megapixel photos.
    public static func thumbnailURL(for target: String, noteId: UUID, maxDimension: CGFloat = 480) -> URL? {
        guard let (hash, ext) = parseLocalTarget(target) else { return nil }
        let dir = directory(for: noteId)
        let thumb = dir.appendingPathComponent("\(hash)-thumb.jpg")
        if FileManager.default.fileExists(atPath: thumb.path) { return thumb }
        let original = dir.appendingPathComponent("\(hash).\(ext)")
        guard let data = try? Data(contentsOf: original),
              let jpeg = reencodeJPEG(data, maxDimension: maxDimension) else { return nil }
        do {
            try jpeg.write(to: thumb, options: .atomic)
            return thumb
        } catch {
            return nil
        }
    }

    // MARK: - Maintenance

    /// Remove cached images no longer referenced by the note's markdown.
    /// Call when edits settle (save/disappear). Returns bytes freed.
    @discardableResult
    public static func prune(noteId: UUID, markdown: String) -> Int64 {
        let hashes = Set(
            MarkdownText.imageTokens(in: markdown)
                .compactMap { parseLocalTarget($0.url)?.hash }
        )
        return prune(noteId: noteId, keepingHashes: hashes)
    }

    @discardableResult
    public static func prune(noteId: UUID, keepingHashes: Set<String>) -> Int64 {
        let dir = directory(for: noteId)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var freed: Int64 = 0
        for file in files {
            var stem = file.lastPathComponent
            if stem.hasSuffix("-thumb.jpg") {
                stem = String(stem.dropLast("-thumb.jpg".count))
            } else if let dot = stem.lastIndex(of: ".") {
                stem = String(stem[..<dot])
            }
            if keepingHashes.contains(stem) { continue }
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if (try? FileManager.default.removeItem(at: file)) != nil {
                freed += size
            }
        }
        return freed
    }

    /// Copy every cached image to another note (note duplication).
    public static func copyImages(from source: UUID, to destination: UUID) {
        let src = directory(for: source)
        let dst = directory(for: destination)
        guard let files = try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        for file in files {
            let target = dst.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.copyItem(at: file, to: target)
            }
        }
    }

    /// Bytes used by the whole store across all notes (thumbnails excluded).
    public static func totalFootprint() -> Int64 {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("note-images", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasSuffix("-thumb.jpg") { continue }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Every stored image for a note, as `speechnotes://` targets.
    public static func allTargets(for noteId: UUID) -> [String] {
        let dir = directory(for: noteId)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file -> String? in
            let name = file.lastPathComponent
            guard !name.hasSuffix("-thumb.jpg") else { return nil }
            let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return "\(scheme)://\(pathPrefix)/\(parts[0]).\(parts[1])"
        }
    }

    /// Every stored image across ALL notes. Used by the Storage screen's
    /// "Cached images" list.
    public static func allTargets() -> [String] {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("note-images", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let file = item as? URL else { return nil }
            let path = file.lastPathComponent
            guard !path.hasSuffix("-thumb.jpg") else { return nil }
            let parts = path.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return "\(scheme)://\(pathPrefix)/\(parts[0]).\(parts[1])"
        }
    }

    /// Delete the cached file behind a `speechnotes://note-image/<hash>.<ext>`
    /// target. Used by the Storage list's per-row delete.
    @discardableResult
    public static func remove(target: String) -> Bool {
        guard let (hash, ext) = parseLocalTarget(target) else { return false }
        // We don't know the noteId from the target alone — scan every
        // per-note directory for this hash and remove any match.
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("note-images", isDirectory: true)
        guard let noteDirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        var removed = false
        for dir in noteDirs {
            let file = dir.appendingPathComponent("\(hash).\(ext)")
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
                removed = true
            }
            let thumb = dir.appendingPathComponent("\(hash)-thumb.jpg")
            if FileManager.default.fileExists(atPath: thumb.path) {
                try? FileManager.default.removeItem(at: thumb)
            }
        }
        return removed
    }

    /// Nuke everything for a note (note deletion).
    @discardableResult
    public static func removeAllImages(for noteId: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: directory(for: noteId))
            return true
        } catch {
            return false
        }
    }
}
