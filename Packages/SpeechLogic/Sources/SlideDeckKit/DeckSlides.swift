// DeckSlides.swift — the resolved deck: every shape resolved through the
// inheritance chain (DeckResolve.swift), then mapped onto the viewer's item
// list. Port of the Linux app's sn-doc/src/slides.rs resolution half, against
// the ported read model. Charts and SmartArt arrive as labelled frames (the
// reference's chart SVG and diagram outlines are the documented follow-up);
// everything else — text, pictures, tables, connectors, preset geometry,
// fills, gradients, borders and shadows — resolves as the reference does.
//
// Deliberate deviations from the reference, each answering a device report:
// bare shapes (no text body) paint instead of vanishing (the reference's
// "geometry only" return dropped the rule lines and arrows generated decks
// are built from); bullets and runs in symbol fonts map to Unicode shapes
// (the fonts don't exist on iOS — see SymbolFonts.swift); gradient angles
// convert pptx+90° instead of the reference's mirrored 90−angle; and the
// SPEECH text reads in visual order with repeated chrome deduped
// (assembleText) while the render order stays z-order.

import Foundation

public enum DeckSlides {

    /// A deck from the read model: every shape resolved, then mapped onto
    /// the viewer's item list.
    public static func fromPresentation(_ pres: Presentation) -> SlideDeck {
        var media: [DeckMedia] = []
        // The media indexes the viewer serves. Only what a browser can render
        // is kept; the rest is dropped and the shape that references it
        // renders as a frame.
        var indexOf: [Int: Int] = [:]
        for item in pres.media {
            let serveable = [
                "image/png", "image/jpeg", "image/gif", "image/webp",
                "image/svg+xml", "image/bmp", "image/tiff",
            ].contains(item.contentType)
            if !serveable { continue }
            if item.data.isEmpty { continue }
            let id = media.count
            media.append(DeckMedia(name: item.name, contentType: item.contentType, data: item.data))
            indexOf[item.id] = id
        }

        var deck = SlideDeck(
            w: pres.slideW,
            h: pres.slideH,
            title: pres.propsTitle,
            author: pres.propsAuthor,
            slides: [],
            media: media
        )

        for (number, slide) in pres.slides.enumerated() {
            guard let ctx = DeckResolve.Ctx.forSlide(pres, slide) else { continue }
            var built = Slide(title: slide.title())
            built.notes = slide.notes.text()

            // The slide's background.
            let (bgFill, bgPh) = DeckResolve.background(ctx, slide)
            built.bg = fillCSS(ctx, bgFill, bgPh)

            // Master and layout shapes draw behind the slide's own, with the
            // usual PowerPoint rules: the layout's shapes show when the slide
            // says so, the master's when both do; footer-row shapes show only
            // when the deck turns them on. Master/layout content
            // placeholders never draw: their prompt text is editor-only.
            let (slideShowsLayout, layoutShowsMaster) = DeckResolve.showMasterShapes(slide, ctx.layout)
            if layoutShowsMaster {
                let mctx = DeckResolve.Ctx.forMaster(pres, ctx.master)
                for shape in ctx.master.shapes {
                    if isContentPlaceholder(shape) || isHiddenFooter(shape, pres.headerFooter) { continue }
                    buildShape(mctx, shape, number + 1, pres.headerFooter, &built, indexOf)
                }
            }
            if slideShowsLayout, let layout = ctx.layout {
                let lctx = DeckResolve.Ctx.forLayout(pres, ctx.master, layout)
                for shape in layout.shapes {
                    if isContentPlaceholder(shape) || isHiddenFooter(shape, pres.headerFooter) { continue }
                    buildShape(lctx, shape, number + 1, pres.headerFooter, &built, indexOf)
                }
            }
            for shape in slide.shapes {
                buildShape(ctx, shape, number + 1, pres.headerFooter, &built, indexOf)
            }

            // The speakable text, in the same order the items were built.
            assembleText(&built)
            deck.slides.append(built)
        }
        return deck
    }

