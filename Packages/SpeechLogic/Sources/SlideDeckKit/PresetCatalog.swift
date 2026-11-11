// PresetCatalog.swift — the preset shape catalog and the geometry value types.
//
// Ported from DeckCraft's geom crate `preset.rs` (github.com/storytold/deckcraft
// @ a0eeb34, MIT/Apache-2.0): `FillMode`, `SubPath`, `Geometry`, `CATALOG`,
// `info`, `mitred_by_default`, `is_line_like`. The gallery `Category` enum is
// editor UI and is dropped; `Handle` (the draggable adjust handles) and the
// connector glue `sites` are editor-only too and are not ported — the read
// path consumes `paths`, `text_rect`, `outline()` and `is_open` only.

/// How a sub-path is filled. `Lighten`/`Darken` variants shade the shape's fill (3-D looking faces).
public enum FillMode: String, Equatable, Sendable {
    case norm
    case none
    case lighten
    case lightenLess
    case darken
    case darkenLess
}

/// One sub-path of a preset outline.
public struct SubPath: Sendable {
    public var path: GeomPath
    public var fill: FillMode
    public var stroke: Bool
    /// Even-odd fill (holes in donuts and frames).
    public var evenOdd: Bool

    public init(path: GeomPath, fill: FillMode, stroke: Bool, evenOdd: Bool) {
        self.path = path
        self.fill = fill
        self.stroke = stroke
        self.evenOdd = evenOdd
    }
}

/// The generated geometry of a preset shape: filled/stroked sub-paths plus where text goes.
public struct Geometry: Sendable {
    public var paths: [SubPath]
    /// Where text goes, in shape-local space.
    public var textRect: DRect

    public init(paths: [SubPath], textRect: DRect) {
        self.paths = paths
        self.textRect = textRect
    }

    /// The union outline used for hit testing and rendering (all sub-paths concatenated).
    public func outline() -> GeomPath {
        var p = GeomPath()
        for s in paths {
            p.extend(s.path)
        }
        return p
    }

    /// Whether nothing is filled (lines, connectors, arcs, brackets).
    public var isOpen: Bool {
        paths.allSatisfy { $0.fill == .none }
    }
}

/// Catalog entry: the OOXML name, a display label, and the default adjust values.
public struct PresetInfo: Sendable {
    public let name: String
    public let label: String
    /// Default adjust values.
    public let defaults: [Double]
}

