// PptxRead.swift — PPTX package → Presentation. Ported from deckcraft-pptx
// src/read/mod.rs + src/read/shapes.rs @ a0eeb34 (read side), carrying the
// viewer's subset: presentation size and slide order, the theme, masters and
// layouts, the slides' shape trees, notes text, the header/footer survey and
// the placeholder geometry/anchor passes. Charts, SmartArt, OLE objects,
// media clips, 3-D models, comments, sections and animations are NOT
// modelled — the shapes that carry them arrive as opaque frames (the
// reference's documented degradation, without its chart SVG).

import Foundation

public enum Pptx {

    /// The magic of a compound-file binary (a legacy `.ppt`, or an encrypted
    /// OOXML package).
    static let cfbMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    public static func isEncrypted(_ bytes: Data) -> Bool {
        guard bytes.count >= 8 else { return false }
        // A CFB at all means either a legacy .ppt (the caller routes by
        // extension) or an encrypted OOXML package; the EncryptionInfo
        // stream tells the two apart.
        return Array(bytes.prefix(8)) == cfbMagic && containsStream(bytes, name: "EncryptionInfo")
    }

    public static func sniffs(_ bytes: Data) -> Bool {
        guard bytes.count >= 4 else { return false }
        let d = [UInt8](bytes.prefix(4))
        return d == [0x50, 0x4B, 0x03, 0x04] || d == [0x50, 0x4B, 0x05, 0x06] || d == [0x50, 0x4B, 0x07, 0x08]
    }

    /// A named CFB stream exists (byte search — the header's directory sector
    /// walk is not worth it for a two-stream sniff).
    private static func containsStream(_ bytes: Data, name: String) -> Bool {
        guard let needle = name.data(using: .utf8) else { return false }
        return bytes.range(of: needle, options: [.backwards]) != nil
    }

    // -----------------------------------------------------------------------
    // Import
    // -----------------------------------------------------------------------

