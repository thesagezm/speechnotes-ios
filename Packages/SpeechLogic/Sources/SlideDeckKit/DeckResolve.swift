// DeckResolve.swift — inheritance: effective position, fill, line, body and
// text properties of a shape, following slide → layout placeholder → master
// placeholder → master text styles → theme. Port of deckcraft-model
// src/resolve.rs @ a0eeb34, against the ported model (DeckTypes.swift).

import Foundation

enum DeckResolve {

    /// Where a shape lives, for resolving inherited values.
    enum Owner {
        case slide
        case layout
        case master
    }

    struct Ctx {
        let pres: Presentation
        let master: Master
        let layout: Layout?
        let owner: Owner
        let scheme: ThemeColors
        /// The colour map in force: the slide's override, else its layout's,
        /// else the master's.
        let colorMap: [(String, String)]

        static func forSlide(_ pres: Presentation, _ slide: PptxSlide) -> Ctx? {
            guard let (master, layout) = pres.masterFor(slide) else { return nil }
            let map = slide.colorMap ?? (layout?.colorMap ?? master.colorMap)
            return Ctx(pres: pres, master: master, layout: layout, owner: .slide,
                       scheme: master.schemeWith(map), colorMap: map)
        }

        static func forLayout(_ pres: Presentation, _ master: Master, _ layout: Layout) -> Ctx {
            let map = layout.colorMap ?? master.colorMap
            return Ctx(pres: pres, master: master, layout: layout, owner: .layout,
                       scheme: master.schemeWith(map), colorMap: map)
        }

        static func forMaster(_ pres: Presentation, _ master: Master) -> Ctx {
            Ctx(pres: pres, master: master, layout: nil, owner: .master,
                scheme: master.scheme(), colorMap: master.colorMap)
        }

        func color(_ c: ColorRef, _ ph: Rgba?) -> Rgba {
            var c = c
            if case .scheme(let slot) = c.base, slot == .bg1 || slot == .tx1 || slot == .bg2 || slot == .tx2 {
                c.base = .scheme(Master.mapSlot(colorMap, slot))
            }
            return c.resolve(master.theme.colors.colors, ph)
        }
    }

    static func compatible(_ slide: PhType, _ other: PhType) -> Bool {
        switch slide {
        case .title, .ctrTitle:
            return other == .title || other == .ctrTitle
        case .subTitle, .body, .obj, .chart, .table, .clipArt, .diagram, .media, .picture:
            return !(other == .title || other == .ctrTitle || other == .date || other == .footer || other == .slideNum || other == .header)
        case let k:
            return k == other
        }
    }

    static func findPh(_ shapes: [Shape], _ shape: Shape, byIdx: Bool) -> Shape? {
        guard let ph = shape.ph else { return nil }
        if byIdx, ph.idx != 0,
           let s = shapes.first(where: { s in
               guard let p = s.ph else { return false }
               return p.idx == ph.idx && compatible(ph.kind, p.kind)
           }) {
            return s
        }
        // Same type first (with the index honoured unless the shape is a
        // title), then a compatible one.
        if let s = shapes.first(where: { s in
            guard let p = s.ph else { return false }
            return p.kind == ph.kind && (!byIdx || ph.idx == 0 || p.idx == ph.idx || ph.kind.isTitle)
        }) {
            return s
        }
        if let s = shapes.first(where: { s in s.ph?.kind == ph.kind }) {
            return s
        }
        return shapes.first(where: { s in
            guard let p = s.ph else { return false }
            return compatible(ph.kind, p.kind)
        })
    }

    static func masterPh(_ master: Master, _ kind: PhType) -> Shape? {
        let want: PhType
        switch kind {
        case .title, .ctrTitle: want = .title
        case .date, .footer, .slideNum, .header: want = kind
        default: want = .body
        }
        return master.shapes.first { $0.phType() == want }
    }

    /// The layout and master placeholders a shape inherits from.
    static func parents(_ ctx: Ctx, _ shape: Shape) -> (Shape?, Shape?) {
        guard let ph = shape.ph else { return (nil, nil) }
        switch ctx.owner {
        case .slide:
            let lp = ctx.layout.flatMap { findPh($0.shapes, shape, byIdx: true) }
            let kind = lp?.phType() ?? ph.kind
            return (lp, masterPh(ctx.master, kind))
        case .layout:
            return (nil, masterPh(ctx.master, ph.kind))
        case .master:
            return (nil, nil)
        }
    }

    /// The text style group (title / body / other) a shape draws from. Text
    /// in a table takes the master's other-text style, also when the table
    /// sits in a content placeholder; other shapes take the presentation's
    /// default text style.
    static func masterListStyle(_ ctx: Ctx, _ shape: Shape) -> ListStyle {
        if case .table = shape.kind {
            return ctx.master.otherStyle
        }
        switch shape.phType() {
        case .some(.title), .some(.ctrTitle):
            return ctx.master.titleStyle
        case .some(.body), .some(.obj), .some(.subTitle), .some(.table), .some(.chart),
             .some(.diagram), .some(.media), .some(.picture), .some(.clipArt):
            return ctx.master.bodyStyle
        case .some:
            return ctx.master.otherStyle
        case nil:
            return ctx.pres.defaultTextStyle
        }
    }

