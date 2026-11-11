// XML.swift — the bounded XML DOM the deck readers share.
//
// Ported from DeckCraft's pptx crate `xml.rs` (github.com/storytold/deckcraft
// @ a0eeb34, MIT/Apache-2.0) and the write-side builder skipped: the deck
// stack only ever READS parts, so the `W`/`A` string builders are not ported.
//
// The Rust file leans on quick-xml; this port carries the same event
// semantics by hand (a small scanner over the UTF-8 bytes) because Foundation's
// XMLParser resolves entity references inline and would merge a `&#13;`
// character reference into the same text as a literal CR — the two must stay
// distinguishable (XML 1.0 §2.11: a literal CR LF or lone CR reads as LF; a
// `&#13;` reference is not literal and stays a CR). Reading is lenient about
// namespaces: elements and attributes are matched by local name, which is how
// real-world files are best understood (prefixes are conventional and stable
// in practice).

import Foundation

/// Maximum element nesting accepted when parsing.
let xmlMaxDepth = 256
/// Maximum number of elements in one part.
let xmlMaxNodes = 4_000_000

/// One XML element with its attributes and children, in document order.
/// A value type on purpose: the Rust model clones `El`s freely and mutates
/// the clones (`slide.clone()` in the text assembly); reference semantics
/// would write through to the shared original. Swift's copy-on-write arrays
/// make the clones cheap until they are actually mutated.
public struct XEl {
    /// Qualified name as written (`p:sp`).
    public let name: String
    public var attrs: [(String, String)]
    public var children: [XNode]

    init(name: String, attrs: [(String, String)]) {
        self.name = name
        self.attrs = attrs
        self.children = []
    }

    /// The local name (`sp` of `p:sp`).
    public var local: String {
        if let idx = name.lastIndex(of: ":") { return String(name[name.index(after: idx)...]) }
        return name
    }

    /// The namespace prefix (`p` of `p:sp`), empty when none.
    public var prefix: String {
        if let idx = name.firstIndex(of: ":") { return String(name[name.startIndex..<idx]) }
        return ""
    }

    /// True when the element's local name is `local`.
    public func isNamed(_ local: String) -> Bool { self.local == local }

    static func localOf(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") { return String(name[name.index(after: idx)...]) }
        return name
    }

    /// Attribute by local name (`id` matches `id`; `r:id` matches `id` only
    /// when no plain `id` exists). A qualified name (`r:id`) requires that
    /// prefix's local name with any prefix.
    public func attr(_ name: String) -> String? {
        if let colon = name.firstIndex(of: ":") {
            let local = String(name[name.index(after: colon)...])
            for (k, v) in attrs where k.contains(":") && !k.hasPrefix("xmlns") && XEl.localOf(k) == local {
                return v
            }
            return nil
        }
        if let exact = attrs.first(where: { $0.0 == name }) { return exact.1 }
        for (k, v) in attrs where !k.hasPrefix("xmlns") && XEl.localOf(k) == name {
            return v
        }
        return nil
    }

    public func hasAttr(_ name: String) -> Bool { attr(name) != nil }

    /// Integer attribute: parses as an integer, or as a finite float clamped
    /// into range (some producers write `1.0` for one).
    public func i64(_ name: String) -> Int64? {
        guard let v = attr(name)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let i = Int64(v) { return i }
        if let f = Double(v), f.isFinite {
            let clamped = max(-9.0e18, min(9.0e18, f))
            if clamped.magnitude < 9.22e18 { return Int64(clamped) }
        }
        return nil
    }

    public func i32(_ name: String) -> Int32? {
        guard let v = i64(name) else { return nil }
        return Int32(clamping: v)
    }

    public func u32(_ name: String) -> UInt32? {
        guard let v = i64(name) else { return nil }
        return UInt32(clamping: v)
    }

    public func f64(_ name: String) -> Double? {
        guard let v = attr(name)?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard let f = Double(v), f.isFinite else { return nil }
        return f
    }

    public func bool(_ name: String) -> Bool? {
        switch attr(name)?.trimmingCharacters(in: .whitespaces) {
        case "1", "true", "on": return true
        case "0", "false", "off": return false
        default: return nil
        }
    }