    /// The slide's speakable text with its byte spans.
    public static func slideText(_ deck: SlideDeck, _ index: Int) -> (String, [TextSpan]) {
        guard index >= 0, index < deck.slides.count else { return ("", []) }
        var slide = deck.slides[index]
        assembleText(&slide)
        return (slide.text, slide.spans)
    }

    // -----------------------------------------------------------------------
    // Master/layout shape gates
    // -----------------------------------------------------------------------

    /// A master or layout shape of the footer row, shown only when the deck's
    /// header/footer settings turn it on.
    static func isHiddenFooter(_ shape: Shape, _ hf: HeaderFooter) -> Bool {
        guard let kind = shape.phType() else { return false }
        switch kind {
        case .footer:
            return !hf.footer || hf.footerText.isEmpty
        case .slideNum:
            return !hf.slideNumber
        case .date:
            if !hf.date { return true }
            // An automatic date is not modelled (it needs the render clock);
            // a fixed one shows its text.
            return hf.dateText.isEmpty
        case .header:
            return !hf.header
        default:
            return false
        }
    }

    /// Whether the shape is a master/layout *content* placeholder — the kind
    /// whose prompt text ("Click to edit Master title style", "Master text
    /// styles", …) must never draw on a slide.
    static func isContentPlaceholder(_ shape: Shape) -> Bool {
        guard shape.ph != nil, let kind = shape.phType() else { return false }
        return !(kind == .header || kind == .date || kind == .footer || kind == .slideNum)
    }

    // -----------------------------------------------------------------------
    // Shape → item
    // -----------------------------------------------------------------------

    static func buildShape(_ ctx: DeckResolve.Ctx, _ shape: Shape, _ slideNumber: Int, _ hf: HeaderFooter, _ slide: inout Slide, _ mediaIndex: [Int: Int]) {
        let xfrm = DeckResolve.xfrm(ctx, shape)
        buildShapeAtXfrm(ctx, shape, xfrm, nil, slideNumber, hf, &slide, mediaIndex, 0)
    }

    /// Build one shape, or flatten a group's children through the group's
    /// transform. `parent` carries the composed affine of the enclosing
    /// group, as (a, b, c, d, e, f).
    static func buildShapeAtXfrm(
        _ ctx: DeckResolve.Ctx, _ shape: Shape, _ xfrm: Xfrm, _ parent: [Double]?,
        _ slideNumber: Int, _ hf: HeaderFooter, _ slide: inout Slide, _ mediaIndex: [Int: Int], _ depth: Int
    ) {
        if shape.hidden || depth > 16 { return }
        let finite = [xfrm.x, xfrm.y, xfrm.w, xfrm.h, xfrm.rot].allSatisfy { $0.isFinite }
        guard finite, xfrm.w > 0 || xfrm.h > 0 else { return }

        if case .group(let children, let childSpace) = shape.kind {
            // The group's own affine, then each child's, composed. The
            // child's box is normalised into the child-space unit box first.
            let ga = compose(parent, xfrm)
            for child in children {
                let local = DeckResolve.xfrm(ctx, child)
                let normalised = childInSpace(local, childSpace)
                buildShapeAtXfrm(ctx, child, normalised, ga, slideNumber, hf, &slide, mediaIndex, depth + 1)
            }
            return
        }

        let (x, y, w, h, rot, fh, fv) = place(compose(parent, xfrm))
        if w < 0.05 && h < 0.05 { return }
        let (fill, ph) = DeckResolve.fill(ctx, shape)
        let paint = fillCSS(ctx, fill, ph)
        let (line, lph) = DeckResolve.line(ctx, shape)
        let border = borderCSS(ctx, line, lph, shape)
        let shadow = DeckResolve.effects(ctx, shape)

        let content: Content
        switch shape.kind {
        case .plain:
            // A bare shape (no text body) still paints: its fill, border,
            // radius and preset SVG ARE the design — the rule lines, arrows
            // and decorative shapes a generated deck is built from. The
            // reference drops these ("geometry only"), which hollowed out
            // exactly those decks; empty paragraphs say nothing and speak
            // nothing.
            content = textItem(ctx, shape, shape.text ?? TextBody())
        case .picture(let pic):
            guard let m = mediaIndex[pic.media] else {
                content = Content.frame(label: shape.name, media: nil)
                break
            }
            let crop = pic.crop.map { max($0, 0) }
            content = .picture(media: m, crop: crop, ocr: nil)
        case .connector:
            // A line: the SVG body carries the stroke, nothing fills.
            content = Content.frame(label: "", media: nil)
        case .table(let table):
            content = tableItem(ctx, table)
        case .media(let label, let poster):
            content = Content.frame(label: label, media: poster.flatMap { mediaIndex[$0] })
        case .opaque(let label, let preview):
            content = Content.frame(label: label, media: preview.flatMap { mediaIndex[$0] })
        case .group:
            // Groups never reach here — buildShapeAtXfrm flattens them above.
            content = Content.frame(label: "", media: nil)
        }

        slide.items.append(Item(
            x: x, y: y, w: w, h: h,
            rot: rot, flipH: fh, flipV: fv,
            fill: paint,
            border: border,
            radius: presetRadius(shape, w, h),
            svg: shapeSVG(ctx, shape, fill, ph, line, lph),
            shadow: shadowCSS(ctx, shadow),
            content: content
        ))
    }

