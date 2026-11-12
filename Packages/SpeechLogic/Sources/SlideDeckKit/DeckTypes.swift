// DeckTypes.swift — the read-path model between the PPTX parts and the
// resolved viewer model: ported from deckcraft-model @ a0eeb34 (lib.rs,
// style.rs, text.rs, theme.rs, table.rs), carrying only the fields the deck
// viewer's resolve + paint pipeline consumes. Inheritance (`inherit`) follows
// the Rust Option-merge exactly: a present value always wins, a nil keeps
// whatever came from further up the chain (slide → layout → master → theme).

import Foundation

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

/// One DrawingML colour reference: a base colour plus its transform list
/// (`a:lumMod`, `a:alpha`, …), resolved through the theme's scheme.
public enum ColorBase: Equatable {
    case rgb(Rgba)
    case scheme(SchemeSlot)
    /// A system colour: its name and the last RGB the producer cached.
    case system(name: String, last: Rgba)
    case preset(String)
}

public struct ColorRef: Equatable {
    public var base: ColorBase
    public var mods: [ColorTransform]

    public init(base: ColorBase, mods: [ColorTransform] = []) {
        self.base = base
        self.mods = mods
    }

    public static func rgb(_ c: Rgba) -> ColorRef { ColorRef(base: .rgb(c)) }
    public static func scheme(_ slot: SchemeSlot) -> ColorRef { ColorRef(base: .scheme(slot)) }

    /// Resolve through a theme's scheme colours, with the style colour
    /// (`phClr`) substituting a `.phClr` base.
    public func resolve(_ colors: [SchemeSlot: Rgba], _ ph: Rgba?) -> Rgba {
        let raw: Rgba?
        switch base {
        case .rgb(let c): raw = c
        case .scheme(let slot):
            if slot == .phClr {
                raw = ph ?? Rgba(r: 0, g: 0, b: 0)
            } else {
                raw = colors[slot]
            }
        case .system(_, let last): raw = last
        case .preset(let name): raw = presetColor(name)
        }
        guard let raw else { return Rgba(r: 0, g: 0, b: 0) }
        return colorApply(raw, mods)
    }
}

// ---------------------------------------------------------------------------
// Fills, lines, effects
// ---------------------------------------------------------------------------

public enum Fill: Equatable {
    case none
    case solid(color: ColorRef)
    case gradient(Gradient)
    /// A picture filling a shape or background. Only the stretch mode and
    /// crop survive the port — a tile is approximated as a stretch.
    case picture(media: Int, crop: [Double])
    /// A preset pattern approximated by its foreground colour.
    case pattern(fg: ColorRef)
    case group
}

public struct GradientStop: Equatable {
    public var pos: Double
    public var color: ColorRef

    public init(pos: Double, color: ColorRef) {
        self.pos = pos
        self.color = color
    }
}

public enum GradientShape: Equatable {
    case linear(angle: Double, scaled: Bool)
    case path(path: String, focus: [Double])
}

public struct Gradient: Equatable {
    public var stops: [GradientStop]
    public var shape: GradientShape
    public var rotateWithShape: Bool

    public init(stops: [GradientStop], shape: GradientShape, rotateWithShape: Bool = true) {
        self.stops = stops
        self.shape = shape
        self.rotateWithShape = rotateWithShape
    }
}

public struct Shadow: Equatable {
    public var color: ColorRef
    public var blur: Double
    public var dist: Double
    public var dir: Double
    public var sx: Double
    public var sy: Double

    public init(color: ColorRef, blur: Double, dist: Double, dir: Double, sx: Double, sy: Double) {
        self.color = color
        self.blur = blur
        self.dist = dist
        self.dir = dir
        self.sx = sx
        self.sy = sy
    }
}

public struct Effects: Equatable {
    /// Only the outer shadow is modelled; the rest of the effect set is the
    /// documented degradation.
    public var outerShadow: Shadow?

    public init(outerShadow: Shadow? = nil) { self.outerShadow = outerShadow }
}

public struct Line {
    public var width: Double?
    /// Fill of the line: the solid colour is what CSS borders draw; none
    /// removes the line.
    public var fill: Fill?
    public var cap: String?
    public var dash: String?
    /// `double` maps to the CSS border style of the same name.
    public var compound: String?

    public init() {}

    public static func none() -> Line {
        var l = Line()
        l.fill = .none
        return l
    }

