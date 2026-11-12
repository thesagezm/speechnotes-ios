// DmlRead.swift — DrawingML element reading: colours, fills, lines, effects,
// transforms, text bodies and tables. Ported from deckcraft-pptx
// src/read/dml.rs + the table half of read/shapes.rs @ a0eeb34, carrying the
// fields the deck viewer resolves and paints. The documented degradations:
// picture fills lose tile mode (stretch instead), pattern fills draw their
// foreground colour, hyperlinks keep presence only (colour + underline, no
// jump actions), table style GUIDs are not followed (cells keep their own
// fills over thin dark grid lines).

import Foundation

/// Import state shared by all parts (the Rust `Imp`): media allocation and
/// the per-part relationship lookups.
final class ReadCtx {
    let pkg: Ooxml.Package
    private(set) var media: [(id: Int, part: String, name: String, contentType: String, data: [UInt8])] = []
    private var mediaByPart: [String: Int] = [:]
    private var next = 0
    /// Part name (normalised) → slide index, for slide-jump links (unused by
    /// the viewer but kept so link presence is honest).
    var slideByPart: [String: Int] = [:]

    init(pkg: Ooxml.Package) {
        self.pkg = pkg
    }

    func alloc() -> Int {
        next += 1
        return next
    }

    /// Media id for an internal part, read once.
    func mediaFor(_ part: String) -> Int? {
        let key = Ooxml.normalize(part)
        if let m = mediaByPart[key] { return m }
        guard let data = pkg.get(part) else { return nil }
        let original = pkg.originalName(part) ?? part
        let name = Ooxml.fileOf(original)
        let contentType = pkg.contentType(part) ?? Self.mimeFallback(name)
        let id = alloc()
        media.append((id, key, name, contentType, [UInt8](data)))
        mediaByPart[key] = id
        return id
    }

    static func mimeFallback(_ name: String) -> String {
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "emf", "wmf": return "image/x-emf"
        default: return "application/octet-stream"
        }
    }

    /// A part's relationships, with the caller's XML doc (roots differ per part).
    func rels(_ part: String) -> Ooxml.Rels {
        pkg.rels(part)
    }
}

enum Dml {

    static func pt(_ e: XEl, _ name: String) -> Double? {
        e.i64(name).map(emuToPt)
    }

    /// 1/100 000 → fraction.
    static func pct(_ e: XEl, _ name: String) -> Double? {
        e.f64(name).map { $0 / 100_000.0 }
    }

    /// 1/60 000 degree → degrees.
    static func ang(_ e: XEl, _ name: String) -> Double? {
        e.f64(name).map { $0 / 60_000.0 }
    }

    static func linToSRGB(_ v: Double) -> Double {
        let v = min(max(v, 0), 1)
        return v <= 0.003_130_8 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// A colour element (`srgbClr`, `schemeClr`, …) with its transforms.
    static func colorEl(_ c: XEl) -> ColorRef? {
        let base: ColorBase
        switch c.local {
        case "srgbClr":
            base = .rgb(Rgba.fromHex(c.attr("val") ?? "000000") ?? Rgba(r: 0, g: 0, b: 0))
        case "schemeClr":
            base = .scheme(SchemeSlot.fromXML(c.attr("val") ?? "") ?? .tx1)
        case "sysClr":
            let last = Rgba.fromHex(c.attr("lastClr") ?? "")
                ?? ((c.attr("val") ?? "") == "window" ? Rgba(r: 255, g: 255, b: 255) : Rgba(r: 0, g: 0, b: 0))
            base = .system(name: c.attr("val") ?? "windowText", last: last)
        case "prstClr":
            base = .preset(c.attr("val") ?? "black")
        case "scrgbClr":
            let f = { (n: String) -> Double in linToSRGB((c.f64(n) ?? 0) / 100_000.0) }
            base = .rgb(Rgba.fromF64(f("r"), f("g"), f("b"), 1.0))
        case "hslClr":
            let h = (c.f64("hue") ?? 0) / 60_000.0
            let s = (c.f64("sat") ?? 0) / 100_000.0
            let l = (c.f64("lum") ?? 0) / 100_000.0
            base = .rgb(Rgba.fromHSL(h, s, l, 255))
        default:
            return nil
        }
        let mods = c.elements.prefix(32).compactMap { m -> ColorTransform? in
            ColorTransform.fromXML(m.local, m.i32("val"))
        }
        return ColorRef(base: base, mods: mods)
    }

    /// The first colour child of a container (`solidFill`, `fgClr`, `lnRef`…).
    static func color(_ container: XEl) -> ColorRef? {
        container.elements.lazy.compactMap(colorEl).first
    }

    static let fillNames: Set<String> = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]