    public static func `import`(_ bytes: Data) throws -> Presentation {
        guard !isEncrypted(bytes) else { throw SlideError.encrypted }
        guard sniffs(bytes) else { throw SlideError.notADeck("neither an OOXML package nor an ODF presentation") }
        let pkg: Ooxml.Package
        do {
            pkg = try Ooxml.Package.open(bytes)
        } catch {
            throw SlideError.read("\(error)")
        }
        let rootRels = pkg.rels("")
        let presPath = rootRels.firstOf("officeDocument")?.target ?? "ppt/presentation.xml"
        guard let presDoc = pkg.xml(presPath), presDoc.root.isNamed("presentation") else {
            throw SlideError.read("missing or unreadable \(presPath)")
        }
        let presPart = PartInfo(pkg, presPath)
        let presEl = presDoc.root
        let ctx = ReadCtx(pkg: pkg)

        var p = Presentation()

        // PptxSlide size (EMU → pt), sane bounds like the reference's sane_len.
        if let sz = presEl.child("sldSz") {
            let w = sz.i64("cx").map(emuToPt) ?? 960
            let h = sz.i64("cy").map(emuToPt) ?? 540
            p.slideW = saneLen(w, 960)
            p.slideH = saneLen(h, 540)
        }
        if let dts = presEl.child("defaultTextStyle") {
            p.defaultTextStyle = Dml.listStyle(ctx, presPart, dts)
        }

        // Masters, layouts and slides to read.
        let listedMasters: [String] = presEl.child("sldMasterIdLst").map { l in
            l.childrenNamed("sldMasterId").compactMap { m in
                presPart.rels.target(m.attr("r:id") ?? "")
            }
        } ?? []
        var masterPaths = listedMasters.isEmpty
            ? presPart.rels.allOf("slideMaster").map(\.target)
            : listedMasters
        var slideEntries: [(String, String)] = presEl.child("sldIdLst").map { l in
            l.childrenNamed("sldId").prefix(10_000).compactMap { s in
                guard let target = presPart.rels.target(s.attr("r:id") ?? "") else { return nil }
                return (s.attr("id") ?? "", target)
            }
        } ?? []
        // Dedup in list order (a repeated rel is one part).
        var seenMasters = Set<String>()
        masterPaths = masterPaths.filter { seenMasters.insert(Ooxml.normalize($0)).inserted }
        var seenSlides = Set<String>()
        slideEntries = slideEntries.filter { seenSlides.insert(Ooxml.normalize($0.1)).inserted }

        // Read the master/layout/slide XML docs once.
        var docs: [String: XDoc] = [:]
        for path in masterPaths + slideEntries.map(\.1) {
            let key = Ooxml.normalize(path)
            if docs[key] == nil, let d = pkg.xml(path) {
                docs[key] = d
            }
        }

        // PptxSlide parts, in presentation order.
        var slidePaths: [String] = []
        for (_, path) in slideEntries where docs[Ooxml.normalize(path)] != nil {
            ctx.slideByPart[Ooxml.normalize(path)] = slidePaths.count
            slidePaths.append(path)
        }

        // Masters and layouts. layoutByPart maps a layout part to the
        // (master, layout) indices the slides resolve through.
        var layoutByPart: [String: (Int, Int)] = [:]
        for (mi, mp) in masterPaths.enumerated() {
            guard let doc = docs[Ooxml.normalize(mp)] else { continue }
            p.masters.append(readMaster(ctx, mp, doc, docs, mi, &layoutByPart))
        }
        if p.masters.isEmpty {
            // A deck without a readable master still shows: one blank master
            // with one blank layout.
            var m = Master()
            m.name = "Default"
            m.layouts.append(Layout())
            p.masters.append(m)
        }

        // Slides.
        for path in slidePaths {
            guard let doc = docs[Ooxml.normalize(path)] else { continue }
            let part = PartInfo(pkg, path)
            var slide = readSlide(ctx, part, doc)
            // The layout rel names the layout part; its owner indices were
            // recorded when the master read it.
            if let lr = part.rels.firstOf("slideLayout"),
               let (mi, li) = layoutByPart[Ooxml.normalize(lr.target)] {
                slide.masterIndex = mi
                slide.layoutIndex = li
            } else {
                slide.masterIndex = 0
                slide.layoutIndex = 0
            }
            // Notes.
            if let n = part.rels.firstOf("notesSlide"), let nd = pkg.xml(n.target) {
                let np = PartInfo(pkg, n.target)
                slide.notes = readNotes(ctx, np, nd.root)
            }
            p.slides.append(slide)
        }

        // Document properties.
        if let r = rootRels.firstOf("core-properties"), let d = pkg.xml(r.target) {
            for e in d.root.elements {
                switch e.local {
                case "title": p.propsTitle = e.text()
                case "creator": p.propsAuthor = e.text()
                default: break
                }
            }
        }

        p.headerFooter = headerFooter(p)
        inheritPlaceholderGeometry(&p)
        defaultTextAnchor(&p)
        p.media = ctx.media.map { m in
            (id: m.id, name: "m\(m.id)", contentType: m.contentType, data: m.data)
        }
        return p
    }

    private static func saneLen(_ v: Double, _ dflt: Double) -> Double {
        v.isFinite && v >= 1 && v <= 20_000 ? v : dflt
    }

    // -----------------------------------------------------------------------
    // Parts
    // -----------------------------------------------------------------------

    static func colorMap(_ cm: XEl) -> [(String, String)] {
        cm.attrs.filter { !$0.0.hasPrefix("xmlns") }
    }

    /// A layout's or slide's `clrMapOvr/overrideClrMapping` (nil for
    /// `masterClrMapping` or none).
    static func colorMapOverride(_ root: XEl) -> [(String, String)]? {
        root.child("clrMapOvr")?.child("overrideClrMapping").map(colorMap)
    }

