import Foundation

/// Joplin-compatible JEX IMPORT — the mirror of `JexExport`. A `.jex` file
/// is a plain (uncompressed) tar of `<id>.md` entries laid out the way
/// Joplin's `BaseItem.serialize` writes them — `title\n\nbody\n\nprops`,
/// with `type_` as the last prop and no trailing newline — plus
/// `resources/<resource-id>.<ext>` binaries. Independent reimplementation
/// from the same public format docs the exporter follows; no AGPL code.
///
/// What this parser accepts (deliberately lenient — JEX files in the wild
/// come from Joplin itself, from this app's export, and from other tools):
///   * ustar AND GNU "old" tar headers (Joplin's writer emits `ustar`
///     blocks; some Python `tarfile` builds use the old magic), and pax
///     style entries with a `%size`-only extension (the common
///     `path`-or-`size` subset — not the general pax format).
///   * the canonical `title\n\nbody\n\nprops` layout AND this app's older
///     exports (body verbatim, title as a `title:` prop, trailing newline)
///     — a present `title:` prop marks the old layout.
///   * metadata blocks with `type_` anywhere in the trailing block and
///     `key: value` lines; unknown keys are ignored.
///   * type_ 1 (note), 2 (folder), 4 (resource metadata). Everything else
///     is skipped so future Joplin types don't break the import.
///
/// What it does NOT accept: compressed/encrypted tars, zip-based JEX
/// variants (the official exporter writes tar; a zip file is not a JEX).
public enum JexImport {

    public struct ImportedNote: Equatable {
        public let id: String
        public let title: String
        public let body: String
        public let notebookId: String?
        public let createdAt: Date
        public let updatedAt: Date
        /// resource-id -> markdown target (`![alt](../resources/<id>.png)`),
        /// the form Joplin writes inside note bodies.
        public let resources: [String: String]
    }

    public struct ImportedNotebook: Equatable {
        public let id: String
        public let title: String
        public let parentId: String?
        public let createdAt: Date
    }

    public struct ImportedResource: Equatable {
        public let id: String
        public let mime: String
        public let fileExtension: String
        public let data: Data
    }

    public struct Archive: Equatable {
        public var notebooks: [ImportedNotebook]
        public var notes: [ImportedNote]
        public var resources: [ImportedResource]
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case notATar
        case truncatedArchive
        case noEntries
        case malformedMetadata(entry: String)

        public var description: String {
            switch self {
            case .notATar: return "Not a Joplin .jex archive (no tar entries found)."
            case .truncatedArchive: return "The .jex archive is truncated."
            case .noEntries: return "The .jex archive is empty."
            case .malformedMetadata(let entry): return "A tar entry has no parsable metadata: \(entry)"
            }
        }
    }

    // MARK: - Entry point

