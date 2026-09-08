import Foundation
import UniformTypeIdentifiers

/// Joplin-compatible JEX export. Independent reimplementation — a `.jex`
/// file is a plain (uncompressed) tar containing `<id>.md` files whose
/// trailing metadata block Joplin parses on import. Schema per the public
/// Joplin export-format docs (Interops RAW/JEX exporter); no AGPL code read
/// or repurposed.
///
/// Entry catalog Joplin consumes:
///   <note-id>.md     — note body + metadata + `type_: 1`
///   <folder-id>.md   — notebook title line + metadata + `type_: 2`
///   <resource-id>.md — empty body + metadata (id, title=filename, mime) + `type_: 4`
///   resources/<resource-id>.<ext> — the binary blob
///
/// Conventions: 32 lowercase hex ids (no dashes), ISO-8601 UTC timestamps
/// with milliseconds (`2026-09-08T16:00:43.123Z`), UTF-8, metadata keys in
/// a fixed order with `type_` LAST (the Joplin importer anchors on it).
public enum JexExport {

    public struct NotePayload {
        public let id: String            // 32 lowercase hex
        public let title: String
        public let markdownBody: String
        public let notebookId: String?   // parent notebook id, nil = root
        public let createdAt: Date
        public let updatedAt: Date
        public let images: [ImagePayload] // referenced from the body as ![alt](resource-id)
        public init(id: String, title: String, markdownBody: String, notebookId: String?,
                    createdAt: Date, updatedAt: Date, images: [ImagePayload] = []) {
            self.id = id
            self.title = title
            self.markdownBody = markdownBody
            self.notebookId = notebookId
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.images = images
        }
    }

    public struct NotebookPayload {
        public let id: String
        public let title: String
        public let parentId: String?
        public let createdAt: Date
        public init(id: String, title: String, parentId: String?, createdAt: Date) {
            self.id = id
            self.title = title
            self.parentId = parentId
            self.createdAt = createdAt
        }
    }

    public struct ImagePayload {
        public let id: String            // 32 hex, = resource id
        public let fileExtension: String // "png", "jpg", ...
        public let mimeType: String      // image/png, image/jpeg, ...
        public let data: Data
        public init(id: String, fileExtension: String, mimeType: String, data: Data) {
            self.id = id
            self.fileExtension = fileExtension
            self.mimeType = mimeType
            self.data = data
        }
    }

    // MARK: - Tar writer

    /// Minimal ustar writer. Tar entries are 512-byte aligned headers + data
    /// + padding. Enough for Joplin's importer (verified against the format
    /// docs); flat top-level layout for entries + one `resources/` folder.
    private struct TarWriter {
        private var bytes = Data()

        mutating func append(name: String, data: Data, mode: Int = 0o644) {
            var header = [UInt8](repeating: 0, count: 512)
            func write(_ string: String, at offset: Int, max: Int) {
                let encoded = Array(string.utf8.prefix(max))
                header.replaceSubrange(offset..<offset + encoded.count, with: encoded)
            }
            func writeOctal(_ value: Int, at offset: Int, width: Int) {
                let s = String(value, radix: 8)
                let padded = String(repeating: "0", count: max(0, width - 1 - s.count)) + s
                write(padded, at: offset, max: width - 1)
            }
            write(name, at: 0, max: 100)
            writeOctal(mode, at: 100, width: 8)
            writeOctal(0, at: 108, width: 8)   // uid
            writeOctal(0, at: 116, width: 8)   // gid
            writeOctal(data.count, at: 124, width: 12)
            writeOctal(Int(Date().timeIntervalSince1970), at: 136, width: 12)
            write("        ", at: 148, max: 8) // chksum placeholder: 8 spaces per POSIX
            header[156] = UInt8(ascii: "0")    // type: regular file
            write("ustar", at: 257, max: 6)
            var checksum = 0
            for b in header { checksum += Int(b) }
            writeOctal(checksum, at: 148, width: 8)
            bytes.append(contentsOf: header)
            bytes.append(data)
            let pad = (512 - (data.count % 512)) % 512
            if pad > 0 { bytes.append(Data(count: pad)) }
        }

        mutating func finish() -> Data {
            bytes.append(Data(count: 1024)) // end-of-archive: two zero blocks
            return bytes
        }
    }