    /// A text shape's paragraphs, resolved.
    static func textItem(_ ctx: DeckResolve.Ctx, _ shape: Shape, _ text: TextBody) -> Content {
        let body = DeckResolve.body(ctx, shape)
        let anchor: Anchor
        switch body.anchor ?? .top {
        case .bottom: anchor = .bottom
        case .middle: anchor = .middle
        default: anchor = .top
        }
        let scale = fontScale(body)
        var paras: [Para] = []
        for para in text.paragraphs {
            let props = DeckResolve.para(ctx, shape, para)
            let level = min(para.level, 8)
            let style = DeckResolve.levelStyle(ctx, shape, level)
            let bullet: Bullet?
            let bulletFont = (props.bullet != nil ? props.bulletFont : nil) ?? style.para.bulletFont
            switch props.bullet ?? style.para.bullet {
            case .some(.char(let c)):
                bullet = Bullet(char: mapSymbolBullet(c, bulletFont), media: nil)
            case .some(.autoNum(let _, let startAt)):
                // The scheme's numbering restarts per shape in practice; a
                // "1." shape is what nearly every deck uses.
                let n = startAt + paras.filter { p in
                    p.bullet.map { b in b.char.allSatisfy { $0.isNumber || $0 == "." || $0 == ")" } } ?? false
                }.count
                bullet = Bullet(char: "\(n).", media: nil)
            case .some(.picture):
                bullet = Bullet(char: "▪", media: nil)
            case .some(.none), nil:
                bullet = nil
            }
            var linePct = 0.0
            var linePts = 0.0
            switch props.lineSpacing {
            case .some(.pct(let v)): linePct = v
            case .some(.pts(let v)): linePts = v
            case nil: break
            }
            var out = Para(
                align: alignName(props.align ?? "l"),
                level: level,
                bullet: bullet,
                marginLeft: max(props.marginLeft ?? 0, 0),
                indent: props.indent ?? 0,
                spaceBefore: spacingPts(props.spaceBefore),
                spaceAfter: spacingPts(props.spaceAfter),
                linePct: linePct,
                linePts: linePts
            )
            // The end mark's size sizes an empty paragraph.
            var endResolved = para.endProps
            endResolved.inherit(para.defProps)
            let endLvl = DeckResolve.levelStyle(ctx, shape, para.level)
            endResolved.inherit(endLvl.run)
            out.emptySize = endResolved.size ?? 18.0
            if para.runs.isEmpty {
                paras.append(out)
                continue
            }
            for run in para.runs {
                switch run.kind {
                case .br:
                    // A soft break splits the paragraph's HTML, not its
                    // speech text (the chunker never sees U+000B).
                    if !out.runs.isEmpty {
                        out.runs[out.runs.count - 1].text.append("\n")
                    }
                case .field(let field):
                    let resolved = DeckResolve.run(ctx, shape, para, run.props)
                    let value = fieldText(field, run.text)
                    out.runs.append(makeRun(ctx, value, resolved, scale))
                case .text:
                    if run.text.isEmpty { continue }
                    var resolved = DeckResolve.run(ctx, shape, para, run.props)
                    if resolved.size == nil {
                        // Nothing anywhere set a size: the presentation's
                        // default text style carries one per level.
                        resolved.size = 18.0
                    }
                    out.runs.append(makeRun(ctx, run.text, resolved, scale))
                }
            }
            paras.append(out)
        }
        let dir: String
        switch body.vert ?? .horizontal {
        case .vertical, .stacked: dir = body.vert == .vertical ? "vert" : "stacked"
        case .vertical270: dir = "vert270"
        case .horizontal: dir = ""
        }
        return .text(paras: paras, anchor: anchor, wrap: body.wrap ?? true, dir: dir)
    }