    /// The fill child of `parent`, if any.
    static func fillOf(_ ctx: ReadCtx, _ part: PartInfo, _ parent: XEl) -> Fill? {
        parent.elements.first(where: { fillNames.contains($0.local) }).flatMap { fillEl(ctx, part, $0) }
    }

    static func fillEl(_ ctx: ReadCtx, _ part: PartInfo, _ f: XEl) -> Fill? {
        switch f.local {
        case "noFill":
            return .none
        case "solidFill":
            return .solid(color: color(f) ?? .rgb(Rgba(r: 0, g: 0, b: 0)))
        case "gradFill":
            return .gradient(gradient(f))
        case "blipFill":
            // A picture filling a shape or background with neither `a:stretch`
            // nor `a:tile` is tiled at its own size; the port draws a stretch.
            if let p = blipFill(ctx, part, f) { return .picture(media: p.media, crop: p.crop) }
            return .none
        case "pattFill":
            return .pattern(fg: f.child("fgClr").flatMap(color) ?? .rgb(Rgba(r: 0, g: 0, b: 0)))
        case "grpFill":
            return .group
        default:
            return nil
        }
    }

    static func gradient(_ f: XEl) -> Gradient {
        var stops: [GradientStop] = f.child("gsLst").map { l in
            l.childrenNamed("gs").prefix(256).map { g in
                GradientStop(pos: min(max(pct(g, "pos") ?? 0, 0), 1), color: color(g) ?? .rgb(Rgba(r: 0, g: 0, b: 0)))
            }
        } ?? []
        stops.sort { $0.pos < $1.pos }
        let shape: GradientShape
        if let l = f.child("lin") {
            shape = .linear(angle: ang(l, "ang") ?? 0, scaled: l.bool("scaled") ?? false)
        } else if let p = f.child("path") {
            let r = p.child("fillToRect")
            let g = { (n: String) -> Double in r.flatMap { pct($0, n) } ?? 0 }
            shape = .path(path: p.attr("path") ?? "circle", focus: [g("l"), g("t"), g("r"), g("b")])
        } else {
            shape = .linear(angle: 90, scaled: false)
        }
        return Gradient(stops: stops, shape: shape, rotateWithShape: f.bool("rotWithShape") ?? true)
    }

    /// `blipFill` (either `a:` or `p:`) → the picture's media id and crop.
    static func blipFill(_ ctx: ReadCtx, _ part: PartInfo, _ bf: XEl) -> PictureFill? {
        guard let blip = bf.child("blip") else { return nil }
        guard let media = mediaRef(ctx, part, blip) else { return nil }
        var crop: [Double] = [0, 0, 0, 0]
        if let r = bf.child("srcRect") {
            crop = [pct(r, "l") ?? 0, pct(r, "t") ?? 0, pct(r, "r") ?? 0, pct(r, "b") ?? 0]
                .map { min(max($0, -10), 1) }
        }
        return PictureFill(media: media, crop: crop)
    }

    /// Media for an element with `r:embed` (or `r:link`).
    static func mediaRef(_ ctx: ReadCtx, _ part: PartInfo, _ b: XEl) -> Int? {
        if let id = b.attr("r:embed"), !id.isEmpty, let r = part.rels.get(id) {
            if !r.external, let m = ctx.mediaFor(r.target) { return m }
        }
        if let id = b.attr("r:link"), !id.isEmpty, let r = part.rels.get(id) {
            if !r.external, let m = ctx.mediaFor(r.target) { return m }
        }
        return nil
    }