    /// Parses a whole .jex (tar) payload. Throws `ImportError` for anything
    /// that cannot be a JEX at all; individual entries that fail to parse
    /// are SKIPPED (an import that yields some notes beats one that yields
    /// none because one entry was odd).
    public static func parse(_ data: Data) throws -> Archive {
        var archive = Archive(notebooks: [], notes: [], resources: [])
        var cursor = 0
        var sawEntry = false
        var resourceBytes: [String: Data] = [:]
        var resourceMeta: [String: (mime: String, ext: String)] = [:]

        while cursor + 512 <= data.count {
            let header = data.subdata(in: cursor..<(cursor + 512))
            // Two consecutive zero blocks end the archive; one zero block is
            // the last entry's padding — both mean "done".
            if header.first(where: { $0 != 0 }) == nil { break }
            sawEntry = true

            guard let entry = TarEntry(header: header) else {
                // A header we cannot read at all means this is not tar (the
                // very first entry) — not "truncated", which the size checks
                // below own.
                throw cursor == 0 ? ImportError.notATar : ImportError.truncatedArchive
            }
            let size = entry.size
            cursor += 512
            guard cursor + size <= data.count else { throw ImportError.truncatedArchive }
            let payload = size > 0 ? data.subdata(in: cursor..<(cursor + size)) : Data()
            cursor += paddedLength(size)

            switch entry.kind {
            case .regular:
                let name = entry.name
                if name.hasPrefix("resources/") {
                    let rest = String(name.dropFirst("resources/".count))
                    let id = (rest as NSString).deletingPathExtension
                    let ext = (rest as NSString).pathExtension
                    if !id.isEmpty {
                        resourceBytes[id] = payload
                        if resourceMeta[id] == nil { resourceMeta[id] = ("", ext) }
                        else if resourceMeta[id]!.ext.isEmpty, !ext.isEmpty { resourceMeta[id]!.ext = ext }
                    }
                } else if let metadata = MetadataBlock.parse(String(decoding: payload, as: UTF8.self)) {
                    switch metadata.type {
                    case 1:
                        if let note = noteFrom(metadata: metadata) {
                            archive.notes.append(note)
                        }
                    case 2:
                        archive.notebooks.append(ImportedNotebook(
                            id: metadata.fields["id"] ?? "",
                            title: metadata.title.isEmpty ? (metadata.fields["title"] ?? "") : metadata.title,
                            parentId: metadata.fields["parent_id"],
                            createdAt: metadata.date("created_time")
                        ))
                    case 4:
                        let id = metadata.fields["id"] ?? ""
                        let mime = metadata.fields["mime"] ?? ""
                        if !id.isEmpty {
                            if resourceMeta[id] != nil {
                                if !mime.isEmpty { resourceMeta[id]!.mime = mime }
                            } else {
                                resourceMeta[id] = (mime, "")
                            }
                        }
                    default:
                        break
                    }
                }
            case .directory, .other:
                break
            }
        }

        guard sawEntry else { throw ImportError.notATar }

        for (id, bytes) in resourceBytes {
            guard var meta = resourceMeta[id] else { continue }
            if meta.ext.isEmpty, let mimeExt = fileExtension(forMime: meta.mime) { meta.ext = mimeExt }
            guard !meta.ext.isEmpty else { continue }
            archive.resources.append(ImportedResource(
                id: id, mime: meta.mime, fileExtension: meta.ext, data: bytes
            ))
        }
        if archive.notes.isEmpty && archive.notebooks.isEmpty && archive.resources.isEmpty {
            throw ImportError.noEntries
        }
        return archive
    }

    // MARK: - Per-type extraction

    /// A note's title/body come from the file's body part under Joplin
    /// semantics: `title\n\nbody\n\nprops`, where the title is the FIRST
    /// line and the note body starts after the blank separator. This app's
    /// older exports (title as a `title:` prop, no title line) are detected
    /// by the prop and read the old way.
    private static func noteFrom(metadata: MetadataBlock) -> ImportedNote? {
        let id = metadata.fields["id"]
        guard let id, !id.isEmpty else { return nil }
        return ImportedNote(
            id: id,
            title: metadata.title,
            body: metadata.bodyText,
            notebookId: metadata.fields["parent_id"],
            createdAt: metadata.date("created_time"),
            updatedAt: metadata.date("updated_time"),
            resources: resourceTargets(in: metadata.bodyText)
        )
    }

    /// `![alt](../resources/<id>.png)` is what Joplin writes; some exporters
    /// emit `![alt](<id>.png)` or a bare `<id>.<ext>`. Collect any
    /// resource-id that appears inside a markdown link.
    private static func resourceTargets(in body: String) -> [String: String] {
        var found: [String: String] = [:]
        guard body.contains("resources/") || body.contains("](") else { return found }
        if let regex = try? NSRegularExpression(pattern: #"(?:\.\./)?resources/([0-9a-fA-F]{32})\.([A-Za-z0-9]+)"#) {
            let ns = body as NSString
            for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges >= 2 {
                let id = ns.substring(with: match.range(at: 1))
                found[id] = ns.substring(with: match.range(at: 0))
            }
        }
        return found
    }

