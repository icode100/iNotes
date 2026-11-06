import Foundation
import CoreGraphics

/// Editable vector objects. Coordinates and colors are canonical page values.
public struct PageDiagram: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case rectangle, roundedRectangle, ellipse, triangle, diamond, connector, table
    }
    public enum AnchorSide: String, Codable, CaseIterable, Sendable { case top, right, bottom, left }
    public enum ConnectorRoute: String, Codable, CaseIterable, Sendable { case straight, elbow }
    public enum ArrowHeads: String, Codable, CaseIterable, Sendable { case none, end, both }

    public var id: UUID
    public var kind: Kind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var colorHex: String
    public var lineWidth: Double
    public var linePattern: LinePattern
    public var fill: Bool
    public var text: String
    public var rows: Int
    public var columns: Int
    /// Row-major plain text, deliberately independent of native text archives.
    public var cells: [String]
    /// Fallback world coordinates remain useful when an attachment is detached.
    public var start: InkPoint
    public var end: InkPoint
    public var startAttachment: PageDiagramAttachment?
    public var endAttachment: PageDiagramAttachment?
    public var route: ConnectorRoute
    public var arrowHeads: ArrowHeads

    public init(id: UUID = UUID(), kind: Kind = .rectangle,
                x: Double = 40, y: Double = 40, width: Double = 240, height: Double = 140,
                colorHex: String = "#202020", lineWidth: Double = 2,
                linePattern: LinePattern = .solid, fill: Bool = false, text: String = "",
                rows: Int = 3, columns: Int = 3, cells: [String]? = nil,
                start: InkPoint = InkPoint(x: 40, y: 40), end: InkPoint = InkPoint(x: 280, y: 180),
                startAttachment: PageDiagramAttachment? = nil, endAttachment: PageDiagramAttachment? = nil,
                route: ConnectorRoute = .straight, arrowHeads: ArrowHeads = .end) {
        self.id = id; self.kind = kind; self.x = x; self.y = y
        self.width = width; self.height = height; self.colorHex = colorHex
        self.lineWidth = lineWidth; self.linePattern = linePattern; self.fill = fill; self.text = text
        self.rows = rows; self.columns = columns
        // Avoid multiplication/allocation for malformed programmatic dimensions.
        self.cells = cells ?? (kind == .table && (1...20).contains(rows) && (1...12).contains(columns)
            ? Array(repeating: "", count: rows * columns) : [])
        self.start = start; self.end = end
        self.startAttachment = startAttachment; self.endAttachment = endAttachment
        self.route = route; self.arrowHeads = arrowHeads
    }

    public var plainText: String {
        if kind == .table {
            guard rows > 0, columns > 0, rows <= 20, columns <= 12,
                  cells.count == rows * columns else { return text }
            let lines = (0..<rows).map { row in cells[(row * columns)..<((row + 1) * columns)].joined(separator: "\t") }
            return ([text] + lines).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return text
    }
}

public struct PageDiagramAttachment: Codable, Equatable, Sendable {
    public var targetDiagramID: UUID
    public var side: PageDiagram.AnchorSide
    public init(targetDiagramID: UUID, side: PageDiagram.AnchorSide) {
        self.targetDiagramID = targetDiagramID; self.side = side
    }
}

public enum PageDiagramLimits {
    public static let maximumObjects = 500
    public static let maximumRows = 20
    public static let maximumColumns = 12
    public static let maximumPageCells = 512
    public static let maximumCellBytes = 1_024
    public static let maximumLabelBytes = 4_096
    public static let maximumPageTextBytes = 1_024 * 1_024
    public static let maximumPatternSegments = 100_000

