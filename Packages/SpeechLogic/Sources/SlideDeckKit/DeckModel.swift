// DeckModel.swift — the RESOLVED deck model, ported from the Linux app's
// sn-doc/src/slides.rs (crates/sn-doc @ speechnotes-linux-rust): every
// position, fill, font and colour is final when it reaches this model. The
// placeholder → layout → master → theme inheritance chain is walked at parse
// time (DeckResolve.swift), not in the UI; what the app receives is a slide
// of absolutely-positioned items it paints as HTML/CSS (DeckHTML.swift) —
// exactly what the Linux viewer does.
//
// Alongside the geometry, each slide carries its speakable text with byte
// spans (assembleText): the exact string the speech pipeline chunks, with the
// byte range of every paragraph mapped back to the item that shows it. Built
// in the same pass as the geometry so the two cannot drift.

import Foundation

/// One embedded image the deck's items reference, served to the viewer
/// through the deck's own URL scheme.
public struct DeckMedia {
    public var name: String
    public var contentType: String
    public var data: [UInt8]

    public init(name: String, contentType: String, data: [UInt8]) {
        self.name = name
        self.contentType = contentType
        self.data = data
    }
}

/// A resolved deck: slide size in points and the slides in reading order.
public struct SlideDeck {
    public var w: Double
    public var h: Double
    public var title: String
    public var author: String
    public var slides: [Slide]
    public var media: [DeckMedia]

    public init(w: Double = 0, h: Double = 0, title: String = "", author: String = "", slides: [Slide] = [], media: [DeckMedia] = []) {
        self.w = w
        self.h = h
        self.title = title
        self.author = author
        self.slides = slides
        self.media = media
    }
}

/// One resolved slide.
public struct Slide {
    /// The first title placeholder's text — the TOC row, the status line.
    public var title: String
    /// The slide's own background paint, when it sets one.
    public var bg: String?
    /// The shapes in z-order (document order), groups flattened.
    public var items: [Item]
    /// Speaker notes, verbatim.
    public var notes: String
    /// The speakable text: shape text in reading order, then the notes. The
    /// byte spans below index into exactly this string — the string the
    /// speech plan chunks.
    public var text: String
    /// Where each paragraph of `text` lives on the slide.
    public var spans: [TextSpan]

    public init(title: String = "", bg: String? = nil, items: [Item] = [], notes: String = "", text: String = "", spans: [TextSpan] = []) {
        self.title = title
        self.bg = bg
        self.items = items
        self.notes = notes
        self.text = text
        self.spans = spans
    }
}

/// A byte range of `Slide.text` mapped to the item that shows it.
public struct TextSpan: Equatable {
    public var start: Int
    /// Half-open end.
    public var end: Int
    /// Index into `Slide.items`. `Int.max` for the notes tail, which the
    /// slide itself does not show.
    public var item: Int
    /// The paragraph inside the item's text, when the span is one paragraph
    /// of a text item (the highlight target `i{item}p{para}`); nil for a
    /// whole-item span.
    public var para: Int?

    public init(start: Int, end: Int, item: Int, para: Int?) {
        self.start = start
        self.end = end
        self.item = item
        self.para = para
    }
}

/// One absolutely-positioned, fully-resolved shape.
public struct Item {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// Clockwise degrees.
    public var rot: Double
    public var flipH: Bool
    public var flipV: Bool
    public var fill: String?
    public var border: Border?
    /// Corner radius in points, for the rect-family shapes CSS rounds.
    public var radius: Double
    /// An SVG body for the shapes CSS cannot draw: the preset's own path in
    /// a `0 0 w h` view box, fill and stroke applied.
    public var svg: SvgBody?
    public var shadow: String?
    public var content: Content

    public init(x: Double, y: Double, w: Double, h: Double, rot: Double, flipH: Bool, flipV: Bool,
                fill: String?, border: Border?, radius: Double, svg: SvgBody?, shadow: String?, content: Content) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rot = rot
        self.flipH = flipH
        self.flipV = flipV
        self.fill = fill
        self.border = border
        self.radius = radius
        self.svg = svg
        self.shadow = shadow
        self.content = content
    }
}

public struct Border: Equatable {
    public var width: Double
    public var color: String
    /// CSS border-style (`solid`, `dashed`, `dotted`, `double`).
    public var style: String