    static func line(_ ctx: ReadCtx, _ part: PartInfo, _ ln: XEl) -> Line {
        var l = Line()
        l.width = pt(ln, "w").map { min(max($0, 0), 2000) }
        l.cap = ln.attr("cap")
        l.compound = ln.attr("cmpd")
        l.fill = fillOf(ctx, part, ln)
        for e in ln.elements {
            switch e.local {
            case "prstDash":
                l.dash = e.attr("val") ?? "solid"
            default:
                break
            }
        }
        return l
    }

    static func shadow(_ e: XEl) -> Shadow {
        Shadow(
            color: color(e) ?? .rgb(Rgba(r: 0, g: 0, b: 0)),
            blur: max(pt(e, "blurRad") ?? 0, 0),
            dist: pt(e, "dist") ?? 0,
            dir: ang(e, "dir") ?? 0,
            sx: pct(e, "sx") ?? 1,
            sy: pct(e, "sy") ?? 1
        )
    }

    /// `effectLst` → effects (outer shadow only; the rest is dropped).
    static func effects(_ el: XEl) -> Effects {
        var fx = Effects()
        for e in el.elements {
            switch e.local {
            case "outerShdw":
                fx.outerShadow = shadow(e)
            case "prstShdw":
                fx.outerShadow = shadow(e)
            default:
                break
            }
        }
        return fx
    }

    /// `a:xfrm` → (box, child box for groups).
    static func xfrm(_ x: XEl) -> (Xfrm, Xfrm?) {
        let off = x.child("off")
        let ext = x.child("ext")
        let g = { (e: XEl?, _ n: String) -> Double in 0 } // placeholder, replaced below
        func val(_ e: XEl?, _ n: String) -> Double {
            e.flatMap { pt($0, n) } ?? 0
        }
        _ = g
        var xf = Xfrm(x: val(off, "x"), y: val(off, "y"), w: max(val(ext, "cx"), 0), h: max(val(ext, "cy"), 0))
        xf.rot = ang(x, "rot") ?? 0
        if !xf.rot.isFinite { xf.rot = 0 }
        xf.flipH = x.bool("flipH") ?? false
        xf.flipV = x.bool("flipV") ?? false
        var child: Xfrm?
        if let o = x.child("chOff"), let e = x.child("chExt") {
            child = Xfrm(x: val(o, "x"), y: val(o, "y"), w: max(val(e, "cx"), 0), h: max(val(e, "cy"), 0))
        }
        return (xf, child)
    }

    // MARK: - Text

    static func bodyPr(_ b: XEl) -> BodyProps {
        var p = BodyProps()
        p.insetL = pt(b, "lIns")
        p.insetT = pt(b, "tIns")
        p.insetR = pt(b, "rIns")
        p.insetB = pt(b, "bIns")
        p.anchor = TextAnchor.fromXML(b.attr("anchor"))
        p.anchorCtr = b.bool("anchorCtr")
        p.wrap = b.attr("wrap").map { $0 != "none" }
        p.vert = TextDir.fromXML(b.attr("vert"))
        for e in b.elements {
            switch e.local {
            case "normAutofit":
                p.autofit = .shrink(
                    fontScale: pct(e, "fontScale").map { min(max($0, 0.01), 1) },
                    lineReduction: min(max(pct(e, "lnSpcReduction") ?? 0, 0), 1)
                )
            case "spAutoFit":
                p.autofit = .shape
            case "noAutofit":
                p.autofit = .none
            default:
                break
            }
        }
        return p
    }

    static func spacing(_ e: XEl) -> Spacing? {
        if let p = e.child("spcPct") {
            return .pct(min(max(pct(p, "val") ?? 1, 0), 100))
        }
        if let p = e.child("spcPts") {
            return .pts(min(max(p.f64("val") ?? 0, 0), 1_000_000) / 100)
        }
        return nil
    }