    /// The element children, in document order (text nodes skipped).
    public var elements: [XEl] {
        children.compactMap { node in if case .el(let e) = node { return e }; return nil }
    }

    /// The first element child whose local name is `local`.
    public func child(_ local: String) -> XEl? {
        elements.first { $0.isNamed(local) }
    }

    /// Every element child whose local name is `local`.
    public func childrenNamed(_ local: String) -> [XEl] {
        elements.filter { $0.isNamed(local) }
    }

    /// Follow a chain of child local names.
    public func path(_ names: [String]) -> XEl? {
        var cur: XEl? = self
        for n in names {
            cur = cur?.child(n)
            if cur == nil { return nil }
        }
        return cur
    }

    /// First descendant (depth-first, bounded) with this local name.
    public func find(_ local: String) -> XEl? {
        findRecursive(local, depth: 0)
    }

    private func findRecursive(_ local: String, depth: Int) -> XEl? {
        if depth > xmlMaxDepth { return nil }
        for c in elements {
            if c.isNamed(local) { return c }
            if let f = c.findRecursive(local, depth: depth + 1) { return f }
        }
        return nil
    }

    /// All descendants with this local name (bounded depth), document order.
    public func findAll(_ local: String) -> [XEl] {
        var out: [XEl] = []
        findAllRecursive(local, depth: 0, into: &out)
        return out
    }

    private func findAllRecursive(_ local: String, depth: Int, into out: inout [XEl]) {
        if depth > xmlMaxDepth { return }
        for c in elements {
            if c.isNamed(local) { out.append(c) }
            c.findAllRecursive(local, depth: depth + 1, into: &out)
        }
    }

    /// Concatenated text content of this element and its descendants.
    public func text() -> String {
        var s = ""
        textRecursive(into: &s, depth: 0)
        return s
    }

    private func textRecursive(into s: inout String, depth: Int) {
        if depth > xmlMaxDepth { return }
        for c in children {
            switch c {
            case .text(let t): s += t
            case .el(let e): e.textRecursive(into: &s, depth: depth + 1)
            }
        }
    }

    /// Value of `<x val="…"/>` child.
    public func childVal(_ local: String) -> String? {
        child(local)?.attr("val")
    }
}

/// A child of an element: another element or a text run. Not `indirect` on
/// purpose — the recursion only passes through `XEl.children`, an Array, whose
/// heap-backed buffer breaks the layout cycle (exactly the shape of the Rust
/// `Vec<Node>`), so both payloads store inline and no per-node boxing happens.
public enum XNode {
    case el(XEl)
    case text(String)
}

/// A parsed document: its root element (namespace declarations ride the
/// root's own attrs, so `nsDecls` is a filter, not a separate list).
public struct XDoc {
    public let root: XEl

    /// Namespace declarations (`xmlns:x`, `xmlns`) on the root element.
    public var nsDecls: [(String, String)] {
        root.attrs.filter { $0.0 == "xmlns" || $0.0.hasPrefix("xmlns:") }
    }
}

public enum XError: Error, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let why): return "xml: \(why)"
        }
    }
}

/// Parse XML bytes into a DOM. Bounded depth and node count; entity
/// references are resolved; a truncated document folds its unclosed elements
/// up so partial content is still usable.
public func parseXML(_ raw: [UInt8]) throws -> XDoc {
    // Skip a UTF-8 BOM; UTF-16 parts (rare) are decoded first.
    let text: String
    if raw.starts(with: [0xFF, 0xFE]) || raw.starts(with: [0xFE, 0xFF]) {
        text = decodeUTF16(raw)
    } else {
        let body = raw.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(raw[3...]) : raw
        text = String(decoding: body, as: UTF8.self)
    }
    return try XDOMBuilder(text).build()
}

/// The event-driven build of the DOM, mirroring the Rust `parse` match.
private final class XDOMBuilder {
    private let source: String
    private var bytes: [UInt8] = []
    private var pos = 0
    private var stack: [XEl] = []
    private var root: XEl?
    private var nodes = 0
    /// Nesting level of a subtree being skipped after its start element hit a
    /// limit: every start inside it raises this, every end lowers it, and the
    /// whole subtree vanishes instead of corrupting sibling structure.
    private var skipDepth = 0

    init(_ source: String) {
        self.source = source
        self.bytes = Array(source.utf8)
    }

