import Foundation

/// Shared acceptance limits for portable ink, regardless of whether it arrives
/// from a notebook, clipboard, saved library or an editor transaction.
public enum InkGeometryLimits {
    public static let maximumCoordinate: Double = 100_000
    public static let maximumStrokeWidth: Double = 100
    public static let maximumStrokeCount = 10_000
    public static let maximumPointCount = 1_000_000
    /// Numeric path lengths can amplify a small archive into millions of dashes.
    /// Bound the entire page, not just each independently accepted stroke.
    public static let maximumPatternSegments = 100_000
    /// Matches the existing 100,000-point object positions plus 10,000 extents.
    /// Renderers must additionally limit work to their visible region.
    public static let maximumPageDimension: Double = 110_000

    public static func validate(_ strokes: [InkStroke]) throws {
        guard strokes.count <= maximumStrokeCount else { throw LibraryError.tooLarge }
        var pointCount = 0
        var patternBudget = maximumPatternSegments
        for stroke in strokes {
            guard !stroke.points.isEmpty,
                  stroke.width.isFinite, stroke.width > 0, stroke.width <= maximumStrokeWidth else {
                throw LibraryError.invalidData("A drawing contains an empty stroke or invalid nib width.")
            }
            // Subtract before adding so malformed counts cannot overflow.
            guard stroke.points.count <= maximumPointCount - pointCount else { throw LibraryError.tooLarge }
            pointCount += stroke.points.count
            guard stroke.points.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && abs($0.x) <= maximumCoordinate && abs($0.y) <= maximumCoordinate
                    && $0.pressure.isFinite && (0...1).contains($0.pressure)
            }) else {
                throw LibraryError.invalidData("A drawing contains invalid coordinates or pressure, or lies outside the supported page area.")
            }
            guard consumePatternBudget(for: stroke, remaining: &patternBudget) else {
                throw LibraryError.invalidData("Dashed or dotted ink exceeds the supported page rendering limit.")
            }
        }
    }

    /// Shared by acceptance and rendering. A cubic is no longer than its control
    /// polygon, including curves whose endpoints coincide. Each segment also
    /// pays for a partial dash, so short segments and phase restarts are bounded.
    /// The loop stops as soon as the remaining page budget is exhausted.
    public static func consumePatternBudget(for stroke: InkStroke, remaining: inout Int) -> Bool {
        guard (0...maximumPatternSegments).contains(remaining) else { return false }
        guard stroke.linePattern != .solid else { return true }
        guard !stroke.points.isEmpty, stroke.points.count <= maximumPointCount,
              stroke.width.isFinite, stroke.width > 0, stroke.width <= maximumStrokeWidth else { return false }
        func valid(_ point: InkPoint) -> Bool {
            point.x.isFinite && point.y.isFinite && abs(point.x) <= maximumCoordinate && abs(point.y) <= maximumCoordinate
        }
        guard let first = stroke.points.first, valid(first) else { return false }
        if stroke.points.count == 1 {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        // Pencil is the narrowest rendered tool (0.8 of its nominal nib).
        // Using its cycle also conservatively covers native nominal-width
        // segments and the wider Mac pen/marker/highlighter representations.
        let lengths = stroke.linePattern.dashLengths(width: max(0.5, stroke.width) * 0.8)
        let cycle = lengths[0] + lengths[1]
        for index in 1..<stroke.points.count {
            let p0 = stroke.points[max(0, index - 2)], p1 = stroke.points[index - 1]
            let p2 = stroke.points[index], p3 = stroke.points[min(stroke.points.count - 1, index + 1)]
            guard valid(p0), valid(p1), valid(p2), valid(p3) else { return false }
            let c1x = p1.x + (p2.x - p0.x) / 6, c1y = p1.y + (p2.y - p0.y) / 6
            let c2x = p2.x - (p3.x - p1.x) / 6, c2y = p2.y - (p3.y - p1.y) / 6
            let upperLength = hypot(c1x - p1.x, c1y - p1.y)
                + hypot(c2x - c1x, c2y - c1y) + hypot(p2.x - c2x, p2.y - c2y)
            let cost = ceil(upperLength / cycle) + 1
            guard cost.isFinite, cost <= Double(remaining) else { return false }
            remaining -= Int(cost)
        }
        return true
    }
}