    // MARK: - Metadata

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Trailing metadata block Joplin's importer anchors on. `type_` is
    /// LAST on purpose — its parser looks for it to delimit the block.
    private static func metadataBlock(fields: [(String, String)], type: Int) -> String {
        var lines = fields.map { "\($0.0): \($0.1)" }
        lines.append("type_: \(type)")
        return "\n\n" + lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Entry builders

    private static func noteEntry(_ note: NotePayload) -> (name: String, data: Data) {
        var fields: [(String, String)] = [
            ("id", note.id)
        ]
        if let parent = note.notebookId { fields.append(("parent_id", parent)) }
        fields.append(("created_time", iso(note.createdAt)))
        fields.append(("updated_time", iso(note.updatedAt)))
        fields.append(("markup_language", "1")) // 1 = markdown
        let body = note.markdownBody + metadataBlock(fields: fields, type: 1)
        return ("\(note.id).md", Data(body.utf8))
    }

    private static func notebookEntry(_ nb: NotebookPayload) -> (name: String, data: Data) {
        var fields: [(String, String)] = [
            ("id", nb.id)
        ]
        if let parent = nb.parentId { fields.append(("parent_id", parent)) }
        fields.append(("created_time", iso(nb.createdAt)))
        let body = nb.title + metadataBlock(fields: fields, type: 2)
        return ("\(nb.id).md", Data(body.utf8))
    }

    private static func resourceMetadataEntry(_ image: ImagePayload) -> (name: String, data: Data) {
        let fields: [(String, String)] = [
            ("id", image.id),
            ("title", image.id + "." + image.fileExtension),
            ("mime", image.mimeType),
            ("filename", ""),
            ("created_time", iso(Date()))
        ]
        let body = metadataBlock(fields: fields, type: 4)
        return ("\(image.id).md", Data(body.utf8))
    }

    // MARK: - Public API

    /// Builds the .jex payload. Notes referencing notebook ids not in
    /// `notebooks` are dropped from the archive (a dangling parent_id makes
    /// Joplin's importer complain); caller should filter first or pass a
    /// consistent set.
    public static func buildArchive(
        notes: [NotePayload],
        notebooks: [NotebookPayload]
    ) -> Data {
        var tar = TarWriter()

        let notebookIds = Set(notebooks.map(\.id))
        for nb in notebooks {
            let entry = notebookEntry(nb)
            tar.append(name: entry.name, data: entry.data)
        }
        var emittedResources = Set<String>()
        for note in notes where note.notebookId.map({ notebookIds.contains($0) }) ?? true {
            let entry = noteEntry(note)
            tar.append(name: entry.name, data: entry.data)
            for image in note.images where !emittedResources.contains(image.id) {
                emittedResources.insert(image.id)
                let meta = resourceMetadataEntry(image)
                tar.append(name: meta.name, data: meta.data)
                tar.append(name: "resources/\(image.id).\(image.fileExtension)", data: image.data)
            }
        }
        return tar.finish()
    }
}

// MARK: - App-side adapter

public extension JexExport {

    /// Adapter from a (markdownBody, noteId) pair: extracts every
    /// `speechnotes://note-image/<hash>.<ext>` reference from the markdown
    /// and materializes an ImagePayload with the stored bytes. Notes whose
    /// images don't resolve contribute no resource entries (the body then
    /// shows a broken image in Joplin, but still imports).
    static func payloads(
        notes: [(id: UUID, title: String, body: String, notebookId: UUID?, createdAt: Date, updatedAt: Date)],
        notebooks: [(id: UUID, title: String, createdAt: Date)]
    ) -> (notes: [NotePayload], notebooks: [NotebookPayload]) {
        let nbPayloads = notebooks.map {
            NotebookPayload(
                id: joplinId($0.id),
                title: $0.title,
                parentId: nil,
                createdAt: $0.createdAt
            )
        }
        let notePayloads = notes.map { note in
            NotePayload(
                id: joplinId(note.id),
                title: note.title,
                markdownBody: note.body,
                notebookId: note.notebookId.map(joplinId),
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                images: images(in: note.body, noteId: note.id)
            )
        }
        return (notePayloads, nbPayloads)
    }

    /// Joplin ids are 32 lowercase hex. A UUID's dashes stripped satisfy it
    /// exactly and stay stable across re-exports (Joplin updates rather
    /// than duplicates).
    static func joplinId(_ uuid: UUID) -> String {
        uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func images(in markdown: String, noteId: UUID) -> [ImagePayload] {
        // Find every speechnotes://note-image/<hash>.<ext> reference, then
        // read the file NoteImageStore persisted.
        let targets = NoteImageStore.allTargets(for: noteId).filter { markdown.contains($0) }
        return targets.compactMap { target in
            guard let url = NoteImageStore.resolveLocalURL(target, noteId: noteId),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let parsed = NoteImageStore.parseLocalTarget(target) else { return nil }
            let mime = Self.mimeType(for: parsed.ext)
            return ImagePayload(
                id: joplinResourceId(from: parsed.hash),
                fileExtension: parsed.ext,
                mimeType: mime,
                data: data
            )
        }
    }

    /// NoteImageStore content-hash ids are 64-char hex; Joplin wants 32.
    /// Take the leading 32 — still collision-safe at this scale.
    private static func joplinResourceId(from hash: String) -> String {
        String(hash.prefix(32)).lowercased()
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}
