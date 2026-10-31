import Foundation
import CoreGraphics

/// Geometry shared by the AppKit and PencilKit selection surfaces. Paths use
/// page coordinates, so zooming never changes what a lasso selects.
public enum PageSelectionGeometry {
    public static func rectangle(from start: InkPoint, to end: InkPoint) -> [InkPoint] {
        [InkPoint(x: start.x, y: start.y), InkPoint(x: end.x, y: start.y),
         InkPoint(x: end.x, y: end.y), InkPoint(x: start.x, y: end.y)]
    }

    public static func bounds(of points: [InkPoint], padding: Double = 0) -> CGRect? {
        let valid = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = valid.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in valid.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let inset = padding.isFinite ? max(0, padding) : 0
        return CGRect(x: minX - inset, y: minY - inset,
                      width: maxX - minX + inset * 2, height: maxY - minY + inset * 2)
    }

    public static func contains(_ point: InkPoint, polygon: [InkPoint]) -> Bool {
        guard valid(polygon), point.x.isFinite, point.y.isFinite else { return false }
        var inside = false
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if distance(point, to: a, b) <= 0.0001 { return true }
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
        }
        return inside
    }

    public static func intersects(rect: CGRect, polygon: [InkPoint]) -> Bool {
        guard valid(polygon), rect.isFiniteSelectionRect else { return false }
        let corners = rectangle(from: InkPoint(x: rect.minX, y: rect.minY),
                                to: InkPoint(x: rect.maxX, y: rect.maxY))
        if corners.contains(where: { contains($0, polygon: polygon) }) { return true }
        if polygon.contains(where: { rect.insetBy(dx: -0.001, dy: -0.001).contains(CGPoint(x: $0.x, y: $0.y)) }) { return true }
        return corners.indices.contains { index in
            let a = corners[index], b = corners[(index + 1) % corners.count]
            return edges(polygon).contains { intersects(a, b, $0.0, $0.1) }
        }
    }

    public static func intersects(stroke: InkStroke, polygon: [InkPoint]) -> Bool {
        guard valid(polygon), let region = bounds(of: polygon),
              let pathBounds = bounds(of: stroke.points, padding: radius(stroke)),
              pathBounds.intersects(region) else { return false }
        let points = stroke.points.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = points.first else { return false }
        let tolerance = radius(stroke)
        if points.count == 1 { return contains(first, polygon: polygon) || edges(polygon).contains { distance(first, to: $0.0, $0.1) <= tolerance } }
        let boundary = edges(polygon)
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            guard let segmentBounds = bounds(of: [a, b], padding: tolerance), segmentBounds.intersects(region) else { continue }
            if contains(a, polygon: polygon) || contains(b, polygon: polygon) { return true }
            if boundary.contains(where: { edge in
                intersects(a, b, edge.0, edge.1)
                    || distance(a, to: edge.0, edge.1) <= tolerance
                    || distance(b, to: edge.0, edge.1) <= tolerance
                    || distance(edge.0, to: a, b) <= tolerance
                    || distance(edge.1, to: a, b) <= tolerance
            }) { return true }
        }
        return false
    }

    public static func hits(stroke: InkStroke, at point: InkPoint, tolerance: Double = 5) -> Bool {
        let points = stroke.points.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = points.first, point.x.isFinite, point.y.isFinite else { return false }
        let radius = radius(stroke) + max(0, tolerance)
        if points.count == 1 { return hypot(first.x - point.x, first.y - point.y) <= radius }
        return (1..<points.count).contains { distance(point, to: points[$0 - 1], points[$0]) <= radius }
    }

    public static func translated(_ stroke: InkStroke, dx: Double, dy: Double) -> InkStroke {
        guard dx.isFinite, dy.isFinite else { return stroke }
        var result = stroke
        result.points = stroke.points.map { InkPoint(x: $0.x + dx, y: $0.y + dy, pressure: $0.pressure) }
        return result
    }

    private static func radius(_ stroke: InkStroke) -> Double {
        let multiplier: Double = stroke.style == .highlighter ? 4 : stroke.style == .marker ? 1.8 : stroke.style == .pencil ? 0.8 : 1
        return max(0.5, min(100, stroke.width.isFinite ? stroke.width : 2.5)) * multiplier / 2
    }

    private static func valid(_ polygon: [InkPoint]) -> Bool {
        polygon.count >= 3 && polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    private static func edges(_ polygon: [InkPoint]) -> [(InkPoint, InkPoint)] {
        polygon.indices.map { (polygon[$0], polygon[($0 + 1) % polygon.count]) }
    }

    private static func distance(_ point: InkPoint, to a: InkPoint, _ b: InkPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
    }

    private static func intersects(_ a: InkPoint, _ b: InkPoint, _ c: InkPoint, _ d: InkPoint) -> Bool {
        func cross(_ a: InkPoint, _ b: InkPoint, _ c: InkPoint) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if ((abC > 0 && abD < 0) || (abC < 0 && abD > 0)) && ((cdA > 0 && cdB < 0) || (cdA < 0 && cdB > 0)) { return true }
        return (abs(abC) < 0.0001 && distance(c, to: a, b) < 0.0001)
            || (abs(abD) < 0.0001 && distance(d, to: a, b) < 0.0001)
            || (abs(cdA) < 0.0001 && distance(a, to: c, d) < 0.0001)
            || (abs(cdB) < 0.0001 && distance(b, to: c, d) < 0.0001)
    }
}

private extension CGRect {
    var isFiniteSelectionRect: Bool {
        !isNull && !isInfinite && [minX, minY, width, height].allSatisfy(\.isFinite)
    }
}