    /// Inherit: the receiver's unset fields take the other's set ones.
    public mutating func inherit(_ o: Line) {
        if width == nil { width = o.width }
        if fill == nil { fill = o.fill }
        if cap == nil { cap = o.cap }
        if dash == nil { dash = o.dash }
        if compound == nil { compound = o.compound }
    }
}

/// A shape's style references into the theme's format scheme
/// (`p:style`): `(idx, ph colour)` pairs.
public struct ShapeStyle {
    public var lineRef: (Int, ColorRef)
    public var fillRef: (Int, ColorRef)
    public var effectRef: (Int, ColorRef)
    /// ("major" | "minor", ph colour).
    public var fontRef: (String, ColorRef?)

    public init(lineRef: (Int, ColorRef), fillRef: (Int, ColorRef), effectRef: (Int, ColorRef), fontRef: (String, ColorRef?)) {
        self.lineRef = lineRef
        self.fillRef = fillRef
        self.effectRef = effectRef
        self.fontRef = fontRef
    }
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

public enum TextAnchor: Equatable {
    case top, middle, bottom

    public static func fromXML(_ s: String?) -> TextAnchor? {
        switch s {
        case "t": return .top
        case "ctr": return .middle
        case "b": return .bottom
        default: return nil
        }
    }
}

public enum TextDir: Equatable {
    case horizontal, vertical, vertical270, stacked

    public static func fromXML(_ s: String?) -> TextDir? {
        switch s {
        case "vert": return .vertical
        case "vert270": return .vertical270
        case "stacked", "eaVert": return .stacked
        default: return nil
        }
    }
}

public enum AutoFit: Equatable {
    case none
    /// `normAutofit`'s saved shrink; the font scale applies to every run.
    case shrink(fontScale: Double?, lineReduction: Double)
    case shape
}

public struct BodyProps {
    public var insetL: Double?
    public var insetT: Double?
    public var insetR: Double?
    public var insetB: Double?
    public var anchor: TextAnchor?
    public var anchorCtr: Bool?
    public var wrap: Bool?
    public var vert: TextDir?
    public var autofit: AutoFit?

    public init() {}

    public mutating func inherit(_ o: BodyProps) {
        if insetL == nil { insetL = o.insetL }
        if insetT == nil { insetT = o.insetT }
        if insetR == nil { insetR = o.insetR }
        if insetB == nil { insetB = o.insetB }
        if anchor == nil { anchor = o.anchor }
        if anchorCtr == nil { anchorCtr = o.anchorCtr }
        if wrap == nil { wrap = o.wrap }
        if vert == nil { vert = o.vert }
        if autofit == nil { autofit = o.autofit }
    }
}

public enum BulletSpec: Equatable {
    case char(String)
    case autoNum(scheme: String, startAt: Int)
    case picture(media: Int)
    case none
}

public enum Spacing: Equatable {
    case pct(Double)
    case pts(Double)
}

public struct ParaProps {
    public var align: String?
    public var marginLeft: Double?
    public var marginRight: Double?
    public var indent: Double?
    public var lineSpacing: Spacing?
    public var spaceBefore: Spacing?
    public var spaceAfter: Spacing?
    public var bullet: BulletSpec?
    /// The bullet glyph's font (`a:buFont` typeface): Wingdings and friends
    /// encode shapes on ASCII code points, and the glyph must be mapped to
    /// the Unicode shape the web can show (see `mapSymbolBullet`).
    public var bulletFont: String?
    public var bulletColor: ColorRef?
    public var bulletSize: Double?

    public init() {}

    public mutating func inherit(_ o: ParaProps) {
        if align == nil { align = o.align }
        if marginLeft == nil { marginLeft = o.marginLeft }
        if marginRight == nil { marginRight = o.marginRight }
        if indent == nil { indent = o.indent }
        if lineSpacing == nil { lineSpacing = o.lineSpacing }
        if spaceBefore == nil { spaceBefore = o.spaceBefore }
        if spaceAfter == nil { spaceAfter = o.spaceAfter }
        if bullet == nil { bullet = o.bullet }
        if bulletFont == nil { bulletFont = o.bulletFont }
        if bulletColor == nil { bulletColor = o.bulletColor }
        if bulletSize == nil { bulletSize = o.bulletSize }
    }
}

public struct RunProps {
    public var size: Double?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: String?
    public var strike: String?
    public var baseline: Double?
    public var caps: String?
    public var spacing: Double?
    public var fill: Fill?
    public var highlight: ColorRef?
    public var font: String?
    public var link: Bool