    static func background(_ ctx: ReadCtx, _ part: PartInfo, _ csld: XEl) -> Background? {
        guard let bg = csld.child("bg") else { return nil }
        if let pr = bg.child("bgPr") {
            return .fill(Dml.fillOf(ctx, part, pr) ?? .none)
        }
        guard let r = bg.child("bgRef") else { return nil }
        return .ref(
            idx: Int(min(r.u32("idx") ?? 1001, 1003)),
            color: Dml.color(r) ?? .scheme(.bg1)
        )
    }

    static func readMaster(_ ctx: ReadCtx, _ path: String, _ doc: XDoc, _ docs: [String: XDoc], _ masterIndex: Int, _ layoutByPart: inout [String: (Int, Int)]) -> Master {
        let pkg = ctx.pkg
        let part = PartInfo(pkg, path)
        let root = doc.root
        var m = Master()
        if let t = part.rels.firstOf("theme"), let td = pkg.xml(t.target) {
            let tp = PartInfo(pkg, t.target)
            m.theme = readTheme(ctx, tp, td.root)
        }
        if let cm = root.child("clrMap") {
            m.colorMap = colorMap(cm)
        }
        if let csld = root.child("cSld") {
            m.name = csld.attr("name") ?? ""
            m.background = background(ctx, part, csld)
            if let tree = csld.child("spTree") {
                m.shapes = spTree(ctx, part, tree, 0)
            }
        }
        if m.name.isEmpty { m.name = m.theme.name }
        if let ts = root.child("txStyles") {
            if let s = ts.child("titleStyle") { m.titleStyle = Dml.listStyle(ctx, part, s) }
            if let s = ts.child("bodyStyle") { m.bodyStyle = Dml.listStyle(ctx, part, s) }
            if let s = ts.child("otherStyle") { m.otherStyle = Dml.listStyle(ctx, part, s) }
        }
        // Layouts in list order, then any other related layouts.
        var lpaths: [String] = root.child("sldLayoutIdLst").map { l in
            l.childrenNamed("sldLayoutId").compactMap { part.rels.target($0.attr("r:id") ?? "") }
        } ?? []
        for r in part.rels.allOf("slideLayout") where !lpaths.contains(where: { Ooxml.normalize($0) == Ooxml.normalize(r.target) }) {
            lpaths.append(r.target)
        }
        for lp in lpaths.prefix(1000) {
            let key = Ooxml.normalize(lp)
            guard layoutByPart[key] == nil else { continue }
            guard let ld = docs[key] else { continue }
            let lpart = PartInfo(pkg, lp)
            let l = readLayout(ctx, lpart, ld)
            layoutByPart[key] = (masterIndex, m.layouts.count)
            m.layouts.append(l)
        }
        if m.layouts.isEmpty {
            // A master must have a layout for slides to use.
            var l = Layout()
            l.name = "Blank"
            m.layouts.append(l)
        }
        return m
    }

    static func readLayout(_ ctx: ReadCtx, _ part: PartInfo, _ doc: XDoc) -> Layout {
        let root = doc.root
        var l = Layout()
        l.showMasterShapes = root.bool("showMasterSp") ?? true
        if let csld = root.child("cSld") {
            l.name = csld.attr("name") ?? ""
            l.background = background(ctx, part, csld)
            if let tree = csld.child("spTree") {
                l.shapes = spTree(ctx, part, tree, 0)
            }
        }
        l.colorMap = colorMapOverride(root)
        return l
    }

    static func readSlide(_ ctx: ReadCtx, _ part: PartInfo, _ doc: XDoc) -> PptxSlide {
        let root = doc.root
        var s = PptxSlide()
        s.showMasterShapes = root.bool("showMasterSp") ?? true
        s.colorMap = colorMapOverride(root)
        if let csld = root.child("cSld") {
            s.background = background(ctx, part, csld)
            if let tree = csld.child("spTree") {
                s.shapes = spTree(ctx, part, tree, 0)
            }
        }
        return s
    }