    static func makeRun(_ ctx: DeckResolve.Ctx, _ text: String, _ resolved: RunProps, _ scale: Double) -> Run {
        let family = DeckResolve.fontFamily(ctx, resolved)
        // A run set in a symbol font (Wingdings, the Adobe Symbol font…)
        // carries shapes and Greek letters on ASCII code points; the font
        // does not exist on iOS, so the raw letters would show. Map to the
        // Unicode shapes the fallback font can draw.
        let mapped = mapSymbolText(text, family)
        Run(
            text: mapped,
            size: max(resolved.size ?? 18.0, 4.0) * scale,
            bold: resolved.bold ?? false,
            italic: resolved.italic ?? false,
            underline: resolved.underline.map { $0 != "none" } ?? false,
            strike: !(resolved.strike == nil || resolved.strike == "noStrike"),
            color: runColor(ctx, resolved),
            font: family,
            spacing: resolved.spacing ?? 0,
            baseline: resolved.baseline ?? 0,
            highlight: resolved.highlight.map { css(ctx.color($0, nil)) }
        )
    }

    static func alignName(_ a: String) -> String {
        switch a {
        case "ctr": return "center"
        case "r": return "right"
        case "just", "justLow", "dist": return "justify"
        default: return "left"
        }
    }

    /// `normAutofit`'s saved scale, applied to every run of the shape.
    static func fontScale(_ body: BodyProps) -> Double {
        if case .some(.shrink(let fontScale, _)) = body.autofit, let v = fontScale, v > 0 {
            return v
        }
        return 1.0
    }

    static func spacingPts(_ s: Spacing?) -> Double {
        switch s {
        case .some(.pts(let v)): return v
        case .some(.pct(let v)): return v // a percent of the line: approximated as points
        case nil: return 0
        }
    }

    /// A field run's text: the value the file cached.
    static func fieldText(_ field: String, _ cached: String) -> String {
        if field.hasPrefix("datetime") || field == "slidenum" {
            return cached
        }
        return field
    }

    static func runColor(_ ctx: DeckResolve.Ctx, _ props: RunProps) -> String? {
        guard let fill = props.fill else { return nil }
        switch fill {
        case .none:
            return "transparent"
        case .solid(let color):
            return css(ctx.color(color, nil))
        default:
            return nil
        }
    }