    public init() {
        link = false
    }

    public mutating func inherit(_ o: RunProps) {
        if size == nil { size = o.size }
        if bold == nil { bold = o.bold }
        if italic == nil { italic = o.italic }
        if underline == nil { underline = o.underline }
        if strike == nil { strike = o.strike }
        if baseline == nil { baseline = o.baseline }
        if caps == nil { caps = o.caps }
        if spacing == nil { spacing = o.spacing }
        if fill == nil { fill = o.fill }
        if highlight == nil { highlight = o.highlight }
        if font == nil { font = o.font }
        if !link && o.link { link = true }
    }
}

public struct LevelStyle {
    public var para: ParaProps
    public var run: RunProps

    public init(para: ParaProps = ParaProps(), run: RunProps = RunProps()) {
        self.para = para
        self.run = run
    }
}

/// Nine levels of paragraph/run defaults (`a:lstStyle`, `p:titleStyle`, …).
public struct ListStyle {
    public var levels: [LevelStyle?] // 0..<9

    public init() { levels = [LevelStyle?](repeating: nil, count: 9) }

    public func level(_ l: Int) -> LevelStyle? {
        guard l >= 0, l < 9 else { return nil }
        return levels[l]
    }

    public mutating func set(_ l: Int, _ v: LevelStyle) {
        guard l >= 0, l < 9 else { return }
        levels[l] = v
    }

    public var isEmpty: Bool { levels.allSatisfy { $0 == nil } }
}

public enum RunKind: Equatable {
    case text
    case br
    case field(String)
}

public struct TextRun {
    public var text: String
    public var props: RunProps
    public var kind: RunKind

    public init(text: String, props: RunProps, kind: RunKind) {
        self.text = text
        self.props = props
        self.kind = kind
    }
}

public struct TextParagraph {
    public var level: Int
    public var props: ParaProps
    public var defProps: RunProps
    public var endProps: RunProps
    public var runs: [TextRun]

    public init() {
        level = 0
        props = ParaProps()
        defProps = RunProps()
        endProps = RunProps()
        runs = []
    }
}

public struct TextBody {
    public var body: BodyProps
    public var listStyle: ListStyle
    public var paragraphs: [TextParagraph]

    public init() {
        body = BodyProps()
        listStyle = ListStyle()
        paragraphs = []
    }

    /// The plain text, paragraphs joined by newlines.
    public func text() -> String {
        paragraphs.map { p in p.runs.filter { $0.kind != .br }.map(\.text).joined() }.joined(separator: "\n")
    }

    public var isEmpty: Bool {
        paragraphs.allSatisfy { p in p.runs.allSatisfy { $0.text.isEmpty } }
    }
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

public enum PhType: Equatable {
    case title, ctrTitle, subTitle, body, obj
    case chart, table, clipArt, diagram, media, picture, slideImage
    case date, footer, slideNum, header
    case custom(String)

    public static func fromXML(_ s: String?) -> PhType {
        switch s {
        case "title": return .title
        case "ctrTitle": return .ctrTitle
        case "subTitle": return .subTitle
        case "body": return .body
        case "obj": return .obj
        case "chart": return .chart
        case "tbl": return .table
        case "clipArt": return .clipArt
        case "diagram": return .diagram
        case "media": return .media
        case "pic": return .picture
        case "sldImg": return .slideImage
        case "dt": return .date
        case "ftr": return .footer
        case "sldNum": return .slideNum
        case "hdr": return .header
        default: return .custom(s ?? "")
        }
    }

    public var isTitle: Bool {
        self == .title || self == .ctrTitle
    }
}

public struct Placeholder {
    public var kind: PhType
    public var idx: Int

    public init(kind: PhType, idx: Int) {
        self.kind = kind
        self.idx = idx
    }
}

/// Shape geometry: a preset (by catalog name and its adjust values) or a
/// custom path list. The empty custom geometry is the marker for "this
/// placeholder inherits its geometry" (see PptxRead.inheritPlaceholderGeometry).
public enum Geom {
    case preset(name: String, adj: [Double])
    case custom(paths: [GeomPath])

    public static func `default`() -> Geom { .preset(name: "rect", adj: []) }
}

public enum ShapeKind {
    case plain
    case picture(fill: PictureFill)
    case group(children: [Shape], child: Xfrm)
    case connector
    case table(Table)
    case media(label: String, poster: Int?)
    case opaque(label: String, preview: Int?)
}

public struct PictureFill {
    public var media: Int
    /// Crop as fractions (l, t, r, b).
    public var crop: [Double]