    static func readNotes(_ ctx: ReadCtx, _ part: PartInfo, _ root: XEl) -> TextBody {
        guard let tree = root.path(["cSld", "spTree"]) else { return TextBody() }
        for sp in tree.childrenNamed("sp") {
            let ph = sp.path(["nvSpPr", "nvPr", "ph"])
            let type = ph?.attr("type")
            let isBody = ph != nil && (type == "body" || type == nil) && type != "sldImg"
            if isBody, let tx = sp.child("txBody") {
                var t = Dml.textBody(ctx, part, tx)
                // Notes keep only content: drop body formatting from the
                // notes master placeholder.
                t.listStyle = ListStyle()
                if t.isEmpty { return TextBody() }
                return t
            }
        }
        return TextBody()
    }

    /// Which footer placeholders the slides show (the reference's
    /// header_footer survey).
    static func headerFooter(_ p: Presentation) -> HeaderFooter {
        var hf = HeaderFooter()
        for s in p.slides {
            for sh in s.shapes {
                switch sh.phType() {
                case .slideNum:
                    hf.slideNumber = true
                case .date:
                    hf.date = true
                    if let t = sh.text,
                       !t.paragraphs.flatMap(\.runs).contains(where: { if case .field = $0.kind { return true } else { return false } }),
                       hf.dateText.isEmpty {
                        hf.dateText = t.text()
                    }
                case .footer:
                    hf.footer = true
                    if hf.footerText.isEmpty, let t = sh.text {
                        hf.footerText = t.text()
                    }
                default:
                    break
                }
            }
        }
        return hf
    }

    // -----------------------------------------------------------------------
    // Shape trees (read/shapes.rs)
    // -----------------------------------------------------------------------

    static let maxTreeDepth = 32
    static let maxShapes = 20_000

    /// Read the children of an `spTree` / `grpSp`.
    static func spTree(_ ctx: ReadCtx, _ part: PartInfo, _ tree: XEl, _ depth: Int) -> [Shape] {
        var out: [Shape] = []
        if depth > maxTreeDepth { return out }
        for e in tree.elements {
            if out.count >= maxShapes { break }
            let s: Shape?
            switch e.local {
            case "sp":
                s = sp(ctx, part, e)
            case "pic":
                s = pic(ctx, part, e)
            case "grpSp":
                s = grp(ctx, part, e, depth)
            case "cxnSp":
                s = cxn(ctx, part, e)
            case "graphicFrame":
                s = frame(ctx, part, e)
            default:
                s = nil
            }
            if var shape = s {
                fixGeometryMarker(&shape, e.child("spPr"))
                out.append(shape)
            }
        }
        return out
    }

    /// Common non-visual properties (`p:nvSpPr`, `p:nvPicPr`…).
    static func base(_ nv: XEl?) -> Shape {
        var s = Shape()
        let c = nv?.child("cNvPr")
        if let c {
            s.name = c.attr("name") ?? ""
            s.hidden = c.bool("hidden") ?? false
        }
        if let nv {
            for e in nv.elements {
                switch e.local {
                case "cNvSpPr":
                    s.textBox = e.bool("txBox") ?? false
                case "nvPr":
                    if let ph = e.child("ph") {
                        s.ph = Placeholder(
                            kind: PhType.fromXML(ph.attr("type")),
                            idx: Int(ph.u32("idx") ?? 0)
                        )
                    }
                default:
                    break
                }
            }
        }
        return s
    }

    static func presetGeom(_ pg: XEl) -> Geom {
        let name = pg.attr("prst") ?? "rect"
        var adj: [Double] = []
        var any = false
        if let av = pg.child("avLst") {
            for gd in av.childrenNamed("gd").prefix(16) {
                let n = gd.attr("name") ?? ""
                let idx: Int?
                if n == "adj" {
                    idx = 0
                } else if n.hasPrefix("adj"), let k = Int(n.dropFirst("adj".count)), (1...16).contains(k) {
                    idx = k - 1
                } else {
                    idx = nil
                }
                guard let idx, let fmla = gd.attr("fmla")?.trimmingCharacters(in: .whitespaces) else { continue }
                guard fmla.hasPrefix("val"), let v = Double(fmla.dropFirst("val".count).trimmingCharacters(in: .whitespaces)), v.isFinite else { continue }
                while adj.count <= idx { adj.append(0) }
                adj[idx] = v
                any = true
            }
        }
        return .preset(name: name, adj: any ? adj : [])
    }

