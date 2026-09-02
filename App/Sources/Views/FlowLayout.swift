import SwiftUI

/// Minimal flow layout for the preview's inline-runs view. SwiftUI's Text
/// can carry a mix of styled spans, but mixing text + AsyncImage in a
/// single line requires manual layout. FlowLayout wraps children
/// left-to-right with wrapping when they exceed the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let positions = arrange(subviews: subviews, in: maxWidth)
        let height = positions.last.map { $0.maxY } ?? 0
        return CGSize(width: maxWidth.isFinite ? maxWidth : positions.map(\.maxX).max() ?? 0,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews: subviews, in: bounds.width)
        for (index, point) in positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: point.width, height: point.height))
        }
    }

    private struct Position {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var maxX: CGFloat { x + width }
        var maxY: CGFloat { y + height }
    }

    private func arrange(subviews: Subviews, in maxWidth: CGFloat) -> [Position] {
        var positions: [Position] = []
        var rowX: CGFloat = 0
        var rowY: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowX + size.width > maxWidth, rowX > 0 {
                rowX = 0
                rowY += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(Position(x: rowX, y: rowY, width: size.width, height: size.height))
            rowX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return positions
    }
}