    /// A table, resolved: fills and text through the cell text bodies.
    static func tableItem(_ ctx: DeckResolve.Ctx, _ table: Table) -> Content {
        var rows: [TableRow] = []
        for row in table.rows {
            var cells: [TableCell] = []
            for cell in row.cells {
                var runs: [Run] = []
                var text = ""
                // A synthetic shape so the cell's text resolves through the
                // master's other-text style only.
                var cellShape = Shape()
                cellShape.kind = .plain
                cellShape.text = cell.text
                for para in cell.text.paragraphs {
                    for run in para.runs {
                        let props = DeckResolve.run(ctx, cellShape, para, run.props, isTableCell: true)
                        text += run.text
                        runs.append(Run(
                            text: run.text,
                            size: max(props.size ?? 14.0, 4.0),
                            bold: props.bold ?? false,
                            italic: props.italic ?? false,
                            underline: props.underline.map { $0 != "none" } ?? false,
                            strike: false,
                            color: runColor(ctx, props),
                            font: DeckResolve.fontFamily(ctx, props),
                            spacing: 0,
                            baseline: 0,
                            highlight: nil
                        ))
                    }
                    text += "\n"
                }
                let fill: String?
                if case .some(.solid(let color)) = cell.fill {
                    fill = css(ctx.color(color, nil))
                } else {
                    fill = nil
                }
                let align: String
                if let p = cell.text.paragraphs.first {
                    let props = DeckResolve.para(ctx, cellShape, p, isTableCell: true)
                    switch props.align ?? "l" {
                    case "ctr": align = "center"
                    case "r": align = "right"
                    default: align = "left"
                    }
                } else {
                    align = "left"
                }
                cells.append(TableCell(
                    text: String(text.dropLast(text.hasSuffix("\n") ? 1 : 0)),
                    runs: runs,
                    fill: fill,
                    colSpan: max(cell.gridSpan, 1),
                    rowSpan: max(cell.rowSpan, 1),
                    covered: cell.isCovered(),
                    align: align
                ))
            }
            rows.append(TableRow(cells: cells))
        }
        let bg: String?
        if case .some(.solid(let color)) = table.background {
            bg = css(ctx.color(color, nil))
        } else {
            bg = nil
        }
        return .table(colWidths: table.cols, rowHeights: table.rows.map(\.height), rows: rows, bg: bg)
    }

    // -----------------------------------------------------------------------
    // Geometry and paint
    // -----------------------------------------------------------------------

    /// The composed placement of a shape: its resolved transform through any
    /// enclosing group's, flattened into (x, y, w, h, rot, flipH, flipV).
    static func place(_ aff: [Double]) -> (Double, Double, Double, Double, Double, Bool, Bool) {
        let (a, b, c, d, e, f) = (aff[0], aff[1], aff[2], aff[3], aff[4], aff[5])
        let sx = (a * a + b * b).squareRoot()
        let sy = (c * c + d * d).squareRoot()
        let rot = atan2(b, a) * 180.0 / .pi
        // A mirror shows up as a negative determinant.
        let mirrored = a * d - b * c < 0
        // Centre of the unit box, mapped.
        let cx = e + (a * 0.5 + c * 0.5)
        let cy = f + (b * 0.5 + d * 0.5)
        return (cx - sx / 2, cy - sy / 2, sx, sy, rot, mirrored, false)
    }

    /// The shape's own transform, composed with an enclosing group's.
    static func compose(_ parent: [Double]?, _ xfrm: Xfrm) -> [Double] {
        let own = xfrmAffine(xfrm)
        guard let p = parent else { return own }
        return composeAffines(p, own)
    }

    /// A transform as (a, b, c, d, e, f): the same mapping `Xfrm.affine`
    /// builds (translate to centre, rotate, flip, scale, translate back),
    /// carrying the box's own width and height so `place` reads the size
    /// back out of the matrix scale.
    static func xfrmAffine(_ x: Xfrm) -> [Double] {
        let rad = x.rot * Double.pi / 180
        let sr = sin(rad)
        let cr = cos(rad)
        let sx = x.flipH ? -x.w : x.w
        let sy = x.flipV ? -x.h : x.h
        // scale*rotate about the box centre, then translate: the unit box's
        // centre (½, ½) must land on the rect's centre.
        let a = cr * sx
        let b = sr * sx
        let c = -sr * sy
        let d = cr * sy
        let e = x.x + x.w / 2 - (a + c) / 2
        let f = x.y + x.h / 2 - (b + d) / 2
        return [a, b, c, d, e, f]
    }