    /// `spPr` → transform, geometry, fill, line, effects.
    static func spPr(_ ctx: ReadCtx, _ part: PartInfo, _ s: inout Shape, _ pr: XEl) {
        if let x = pr.child("xfrm") {
            s.xfrm = Dml.xfrm(x).0
        }
        if let pg = pr.child("prstGeom") {
            s.geom = presetGeom(pg)
        } else if pr.child("custGeom") != nil {
            // Custom paths are not modelled; the shape keeps its box and the
            // geometry marker stays empty so the placeholder pass can fill
            // inherited geometry where one exists.
            s.geom = .custom(paths: [])
        }
        s.fill = Dml.fillOf(ctx, part, pr)
        if let ln = pr.child("ln") {
            s.line = Dml.line(ctx, part, ln)
        }
        if let fx = pr.child("effectLst") {
            s.effects = Dml.effects(fx)
        }
    }

    /// A placeholder whose `spPr` names no geometry takes its layout's (or
    /// master's) placeholder's: marked with an empty custom geometry, filled
    /// in by `inheritPlaceholderGeometry`.
    static func fixGeometryMarker(_ s: inout Shape, _ pr: XEl?) {
        guard s.ph != nil else { return }
        let namesGeometry = pr.map { $0.child("prstGeom") != nil || $0.child("custGeom") != nil } ?? false
        if !namesGeometry {
            s.geom = .custom(paths: [])
        }
    }

    static func style(_ st: XEl) -> ShapeStyle {
        let r = { (n: String) -> (Int, ColorRef) in
            st.child(n).map { e in
                (Int(min(e.u32("idx") ?? 0, 1003)), Dml.color(e) ?? .scheme(.accent1))
            } ?? (0, .scheme(.accent1))
        }
        let font = st.child("fontRef")
        return ShapeStyle(
            lineRef: r("lnRef"),
            fillRef: r("fillRef"),
            effectRef: r("effectRef"),
            fontRef: (font?.attr("idx") ?? "minor", font.flatMap { Dml.color($0) })
        )
    }

    static func sp(_ ctx: ReadCtx, _ part: PartInfo, _ e: XEl) -> Shape {
        var s = base(e.child("nvSpPr"))
        if let pr = e.child("spPr") {
            spPr(ctx, part, &s, pr)
        }
        s.style = e.child("style").map(style)
        s.text = e.child("txBody").map { Dml.textBody(ctx, part, $0) }
        return s
    }

    static func pic(_ ctx: ReadCtx, _ part: PartInfo, _ e: XEl) -> Shape {
        var s = base(e.child("nvPicPr"))
        if let pr = e.child("spPr") {
            spPr(ctx, part, &s, pr)
        }
        s.style = e.child("style").map(style)
        let nvpr = e.path(["nvPicPr", "nvPr"])
        let hasVideo = nvpr?.child("videoFile") != nil
        let hasAudio = nvpr?.child("audioFile") != nil
        if hasVideo || hasAudio {
            let label = hasVideo ? "video" : "audio"
            let poster = e.child("blipFill").flatMap { Dml.blipFill(ctx, part, $0) }?.media
            s.kind = .media(label: label, poster: poster)
            return s
        }
        if let bf = e.child("blipFill"), let pf = Dml.blipFill(ctx, part, bf) {
            s.kind = .picture(fill: pf)
        } else {
            s.kind = .opaque(label: s.name, preview: nil)
        }
        return s
    }