    public init(width: Double, color: String, style: String) {
        self.width = width
        self.color = color
        self.style = style
    }
}

/// The SVG body of a non-rectangular shape.
public struct SvgBody {
    public var d: String
    public var fill: String?
    public var stroke: String?
    public var strokeWidth: Double

    public init(d: String, fill: String?, stroke: String?, strokeWidth: Double) {
        self.d = d
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }
}

public enum Content {
    case text(paras: [Para], anchor: Anchor, wrap: Bool, dir: String)
    case picture(media: Int, crop: [Double], ocr: String?)
    case table(colWidths: [Double], rowHeights: [Double], rows: [TableRow], bg: String?)
    /// Something that renders as a frame and a label: a chart, a SmartArt
    /// drawing this build does not resolve, an EMF/WMF picture, a video or
    /// audio poster. The documented honest degradation — the reference's
    /// chart SVG and diagram outlines are follow-up work.
    case frame(label: String, media: Int?)
}

public enum Anchor: Equatable {
    case top
    case middle
    case bottom
}

public struct Para {
    public var runs: [Run]
    public var align: String
    public var level: Int
    /// The bullet glyph, when the level style asks for one.
    public var bullet: Bullet?
    public var marginLeft: Double
    public var indent: Double
    public var spaceBefore: Double
    public var spaceAfter: Double
    /// Line spacing: a multiplier (0 = unset), or points when `linePts` is set.
    public var linePct: Double
    public var linePts: Double
    /// A minimum height for an empty paragraph, so a blank line keeps its
    /// place: the end mark's size.
    public var emptySize: Double

    public init(runs: [Run] = [], align: String = "left", level: Int = 0, bullet: Bullet? = nil,
                marginLeft: Double = 0, indent: Double = 0, spaceBefore: Double = 0, spaceAfter: Double = 0,
                linePct: Double = 0, linePts: Double = 0, emptySize: Double = 0) {
        self.runs = runs
        self.align = align
        self.level = level
        self.bullet = bullet
        self.marginLeft = marginLeft
        self.indent = indent
        self.spaceBefore = spaceBefore
        self.spaceAfter = spaceAfter
        self.linePct = linePct
        self.linePts = linePts
        self.emptySize = emptySize
    }
}

public struct Bullet {
    public var char: String
    /// A picture bullet's media, when the deck embedded one.
    public var media: Int?

    public init(char: String, media: Int? = nil) {
        self.char = char
        self.media = media
    }
}

public struct Run {
    public var text: String
    /// Font size in points, fully resolved.
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strike: Bool
    public var color: String?
    public var font: String
    /// Extra letter spacing in points.
    public var spacing: Double
    /// Baseline offset as a fraction of the size (0.3 = superscript).
    public var baseline: Double
    public var highlight: String?

    public init(text: String, size: Double, bold: Bool, italic: Bool, underline: Bool, strike: Bool,
                color: String?, font: String, spacing: Double, baseline: Double, highlight: String?) {
        self.text = text
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.color = color
        self.font = font
        self.spacing = spacing
        self.baseline = baseline
        self.highlight = highlight
    }
}

public struct TableRow {
    public var cells: [TableCell]

    public init(cells: [TableCell]) { self.cells = cells }
}

public struct TableCell {
    public var text: String
    /// The cell's runs, for the viewer; `text` is the plain form for speech.
    public var runs: [Run]
    public var fill: String?
    public var colSpan: Int
    public var rowSpan: Int
    /// Covered by a merge to the left / above: not rendered.
    public var covered: Bool
    public var align: String

    public init(text: String, runs: [Run], fill: String?, colSpan: Int, rowSpan: Int, covered: Bool, align: String) {
        self.text = text
        self.runs = runs
        self.fill = fill
        self.colSpan = colSpan
        self.rowSpan = rowSpan
        self.covered = covered
        self.align = align
    }
}

public enum SlideError: Error, CustomStringConvertible {
    case notADeck(String)
    case encrypted
    case read(String)

    public var description: String {
        switch self {
        case .notADeck(let why): return "not a slide deck: \(why)"
        case .encrypted: return "the deck is password-protected"
        case .read(let why): return "the deck could not be read: \(why)"
        }
    }
}
