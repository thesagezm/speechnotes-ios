// Ooxml.swift — Open Packaging Conventions for the deck reader: part names,
// relationships and content types. Ported from deckcraft-pptx/src/opc.rs
// (read side only — the deck stack never writes PPTX) over the DeckZip
// reader.

import Foundation

public enum Ooxml {

    /// The files of a package, keyed by normalised part name (no leading
    /// slash, lowercase).
    public struct Package {
        var parts: [String: (original: String, data: Data)]
        var contentTypeCache: (overrides: [String: String], defaults: [String: String])?

        public static func open(_ bytes: Data) throws -> Package {
            let entries = try DeckZip.entries(in: bytes)
            var parts: [String: (String, Data)] = [:]
            for entry in entries {
                guard !entry.isDirectory else { continue }
                guard entry.uncompressedSize <= DeckZip.maxPart else { continue }
                let data = try DeckZip.read(entry, in: bytes)
                let name = normalize(entry.name)
                if parts[name] == nil {
                    parts[name] = (entry.name, data)
                }
            }
            // Content types, read once: (extension defaults, part overrides).
            var ov: [String: String] = [:]
            var def: [String: String] = [:]
            if let doc = Package(parts: parts, contentTypeCache: nil).xml("[Content_Types].xml") {
                for o in doc.root.childrenNamed("Override") {
                    if let n = o.attr("PartName"), let ct = o.attr("ContentType") {
                        ov[n.lowercased()] = ct
                    }
                }
                for d in doc.root.childrenNamed("Default") {
                    if let e = d.attr("Extension"), let ct = d.attr("ContentType") {
                        def[e.lowercased()] = ct
                    }
                }
            }
            return Package(parts: parts, contentTypeCache: (ov, def))
        }

        public func get(_ name: String) -> Data? {
            parts[normalize(name)]?.data
        }

        /// Parse an XML part with SlideDeckKit's bounded DOM.
        public func xml(_ name: String) -> XDoc? {
            guard let b = get(name), b.count <= DeckZip.maxXMLPart else { return nil }
            return try? parseXML([UInt8](b))
        }

        /// Relationships of a part (`ppt/slides/slide1.xml` →
        /// `ppt/slides/_rels/slide1.xml.rels`).
        public func rels(_ part: String) -> Rels {
            guard let doc = xml(relsPath(part)) else { return Rels() }
            return relsOf(doc, part: part)
        }

        /// Content types: (extension defaults, part overrides). The cache is
        /// built once at open time.
        public func contentType(_ part: String) -> String? {
            guard let cache = contentTypeCache else { return nil }
            if let ct = cache.overrides["/" + normalize(part)] {
                return ct
            }
            let ext = part.split(separator: ".").last.map { $0.lowercased() } ?? ""
            return cache.defaults[ext]
        }

        public func originalName(_ name: String) -> String? {
            parts[normalize(name)]?.original
        }
    }

    public struct Rel {
        public var id: String
        /// Last segment of the relationship type (`slide`, `image`, `media`…).
        public var kind: String
        /// Absolute part name for internal targets; the URL for external ones.
        public var target: String
        public var external: Bool
    }

    public struct Rels {
        public var items: [Rel] = []

        public func get(_ id: String) -> Rel? { items.first { $0.id == id } }
        public func target(_ id: String) -> String? { get(id)?.target }
        public func firstOf(_ kind: String) -> Rel? { items.first { $0.kind == kind } }
        public func allOf(_ kind: String) -> [Rel] { items.filter { $0.kind == kind } }
    }

    static func relsOf(_ doc: XDoc, part: String) -> Rels {
        let base = dirOf(part)
        var out = Rels()
        for r in doc.root.childrenNamed("Relationship") {
            guard let id = r.attr("Id"), let ty = r.attr("Type"), let target = r.attr("Target") else { continue }
            let external = (r.attr("TargetMode") ?? "").lowercased() == "external"
            let resolved = external ? target : resolve(base, target)
            out.items.append(Rel(
                id: id,
                kind: ty.split(separator: "/").last.map(String.init) ?? ty,
                target: resolved,
                external: external
            ))
        }
        return out
    }

    public static func normalize(_ name: String) -> String {
        var n = name
        while n.hasPrefix("/") { n.removeFirst() }
        return n.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    public static func dirOf(_ part: String) -> String {
        let p = part.hasPrefix("/") ? String(part.dropFirst()) : part
        guard let i = p.lastIndex(of: "/") else { return "" }
        return String(p[..<i])
    }

    public static func fileOf(_ part: String) -> String {
        part.split(separator: "/").last.map(String.init) ?? part
    }

    public static func relsPath(_ part: String) -> String {
        let p = part.hasPrefix("/") ? String(part.dropFirst()) : part
        let dir = dirOf(p)
        let file = fileOf(p)
        return dir.isEmpty ? "_rels/\(file).rels" : "\(dir)/_rels/\(file).rels"
    }

    static func percentDecode(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let b = Array(s.utf8)
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        func hexVal(_ c: UInt8) -> Int? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(c - UInt8(ascii: "A")) + 10
            default: return nil
            }
        }
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "%"), i + 2 < b.count, let hi = hexVal(b[i + 1]), let lo = hexVal(b[i + 2]) {
                out.append(UInt8(hi << 4 | lo))
                i += 3
                continue
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Resolve a relative target against a base directory into a part name.
    public static func resolve(_ base: String, _ target: String) -> String {
        let t = percentDecode(target.split(separator: "#").first.map(String.init) ?? "")
        var segs: [String] = t.hasPrefix("/") ? [] : base.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        for s in t.split(separator: "/") {
            switch s {
            case "", ".":
                continue
            case "..":
                if !segs.isEmpty { segs.removeLast() }
            default:
                segs.append(String(s))
            }
        }
        return segs.joined(separator: "/")
    }
}