    static func grp(_ ctx: ReadCtx, _ part: PartInfo, _ e: XEl, _ depth: Int) -> Shape {
        var s = base(e.child("nvGrpSpPr"))
        var child: Xfrm?
        if let pr = e.child("grpSpPr") {
            if let x = pr.child("xfrm") {
                let (xf, ch) = Dml.xfrm(x)
                s.xfrm = xf
                child = ch
            }
            s.fill = Dml.fillOf(ctx, part, pr)
            if let fx = pr.child("effectLst") {
                s.effects = Dml.effects(fx)
            }
        }
        let children = spTree(ctx, part, e, depth + 1)
        let childSpace = child ?? s.xfrm.map { Xfrm(x: $0.x, y: $0.y, w: $0.w, h: $0.h) } ?? Xfrm()
        s.kind = .group(children: children, child: childSpace)
        return s
    }

    static func cxn(_ ctx: ReadCtx, _ part: PartInfo, _ e: XEl) -> Shape {
        var s = base(e.child("nvCxnSpPr"))
        if let pr = e.child("spPr") {
            spPr(ctx, part, &s, pr)
        }
        s.style = e.child("style").map(style)
        s.kind = .connector
        return s
    }

    static func frame(_ ctx: ReadCtx, _ part: PartInfo, _ e: XEl) -> Shape {
        var s = base(e.child("nvGraphicFramePr"))
        if let x = e.child("xfrm") {
            s.xfrm = Dml.xfrm(x).0
        }
        let gd = e.path(["graphic", "graphicData"])
        if let gd {
            if let tbl = gd.child("tbl") {
                s.kind = .table(Dml.table(ctx, part, tbl))
                return s
            }
            // Charts, SmartArt and OLE objects: a labelled frame. A preview
            // picture (the fallback image PowerPoint caches) is shown when
            // the frame carries one.
            let preview = gd.findAll("blip").lazy.compactMap { Dml.mediaRef(ctx, part, $0) }.first
            var label = "Object"
            if gd.child("chart") != nil {
                label = "Chart"
            } else if (gd.attr("uri") ?? "").hasSuffix("/diagram") {
                label = "SmartArt"
            } else if let ole = gd.find("oleObj") {
                label = ole.attr("progId") ?? ole.attr("name") ?? "Object"
            }
            s.kind = .opaque(label: label, preview: preview)
            return s
        }
        s.kind = .opaque(label: "Object", preview: nil)
        return s
    }

    // -----------------------------------------------------------------------
    // Theme (read/theme.rs)
    // -----------------------------------------------------------------------

    static func readTheme(_ ctx: ReadCtx, _ part: PartInfo, _ root: XEl) -> Theme {
        var t = Theme()
        t.name = root.attr("name") ?? "Theme"
        guard let te = root.child("themeElements") else { return t }
        if let cs = te.child("clrScheme") {
            for slot in SchemeSlot.theme {
                if let c = cs.child(slot.xmlName).flatMap(Dml.color) {
                    let rgb: Rgba?
                    switch c.base {
                    case .rgb(let v): rgb = v
                    case .system(_, let last): rgb = last
                    case .preset(let name): rgb = presetColor(name)
                    case .scheme: rgb = nil
                    }
                    if let rgb {
                        t.colors[slot] = rgb
                    }
                }
            }
        }
        if let fs = te.child("fontScheme") {
            let fontSet = { (e: XEl?) -> FontSet in
                let tf = { (n: String) -> String in e?.child(n)?.attr("typeface") ?? "" }
                return FontSet(latin: tf("latin"), ea: tf("ea"), cs: tf("cs"))
            }
            t.fonts.major = fontSet(fs.child("majorFont"))
            t.fonts.minor = fontSet(fs.child("minorFont"))
        }
        if let fm = te.child("fmtScheme") {
            var f = FormatScheme()
            if let l = fm.child("fillStyleLst") {
                f.fills = l.elements.prefix(16).compactMap { Dml.fillEl(ctx, part, $0) }
            }
            if let l = fm.child("lnStyleLst") {
                f.lines = l.childrenNamed("ln").prefix(16).map { Dml.line(ctx, part, $0) }
            }
            if let l = fm.child("effectStyleLst") {
                f.effects = l.childrenNamed("effectStyle").prefix(16).map { e in
                    e.child("effectLst").map(Dml.effects) ?? Effects()
                }
            }
            if let l = fm.child("bgFillStyleLst") {
                f.bgFills = l.elements.prefix(16).compactMap { Dml.fillEl(ctx, part, $0) }
            }
            // The style matrix needs three entries of each kind.
            let dflt = defaultFormat()
            pad(&f.fills, dflt.fills)
            pad(&f.lines, dflt.lines)
            pad(&f.bgFills, dflt.bgFills)
            while f.effects.count < 3 { f.effects.append(Effects()) }
            t.format = f
        }
        return t
    }