    static func composeAffines(_ outer: [Double], _ inner: [Double]) -> [Double] {
        let (a1, b1, c1, d1, e1, f1) = (outer[0], outer[1], outer[2], outer[3], outer[4], outer[5])
        let (a2, b2, c2, d2, e2, f2) = (inner[0], inner[1], inner[2], inner[3], inner[4], inner[5])
        // The inner affine's input space is the outer affine's unit box: the
        // group's children are normalised into the child-space box before
        // this is built (see `childInSpace`), so plain matrix composition
        // applies.
        return [
            a1 * a2 + c1 * b2,
            b1 * a2 + d1 * b2,
            a1 * c2 + c1 * d2,
            b1 * c2 + d1 * d2,
            a1 * e2 + c1 * f2 + e1,
            b1 * e2 + d1 * f2 + f1,
        ]
    }

    /// A group child's box, written in the group's child-space unit
    /// coordinates: (p − origin) / extent.
    static func childInSpace(_ local: Xfrm, _ space: Xfrm) -> Xfrm {
        let sw = space.w != 0 ? space.w : 1
        let sh = space.h != 0 ? space.h : 1
        return Xfrm(
            x: (local.x - space.x) / sw,
            y: (local.y - space.y) / sh,
            w: local.w / sw,
            h: local.h / sh,
            rot: local.rot,
            flipH: local.flipH,
            flipV: local.flipV
        )
    }

    /// Whether a shape draws as a line (a connector, or a line-like preset).
    static func isLine(_ shape: Shape) -> Bool {
        if case .connector = shape.kind { return true }
        if case .preset(let name, _) = shape.geom {
            return isLineLike(name)
        }
        return false
    }

    /// The corner radius a roundRect-family preset asks for, in points.
    static func presetRadius(_ shape: Shape, _ w: Double, _ h: Double) -> Double {
        guard case .preset(let name, let adj) = shape.geom else { return 0 }
        switch name {
        case "roundRect", "round1Rect", "round2DiagRect", "round2SameRect", "snip1Rect",
             "snip2DiagRect", "snip2SameRect", "snipRoundRect":
            let frac = adj.first.map { min(max($0 / 100_000, 0), 0.5) } ?? (1.0 / 6.0)
            return min(w, h) * frac
        default:
            return 0
        }
    }

    /// An SVG body for the shapes CSS cannot draw: the preset's own path, in
    /// the shape's own coordinate space, with the resolved fill and stroke.
    /// `rect`, `ellipse` and the rounded family are CSS instead; connectors
    /// draw as their preset path across the box.
    static func shapeSVG(
        _ ctx: DeckResolve.Ctx, _ shape: Shape,
        _ fill: Fill?, _ ph: Rgba?,
        _ line: Line, _ lph: Rgba?
    ) -> SvgBody? {
        let fillValue: String?
        if let f = fill {
            switch f {
            case .solid(let color): fillValue = css(ctx.color(color, ph))
            case .none: fillValue = "none"
            default: fillValue = nil
            }
        } else {
            fillValue = nil
        }
        let strokeValue: String?
        if let lf = line.fill {
            switch lf {
            case .solid(let color): strokeValue = css(ctx.color(color, lph))
            default: strokeValue = nil
            }
        } else {
            strokeValue = nil
        }
        let width = line.width ?? 0

        if isLine(shape) {
            // A line: a stroke across the box, flips respected.
            let color = strokeValue ?? "#000"
            let w = line.width ?? 1.0
            guard case .preset(let name, let adj) = shape.geom else {
                return SvgBody(d: "M0,0 L100,100", fill: nil, stroke: color, strokeWidth: w)
            }
            guard let geom = presetBuild(name, 100, 100, adj) else { return nil }
            return SvgBody(d: geom.outline().toSVG(), fill: nil, stroke: color, strokeWidth: w)
        }

        guard case .preset(let name, let adj) = shape.geom else {
            // Custom geometry is not modelled: no SVG body (the box paints).
            return nil
        }
        switch name {
        case "rect", "roundRect":
            return nil // CSS paints these
        default:
            guard let geom = presetBuild(name, 100, 100, adj) else { return nil }
            let d = geom.outline().toSVG()
            return SvgBody(d: d, fill: fillValue, stroke: strokeValue, strokeWidth: width)
        }
    }

