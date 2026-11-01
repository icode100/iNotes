import Foundation

/// Shared acceptance limits for portable ink, regardless of whether it arrives
/// from a notebook, clipboard, saved library or an editor transaction.
public enum InkGeometryLimits {
    public static let maximumCoordinate: Double = 100_000
    public static let maximumStrokeWidth: Double = 100
    public static let maximumStrokeCount = 10_000
    public static let maximumPointCount = 1_000_000
    /// Matches the existing 100,000-point object positions plus 10,000 extents.
    /// Renderers must additionally limit work to their visible region.
    public static let maximumPageDimension: Double = 110_000

    public static func validate(_ strokes: [InkStroke]) throws {
        guard strokes.count <= maximumStrokeCount else { throw LibraryError.tooLarge }
        var pointCount = 0
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
        }
    }
}