    /// The theme format scheme defaults (thin line, plain shadow), used to
    /// pad a theme that declares fewer than three entries of a kind.
    static func defaultFormat() -> FormatScheme {
        var f = FormatScheme()
        f.fills = [.solid(color: .scheme(.accent1)), .none, .none]
        var l = Line()
        l.width = 0.5334 // 6350 EMU
        l.fill = .solid(color: .scheme(.accent1))
        f.lines = [l, Line.none(), Line.none()]
        f.bgFills = [.solid(color: .scheme(.bg1)), .none, .none]
        f.effects = [Effects(), Effects(), Effects()]
        return f
    }

    private static func pad<T>(_ v: inout [T], _ d: [T]) {
        while v.count < 3, v.count < d.count {
            v.append(d[v.count])
        }
    }

    // -----------------------------------------------------------------------
    // Post-passes (read/mod.rs)
    // -----------------------------------------------------------------------

    /// A shape's text without an anchor of its own sits at the top, as the
    /// standard has it and as PowerPoint draws it. The model's own default
    /// for shapes is the middle, so a top or bottom anchor is made explicit
    /// here and a middle one left unset (placeholders and text boxes keep
    /// inheriting).
    static func defaultTextAnchor(_ p: inout Presentation) {
        func fix(_ shapes: inout [Shape]) {
            walkShapesMut(&shapes) { s in
                if s.ph == nil, !s.textBox, var t = s.text {
                    let got = t.body.anchor ?? .top
                    t.body.anchor = got != .middle ? got : nil
                    s.text = t
                }
            }
        }
        for mi in p.masters.indices {
            fix(&p.masters[mi].shapes)
            for li in p.masters[mi].layouts.indices {
                fix(&p.masters[mi].layouts[li].shapes)
            }
        }
        for si in p.slides.indices {
            fix(&p.slides[si].shapes)
        }
    }

    /// Placeholders read without a geometry (an empty custom geometry) take
    /// the geometry of the layout or master placeholder they inherit from,
    /// as PowerPoint draws them. Anything left is a rectangle.
    static func inheritPlaceholderGeometry(_ p: inout Presentation) {
        func unset(_ g: Geom) -> Bool {
            if case .custom(let paths) = g { return paths.isEmpty }
            return false
        }
        for mi in p.masters.indices {
            walkShapesMut(&p.masters[mi].shapes) { s in
                if unset(s.geom) { s.geom = .default() }
            }
            for li in p.masters[mi].layouts.indices {
                walkShapesMut(&p.masters[mi].layouts[li].shapes) { s in
                    if unset(s.geom) { s.geom = .default() }
                }
            }
        }
        for si in p.slides.indices {
            walkShapesMut(&p.slides[si].shapes) { s in
                if unset(s.geom) { s.geom = .default() }
            }
        }
    }

    static func walkShapesMut(_ shapes: inout [Shape], _ f: (inout Shape) -> Void) {
        for i in shapes.indices {
            f(&shapes[i])
            if case .group(var children, let child) = shapes[i].kind {
                walkShapesMut(&children, f)
                shapes[i].kind = .group(children: children, child: child)
            }
        }
    }
}