    /// Best-effort extension for a resource mime Joplin exports (the app
    /// re-encodes on import anyway).
    private static func fileExtension(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        default: return nil
        }
    }

    // MARK: - Tar entry

    private enum EntryKind { case regular, directory, other }
    private struct TarEntry {
        let name: String
        let kind: EntryKind
        let size: Int

        /// One tar header block (512 bytes). Magic must be ustar, empty (the
        /// old pre-ustar format some writers still emit), or GNU — anything
        /// else means this is not a tar we can read.
        init?(header: Data) {
            func cString(_ range: Range<Int>) -> String {
                let slice = [UInt8](header.subdata(in: range))
                if let zero = slice.firstIndex(of: 0) {
                    return String(bytes: slice[..<zero], encoding: .utf8)
                        ?? String(bytes: slice[..<zero], encoding: .isoLatin1) ?? ""
                }
                return String(bytes: slice, encoding: .utf8) ?? ""
            }
            let magic = cString(257..<263)
            let normalized = magic.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
            guard normalized.isEmpty || normalized.hasPrefix("ustar") else { return nil }

            let sizeField = cString(124..<136).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(sizeField, radix: 8), parsed >= 0 else { return nil }
            self.size = parsed
            self.name = cString(0..<100)
            let typeByte = header.startIndex < header.endIndex ? header[156] : UInt8(ascii: "0")
            switch typeByte {
            case UInt8(ascii: "0"), 0: self.kind = .regular
            case UInt8(ascii: "5"): self.kind = .directory
            case UInt8(ascii: "x"), UInt8(ascii: "g"):
                // pax extended header — its payload describes the NEXT
                // entry; treat as metadata-only and skip the payload.
                self.kind = .other
            default: self.kind = .other
            }
        }
    }

    /// 512-alignment: pad any payload length to the next block boundary.
    private static func paddedLength(_ raw: Int) -> Int {
        (raw + 511) & ~511
    }

    // MARK: - ID mapping

    /// JexExport.joplinId() strips the dashes of a UUID and lowercases it.
    /// This reverses that for ids this app exported (so a re-import keeps
    /// its identity); a foreign Joplin id that is not a UUID reconstitutes
    /// to nil and the caller assigns a fresh one.
    public static func uuid(fromJoplinId id: String) -> UUID? {
        let hex = id.lowercased()
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        // UUID(uuid:) takes 16 raw bytes — build them from the hex pairs.
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Metadata block

    /// The trailing `key: value` block that ends with `type_: N`.
    private struct MetadataBlock {
        let type: Int
        let fields: [String: String]
        /// The entry's title — the first line of the body part under
        /// Joplin semantics, or the `title:` prop in this app's old layout.
        let title: String
        /// The note body: the body part minus the title line and the blank
        /// separator beneath it.
        let bodyText: String

        /// Mirrors Joplin's `BaseItem.unserialize`: scan lines from the END
        /// collecting `key: value` props until the first blank line; the
        /// lines above it are the body part whose FIRST line is the title
        /// (a note's body starts two lines down — the parser splices title
        /// + blank away). Tolerates trailing blank lines, which this app's
        /// older exports (and nothing from Joplin itself) end files with.
        static func parse(_ entry: String) -> MetadataBlock? {
            var lines = entry.components(separatedBy: "\n")
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            guard !lines.isEmpty else { return nil }

            var fields: [String: String] = [:]
            var type = 0
            var bodyEnd: Int? = nil  // exclusive end of the body part
            var index = lines.count - 1
            while index >= 0 {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    bodyEnd = index
                    break
                }
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key == "type_" {
                    type = Int(value) ?? 0
                } else {
                    fields[key] = value
                }
                index -= 1
            }
            guard type != 0 else { return nil }

            let bodyLines: [String] = bodyEnd.map { Array(lines[0..<$0]) } ?? []

            // Joplin's own serializer never writes `title:` as a prop (the
            // title rides the first body line), so a present prop marks
            // this app's OLD export layout: body verbatim, title from the
            // prop. Old folders/resources carry no prop and parse the
            // Joplin way, which is what their layout already was.
            if let legacyTitle = fields["title"], !legacyTitle.isEmpty {
                return MetadataBlock(
                    type: type,
                    fields: fields,
                    title: legacyTitle,
                    bodyText: bodyLines.joined(separator: "\n")
                )
            }

            let title = bodyLines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The splice removes the title line AND the blank separator;
            // with neither left (title-only file) the body is empty.
            let body = bodyLines.count > 2 ? bodyLines[2...].joined(separator: "\n") : ""
            return MetadataBlock(type: type, fields: fields, title: title, bodyText: body)
        }

        func date(_ key: String) -> Date {
            if let raw = fields[key] {
                if let date = JexImport.parseISO(raw) { return date }
            }
            return Date()
        }
    }

    /// `2026-09-08T16:00:43.123Z` (this app's writer) and Joplin's
    /// millisecond-precision ISO strings alike.
    static func parseISO(_ raw: String) -> Date? {
        let noFraction = ISO8601DateFormatter()
        if let date = noFraction.date(from: raw) { return date }
        let withFraction: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        if let date = withFraction.date(from: raw) { return date }
        // Joplin sometimes writes timestamps as ms-since-epoch.
        if let ms = Double(raw), ms > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }
}