    func build() throws -> XDoc {
        while pos < bytes.count {
            let b = bytes[pos]
            if b == 0x3C { // '<'
                if let event = try scanMarkup() {
                    handle(event)
                }
            } else if b == 0x26 { // '&'
                let ref = scanReference()
                if let ref {
                    pushText(ref)
                } else {
                    // Lenient: a bare '&' that is not a reference is text.
                    pushText("&")
                    pos += 1
                }
            } else {
                let t = scanText()
                if let t { handle(.text(t)) }
            }
        }
        // Unclosed elements (truncated document): fold them up so partial
        // content is still usable.
        while let el = stack.popLast() {
            attach(el)
        }
        guard let root else { throw XError.malformed("no root element") }
        return XDoc(root: root)
    }

    // MARK: events

    private enum Event {
        case start(XEl)
        case empty(XEl)
        case end
        case text(String)
        case cdata(String)
    }

    private func handle(_ event: Event) {
        switch event {
        case .start(let el):
            nodes += 1
            if nodes > xmlMaxNodes || stack.count >= xmlMaxDepth {
                // The Rust reader errors out; here the over-limit subtree is
                // dropped whole (until its matching end) and the scan
                // continues — the DOM already built stays usable and its
                // siblings stay siblings, which is what a viewer wants of a
                // hostile part it cannot fully read.
                nodes = xmlMaxNodes
                skipDepth += 1
                return
            }
            stack.append(el)
        case .empty(let el):
            nodes += 1
            if nodes > xmlMaxNodes || skipDepth > 0 { return }
            attach(el)
        case .end:
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            if let el = stack.popLast() {
                attach(el)
            }
        case .text(let t):
            guard skipDepth == 0 else { return }
            pushText(lineEnds(t))
        case .cdata(let t):
            guard skipDepth == 0 else { return }
            pushText(lineEnds(t))
        }
    }

    private func attach(_ el: XEl) {
        if !stack.isEmpty {
            stack[stack.count - 1].children.append(.el(el))
        } else if root == nil {
            // First element to close at depth 0 is the root; everything the
            // scan finds after it is ignored (content after the root).
            root = el
        }
    }

    private func pushText(_ s: String) {
        guard !s.isEmpty, !stack.isEmpty else { return }
        let top = stack.count - 1
        if case .text(let t)? = stack[top].children.last {
            stack[top].children[stack[top].children.count - 1] = .text(t + s)
        } else {
            stack[top].children.append(.text(s))
        }
    }

    // MARK: scanner

