import SwiftUI

/// Base spacing values for the reading surfaces (markdown preview +
/// read-along reader), in points, BEFORE the user's multipliers.
///
/// These are the v1.6.3 defaults — deliberately roomier than the hardcoded
/// values they replace (paragraph line 4→6, block gap 14→16, table row 6→10,
/// table cell padding 8→11, heading bottom 6→9, list row 6→9) because the
/// reader read as crowded. The multipliers in AppTheme
/// (`readerLineSpacing`, `readerBlockSpacing`, `readerTableSpacing`) scale
/// these from Appearance settings, so nothing here is a final answer — it is
/// the 1.0× position of a slider the user owns.
///
/// Pure constants so both readers (and any future one) agree on the scale.
enum ReaderSpacing {

    /// Line spacing inside a paragraph.
    static let paragraphLine: CGFloat = 6
    /// Line spacing inside a blockquote (a touch tighter than paragraphs).
    static let quoteLine: CGFloat = 5

    /// Vertical gap between blocks: paragraphs, quotes, code, images, tables.
    static let blockGap: CGFloat = 16
    /// Gap between list rows.
    static let listRow: CGFloat = 9
    /// Clearance under a heading.
    static let headingBottom: CGFloat = 9
    /// Clearance ABOVE a heading (keeps a heading with its section).
    static let headingTopLevel1: CGFloat = 20
    static let headingTopLevel3Plus: CGFloat = 16

    /// Vertical gap between table rows.
    static let tableRow: CGFloat = 10
    /// Padding inside each table cell.
    static let tableCell: CGFloat = 11

    /// Read-along reader's per-paragraph row spacing (its paragraphs are the
    /// spoken text, so it matches the preview's block gap).
    static let readAlongRow: CGFloat = 18
}