    /// `a:pPr` / `a:lvlNpPr` → (level, paragraph props, default run props).
    static func ppr(_ ctx: ReadCtx, _ part: PartInfo, _ p: XEl) -> (Int?, ParaProps, RunProps?) {
        var pp = ParaProps()
        pp.align = p.attr("algn")
        pp.marginLeft = pt(p, "marL")
        pp.marginRight = pt(p, "marR")
        pp.indent = pt(p, "indent")
        let lvl = p.u32("lvl").map { Int(min($0, 8)) }
        var def: RunProps?
        for e in p.elements {
            switch e.local {
            case "lnSpc": pp.lineSpacing = spacing(e)
            case "spcBef": pp.spaceBefore = spacing(e)
            case "spcAft": pp.spaceAfter = spacing(e)
            case "buNone": pp.bullet = .none
            case "buChar":
                let ch = (e.attr("char") ?? "•").prefix(4)
                pp.bullet = .char(String(ch))
            case "buFont":
                // The glyph font of the bullet: Wingdings and friends encode
                // shapes on ASCII, so the viewer maps the char to the Unicode
                // shape (SymbolFonts.swift). Segoe UI Symbol and real-Unicode
                // bullets pass through unmapped.
                if let t = e.attr("typeface"), !t.isEmpty { pp.bulletFont = String(t.prefix(128)) }
            case "buAutoNum":
                pp.bullet = .autoNum(scheme: e.attr("type") ?? "arabicPeriod", startAt: Int(min(e.u32("startAt") ?? 1, 32767)))
            case "buBlip":
                if let m = e.child("blip").flatMap({ mediaRef(ctx, part, $0) }) {
                    pp.bullet = .picture(media: m)
                }
            case "buClr": pp.bulletColor = color(e)
            case "buSzPct": pp.bulletSize = pct(e, "val").map { min(max($0, 0.25), 4) }
            case "defRPr": def = rpr(ctx, part, e)
            default:
                break
            }
        }
        return (lvl, pp, def)
    }

    static func rpr(_ ctx: ReadCtx, _ part: PartInfo, _ r: XEl) -> RunProps {
        var p = RunProps()
        p.size = r.f64("sz").map { min(max($0 / 100, 1), 4000) }
        p.bold = r.bool("b")
        p.italic = r.bool("i")
        p.underline = r.attr("u")
        p.strike = r.attr("strike")
        p.baseline = pct(r, "baseline").map { min(max($0, -10), 10) }
        p.caps = r.attr("cap")
        p.spacing = r.f64("spc").map { min(max($0 / 100, -4000), 4000) }
        for e in r.elements {
            switch e.local {
            case "ln":
                // Text outline: presence only (no outline drawing).
                break
            case let n where fillNames.contains(n):
                p.fill = fillEl(ctx, part, e)
            case "highlight":
                p.highlight = color(e)
            case "latin":
                let t = e.attr("typeface") ?? ""
                if !t.isEmpty { p.font = String(t.prefix(256)) }
            case "hlinkClick", "hlinkMouseOver":
                p.link = true
            default:
                break
            }
        }
        return p
    }

    /// `a:lstStyle`, `p:titleStyle`, `a:defaultTextStyle`… → list style.
    static func listStyle(_ ctx: ReadCtx, _ part: PartInfo, _ ls: XEl) -> ListStyle {
        var out = ListStyle()
        for e in ls.elements {
            let n = e.local
            guard n.hasPrefix("lvl"), n.hasSuffix("pPr") else { continue }
            let digits = n.dropFirst("lvl".count).dropLast("pPr".count)
            guard let l = Int(digits), (1...9).contains(l) else { continue }
            let (_, para, run) = ppr(ctx, part, e)
            out.set(l - 1, LevelStyle(para: para, run: run ?? RunProps()))
        }
        return out
    }

    static func textBody(_ ctx: ReadCtx, _ part: PartInfo, _ tx: XEl) -> TextBody {
        var t = TextBody()
        t.body = tx.child("bodyPr").map(bodyPr) ?? BodyProps()
        t.listStyle = tx.child("lstStyle").map { listStyle(ctx, part, $0) } ?? ListStyle()
        t.paragraphs = tx.childrenNamed("p").prefix(100_000).map { paragraph(ctx, part, $0) }
        return t
    }

    static let maxParagraphRuns = 10_000

