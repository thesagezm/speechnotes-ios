import Foundation

/// Joplin-compatible JEX IMPORT — the mirror of `JexExport`. A `.jex` file
/// is a plain (uncompressed) tar of `<id>.md` entries whose trailing
/// metadata block carries the id/type/parent/timestamps, plus
/// `resources/<resource-id>.<ext>` binaries. Independent reimplementation
/// from the same public format docs the exporter follows; no AGPL code.
///
/// What this parser accepts (deliberately lenient — JEX files in the wild
/// come from Joplin itself, from this app's export, and from other tools):
///   * ustar AND GNU "old" tar headers (Joplin's writer emits `ustar`
///     blocks; some Python `tarfile` builds use the old magic), and pax
///     style entries with a `%size`-only extension (the common
///     `path`-or-`size` subset — not the general pax format).
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
                        if let note = noteFrom(metadata: metadata, bodyText: String(decoding: payload, as: UTF8.self)) {
                            archive.notes.append(note)
                        }
                    case 2:
                        let bodyText = String(decoding: payload, as: UTF8.self)
                        let title = bodyText
                            .components(separatedBy: "\n")
                            .first?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        archive.notebooks.append(ImportedNotebook(
                            id: metadata.fields["id"] ?? "",
                            title: title,
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

    /// A note's title in JEX is NOT in the metadata block (it is its own
    /// `title` field in the database, not the file). Exporters that follow
    /// Joplin's RAW format leave the first line of the body as the closest
    /// thing to a title; THIS app's exporter writes no separate title either.
    /// The body is everything before the metadata block, verbatim.
    private static func noteFrom(metadata: MetadataBlock, bodyText: String) -> ImportedNote? {
        let id = metadata.fields["id"]
        guard let id, !id.isEmpty else { return nil }
        return ImportedNote(
            id: id,
            title: metadata.fields["title"] ?? "",
            body: metadata.bodyText ?? "",
            notebookId: metadata.fields["parent_id"],
            createdAt: metadata.date("created_time"),
            updatedAt: metadata.date("updated_time"),
            resources: resourceTargets(in: metadata.bodyText ?? "")
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
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }), 
              let raw = UInt32(hex.prefix(8), radix: 16),
              let rest1 = UInt32(hex.dropFirst(8).prefix(4), radix: 16),
              let rest2 = UInt32(hex.dropFirst(12).prefix(4), radix: 16),
              let rest3 = UInt32(hex.dropFirst(16).prefix(4), radix: 16),
              let rest4 = UInt64(hex.dropFirst(20), radix: 16) else { return nil }
        return UUID(
            uuid: (raw, rest1, rest2, rest3, UInt8((rest4 >> 56) & 0xFF), UInt8((rest4 >> 48) & 0xFF),
                   UInt8((rest4 >> 40) & 0xFF), UInt8((rest4 >> 32) & 0xFF),
                   UInt8((rest4 >> 24) & 0xFF), UInt8((rest4 >> 16) & 0xFF),
                   UInt8((rest4 >> 8) & 0xFF), UInt8(rest4 & 0xFF))
        )
    }

    // MARK: - Metadata block

    /// The trailing `key: value` block that ends with `type_: N`.
    private struct MetadataBlock {
        let type: Int
        let fields: [String: String]
        /// Body text = everything before the metadata block began.
        let bodyText: String?

        static func parse(_ entry: String) -> MetadataBlock? {
            // The metadata block starts at the LAST occurrence of a line
            // `key: value` sequence ending in `type_:` — search from the end.
            guard let typeRange = entry.range(of: "\ntype_: ", options: .backwards) else { return nil }
            let blockStart = entry[..<typeRange.lowerBound]
            // Walk back to the blank line that begins the block.
            let head = String(blockStart)
            guard let separator = head.range(of: "\n\n", options: .backwards) else { return nil }
            let body = String(head[..<separator.lowerBound])
            let block = String(entry[separator.upperBound...])
            var fields: [String: String] = [:]
            var type = 0
            for line in block.components(separatedBy: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key.isEmpty { continue }
                if key == "type_" {
                    type = Int(value) ?? 0
                } else {
                    fields[key] = value
                }
            }
            guard type != 0 else { return nil }
            return MetadataBlock(type: type, fields: fields, bodyText: body)
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