    static func xfrm(_ ctx: Ctx, _ shape: Shape) -> Xfrm {
        if let x = shape.xfrm {
            return x
        }
        let (lp, mp) = parents(ctx, shape)
        if let x = lp?.xfrm ?? mp?.xfrm {
            return x
        }
        return Xfrm(x: ctx.pres.slideW * 0.1, y: ctx.pres.slideH * 0.1, w: ctx.pres.slideW * 0.8, h: ctx.pres.slideH * 0.2)
    }

    /// Effective fill and the style colour (`phClr`) to resolve it with.
    static func fill(_ ctx: Ctx, _ shape: Shape) -> (Fill?, Rgba?) {
        let (lp, mp) = parents(ctx, shape)
        func styleFill(_ s: Shape) -> (Fill?, Rgba?)? {
            guard let st = s.style else { return nil }
            let (idx, col) = st.fillRef
            let ph = ctx.color(col, nil)
            let f: Fill?
            if idx == 0 {
                f = Fill.none
            } else if idx >= 1001 {
                f = idx - 1001 < ctx.master.theme.format.bgFills.count ? ctx.master.theme.format.bgFills[idx - 1001] : nil
            } else {
                f = idx - 1 < ctx.master.theme.format.fills.count ? ctx.master.theme.format.fills[idx - 1] : nil
            }
            return (f, ph)
        }
        for s in [shape, lp, mp].compactMap({ $0 }) {
            if let f = s.fill {
                // A gradient without stops takes them from the gradient its
                // style refers to, keeping its own direction.
                if case .gradient(var g) = f, g.stops.isEmpty,
                   let sf = styleFill(s), case .gradient(let sg)? = sf.0 {
                    g.stops = sg.stops
                    return (.gradient(g), sf.1)
                }
                return (f, nil)
            }
            if let r = styleFill(s) {
                return r
            }
        }
        if shape.textBox {
            return (.none, nil)
        }
        return (nil, nil)
    }

    static func line(_ ctx: Ctx, _ shape: Shape) -> (Line, Rgba?) {
        let (lp, mp) = parents(ctx, shape)
        var out = Line()
        var ph: Rgba?
        for s in [shape, lp, mp].compactMap({ $0 }) {
            if let l = s.line {
                out.inherit(l)
            }
            if let st = s.style {
                let (idx, col) = st.lineRef
                if ph == nil {
                    ph = ctx.color(col, nil)
                }
                if idx == 0 {
                    out.inherit(Line.none())
                } else if idx - 1 < ctx.master.theme.format.lines.count {
                    out.inherit(ctx.master.theme.format.lines[idx - 1])
                }
                break
            }
        }
        return (out, ph)
    }

    static func effects(_ ctx: Ctx, _ shape: Shape) -> Effects? {
        let (lp, mp) = parents(ctx, shape)
        for s in [shape, lp, mp].compactMap({ $0 }) {
            if let e = s.effects {
                return e
            }
            if let st = s.style {
                let (idx, _) = st.effectRef
                if idx == 0 { return nil }
                return idx - 1 < ctx.master.theme.format.effects.count ? ctx.master.theme.format.effects[idx - 1] : nil
            }
        }
        return nil
    }

    /// Body properties with defaults filled in.
    static func body(_ ctx: Ctx, _ shape: Shape) -> BodyProps {
        let (lp, mp) = parents(ctx, shape)
        var b = shape.text?.body ?? BodyProps()
        for s in [lp, mp].compactMap({ $0 }) {
            if let t = s.text {
                b.inherit(t.body)
            }
        }
        let anchor: TextAnchor
        if shape.ph == nil && !shape.textBox {
            if case .table = shape.kind {
                anchor = .top
            } else {
                anchor = .middle
            }
        } else {
            anchor = .top
        }
        // The defaults `resolve::body` merges last.
        if b.insetL == nil { b.insetL = 7.2 }
        if b.insetT == nil { b.insetT = 3.6 }
        if b.insetR == nil { b.insetR = 7.2 }
        if b.insetB == nil { b.insetB = 3.6 }
        if b.anchor == nil { b.anchor = anchor }
        if b.anchorCtr == nil { b.anchorCtr = false }
        if b.wrap == nil { b.wrap = true }
        b.autofit = b.autofit ?? (shape.textBox ? AutoFit.shape : AutoFit.none)
        if b.vert == nil { b.vert = .horizontal }
        return b
    }