/// Every preset we generate, in gallery order.
public let CATALOG: [PresetInfo] = [
    PresetInfo(name: "line", label: "Line", defaults: []),
    PresetInfo(name: "straightConnector1", label: "Arrow", defaults: []),
    PresetInfo(name: "bentConnector3", label: "Connector: Elbow", defaults: [50000]),
    PresetInfo(name: "curvedConnector3", label: "Connector: Curved", defaults: [50000]),
    PresetInfo(name: "bentConnector2", label: "Connector: Elbow (one bend)", defaults: []),
    PresetInfo(name: "lineInv", label: "Line: Rising", defaults: []),
    PresetInfo(name: "rect", label: "Rectangle", defaults: []),
    PresetInfo(name: "roundRect", label: "Rectangle: Rounded Corners", defaults: [16667]),
    PresetInfo(name: "snip1Rect", label: "Rectangle: Single Corner Snipped", defaults: [16667]),
    PresetInfo(name: "snip2SameRect", label: "Rectangle: Top Corners Snipped", defaults: [16667, 0]),
    PresetInfo(name: "snip2DiagRect", label: "Rectangle: Diagonal Corners Snipped", defaults: [0, 16667]),
    PresetInfo(name: "snipRoundRect", label: "Rectangle: Top Corners One Rounded and One Snipped", defaults: [16667, 16667]),
    PresetInfo(name: "round1Rect", label: "Rectangle: Single Corner Rounded", defaults: [16667]),
    PresetInfo(name: "round2SameRect", label: "Rectangle: Top Corners Rounded", defaults: [16667, 0]),
    PresetInfo(name: "round2DiagRect", label: "Rectangle: Diagonal Corners Rounded", defaults: [16667, 0]),
    PresetInfo(name: "textBox", label: "Text Box", defaults: []),
    PresetInfo(name: "ellipse", label: "Oval", defaults: []),
    PresetInfo(name: "triangle", label: "Isosceles Triangle", defaults: [50000]),
    PresetInfo(name: "rtTriangle", label: "Right Triangle", defaults: []),
    PresetInfo(name: "parallelogram", label: "Parallelogram", defaults: [25000]),
    PresetInfo(name: "trapezoid", label: "Trapezoid", defaults: [25000]),
    PresetInfo(name: "nonIsoscelesTrapezoid", label: "Trapezoid: Uneven Sides", defaults: [25000, 25000]),
    PresetInfo(name: "diamond", label: "Diamond", defaults: []),
    PresetInfo(name: "pentagon", label: "Regular Pentagon", defaults: []),
    PresetInfo(name: "hexagon", label: "Hexagon", defaults: [25000]),
    PresetInfo(name: "heptagon", label: "Heptagon", defaults: []),
    PresetInfo(name: "octagon", label: "Octagon", defaults: [29289]),
    PresetInfo(name: "decagon", label: "Decagon", defaults: []),
    PresetInfo(name: "dodecagon", label: "Dodecagon", defaults: []),
    PresetInfo(name: "pie", label: "Partial Circle", defaults: [0, 16200000]),
    PresetInfo(name: "pieWedge", label: "Quarter Wedge", defaults: []),
    PresetInfo(name: "chord", label: "Chord", defaults: [2700000, 16200000]),
    PresetInfo(name: "teardrop", label: "Teardrop", defaults: [100000]),
    PresetInfo(name: "frame", label: "Frame", defaults: [12500]),
    PresetInfo(name: "cornerTabs", label: "Corner Tabs: Triangles", defaults: []),
    PresetInfo(name: "squareTabs", label: "Corner Tabs: Squares", defaults: []),
    PresetInfo(name: "plaqueTabs", label: "Corner Tabs: Quarter Circles", defaults: []),
    PresetInfo(name: "halfFrame", label: "Half Frame", defaults: [33333, 33333]),
    PresetInfo(name: "corner", label: "L-Shape", defaults: [50000, 50000]),
    PresetInfo(name: "diagStripe", label: "Diagonal Stripe", defaults: [50000]),
    PresetInfo(name: "plus", label: "Cross", defaults: [25000]),
    PresetInfo(name: "plaque", label: "Plaque", defaults: [16667]),
    PresetInfo(name: "can", label: "Cylinder", defaults: [25000]),
    PresetInfo(name: "cube", label: "Cube", defaults: [25000]),
    PresetInfo(name: "bevel", label: "Bevel", defaults: [12500]),
    PresetInfo(name: "donut", label: "Donut", defaults: [25000]),
    PresetInfo(name: "noSmoking", label: "\"Not Allowed\" Symbol", defaults: [18750]),
    PresetInfo(name: "blockArc", label: "Block Arc", defaults: [10800000, 0, 25000]),
    PresetInfo(name: "foldedCorner", label: "Folded Corner", defaults: [16667]),
    PresetInfo(name: "smileyFace", label: "Smiley Face", defaults: [4653]),
    PresetInfo(name: "heart", label: "Heart", defaults: []),
    PresetInfo(name: "lightningBolt", label: "Lightning Bolt", defaults: []),
    PresetInfo(name: "sun", label: "Sun", defaults: [25000]),
    PresetInfo(name: "moon", label: "Moon", defaults: [50000]),
    PresetInfo(name: "cloud", label: "Cloud", defaults: []),
    PresetInfo(name: "gear6", label: "Gear: 6 Teeth", defaults: [15000, 3526]),
    PresetInfo(name: "gear9", label: "Gear: 9 Teeth", defaults: [10000, 1763]),
    PresetInfo(name: "funnel", label: "Funnel", defaults: []),
    PresetInfo(name: "arc", label: "Arc", defaults: [16200000, 0]),
    PresetInfo(name: "bracketPair", label: "Double Bracket", defaults: [16667]),
    PresetInfo(name: "bracePair", label: "Double Brace", defaults: [8333]),
    PresetInfo(name: "leftBracket", label: "Left Bracket", defaults: [8333]),
    PresetInfo(name: "rightBracket", label: "Right Bracket", defaults: [8333]),
    PresetInfo(name: "leftBrace", label: "Left Brace", defaults: [8333, 50000]),
    PresetInfo(name: "rightBrace", label: "Right Brace", defaults: [8333, 50000]),
    PresetInfo(name: "chartX", label: "Chart Marker: Cross Lines", defaults: []),
    PresetInfo(name: "chartStar", label: "Chart Marker: Star Lines", defaults: []),
    PresetInfo(name: "chartPlus", label: "Chart Marker: Plus Lines", defaults: []),
    PresetInfo(name: "rightArrow", label: "Arrow: Right", defaults: [50000, 50000]),
    PresetInfo(name: "leftArrow", label: "Arrow: Left", defaults: [50000, 50000]),
    PresetInfo(name: "upArrow", label: "Arrow: Up", defaults: [50000, 50000]),
    PresetInfo(name: "downArrow", label: "Arrow: Down", defaults: [50000, 50000]),
    PresetInfo(name: "leftRightArrow", label: "Arrow: Left-Right", defaults: [50000, 50000]),
    PresetInfo(name: "upDownArrow", label: "Arrow: Up-Down", defaults: [50000, 50000]),
    PresetInfo(name: "quadArrow", label: "Arrow: Quad", defaults: [22500, 22500, 22500]),
    PresetInfo(name: "leftRightUpArrow", label: "Arrow: Left-Right-Up", defaults: [25000, 25000, 25000]),
    PresetInfo(name: "bentArrow", label: "Arrow: Bent", defaults: [25000, 25000, 25000, 43750]),
    PresetInfo(name: "uturnArrow", label: "Arrow: U-Turn", defaults: [25000, 25000, 25000, 43750, 75000]),
    PresetInfo(name: "curvedRightArrow", label: "Arrow: Curved Right", defaults: [25000, 50000, 25000]),
    PresetInfo(name: "curvedLeftArrow", label: "Arrow: Curved Left", defaults: [25000, 50000, 25000]),
    PresetInfo(name: "curvedUpArrow", label: "Arrow: Curved Up", defaults: [25000, 50000, 25000]),
    PresetInfo(name: "curvedDownArrow", label: "Arrow: Curved Down", defaults: [25000, 50000, 25000]),
    PresetInfo(name: "leftUpArrow", label: "Arrow: Left-Up", defaults: [25000, 25000, 25000]),
    PresetInfo(name: "bentUpArrow", label: "Arrow: Bent-Up", defaults: [25000, 25000, 25000]),
    PresetInfo(name: "stripedRightArrow", label: "Arrow: Striped Right", defaults: [50000, 50000]),
    PresetInfo(name: "notchedRightArrow", label: "Arrow: Notched Right", defaults: [50000, 50000]),
    PresetInfo(name: "homePlate", label: "Arrow: Pentagon", defaults: [50000]),
    PresetInfo(name: "chevron", label: "Arrow: Chevron", defaults: [50000]),
    PresetInfo(name: "circularArrow", label: "Arrow: Circular", defaults: [12500, 1142319, 20457681, 10800000, 12500]),
    PresetInfo(name: "leftCircularArrow", label: "Arrow: Circular Counter-clockwise", defaults: [12500, -1142319, 1142319, 10800000, 12500]),
    PresetInfo(name: "leftRightCircularArrow", label: "Arrow: Circular Two-headed", defaults: [12500, 1142319, 20457681, 11942319, 12500]),
    PresetInfo(name: "swooshArrow", label: "Arrow: Swoosh", defaults: [25000, 16667]),
    PresetInfo(name: "rightArrowCallout", label: "Callout: Right Arrow", defaults: [25000, 25000, 25000, 64977]),
    PresetInfo(name: "downArrowCallout", label: "Callout: Down Arrow", defaults: [25000, 25000, 25000, 64977]),
    PresetInfo(name: "leftArrowCallout", label: "Callout: Left Arrow", defaults: [25000, 25000, 25000, 64977]),
    PresetInfo(name: "upArrowCallout", label: "Callout: Up Arrow", defaults: [25000, 25000, 25000, 64977]),
    PresetInfo(name: "leftRightArrowCallout", label: "Callout: Left-Right Arrow", defaults: [25000, 25000, 25000, 48123]),
    PresetInfo(name: "upDownArrowCallout", label: "Callout: Up-Down Arrow", defaults: [25000, 25000, 25000, 48123]),
    PresetInfo(name: "quadArrowCallout", label: "Callout: Quad Arrow", defaults: [18515, 18515, 18515, 48123]),
    PresetInfo(name: "mathPlus", label: "Plus Sign", defaults: [23520]),
    PresetInfo(name: "mathMinus", label: "Minus Sign", defaults: [23520]),
    PresetInfo(name: "mathMultiply", label: "Multiplication Sign", defaults: [23520]),
    PresetInfo(name: "mathDivide", label: "Division Sign", defaults: [23520, 5880, 11760]),
    PresetInfo(name: "mathEqual", label: "Equals", defaults: [23520, 11760]),
    PresetInfo(name: "mathNotEqual", label: "Not Equal", defaults: [23520, 6600000, 11760]),
    PresetInfo(name: "flowChartProcess", label: "Flowchart: Process", defaults: []),
    PresetInfo(name: "flowChartAlternateProcess", label: "Flowchart: Alternate Process", defaults: []),
    PresetInfo(name: "flowChartDecision", label: "Flowchart: Decision", defaults: []),
    PresetInfo(name: "flowChartInputOutput", label: "Flowchart: Data", defaults: []),
    PresetInfo(name: "flowChartPredefinedProcess", label: "Flowchart: Predefined Process", defaults: []),
    PresetInfo(name: "flowChartInternalStorage", label: "Flowchart: Internal Storage", defaults: []),
    PresetInfo(name: "flowChartDocument", label: "Flowchart: Document", defaults: []),
    PresetInfo(name: "flowChartMultidocument", label: "Flowchart: Multidocument", defaults: []),
    PresetInfo(name: "flowChartTerminator", label: "Flowchart: Terminator", defaults: []),
    PresetInfo(name: "flowChartPreparation", label: "Flowchart: Preparation", defaults: []),
    PresetInfo(name: "flowChartManualInput", label: "Flowchart: Manual Input", defaults: []),
    PresetInfo(name: "flowChartManualOperation", label: "Flowchart: Manual Operation", defaults: []),
    PresetInfo(name: "flowChartConnector", label: "Flowchart: Connector", defaults: []),
    PresetInfo(name: "flowChartOffpageConnector", label: "Flowchart: Off-page Connector", defaults: []),
    PresetInfo(name: "flowChartPunchedCard", label: "Flowchart: Card", defaults: []),
    PresetInfo(name: "flowChartPunchedTape", label: "Flowchart: Punched Tape", defaults: []),
    PresetInfo(name: "flowChartSummingJunction", label: "Flowchart: Summing Junction", defaults: []),
    PresetInfo(name: "flowChartOr", label: "Flowchart: Or", defaults: []),
    PresetInfo(name: "flowChartCollate", label: "Flowchart: Collate", defaults: []),
    PresetInfo(name: "flowChartSort", label: "Flowchart: Sort", defaults: []),
    PresetInfo(name: "flowChartExtract", label: "Flowchart: Extract", defaults: []),
    PresetInfo(name: "flowChartMerge", label: "Flowchart: Merge", defaults: []),
    PresetInfo(name: "flowChartOnlineStorage", label: "Flowchart: Stored Data", defaults: []),
    PresetInfo(name: "flowChartDelay", label: "Flowchart: Delay", defaults: []),
    PresetInfo(name: "flowChartMagneticTape", label: "Flowchart: Sequential Access Storage", defaults: []),
    PresetInfo(name: "flowChartMagneticDisk", label: "Flowchart: Magnetic Disk", defaults: []),
    PresetInfo(name: "flowChartMagneticDrum", label: "Flowchart: Direct Access Storage", defaults: []),
    PresetInfo(name: "flowChartDisplay", label: "Flowchart: Display", defaults: []),
    PresetInfo(name: "flowChartOfflineStorage", label: "Flowchart: Offline Storage", defaults: []),
    PresetInfo(name: "irregularSeal1", label: "Explosion: 8 Points", defaults: []),
    PresetInfo(name: "irregularSeal2", label: "Explosion: 14 Points", defaults: []),
    PresetInfo(name: "star4", label: "Star: 4 Points", defaults: [12500]),
    PresetInfo(name: "star5", label: "Star: 5 Points", defaults: [19098]),
    PresetInfo(name: "star6", label: "Star: 6 Points", defaults: [28868]),
    PresetInfo(name: "star7", label: "Star: 7 Points", defaults: [34601]),
    PresetInfo(name: "star8", label: "Star: 8 Points", defaults: [37500]),
    PresetInfo(name: "star10", label: "Star: 10 Points", defaults: [42533]),
    PresetInfo(name: "star12", label: "Star: 12 Points", defaults: [37500]),
    PresetInfo(name: "star16", label: "Star: 16 Points", defaults: [37500]),
    PresetInfo(name: "star24", label: "Star: 24 Points", defaults: [37500]),
    PresetInfo(name: "star32", label: "Star: 32 Points", defaults: [37500]),
    PresetInfo(name: "ribbon2", label: "Ribbon: Tilted Up", defaults: [16667, 50000]),
    PresetInfo(name: "ribbon", label: "Ribbon: Tilted Down", defaults: [16667, 50000]),
    PresetInfo(name: "ellipseRibbon2", label: "Ribbon: Curved and Tilted Up", defaults: [25000, 50000, 12500]),
    PresetInfo(name: "ellipseRibbon", label: "Ribbon: Curved and Tilted Down", defaults: [25000, 50000, 12500]),
    PresetInfo(name: "leftRightRibbon", label: "Ribbon: Left-Right Fold", defaults: [50000, 50000, 16667]),
    PresetInfo(name: "verticalScroll", label: "Scroll: Vertical", defaults: [12500]),
    PresetInfo(name: "horizontalScroll", label: "Scroll: Horizontal", defaults: [12500]),
    PresetInfo(name: "wave", label: "Wave", defaults: [12500, 0]),
    PresetInfo(name: "doubleWave", label: "Double Wave", defaults: [6250, 0]),
    PresetInfo(name: "wedgeRectCallout", label: "Speech Bubble: Rectangle", defaults: [-20833, 62500]),
    PresetInfo(name: "wedgeRoundRectCallout", label: "Speech Bubble: Rectangle with Corners Rounded", defaults: [-20833, 62500, 16667]),
    PresetInfo(name: "wedgeEllipseCallout", label: "Speech Bubble: Oval", defaults: [-20833, 62500]),
    PresetInfo(name: "cloudCallout", label: "Thought Bubble: Cloud", defaults: [-20833, 62500]),
    PresetInfo(name: "borderCallout1", label: "Callout: Line", defaults: [18750, -8333, 112500, -38333]),
    PresetInfo(name: "borderCallout2", label: "Callout: Bent Line", defaults: [18750, -8333, 18750, -16667, 112500, -46667]),
    PresetInfo(name: "borderCallout3", label: "Callout: Double Bent Line", defaults: [18750, -8333, 18750, -16667, 100000, -16667, 112963, -8333]),
    PresetInfo(name: "accentCallout1", label: "Callout: Line with Accent Bar", defaults: [18750, -8333, 112500, -38333]),
    PresetInfo(name: "accentCallout2", label: "Callout: Bent Line with Accent Bar", defaults: [18750, -8333, 18750, -16667, 112500, -46667]),
    PresetInfo(name: "accentCallout3", label: "Callout: Double Bent Line with Accent Bar", defaults: [18750, -8333, 18750, -16667, 100000, -16667, 112963, -8333]),
    PresetInfo(name: "callout1", label: "Callout: Line with No Border", defaults: [18750, -8333, 112500, -38333]),
    PresetInfo(name: "callout2", label: "Callout: Bent Line with No Border", defaults: [18750, -8333, 18750, -16667, 112500, -46667]),
    PresetInfo(name: "callout3", label: "Callout: Double Bent Line with No Border", defaults: [18750, -8333, 18750, -16667, 100000, -16667, 112963, -8333]),
    PresetInfo(name: "accentBorderCallout1", label: "Callout: Line with Border and Accent Bar", defaults: [18750, -8333, 112500, -38333]),
    PresetInfo(name: "accentBorderCallout2", label: "Callout: Bent Line with Border and Accent Bar", defaults: [18750, -8333, 18750, -16667, 112500, -46667]),
    PresetInfo(name: "accentBorderCallout3", label: "Callout: Double Bent Line with Border and Accent Bar",
                defaults: [18750, -8333, 18750, -16667, 100000, -16667, 112963, -8333]),
    PresetInfo(name: "actionButtonBackPrevious", label: "Action Button: Go Back or Previous", defaults: []),
    PresetInfo(name: "actionButtonForwardNext", label: "Action Button: Go Forward or Next", defaults: []),
    PresetInfo(name: "actionButtonBeginning", label: "Action Button: Go to Beginning", defaults: []),
    PresetInfo(name: "actionButtonEnd", label: "Action Button: Go to End", defaults: []),
    PresetInfo(name: "actionButtonHome", label: "Action Button: Go Home", defaults: []),
    PresetInfo(name: "actionButtonInformation", label: "Action Button: Get Information", defaults: []),
    PresetInfo(name: "actionButtonReturn", label: "Action Button: Go Back", defaults: []),
    PresetInfo(name: "actionButtonMovie", label: "Action Button: Video", defaults: []),
    PresetInfo(name: "actionButtonDocument", label: "Action Button: Document", defaults: []),
    PresetInfo(name: "actionButtonSound", label: "Action Button: Sound", defaults: []),
    PresetInfo(name: "actionButtonHelp", label: "Action Button: Help", defaults: []),
    PresetInfo(name: "actionButtonBlank", label: "Action Button: Custom", defaults: []),
]