    public init(media: Int, crop: [Double]) {
        self.media = media
        self.crop = crop
    }
}

public struct Shape {
    public var name: String
    public var hidden: Bool
    public var textBox: Bool
    public var ph: Placeholder?
    public var xfrm: Xfrm?
    public var geom: Geom
    public var fill: Fill?
    public var line: Line?
    public var effects: Effects?
    public var style: ShapeStyle?
    public var text: TextBody?
    public var kind: ShapeKind

    public init() {
        name = ""
        hidden = false
        textBox = false
        ph = nil
        xfrm = nil
        geom = .default()
        fill = nil
        line = nil
        effects = nil
        style = nil
        text = nil
        kind = .plain
    }

    public func phType() -> PhType? { ph?.kind }
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

public struct Cell {
    public var text: TextBody
    public var fill: Fill?
    public var gridSpan: Int
    public var rowSpan: Int
    public var hMerge: Bool
    public var vMerge: Bool
    public var anchor: TextAnchor?

    public init() {
        text = TextBody()
        fill = nil
        gridSpan = 1
        rowSpan = 1
        hMerge = false
        vMerge = false
        anchor = nil
    }

    public func isCovered() -> Bool { hMerge || vMerge }
}

public struct TableRowModel {
    public var height: Double
    public var cells: [Cell]

    public init(height: Double, cells: [Cell]) {
        self.height = height
        self.cells = cells
    }
}

public struct Table {
    public var cols: [Double]
    public var rows: [TableRowModel]
    public var background: Fill?

    public init() {
        cols = []
        rows = []
        background = nil
    }

    /// Normalise: ragged rows (fewer cells than the grid) pad with covered
    /// cells so the HTML rows stay rectangular. A cell's own `gridSpan`
    /// carries its width — the renderer writes the colspan attribute; the
    /// producer's `hMerge` continuation cells stay exactly as written.
    public mutating func normalize() {
        let widest = rows.map(\.cells.count).max() ?? 0
        let colCount = max(cols.count, widest)
        if cols.count < colCount {
            cols.append(contentsOf: [Double](repeating: 72.0, count: colCount - cols.count))
        }
        for r in rows.indices {
            var cells = rows[r].cells
            // A cell spans `gridSpan` grid units; pad only until the row's
            // unit total reaches the grid width.
            var units = cells.reduce(0) { $0 + max(1, $1.gridSpan) }
            while units < colCount {
                var cov = Cell()
                cov.hMerge = true
                cells.append(cov)
                units += 1
            }
            rows[r].cells = cells
        }
    }
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

/// A theme's colour scheme: the twelve slots by name.
public struct ThemeColors {
    public var colors: [SchemeSlot: Rgba]

    public init() { colors = [:] }

    public subscript(_ slot: SchemeSlot) -> Rgba? {
        get { colors[slot] }
        set { colors[slot] = newValue }
    }
}

public struct FontSet {
    public var latin: String
    public var ea: String
    public var cs: String

    public init(latin: String = "", ea: String = "", cs: String = "") {
        self.latin = latin
        self.ea = ea
        self.cs = cs
    }
}

public struct FontScheme {
    public var major: FontSet
    public var minor: FontSet

    public init() {
        major = FontSet()
        minor = FontSet()
    }
}

public struct FormatScheme {
    public var fills: [Fill]
    public var lines: [Line]
    public var effects: [Effects]
    public var bgFills: [Fill]

    public init() {
        fills = []
        lines = []
        effects = []
        bgFills = []
    }
}

public struct Theme {
    public var name: String
    public var colors: ThemeColors
    public var fonts: FontScheme
    public var format: FormatScheme

    public init() {
        name = ""
        colors = ThemeColors()
        fonts = FontScheme()
        format = FormatScheme()
    }

    /// Concrete font for a theme reference ("+mj-lt", "+mn-lt", or a
    /// literal typeface).
    public func font(_ ref: String) -> String {
        switch ref {
        case "+mj-lt": return fonts.major.latin
        case "+mn-lt": return fonts.minor.latin
        case "+mj-ea": return fonts.major.ea
        case "+mn-ea": return fonts.minor.ea
        case "+mj-cs": return fonts.major.cs
        case "+mn-cs": return fonts.minor.cs
        default: return ref
        }
    }
}

// ---------------------------------------------------------------------------
// Background
// ---------------------------------------------------------------------------

public enum Background {
    case fill(Fill)
    case ref(idx: Int, color: ColorRef)
}

// ---------------------------------------------------------------------------
// Masters, layouts, slides, presentation
// ---------------------------------------------------------------------------

public struct HeaderFooter {
    public var header = false
    public var date = false
    public var footer = false
    public var slideNumber = false
    public var footerText = ""
    public var dateText = ""