    public static func validate(_ diagrams: [PageDiagram]) throws {
        guard diagrams.count <= maximumObjects else { throw LibraryError.tooLarge }
        guard Set(diagrams.map(\.id)).count == diagrams.count else { throw LibraryError.duplicateID }
        let lookup = Dictionary(uniqueKeysWithValues: diagrams.map { ($0.id, $0) })
        var cellCount = 0, textBytes = 0, patternBudget = maximumPatternSegments
        for value in diagrams {
            guard coordinate(value.x), coordinate(value.y), value.width.isFinite, value.height.isFinite,
                  (1...10_000).contains(value.width), (1...10_000).contains(value.height),
                  value.lineWidth.isFinite, (0.5...100).contains(value.lineWidth),
                  validColor(value.colorHex), value.text.utf8.count <= maximumLabelBytes,
                  point(value.start), point(value.end) else {
                throw LibraryError.invalidData("A diagram has invalid coordinates, style, or text.")
            }
            textBytes += value.text.utf8.count
            if value.kind == .table {
                guard (1...maximumRows).contains(value.rows), (1...maximumColumns).contains(value.columns),
                      value.cells.count == value.rows * value.columns,
                      value.cells.count <= maximumPageCells - cellCount,
                      value.cells.allSatisfy({ $0.utf8.count <= maximumCellBytes }) else {
                    throw LibraryError.invalidData("A table exceeds its row, column, cell, or text limits.")
                }
                cellCount += value.cells.count
                for cell in value.cells { textBytes += cell.utf8.count }
            } else if !value.cells.isEmpty {
                throw LibraryError.invalidData("Only tables may contain cells.")
            }
            guard textBytes <= maximumPageTextBytes else { throw LibraryError.tooLarge }
            for attachment in [value.startAttachment, value.endAttachment].compactMap({ $0 }) {
                guard value.kind == .connector,
                      let target = lookup[attachment.targetDiagramID], target.kind != .connector else {
                    throw LibraryError.invalidData("A connector attachment must target a shape or table on its page.")
                }
            }
            if value.linePattern != .solid {
                let lengths = value.linePattern.dashLengths(width: value.lineWidth)
                let cycle = lengths[0] + lengths[1]
                let length: Double
                let paths: Int
                if value.kind == .connector {
                    let points = PageDiagramGeometry.connectorPoints(for: value, in: diagrams)
                    length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
                    paths = max(1, points.count - 1)
                } else if value.kind == .table {
                    length = Double(value.rows + 1) * value.width + Double(value.columns + 1) * value.height
                    paths = value.rows + value.columns + 2
                } else {
                    length = 2 * (value.width + value.height)
                    paths = 1
                }
                let cost = ceil(length / cycle) + Double(paths)
                guard cost.isFinite, cost <= Double(patternBudget) else {
                    throw LibraryError.invalidData("Patterned diagrams exceed the page rendering limit.")
                }
                patternBudget -= Int(cost)
            }
        }
    }