    /// Consumes one markup construct at a '<'. Returns nil when the markup
    /// is a declaration to skip (comment, PI, DOCTYPE).
    private func scanMarkup() throws -> Event? {
        // pos is at '<'.
        let rest0 = pos + 1
        guard rest0 < bytes.count else { throw XError.malformed("dangling '<'") }
        let b = bytes[rest0]
        if b == 0x21 { // '!' — comment, CDATA or DOCTYPE
            // The needles start at the '<' itself, i.e. at pos, not rest0.
            if has(pos, "<![CDATA[") {
                let start = rest0 + 9
                var end = start
                while end + 2 < bytes.count, !(bytes[end] == 0x5D && bytes[end + 1] == 0x5D && bytes[end + 2] == 0x3E) {
                    end += 1
                }
                let body = Array(bytes[start..<min(end, bytes.count)])
                pos = min(end + 3, bytes.count)
                return .cdata(String(decoding: body, as: UTF8.self))
            }
            if has(pos, "<!--") {
                pos = findSequence(rest0 + 4, "-->") ?? bytes.count
                return nil
            }
            // DOCTYPE and the rest of the <!…> family: skip to '>'.
            pos = findByte(rest0 + 2, 0x3E) ?? bytes.count
            return nil
        }
        if b == 0x3F { // '?' — processing instruction
            pos = findSequence(rest0 + 1, "?>") ?? bytes.count
            return nil
        }
        if b == 0x2F { // '/' — end tag
            pos = (findByte(rest0 + 1, 0x3E) ?? bytes.count) + 1
            return .end
        }
        // A start (or empty) tag: name, attributes, '>' or '/>'.
        var i = rest0
        while i < bytes.count, isNameByte(bytes[i]) { i += 1 }
        guard i > rest0 else { throw XError.malformed("tag without a name") }
        let name = String(decoding: bytes[rest0..<i], as: UTF8.self)
        var attrs: [(String, String)] = []
        while i < bytes.count {
            skipWhitespace(&i)
            guard i < bytes.count else { break }
            if bytes[i] == 0x3E { // '>'
                pos = i + 1
                return .start(XEl(name: name, attrs: attrs))
            }
            if bytes[i] == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x3E { // '/>'
                pos = i + 2
                return .empty(XEl(name: name, attrs: attrs))
            }
            // An attribute: name = value.
            var ks = i
            while ks < bytes.count, isNameByte(bytes[ks]) { ks += 1 }
            guard ks > i else {
                // Not a name (stray '>' was handled; junk here) — skip a byte.
                i += 1
                continue
            }
            let key = String(decoding: bytes[i..<ks], as: UTF8.self)
            i = ks
            skipWhitespace(&i)
            if i < bytes.count, bytes[i] == 0x3D { // '='
                i += 1
                skipWhitespace(&i)
                var value = ""
                if i < bytes.count, bytes[i] == 0x22 || bytes[i] == 0x27 { // " or '
                    let quote = bytes[i]
                    i += 1
                    var vs = i
                    while vs < bytes.count, bytes[vs] != quote {
                        vs += 1
                    }
                    value = attrValue(Array(bytes[i..<min(vs, bytes.count)]))
                    i = min(vs + 1, bytes.count)
                } else {
                    // Unquoted value (not legal XML, seen in the wild).
                    var vs = i
                    while vs < bytes.count, !isWhitespace(bytes[vs]), bytes[vs] != 0x3E { vs += 1 }
                    value = attrValue(Array(bytes[i..<vs]))
                    i = vs
                }
                attrs.append((key, value))
            } else {
                attrs.append((key, ""))
            }
        }
        throw XError.malformed("unterminated tag <\(name)")
    }

    /// Raw text up to the next '<' or '&'.
    private func scanText() -> String? {
        var i = pos
        while i < bytes.count, bytes[i] != 0x3C, bytes[i] != 0x26 { i += 1 }
        guard i > pos else { return nil }
        let t = String(decoding: bytes[pos..<i], as: UTF8.self)
        pos = i
        return t
    }