    /// The merged level style (paragraph + run defaults) for paragraphs at
    /// `level` in `shape`. `isTableCell` marks a synthetic table-cell shape:
    /// a table's text inherits nothing from a placeholder the table sits in,
    /// PowerPoint draws it in the other-text style.
    static func levelStyle(_ ctx: Ctx, _ shape: Shape, _ level: Int, isTableCell: Bool = false) -> LevelStyle {
        var out = LevelStyle()
        func add(_ ls: LevelStyle?) {
            guard let l = ls else { return }
            out.para.inherit(l.para)
            out.run.inherit(l.run)
        }
        if let t = shape.text {
            add(t.listStyle.level(level))
        }
        if !isTableCell {
            let (lp, mp) = parents(ctx, shape)
            for s in [lp, mp].compactMap({ $0 }) {
                if let t = s.text {
                    add(t.listStyle.level(level))
                }
            }
        }
        // Shape style font reference (theme font + colour) sits above the defaults.
        let styleSource: ShapeStyle?
        if isTableCell {
            styleSource = nil
        } else {
            let (lp, _) = parents(ctx, shape)
            styleSource = shape.style ?? lp?.style
        }
        if let st = styleSource {
            let font: String?
            switch st.fontRef.0 {
            case "major": font = "+mj-lt"
            case "minor": font = "+mn-lt"
            default: font = nil
            }
            var r = RunProps()
            r.font = font
            if let col = st.fontRef.1 {
                r.fill = .solid(color: col)
            }
            out.run.inherit(r)
        }
        add(masterListStyle(ctx, shape).level(level))
        add(ctx.pres.defaultTextStyle.level(level))
        // Last resort.
        var r = RunProps()
        r.size = 18.0
        r.font = "+mn-lt"
        r.bold = false
        r.italic = false
        out.run.inherit(r)
        var p = ParaProps()
        p.marginLeft = 0.0
        p.indent = 0.0
        p.align = "l"
        out.para.inherit(p)
        return out
    }

    /// Fully resolved run properties for `run` in paragraph `para`
    /// (explicit → paragraph style).
    static func run(_ ctx: Ctx, _ shape: Shape, _ para: TextParagraph, _ rp: RunProps, isTableCell: Bool = false) -> RunProps {
        var r = rp
        // Paragraph `defRPr` fills gaps in the run, and the list style
        // (including the layout placeholder this shape inherits from) fills
        // whatever is still unset.
        r.inherit(para.defProps)
        let lvl = levelStyle(ctx, shape, para.level, isTableCell: isTableCell)
        r.inherit(lvl.run)
        // Hyperlinked text is drawn in the theme's hyperlink colour and
        // underlined, as in PowerPoint, unless the run itself sets a colour
        // or an underline.
        if r.link {
            let fromDef = !rp.link
            if rp.fill == nil && !(fromDef && para.defProps.fill != nil) {
                r.fill = .solid(color: .scheme(.hlink))
            }
            if rp.underline == nil && !(fromDef && para.defProps.underline != nil) {
                r.underline = "sng"
            }
        }
        return r
    }

    static func para(_ ctx: Ctx, _ shape: Shape, _ para: TextParagraph, isTableCell: Bool = false) -> ParaProps {
        var p = para.props
        let lvl = levelStyle(ctx, shape, para.level, isTableCell: isTableCell)
        p.inherit(lvl.para)
        return p
    }

    /// Concrete font family for a run (theme references resolved).
    static func fontFamily(_ ctx: Ctx, _ r: RunProps) -> String {
        let f = r.font ?? "+mn-lt"
        let name = ctx.master.theme.font(f)
        return name.isEmpty ? ctx.master.theme.fonts.minor.latin : name
    }

    /// Text colour of resolved run props.
    static func textColor(_ ctx: Ctx, _ r: RunProps) -> Rgba {
        switch r.fill {
        case .some(.solid(let color)):
            return ctx.color(color, nil)
        case .some(.gradient(let g)):
            return g.stops.first.map { ctx.color($0.color, nil) } ?? Rgba(r: 0, g: 0, b: 0)
        case .some(.none):
            return Rgba(r: 0, g: 0, b: 0, a: 0)
        default:
            return ctx.color(.scheme(.tx1), nil)
        }
    }

    /// The background fill (and its style colour) of a slide.
    static func background(_ ctx: Ctx, _ slide: PptxSlide?) -> (Fill, Rgba?) {
        let bg = slide?.background ?? ctx.layout?.background ?? ctx.master.background
        switch bg {
        case .some(.fill(let fill)):
            return (fill, nil)
        case .some(.ref(let idx, let color)):
            let ph = ctx.color(color, nil)
            let f: Fill?
            if idx >= 1001 {
                f = idx - 1001 < ctx.master.theme.format.bgFills.count ? ctx.master.theme.format.bgFills[idx - 1001] : nil
            } else {
                f = idx - 1 < ctx.master.theme.format.fills.count ? ctx.master.theme.format.fills[idx - 1] : nil
            }
            return (f ?? .solid(color: .rgb(ph)), ph)
        default:
            return (.solid(color: .scheme(.bg1)), nil)
        }
    }

    /// Should the layout/master graphics (non-placeholder shapes) show
    /// behind this slide? Returns (showLayout, showMaster).
    static func showMasterShapes(_ slide: PptxSlide, _ layout: Layout?) -> (Bool, Bool) {
        let showLayout = slide.showMasterShapes
        let showMaster = showLayout && (layout?.showMasterShapes ?? true)
        return (showLayout, showMaster)
    }
}