    private static func coordinate(_ value: Double) -> Bool { value.isFinite && (0...100_000).contains(value) }
    private static func point(_ value: InkPoint) -> Bool {
        value.x.isFinite && value.y.isFinite
            && (0...InkGeometryLimits.maximumPageDimension).contains(value.x)
            && (0...InkGeometryLimits.maximumPageDimension).contains(value.y)
            && value.pressure.isFinite && (0...1).contains(value.pressure)
    }
    private static func validColor(_ value: String) -> Bool {
        value.utf8.count == 7 && value.first == "#" && value.dropFirst().utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

/// One shared interpretation for native drawing, selection, copying and deletion.
public enum PageDiagramGeometry {
    public static func anchorPoint(on value: PageDiagram, side: PageDiagram.AnchorSide) -> InkPoint {
        switch side {
        case .top: return InkPoint(x: value.x + value.width / 2, y: value.y)
        case .right: return InkPoint(x: value.x + value.width * (value.kind == .triangle ? 0.75 : 1), y: value.y + value.height / 2)
        case .bottom: return InkPoint(x: value.x + value.width / 2, y: value.y + value.height)
        case .left: return InkPoint(x: value.x + (value.kind == .triangle ? value.width * 0.25 : 0), y: value.y + value.height / 2)
        }
    }

    public static func resolvedEndpoints(for value: PageDiagram, in diagrams: [PageDiagram]) -> (start: InkPoint, end: InkPoint) {
        func resolve(_ attachment: PageDiagramAttachment?, fallback: InkPoint) -> InkPoint {
            guard let attachment,
                  let target = diagrams.first(where: { $0.id == attachment.targetDiagramID && $0.kind != .connector }) else { return fallback }
            return anchorPoint(on: target, side: attachment.side)
        }
        return (resolve(value.startAttachment, fallback: value.start), resolve(value.endAttachment, fallback: value.end))
    }

    public static func connectorPoints(for value: PageDiagram, in diagrams: [PageDiagram]) -> [InkPoint] {
        let endpoints = resolvedEndpoints(for: value, in: diagrams)
        if value.route == .straight { return [endpoints.start, endpoints.end] }
        let middleX = (endpoints.start.x + endpoints.end.x) / 2
        return [endpoints.start, InkPoint(x: middleX, y: endpoints.start.y),
                InkPoint(x: middleX, y: endpoints.end.y), endpoints.end]
    }

    public static func bounds(of value: PageDiagram, in diagrams: [PageDiagram]) -> CGRect {
        if value.kind == .connector {
            let padding = value.arrowHeads == .none ? value.lineWidth / 2 : max(10, value.lineWidth * 3)
            return PageSelectionGeometry.bounds(of: connectorPoints(for: value, in: diagrams), padding: padding) ?? .zero
        }
        return CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    public static func hitTest(_ value: PageDiagram, at point: InkPoint, in diagrams: [PageDiagram], tolerance: Double = 5) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        if value.kind == .connector {
            let stroke = InkStroke(points: connectorPoints(for: value, in: diagrams), width: value.lineWidth)
            return PageSelectionGeometry.hits(stroke: stroke, at: point, tolerance: tolerance)
        }
        let rect = bounds(of: value, in: diagrams)
        guard rect.insetBy(dx: -max(0, tolerance), dy: -max(0, tolerance)).contains(CGPoint(x: point.x, y: point.y)) else { return false }
        switch value.kind {
        case .ellipse:
            let rx = value.width / 2 + max(0, tolerance), ry = value.height / 2 + max(0, tolerance)
            let dx = (point.x - rect.midX) / rx, dy = (point.y - rect.midY) / ry
            return dx * dx + dy * dy <= 1
        case .triangle:
            return PageSelectionGeometry.contains(point, polygon: [InkPoint(x: rect.midX, y: rect.minY),
                InkPoint(x: rect.maxX, y: rect.maxY), InkPoint(x: rect.minX, y: rect.maxY)])
        case .diamond:
            return PageSelectionGeometry.contains(point, polygon: [InkPoint(x: rect.midX, y: rect.minY),
                InkPoint(x: rect.maxX, y: rect.midY), InkPoint(x: rect.midX, y: rect.maxY), InkPoint(x: rect.minX, y: rect.midY)])
        default: return true
        }
    }

    public static func translated(_ value: PageDiagram, dx: Double, dy: Double) -> PageDiagram {
        guard dx.isFinite, dy.isFinite else { return value }
        var result = value
        if value.kind == .connector {
            result.start.x += dx; result.start.y += dy; result.end.x += dx; result.end.y += dy
        } else {
            result.x += dx; result.y += dy
        }
        return result
    }

    /// Move the selected objects as one transaction. Moving a connector without
    /// its target detaches that end; unselected connectors follow moved targets.
    public static func translated(_ diagrams: [PageDiagram], selectedIDs: Set<UUID>, dx: Double, dy: Double) -> [PageDiagram] {
        guard dx.isFinite, dy.isFinite else { return diagrams }
        return diagrams.map { value in
            guard selectedIDs.contains(value.id) else { return value }
            var result = value
            let endpoints = resolvedEndpoints(for: value, in: diagrams)
            result.start = endpoints.start; result.end = endpoints.end
            if let attachment = result.startAttachment, !selectedIDs.contains(attachment.targetDiagramID) { result.startAttachment = nil }
            if let attachment = result.endAttachment, !selectedIDs.contains(attachment.targetDiagramID) { result.endAttachment = nil }
            return translated(result, dx: dx, dy: dy)
        }
    }

    /// Deleting a target preserves surviving connector endpoints in world space.
    public static func removing(ids: Set<UUID>, from diagrams: [PageDiagram]) -> [PageDiagram] {
        diagrams.filter { !ids.contains($0.id) }.map { value in
            var result = value
            let endpoints = resolvedEndpoints(for: value, in: diagrams)
            if let attachment = value.startAttachment, ids.contains(attachment.targetDiagramID) {
                result.start = endpoints.start; result.startAttachment = nil
            }
            if let attachment = value.endAttachment, ids.contains(attachment.targetDiagramID) {
                result.end = endpoints.end; result.endAttachment = nil
            }
            return result
        }
    }

    /// Use a mapping containing only copied IDs. Attachments to omitted targets
    /// detach, while copied targets receive the same fresh IDs as their arrows.
    public static func remapped(_ diagrams: [PageDiagram], mapping: [UUID: UUID], dx: Double = 0, dy: Double = 0,
                                resolvingIn page: [PageDiagram] = []) -> [PageDiagram] {
        let source = page.isEmpty ? diagrams : page
        return diagrams.map { value in
            var result = value
            result.id = mapping[value.id] ?? value.id
            let endpoints = resolvedEndpoints(for: value, in: source)
            result.start = endpoints.start; result.end = endpoints.end
            if let attachment = value.startAttachment {
                result.startAttachment = mapping[attachment.targetDiagramID].map { PageDiagramAttachment(targetDiagramID: $0, side: attachment.side) }
            }
            if let attachment = value.endAttachment {
                result.endAttachment = mapping[attachment.targetDiagramID].map { PageDiagramAttachment(targetDiagramID: $0, side: attachment.side) }
            }
            return translated(result, dx: dx, dy: dy)
        }
    }
}