    public init() {}
}

public struct Master {
    public var name: String
    public var theme: Theme
    public var colorMap: [(String, String)]
    public var shapes: [Shape]
    public var titleStyle: ListStyle
    public var bodyStyle: ListStyle
    public var otherStyle: ListStyle
    public var layouts: [Layout]
    public var background: Background?

    public init() {
        name = ""
        theme = Theme()
        colorMap = []
        shapes = []
        titleStyle = ListStyle()
        bodyStyle = ListStyle()
        otherStyle = ListStyle()
        layouts = []
        background = nil
    }

    /// The scheme slots with the master's colour map applied
    /// (`a:clrMap`: bg1→lt1, tx1→dk1, …).
    public func scheme() -> ThemeColors {
        schemeWith(colorMap)
    }

    public func schemeWith(_ map: [(String, String)]) -> ThemeColors {
        var out = ThemeColors()
        for slot in SchemeSlot.theme {
            let mapped = Self.mapSlot(map, slot)
            if let c = theme.colors[mapped] {
                out[slot] = c
            }
        }
        return out
    }

    /// The colour map's redirection of one slot. Map keys/values are the XML
    /// colour names (bg1/tx1/bg2/tx2/…); only the pairs the standard allows
    /// are applied.
    public static func mapSlot(_ map: [(String, String)], _ slot: SchemeSlot) -> SchemeSlot {
        let key: String
        switch slot {
        case .bg1: key = "bg1"
        case .tx1: key = "tx1"
        case .bg2: key = "bg2"
        case .tx2: key = "tx2"
        default: return slot
        }
        if let v = map.first(where: { $0.0 == key })?.1 {
            switch v {
            case "lt1": return .lt1
            case "dk1": return .dk1
            case "lt2": return .lt2
            case "dk2": return .dk2
            case "hlink": return .hlink
            case "folHlink": return .folHlink
            default: return slot
            }
        }
        return slot
    }
}

public struct Layout {
    public var name: String
    public var shapes: [Shape]
    public var colorMap: [(String, String)]?
    public var showMasterShapes: Bool
    public var background: Background?

    public init() {
        name = ""
        shapes = []
        colorMap = nil
        showMasterShapes = true
        background = nil
    }
}

public struct PptxSlide {
    public var shapes: [Shape]
    public var layoutIndex: Int?
    public var masterIndex: Int?
    public var notes: TextBody
    public var background: Background?
    public var colorMap: [(String, String)]?
    public var showMasterShapes: Bool

    public init() {
        shapes = []
        layoutIndex = nil
        masterIndex = nil
        notes = TextBody()
        background = nil
        colorMap = nil
        showMasterShapes = true
    }

    /// The first title placeholder's text — the TOC row, the status line.
    public func title() -> String {
        for s in shapes {
            guard let kind = s.phType(), kind.isTitle, let t = s.text else { continue }
            let txt = t.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !txt.isEmpty { return txt }
        }
        return ""
    }
}

public struct Presentation {
    public var slideW: Double
    public var slideH: Double
    public var masters: [Master]
    public var slides: [PptxSlide]
    public var media: [(id: Int, name: String, contentType: String, data: [UInt8])]
    public var defaultTextStyle: ListStyle
    public var propsTitle: String
    public var propsAuthor: String
    public var headerFooter: HeaderFooter

    public init() {
        slideW = 960
        slideH = 540
        masters = []
        slides = []
        media = []
        defaultTextStyle = ListStyle()
        propsTitle = ""
        propsAuthor = ""
        headerFooter = HeaderFooter()
    }

    /// The master and layout a slide draws from, by stored indices.
    public func masterFor(_ slide: PptxSlide) -> (Master, Layout?)? {
        guard let mi = slide.masterIndex, mi < masters.count else { return nil }
        let master = masters[mi]
        let layout = slide.layoutIndex.flatMap { li in li < master.layouts.count ? master.layouts[li] : nil }
        return (master, layout)
    }
}