    /// A resolved fill as a CSS paint value.
    static func fillCSS(_ ctx: DeckResolve.Ctx, _ fill: Fill?, _ ph: Rgba?) -> String? {
        guard let fill else { return nil }
        switch fill {
        case .none:
            return "transparent"
        case .solid(let color):
            return css(ctx.color(color, ph))
        case .gradient(let g):
            return gradientCSS(ctx, g)
        case .pattern(let fg):
            return css(ctx.color(fg, nil))
        case .picture(let media, _):
            // A picture fill paints the box with the image (cover); the
            // viewer resolves media by id through its scheme handler.
            return "url('deck://media/\(media)/fill') center/cover no-repeat"
        case .group:
            return "transparent"
        }
    }

    static func gradientCSS(_ ctx: DeckResolve.Ctx, _ g: Gradient) -> String {
        let stops = g.stops.map { s in
            String(format: "%.1f%% %@", min(max(s.pos * 100, 0), 100), css(ctx.color(s.color, nil)))
        }
        let list = stops.joined(separator: ", ")
        switch g.shape {
        case .linear(let angle, _):
            // PowerPoint's angle is clockwise from the direction pointing
            // right (and the screen's y grows downward), so 90° — PowerPoint's
            // "Linear Down" — is top→bottom. CSS angles are clockwise from
            // "up": the matching CSS angle is pptx + 90 (90° → 180deg = to
            // bottom, 0° → 90deg = to right). The reference carried `90 −
            // angle`, which mirrors every non-horizontal gradient onto its
            // opposite direction; this port deviates deliberately.
            var cssAngle = (angle + 90).truncatingRemainder(dividingBy: 360)
            if cssAngle < 0 { cssAngle += 360 }
            return String(format: "linear-gradient(%.1fdeg, %@)", cssAngle, list)
        case .path(let path, _):
            if path == "rect" {
                return "linear-gradient(180deg, \(list))"
            }
            return "radial-gradient(circle at center, \(list))"
        }
    }

    /// A resolved outline as a CSS border, for the CSS-painted shapes.
    static func borderCSS(_ ctx: DeckResolve.Ctx, _ line: Line, _ ph: Rgba?, _ shape: Shape) -> Border? {
        if isLine(shape) { return nil } // a connector's stroke is its SVG
        guard let fill = line.fill else { return nil }
        let color: String
        switch fill {
        case .none:
            return nil
        case .solid(let c):
            color = css(ctx.color(c, ph))
        default:
            return nil
        }
        let width = max(line.width ?? 0.75, 0.25)
        let style: String
        switch line.dash {
        case nil, .some("solid"):
            style = "solid"
        case .some(let name):
            switch name {
            case "dot", "sysDot", "sysDashDot", "sysDashDotDot":
                style = "dotted"
            case "dash", "lgDash", "sysDash", "dashDot", "lgDashDot", "lgDashDotDot":
                style = "dashed"
            default:
                style = "dashed"
            }
        }
        return Border(width: width, color: color, style: style)
    }

    /// A shape's outer shadow as CSS.
    static func shadowCSS(_ ctx: DeckResolve.Ctx, _ effects: Effects?) -> String? {
        guard let shadow = effects?.outerShadow else { return nil }
        let color = ctx.color(shadow.color, nil)
        if color.a == 0 { return nil }
        let rad = shadow.dir * Double.pi / 180
        let dx = shadow.dist * cos(rad)
        let dy = shadow.dist * sin(rad)
        return String(format: "%.1fpt %.1fpt %.1fpt %@", dx, dy, max(shadow.blur, 0), css(color))
    }

