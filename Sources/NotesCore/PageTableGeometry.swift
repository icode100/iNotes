import Foundation
import CoreGraphics

public enum PageTableAxis: Equatable, Sendable { case row, column }

/// Page-space table boundaries shared by previews, exports, editing and hit testing.
public enum PageTableGeometry {
    static func validFractions(_ sizes: [Double]?, count: Int) -> Bool {
        guard let sizes else { return true }
        // Even on a one-point table at the maximum page coordinate, adjacent
        // boundaries must remain distinct in double precision.
        return sizes.count == count && sizes.allSatisfy { $0.isFinite && (1e-8...1).contains($0) }
            && abs(sizes.reduce(0, +) - 1) <= 1e-12
    }

    public static func edges(in table: PageDiagram, axis: PageTableAxis) -> [Double] {
        let rows = axis == .row
        let count = rows ? table.rows : table.columns
        let maximum = rows ? PageDiagramLimits.maximumRows : PageDiagramLimits.maximumColumns
        let origin = rows ? table.y : table.x
        let extent = rows ? table.height : table.width
        let sizes = rows ? table.rowFractions : table.columnFractions
        guard table.kind == .table, (1...maximum).contains(count), validFractions(sizes, count: count),
              origin.isFinite, extent.isFinite, extent > 0, (origin + extent).isFinite else { return [] }
        guard let sizes else { return (0...count).map { origin + extent * Double($0) / Double(count) } }
        var edges = [origin], fraction = 0.0
        for size in sizes.dropLast() {
            fraction += size
            edges.append(origin + extent * fraction)
        }
        edges.append(origin + extent)
        return edges
    }

    public static func cellRect(_ index: Int, in table: PageDiagram) -> CGRect {
        let x = edges(in: table, axis: .column), y = edges(in: table, axis: .row)
        guard x.count >= 2, y.count >= 2, index >= 0, index < (x.count - 1) * (y.count - 1) else { return .zero }
        let row = index / table.columns, column = index % table.columns
        return CGRect(x: x[column], y: y[row], width: x[column + 1] - x[column], height: y[row + 1] - y[row])
    }

    public static func cellIndex(at point: InkPoint, in table: PageDiagram) -> Int? {
        func containing(_ edges: [Double], coordinate: Double) -> Int? {
            guard let first = edges.first, let last = edges.last, coordinate >= first, coordinate <= last else { return nil }
            return edges.firstIndex(where: { $0 > coordinate }).map { $0 - 1 } ?? edges.count - 2
        }
        guard let row = containing(edges(in: table, axis: .row), coordinate: point.y),
              let column = containing(edges(in: table, axis: .column), coordinate: point.x) else { return nil }
        return row * table.columns + column
    }

    /// Move an interior boundary against its original snapshot. Its two
    /// neighboring cells share the same span throughout the gesture.
    public static func movingDivider(_ table: PageDiagram, index: Int, on axis: PageTableAxis, to coordinate: Double) -> PageDiagram {
        let edges = edges(in: table, axis: axis)
        guard coordinate.isFinite, index > 0, index < edges.count - 1 else { return table }
        let before = edges[index - 1], current = edges[index], after = edges[index + 1]
        // Keep ordinary cells usable, while still permitting edits in compact
        // legacy tables and preserving any already narrower neighbor.
        let minimum = min(16, (after - before) / 4)
        let low = before + min(minimum, current - before)
        let high = after - min(minimum, after - current)
        let position = min(high, max(low, coordinate))
        guard abs(position - current) > 1e-9 else { return table }
        let count = edges.count - 1
        let equalSize = 1 / Double(count)
        let stored = axis == .row ? table.rowFractions : table.columnFractions
        var sizes = stored ?? [Double](repeating: equalSize, count: count)
        let delta = (position - current) / (axis == .row ? table.height : table.width)
        sizes[index - 1] += delta
        sizes[index] -= delta
        guard validFractions(sizes, count: count) else { return table }
        let custom: [Double]? = sizes.allSatisfy { abs($0 - equalSize) <= 1e-12 } ? nil : sizes
        var result = table
        if axis == .row { result.rowFractions = custom } else { result.columnFractions = custom }
        return result
    }
}