    static func paragraph(_ ctx: ReadCtx, _ part: PartInfo, _ p: XEl) -> TextParagraph {
        var para = TextParagraph()
        for e in p.elements {
            switch e.local {
            case "pPr":
                let (lvl, pp, def) = ppr(ctx, part, e)
                para.level = lvl ?? 0
                para.props = pp
                if let d = def { para.defProps = d }
            case "r":
                let props = e.child("rPr").map { rpr(ctx, part, $0) } ?? RunProps()
                let text = e.child("t").map { $0.text() } ?? ""
                // A vertical tab or line feed inside text is a line break, as
                // it lays out and as export writes it.
                var first = true
                for piece in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\u{0B}" || $0 == "\n" }) {
                    guard para.runs.count < maxParagraphRuns else { break }
                    if !first {
                        para.runs.append(TextRun(text: "", props: props, kind: .br))
                    }
                    first = false
                    if !piece.isEmpty {
                        para.runs.append(TextRun(text: String(piece), props: props, kind: .text))
                    }
                }
            case "br":
                guard para.runs.count < maxParagraphRuns else { break }
                let props = e.child("rPr").map { rpr(ctx, part, $0) } ?? RunProps()
                para.runs.append(TextRun(text: "", props: props, kind: .br))
            case "fld":
                guard para.runs.count < maxParagraphRuns else { break }
                let props = e.child("rPr").map { rpr(ctx, part, $0) } ?? RunProps()
                let text = e.child("t").map { $0.text() } ?? ""
                para.runs.append(TextRun(text: text, props: props, kind: .field(e.attr("type") ?? "")))
            case "endParaRPr":
                para.endProps = rpr(ctx, part, e)
            default:
                break
            }
        }
        return para
    }

    // MARK: - Tables (from read/shapes.rs)

    static func table(_ ctx: ReadCtx, _ part: PartInfo, _ tbl: XEl) -> Table {
        // A table naming no style is drawn by PowerPoint with thin dark grid
        // lines ("No Style, Table Grid"), not without lines. Style GUIDs are
        // not followed (documented); cells keep their own fills.
        var t = Table()
        if let pr = tbl.child("tblPr") {
            t.background = pr.elements.first(where: { $0.local.hasSuffix("Fill") && $0.local != "noFill" }).flatMap { fillEl(ctx, part, $0) }
        }
        t.cols = tbl.child("tblGrid").map { g in
            g.childrenNamed("gridCol").prefix(1000).map { c in min(max(pt(c, "w") ?? 72, 0), 20_000) }
        } ?? []
        for tr in tbl.childrenNamed("tr").prefix(1000) {
            var row = TableRowModel(height: min(max(pt(tr, "h") ?? 0, 0), 20_000), cells: [])
            for tc in tr.childrenNamed("tc").prefix(1000) {
                row.cells.append(cell(ctx, part, tc))
            }
            t.rows.append(row)
        }
        if t.cols.isEmpty {
            let n = t.rows.map { $0.cells.count }.max() ?? 0
            t.cols = [Double](repeating: 72, count: n)
        }
        t.normalize()
        return t
    }

    static func cell(_ ctx: ReadCtx, _ part: PartInfo, _ tc: XEl) -> Cell {
        var c = Cell()
        c.gridSpan = Int(min(max(tc.u32("gridSpan") ?? 1, 1), 1000))
        c.rowSpan = Int(min(max(tc.u32("rowSpan") ?? 1, 1), 1000))
        c.hMerge = tc.bool("hMerge") ?? false
        c.vMerge = tc.bool("vMerge") ?? false
        if let tx = tc.child("txBody") {
            c.text = textBody(ctx, part, tx)
        }
        if let pr = tc.child("tcPr") {
            c.anchor = TextAnchor.fromXML(pr.attr("anchor"))
            c.fill = fillOf(ctx, part, pr)
        }
        return c
    }
}

/// One part being read: its name and relationships (the Rust `Part`).
struct PartInfo {
    var name: String
    var rels: Ooxml.Rels

    init(_ pkg: Ooxml.Package, _ name: String) {
        self.name = name
        self.rels = pkg.rels(name)
    }
}