    static func css(_ c: Rgba) -> String {
        if c.a == 255 {
            return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
        }
        return String(format: "rgba(%d,%d,%d,%.3f)", c.r, c.g, c.b, Double(c.a) / 255.0)
    }

    // -----------------------------------------------------------------------
    // The speakable text and its spans
    // -----------------------------------------------------------------------

    /// Build `Slide.text` from the items, in VISUAL reading order — top to
    /// bottom, left to right on ties — recording a byte span per paragraph.
    /// The RENDER order stays z-order (paint order); only the speech order
    /// follows the eye. Z-order was the reference's reading order too, but it
    /// is the PAINT order, and decks (especially generated ones) paint their
    /// footer last: the trailing echo of the section name made TTS read "the
    /// title" at the end of every slide. Speaking in the order the slide
    /// LOOKS puts the header first, the content next, the footer last — the
    /// way a person reads it.
    ///
    /// Text that repeats on one slide (the footer echoing the header) speaks
    /// once, from its first position: hearing "HIV · Staging & Classification"
    /// at both ends of every slide is noise, not content.
    ///
    /// Idempotent: `spans` are rebuilt from the items each run (slideText
    /// re-assembles a copy of a slide that was already assembled at build
    /// time), and items are never reordered.
    public static func assembleText(_ slide: inout Slide) {
        // Visual order, stable on ties (the file order wins within a band).
        // A 2pt band keeps near-tied boxes (a kicker and its page number on
        // one line) reading left→right instead of splitting on rounding.
        let order = slide.items.enumerated()
            .map { (index: $0.offset, item: $0.element) }
            .sorted { (a: (index: Int, item: Item), b: (index: Int, item: Item)) in
                if abs(a.item.y - b.item.y) > 2 { return a.item.y < b.item.y }
                if abs(a.item.x - b.item.x) > 2 { return a.item.x < b.item.x }
                return a.index < b.index
            }
        var text = ""
        var spans: [TextSpan] = []
        var spoken = Set<String>()
        for (index, item) in order {
            switch item.content {
            case .text(let paras, _, _, _):
                for (para, p) in paras.enumerated() {
                    var joined = ""
                    for run in p.runs {
                        joined += run.text.replacingOccurrences(of: "\n", with: " ")
                    }
                    let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    // Chrome echo: the same line twice on one slide (a footer
                    // repeating the header) speaks once.
                    let key = trimmed.lowercased()
                    if !spoken.insert(key).inserted { continue }
                    if !text.isEmpty { text.append("\n") }
                    let start = text.utf8.count
                    text += trimmed
                    spans.append(TextSpan(start: start, end: text.utf8.count, item: index, para: para))
                }
            case .picture(_, _, let ocr):
                if let ocr {
                    for line in ocr.split(separator: "\n", omittingEmptySubsequences: false) {
                        let line = line.trimmingCharacters(in: .whitespaces)
                        if line.isEmpty { continue }
                        if !text.isEmpty { text.append("\n") }
                        let start = text.utf8.count
                        text += line
                        spans.append(TextSpan(start: start, end: text.utf8.count, item: index, para: nil))
                    }
                }
            case .table(let _, let _, let rows, _):
                for row in rows {
                    let cells = row.cells
                        .filter { !$0.covered }
                        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if cells.isEmpty { continue }
                    if !text.isEmpty { text.append("\n") }
                    let start = text.utf8.count
                    text += cells.joined(separator: ", ")
                    spans.append(TextSpan(start: start, end: text.utf8.count, item: index, para: nil))
                }
            case .frame:
                break // frame labels are shown, not spoken
            }
        }
        let notes = slide.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            if !text.isEmpty { text += "\n\n" }
            let start = text.utf8.count
            text += notes
            spans.append(TextSpan(start: start, end: text.utf8.count, item: Int.max, para: nil))
        }
        slide.text = text
        slide.spans = spans
    }
}