    /// A `&name;` / `&#NNN;` / `&#xHH;` reference at `pos`, resolved to the
    /// text it stands for. nil when this '&' is not a reference (literal).
    private func scanReference() -> String? {
        var i = pos + 1
        guard i < bytes.count else { return nil }
        if bytes[i] == 0x23 { // '#'
            i += 1
            var value = 0
            var hex = false
            if i < bytes.count, bytes[i] == 0x78 || bytes[i] == 0x58 { // x or X
                hex = true
                i += 1
            }
            var digits = 0
            while i < bytes.count, digits < 8 {
                let b = bytes[i]
                let d: Int
                if b >= 0x30 && b <= 0x39 { d = Int(b - 0x30) }
                else if hex && b >= 0x41 && b <= 0x46 { d = Int(b - 0x41) + 10 }
                else if hex && b >= 0x61 && b <= 0x66 { d = Int(b - 0x61) + 10 }
                else { break }
                value = value &* 16 &+ d
                digits += 1
                i += 1
            }
            guard digits > 0, i < bytes.count, bytes[i] == 0x3B else { return nil } // ';'
            pos = i + 1
            guard let scalar = Unicode.Scalar(UInt32(value)) else { return "" }
            return String(Character(scalar))
        }
        var j = i
        while j < bytes.count, isNameByte(bytes[j]) { j += 1 }
        guard j > i, j < bytes.count, bytes[j] == 0x3B else { return nil } // ';'
        let name = String(decoding: bytes[i..<j], as: UTF8.self)
        pos = j + 1
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: return ""
        }
    }

    // MARK: helpers

    /// An attribute value: entity references resolved; literal tab, LF and
    /// CR collapse to a space (XML 1.0 attribute normalization), while
    /// reference-resolved whitespace stays.
    private func attrValue(_ raw: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i < raw.count {
            if raw[i] == 0x26, let (resolved, next) = resolveReference(raw, at: i) {
                out += resolved
                i = next
            } else {
                switch raw[i] {
                case 0x09, 0x0A, 0x0D: out += " "
                default: out.append(Character(UnicodeScalar(raw[i])))
                }
                i += 1
            }
        }
        return out
    }

    /// Resolve one reference inside a byte slice; returns (text, nextIndex).
    /// A malformed reference degrades to a literal '&' (leniency).
    private func resolveReference(_ raw: [UInt8], at i: Int) -> (String, Int)? {
        guard i + 1 < raw.count else { return nil }
        if raw[i + 1] == 0x23 {
            var j = i + 2
            var hex = false
            if j < raw.count, raw[j] == 0x78 || raw[j] == 0x58 { hex = true; j += 1 }
            var value = 0
            var digits = 0
            while j < raw.count, digits < 8 {
                let b = raw[j]
                let d: Int
                if b >= 0x30 && b <= 0x39 { d = Int(b - 0x30) }
                else if hex && b >= 0x41 && b <= 0x46 { d = Int(b - 0x41) + 10 }
                else if hex && b >= 0x61 && b <= 0x66 { d = Int(b - 0x61) + 10 }
                else { break }
                value = value &* 16 &+ d
                digits += 1
                j += 1
            }
            guard digits > 0, j < raw.count, raw[j] == 0x3B else { return nil }
            guard let scalar = Unicode.Scalar(UInt32(value)) else { return ("", j + 1) }
            return (String(Character(scalar)), j + 1)
        }
        var j = i + 1
        while j < raw.count, isNameByte(raw[j]) { j += 1 }
        guard j > i + 1, j < raw.count, raw[j] == 0x3B else { return nil }
        let name = String(decoding: raw[(i + 1)..<j], as: UTF8.self)
        switch name {
        case "amp": return ("&", j + 1)
        case "lt": return ("<", j + 1)
        case "gt": return (">", j + 1)
        case "quot": return ("\"", j + 1)
        case "apos": return ("'", j + 1)
        default: return ("", j + 1)
        }
    }

    private func isNameByte(_ b: UInt8) -> Bool {
        // A permissive name byte set: the XML Name production's ASCII part.
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
            || b == 0x3A || b == 0x5F || b == 0x2D || b == 0x2E || b >= 0x80
    }

    private func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    private func skipWhitespace(_ i: inout Int) {
        while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
    }

    private func has(_ at: Int, _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard at + n.count <= bytes.count else { return false }
        return Array(bytes[at..<(at + n.count)]) == n
    }

    private func findByte(_ from: Int, _ b: UInt8) -> Int? {
        guard from < bytes.count else { return nil }
        for i in from..<bytes.count where bytes[i] == b { return i }
        return nil
    }

    private func findSequence(_ from: Int, _ needle: String) -> Int? {
        let n = Array(needle.utf8)
        guard from < bytes.count else { return nil }
        if n.isEmpty { return from }
        var i = from
        while i + n.count <= bytes.count {
            if Array(bytes[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }
}

/// XML 1.0 §2.11: a literal CR LF or lone CR in the document reads as LF.
/// Applied to Text and CDATA events only — a `&#13;` reference reaches
/// `pushText` through `scanReference`, so it stays a CR.
private func lineEnds(_ s: String) -> String {
    if s.contains("\r") {
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    return s
}

/// UTF-16 parts (rare): decode from the BOM and drop the encoding declaration
/// so the scan reads plain UTF-8 text.
private func decodeUTF16(_ bytes: [UInt8]) -> String {
    let le = bytes.starts(with: [0xFF, 0xFE])
    let body = Array(bytes.dropFirst(2))
    var units: [UInt16] = []
    units.reserveCapacity(body.count / 2)
    var i = 0
    while i + 1 < body.count {
        let u = le ? UInt16(body[i]) | (UInt16(body[i + 1]) << 8)
                   : (UInt16(body[i]) << 8) | UInt16(body[i + 1])
        units.append(u)
        i += 2
    }
    let s = String(decoding: units, as: UTF16.self)
    // Drop the encoding declaration.
    if s.hasPrefix("<?xml"), let end = s.firstIndex(of: ">") {
        return String(s[s.index(after: end)...])
    }
    return s
}