/// The catalog entry for `name`, or nil.
public func presetInfo(_ name: String) -> PresetInfo? {
    CATALOG.first { $0.name == name }
}

/// Whether PowerPoint joins this preset's outline with sharp (miter) corners when the line names
/// no join (it rounds them otherwise). Observed per preset on its export: the plus, the right,
/// up and down block arrows (not the left one), chevrons, stars from five points up, the
/// equation shapes, curved ribbons and the action buttons are mitred.
public func mitredByDefault(_ name: String) -> Bool {
    switch name {
    case "plus", "rightArrow", "upArrow", "downArrow", "upDownArrow", "leftUpArrow", "bentUpArrow",
         "stripedRightArrow", "notchedRightArrow", "chevron", "leftArrowCallout", "leftRightArrowCallout",
         "upDownArrowCallout", "quadArrowCallout", "mathPlus", "mathMinus", "mathMultiply", "mathEqual",
         "mathNotEqual", "star5", "star6", "star8", "star10", "star12", "star16", "star24", "star32",
         "ellipseRibbon", "ellipseRibbon2":
        return true
    default:
        return name.hasPrefix("actionButton")
    }
}

public func isLineLike(_ name: String) -> Bool {
    switch name {
    case "line", "straightConnector1", "bentConnector2", "bentConnector3", "curvedConnector3", "arc":
        return true
    default:
        return name.hasPrefix("bentConnector") || name.hasPrefix("curvedConnector")
    }
}
