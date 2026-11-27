import Foundation
import CoreGraphics

/// A persisted custom axis has at most twenty entries. Bound decoding before
/// allocating a numeric array from an imported document or clipboard payload.
private struct TableFractions: Codable, Equatable, Sendable {
    let values: [Double]

    init(_ values: [Double]) { self.values = values }
    init(from decoder: Decoder) throws {
        var input = try decoder.unkeyedContainer()
        let limit = max(PageDiagramLimits.maximumRows, PageDiagramLimits.maximumColumns)
        if let count = input.count, count > limit { throw LibraryError.invalidData("Too many table dimensions.") }
        var result: [Double] = []
        while !input.isAtEnd {
            guard result.count < limit else { throw LibraryError.invalidData("Too many table dimensions.") }
            result.append(try input.decode(Double.self))
        }
        values = result
    }

    func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
}

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
    public var labelColorHex: String?
    public var labelFontSize: Double?
    public var hasLabelText: Bool { !text.isEmpty || (kind == .table && cells.contains { !$0.isEmpty }) }
    public var lineWidth: Double
    public var linePattern: LinePattern
    public var fill: Bool
    public var text: String
    public var rows: Int
    public var columns: Int
    private var rowSizing: TableFractions?
    private var columnSizing: TableFractions?
    /// Fractions of the outer frame. An absent axis uses equal cell sizes.
    public var rowFractions: [Double]? {
        get { rowSizing?.values }
        set { rowSizing = newValue.map(TableFractions.init) }
    }
    public var columnFractions: [Double]? {
        get { columnSizing?.values }
        set { columnSizing = newValue.map(TableFractions.init) }
    }
    /// Row-major plain text, deliberately independent of native text archives.
    public var cells: [String]
    /// Fallback world coordinates remain useful when an attachment is detached.
    public var start: InkPoint
    public var end: InkPoint
    public var startAttachment: PageDiagramAttachment?
    public var endAttachment: PageDiagramAttachment?
    public var route: ConnectorRoute
    public var arrowHeads: ArrowHeads
    /// True draws an open arrowhead. Absence preserves the solid legacy style.
    public var openArrowheads: Bool?
    public var hasExternalAttachment: Bool { startAttachment?.targetKind != nil || endAttachment?.targetKind != nil }
    public var hasAutomaticPort: Bool { startAttachment?.followsTarget == true || endAttachment?.followsTarget == true }
    public var requiresFormat5: Bool { rowSizing != nil || columnSizing != nil || openArrowheads != nil || hasExternalAttachment || hasAutomaticPort }

    private enum CodingKeys: String, CodingKey {
        case id, kind, x, y, width, height, colorHex, labelColorHex, labelFontSize, lineWidth, linePattern, fill, text, rows, columns, cells
        case start, end, startAttachment, endAttachment, route, arrowHeads, openArrowheads
        case rowSizing = "rowFractions", columnSizing = "columnFractions"
    }

    public init(id: UUID = UUID(), kind: Kind = .rectangle,
                x: Double = 40, y: Double = 40, width: Double = 240, height: Double = 140,
                colorHex: String = "#202020", lineWidth: Double = 2,
                linePattern: LinePattern = .solid, fill: Bool = false, text: String = "",
                rows: Int = 3, columns: Int = 3, cells: [String]? = nil,
                rowFractions: [Double]? = nil, columnFractions: [Double]? = nil,
                start: InkPoint = InkPoint(x: 40, y: 40), end: InkPoint = InkPoint(x: 280, y: 180),
                startAttachment: PageDiagramAttachment? = nil, endAttachment: PageDiagramAttachment? = nil,
                route: ConnectorRoute = .straight, arrowHeads: ArrowHeads = .end, openArrowheads: Bool? = nil,
                labelColorHex: String? = nil, labelFontSize: Double? = nil) {
        self.id = id; self.kind = kind; self.x = x; self.y = y
        self.width = width; self.height = height; self.colorHex = colorHex
        self.labelColorHex = labelColorHex; self.labelFontSize = labelFontSize
        self.lineWidth = lineWidth; self.linePattern = linePattern; self.fill = fill; self.text = text
        self.rows = rows; self.columns = columns
        self.rowSizing = rowFractions.map(TableFractions.init)
        self.columnSizing = columnFractions.map(TableFractions.init)
        // Avoid multiplication/allocation for malformed programmatic dimensions.
        self.cells = cells ?? (kind == .table && (1...20).contains(rows) && (1...12).contains(columns)
            ? Array(repeating: "", count: rows * columns) : [])
        self.start = start; self.end = end
        self.startAttachment = startAttachment; self.endAttachment = endAttachment
        self.route = route; self.arrowHeads = arrowHeads
        self.openArrowheads = openArrowheads
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

public enum PageObjectAnchorKind: String, Codable, Hashable, Sendable { case image, textBox, equation }

public struct PageDiagramAttachment: Codable, Equatable, Sendable {
    /// Retain the original wire key for format 4 diagram-to-diagram attachments.
    public var targetDiagramID: UUID
    public var side: PageDiagram.AnchorSide
    /// A missing kind refers to a shape or table in the page's diagrams.
    public var targetKind: PageObjectAnchorKind?
    /// An automatic port retains its last resolved side for ties and previews
    /// without a live target frame. Older attachments pin the recorded side.
    public var followsTarget: Bool?
    public init(targetDiagramID: UUID, side: PageDiagram.AnchorSide, targetKind: PageObjectAnchorKind? = nil,
                followsTarget: Bool? = nil) {
        self.targetDiagramID = targetDiagramID; self.side = side; self.targetKind = targetKind
        self.followsTarget = followsTarget
    }

    fileprivate func belongs(to diagrams: Set<UUID>, objects: [PageObjectAnchorKind: Set<UUID>]) -> Bool {
        if let targetKind { return objects[targetKind]?.contains(targetDiagramID) == true }
        return diagrams.contains(targetDiagramID)
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

    /// Stored pages and mixed clipboard payloads must also contain the targets
    /// of every typed endpoint. Standalone native drawing validates the bounded
    /// diagram geometry with its projected or saved endpoint coordinates.
    public static func validate(_ page: PageContent) throws {
        try validate(page.diagrams)
        try validateExternalAttachments(in: page)
    }

    static func validateExternalAttachments(in page: PageContent) throws {
        guard page.diagrams.contains(where: \.hasExternalAttachment) else { return }
        guard page.textBoxes.count <= 10_000, page.equations.count <= 10_000,
              page.images.count <= PageImageLimits.maximumImagesPerPage else { throw LibraryError.tooLarge }
        let boxes = Set(page.textBoxes.map(\.id)), equations = Set(page.equations.map(\.id)), images = Set(page.images.map(\.id))
        guard boxes.count == page.textBoxes.count, equations.count == page.equations.count,
              images.count == page.images.count else { throw LibraryError.duplicateID }
        let targets: [PageObjectAnchorKind: Set<UUID>] = [.textBox: boxes, .equation: equations, .image: images]
        for value in page.diagrams {
            for attachment in [value.startAttachment, value.endAttachment].compactMap({ $0 }) {
                if let kind = attachment.targetKind, targets[kind]?.contains(attachment.targetDiagramID) != true {
                    throw LibraryError.invalidData("A connector refers to a missing page object.")
                }
            }
        }
        // A stale fallback in an import must not conceal an excessive dash
        // workload at a model-sized target. Native text height is available to
        // the live renderer, which validates its own projected display geometry.
        if page.diagrams.contains(where: { $0.hasExternalAttachment && $0.linePattern != .solid }) {
            let frames = PageDiagramGeometry.externalAnchorFrames(images: page.images, textBoxes: [],
                equations: page.equations, textBoxHeight: { _ in nil })
            let projected = PageDiagramGeometry.projectingExternalEndpoints(in: page.diagrams, frames: frames)
            if projected != page.diagrams { try validate(projected) }
        }
    }

    public static func validate(_ diagrams: [PageDiagram]) throws {
        guard diagrams.count <= maximumObjects else { throw LibraryError.tooLarge }
        guard Set(diagrams.map(\.id)).count == diagrams.count else { throw LibraryError.duplicateID }
        let lookup = Dictionary(uniqueKeysWithValues: diagrams.map { ($0.id, $0) })
        var cellCount = 0, textBytes = 0, patternBudget = maximumPatternSegments
        for value in diagrams {
            if let color = value.labelColorHex, !PageTheme.isRGBHex(color) {
                throw LibraryError.invalidData("A diagram's text color must be a six-digit RGB color.")
            }
            if let size = value.labelFontSize, !size.isFinite || !(10...72).contains(size) {
                throw LibraryError.invalidData("Diagram text must be between 10 and 72 points.")
            }
            guard coordinate(value.x), coordinate(value.y), value.width.isFinite, value.height.isFinite,
                  (1...10_000).contains(value.width), (1...10_000).contains(value.height),
                  value.lineWidth.isFinite, (0.5...100).contains(value.lineWidth),
                  PageTheme.isRGBHex(value.colorHex), value.text.utf8.count <= maximumLabelBytes,
                  point(value.start), point(value.end) else {
                throw LibraryError.invalidData("A diagram has invalid coordinates, style, or text.")
            }
            textBytes += value.text.utf8.count
            if value.kind == .table {
                guard (1...maximumRows).contains(value.rows), (1...maximumColumns).contains(value.columns),
                      PageTableGeometry.validFractions(value.rowFractions, count: value.rows),
                      PageTableGeometry.validFractions(value.columnFractions, count: value.columns),
                      value.cells.count == value.rows * value.columns,
                      value.cells.count <= maximumPageCells - cellCount,
                      value.cells.allSatisfy({ $0.utf8.count <= maximumCellBytes }) else {
                    throw LibraryError.invalidData("A table has invalid row or column sizes, cell counts, or text.")
                }
                cellCount += value.cells.count
                for cell in value.cells { textBytes += cell.utf8.count }
            } else if !value.cells.isEmpty || value.rowFractions != nil || value.columnFractions != nil {
                throw LibraryError.invalidData("Only tables may contain cells or table dimensions.")
            }
            if let open = value.openArrowheads, !open || value.kind != .connector {
                throw LibraryError.invalidData("Invalid open arrowhead style.")
            }
            guard textBytes <= maximumPageTextBytes else { throw LibraryError.tooLarge }
            for attachment in [value.startAttachment, value.endAttachment].compactMap({ $0 }) {
                guard value.kind == .connector else {
                    throw LibraryError.invalidData("Only connectors can attach to page objects.")
                }
                guard attachment.followsTarget != false else {
                    throw LibraryError.invalidData("Invalid automatic connector port.")
                }
                if attachment.targetKind == nil {
                    guard let target = lookup[attachment.targetDiagramID], target.kind != .connector else {
                        throw LibraryError.invalidData("A connector attachment must target a shape or table on its page.")
                    }
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
    fileprivate static func point(_ value: InkPoint) -> Bool {
        value.x.isFinite && value.y.isFinite
            && (0...InkGeometryLimits.maximumPageDimension).contains(value.x)
            && (0...InkGeometryLimits.maximumPageDimension).contains(value.y)
            && value.pressure.isFinite && (0...1).contains(value.pressure)
    }
}

/// One shared interpretation for native drawing, selection, copying and deletion.
public enum PageDiagramGeometry {
    public static func externalAnchorFrames(images: [PageImage], textBoxes: [PageTextBox], equations: [NoteEquation],
        textBoxHeight: (UUID) -> CGFloat?) -> [PageObjectAnchorKind: [UUID: CGRect]] {
        var result: [PageObjectAnchorKind: [UUID: CGRect]] = [:]
        for image in images {
            result[.image, default: [:]][image.id] = CGRect(x: image.x, y: image.y, width: image.width, height: image.height)
        }
        for box in textBoxes {
            if let height = textBoxHeight(box.id), height.isFinite, height > 0 {
                result[.textBox, default: [:]][box.id] = CGRect(x: box.x, y: box.y, width: box.width, height: height)
            }
        }
        for equation in equations {
            result[.equation, default: [:]][equation.id] = CGRect(x: equation.x, y: equation.y, width: equation.width, height: equation.height)
        }
        return result
    }

    public static func anchorPoint(in frame: CGRect, side: PageDiagram.AnchorSide) -> InkPoint {
        switch side {
        case .top: return InkPoint(x: frame.midX, y: frame.minY)
        case .right: return InkPoint(x: frame.maxX, y: frame.midY)
        case .bottom: return InkPoint(x: frame.midX, y: frame.maxY)
        case .left: return InkPoint(x: frame.minX, y: frame.midY)
        }
    }

    public static func projectingExternalEndpoints(in diagrams: [PageDiagram],
        frames: [PageObjectAnchorKind: [UUID: CGRect]]) -> [PageDiagram] {
        routedConnectors(in: diagrams, frames: frames)
    }

    /// Read both targets from the same snapshot. A scoped mutation updates the
    /// two automatic ends of affected links and only the touched fixed externals.
    public static func routedConnectors(in diagrams: [PageDiagram],
        frames: [PageObjectAnchorKind: [UUID: CGRect]] = [:], movedDiagramIDs: Set<UUID>? = nil,
        movedObjectIDs: [PageObjectAnchorKind: Set<UUID>] = [:]) -> [PageDiagram] {
        guard diagrams.contains(where: { $0.hasAutomaticPort || $0.hasExternalAttachment }) else { return diagrams }
        let shapes = Dictionary(diagrams.filter { $0.kind != .connector }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return diagrams.map { value in
            guard value.kind == .connector, value.hasAutomaticPort || value.hasExternalAttachment else { return value }
            let wholeLink = movedDiagramIDs?.contains(value.id) ?? true
            func touched(_ attachment: PageDiagramAttachment?) -> Bool {
                wholeLink || attachment?.belongs(to: movedDiagramIDs ?? [], objects: movedObjectIDs) == true
            }
            let startTouched = touched(value.startAttachment), endTouched = touched(value.endAttachment)
            guard startTouched || endTouched else { return value }
            var result = resolvedConnector(value, frames: frames, shape: { shapes[$0] })
            if value.startAttachment?.followsTarget != true && !(value.startAttachment?.targetKind != nil && startTouched) {
                result.start = value.start
            }
            if value.endAttachment?.followsTarget != true && !(value.endAttachment?.targetKind != nil && endTouched) {
                result.end = value.end
            }
            return result
        }
    }
    public static func anchorPoint(on value: PageDiagram, side: PageDiagram.AnchorSide) -> InkPoint {
        switch side {
        case .top: return InkPoint(x: value.x + value.width / 2, y: value.y)
        case .right: return InkPoint(x: value.x + value.width * (value.kind == .triangle ? 0.75 : 1), y: value.y + value.height / 2)
        case .bottom: return InkPoint(x: value.x + value.width / 2, y: value.y + value.height)
        case .left: return InkPoint(x: value.x + (value.kind == .triangle ? value.width * 0.25 : 0), y: value.y + value.height / 2)
        }
    }

    private struct AnchorTarget {
        let frame: CGRect
        let shape: PageDiagram?

        func port(_ side: PageDiagram.AnchorSide, fallback: InkPoint) -> InkPoint {
            let port = shape.map { anchorPoint(on: $0, side: side) } ?? anchorPoint(in: frame, side: side)
            return PageDiagramLimits.point(port) ? port : fallback
        }
    }

    private static func resolvedConnector(_ value: PageDiagram, frames: [PageObjectAnchorKind: [UUID: CGRect]],
        shape: (UUID) -> PageDiagram?) -> PageDiagram {
        func target(_ attachment: PageDiagramAttachment?) -> AnchorTarget? {
            guard let attachment else { return nil }
            if let kind = attachment.targetKind {
                guard let frame = frames[kind]?[attachment.targetDiagramID], !frame.isNull, !frame.isInfinite,
                      frame.width > 0, frame.height > 0 else { return nil }
                return AnchorTarget(frame: frame, shape: nil)
            }
            guard let object = shape(attachment.targetDiagramID) else { return nil }
            return AnchorTarget(frame: CGRect(x: object.x, y: object.y, width: object.width, height: object.height), shape: object)
        }
        let first = target(value.startAttachment), last = target(value.endAttachment)
        let autoStart = value.startAttachment?.followsTarget == true, autoEnd = value.endAttachment?.followsTarget == true
        var result = value
        if let attachment = value.startAttachment { result.start = first?.port(attachment.side, fallback: value.start) ?? value.start }
        if let attachment = value.endAttachment { result.end = last?.port(attachment.side, fallback: value.end) ?? value.end }
        guard autoStart || autoEnd, !autoStart || first != nil, !autoEnd || last != nil else { return result }
        // A fixed end aims at its actual port; a free end is a world point.
        // Facing objects choose the axis that separates their outer frames.
        let a = autoStart ? first!.frame : CGRect(x: result.start.x, y: result.start.y, width: 0, height: 0)
        let b = autoEnd ? last!.frame : CGRect(x: result.end.x, y: result.end.y, width: 0, height: 0)
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        guard abs(dx) + abs(dy) > 0.001 else { return result }
        let gapX = max(b.minX - a.maxX, a.minX - b.maxX)
        let gapY = max(b.minY - a.maxY, a.minY - b.maxY)
        let previous = (autoStart ? value.startAttachment : value.endAttachment)!.side
        let horizontal: Bool
        if (gapX >= 0) != (gapY >= 0) { horizontal = gapX >= 0 }
        else if abs(gapX - gapY) <= 6 { horizontal = previous.isHorizontal }
        else { horizontal = gapX > gapY }
        let facing: PageDiagram.AnchorSide = horizontal ? (dx >= 0 ? .right : .left) : (dy >= 0 ? .bottom : .top)
        if autoStart, let first {
            result.startAttachment?.side = facing
            result.start = first.port(facing, fallback: value.start)
        }
        if autoEnd, let last {
            result.endAttachment?.side = facing.opposite
            result.end = last.port(facing.opposite, fallback: value.end)
        }
        return result
    }

    private static func resolvedConnector(_ value: PageDiagram, in diagrams: [PageDiagram]) -> PageDiagram {
        resolvedConnector(value, frames: [:], shape: { id in diagrams.first { $0.id == id && $0.kind != .connector } })
    }

    public static func resolvedEndpoints(for value: PageDiagram, in diagrams: [PageDiagram]) -> (start: InkPoint, end: InkPoint) {
        let resolved = resolvedConnector(value, in: diagrams)
        return (resolved.start, resolved.end)
    }

    public static func connectorPoints(for value: PageDiagram, in diagrams: [PageDiagram]) -> [InkPoint] {
        let resolved = resolvedConnector(value, in: diagrams)
        let a = resolved.start, b = resolved.end
        if value.route == .straight { return [a, b] }
        let midX = (a.x + b.x) / 2
        let horizontal = [a, InkPoint(x: midX, y: a.y), InkPoint(x: midX, y: b.y), b]
        guard value.hasAutomaticPort else { return horizontal }
        let startSide = resolved.startAttachment?.side, endSide = resolved.endAttachment?.side
        // Test directions on nonzero legs so aligned vertical or horizontal
        // ports retain a proper arrowhead and a straight, hittable segment.
        func compact(_ points: [InkPoint]) -> [InkPoint] {
            var result: [InkPoint] = []
            for point in points {
                if let last = result.last, last.x == point.x && last.y == point.y { continue }
                if result.count >= 2 {
                    let u = result[result.count - 2], v = result[result.count - 1]
                    if (u.x == v.x && v.x == point.x && (v.y - u.y) * (point.y - v.y) >= 0)
                        || (u.y == v.y && v.y == point.y && (v.x - u.x) * (point.x - v.x) >= 0) {
                        result.removeLast()
                    }
                }
                result.append(point)
            }
            return result
        }
        func facesPorts(_ points: [InkPoint]) -> Bool {
            guard points.count >= 2 else { return false }
            return startSide?.faces(from: a, toward: points[1]) != false
                && endSide?.faces(from: b, toward: points[points.count - 2]) != false
        }
        let midY = (a.y + b.y) / 2
        let vertical = [a, InkPoint(x: a.x, y: midY), InkPoint(x: b.x, y: midY), b]
        for candidate in [horizontal, vertical, [a, InkPoint(x: b.x, y: a.y), b], [a, InkPoint(x: a.x, y: b.y), b]] {
            let path = compact(candidate)
            if facesPorts(path) { return path }
        }
        // A pinned end may face away from the other object. Route around the
        // outside on its selected side. Never reinterpret that pin as automatic.
        let margin = max(14, value.lineWidth * 3)
        let lead = startSide?.offset(a, by: margin) ?? a, tail = endSide?.offset(b, by: margin) ?? b
        var hull = CGRect(x: min(lead.x, tail.x), y: min(lead.y, tail.y), width: abs(lead.x - tail.x), height: abs(lead.y - tail.y))
        var obstacles: [CGRect] = []
        for attachment in [resolved.startAttachment, resolved.endAttachment].compactMap({ $0 }) where attachment.targetKind == nil {
            guard let object = diagrams.first(where: { $0.id == attachment.targetDiagramID }) else { continue }
            var rect = CGRect(x: object.x, y: object.y, width: object.width, height: object.height)
            if object.kind == .triangle { rect = rect.insetBy(dx: rect.width / 4, dy: 0) }
            obstacles.append(rect)
            hull = hull.union(rect)
        }
        var detours = [[lead, InkPoint(x: lead.x, y: tail.y), tail], [lead, InkPoint(x: tail.x, y: lead.y), tail]]
        for y in [max(0, hull.minY - margin), min(InkGeometryLimits.maximumPageDimension, hull.maxY + margin)] {
            detours.append([lead, InkPoint(x: lead.x, y: y), InkPoint(x: tail.x, y: y), tail])
        }
        for x in [max(0, hull.minX - margin), min(InkGeometryLimits.maximumPageDimension, hull.maxX + margin)] {
            detours.append([lead, InkPoint(x: x, y: lead.y), InkPoint(x: x, y: tail.y), tail])
        }
        var best: [InkPoint]?, shortest = Double.infinity
        for detour in detours {
            let path = compact([a] + detour + [b])
            guard facesPorts(path) else { continue }
            let legs = zip(path, path.dropFirst())
            let crossesObject = legs.contains { u, v in obstacles.contains { rect in
                if u.x == v.x {
                    return rect.minX < u.x && u.x < rect.maxX && min(u.y, v.y) < rect.maxY && max(u.y, v.y) > rect.minY
                }
                return rect.minY < u.y && u.y < rect.maxY && min(u.x, v.x) < rect.maxX && max(u.x, v.x) > rect.minX
            } }
            let length = legs.reduce(0.0) { $0 + abs($1.1.x - $1.0.x) + abs($1.1.y - $1.0.y) }
            if !crossesObject && length < shortest { best = path; shortest = length }
        }
        return best ?? compact([a, lead, InkPoint(x: lead.x, y: tail.y), tail, b])
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
    public static func translated(_ diagrams: [PageDiagram], selectedIDs: Set<UUID>, dx: Double, dy: Double,
                                  selectedObjectIDs: [PageObjectAnchorKind: Set<UUID>] = [:]) -> [PageDiagram] {
        guard dx.isFinite, dy.isFinite else { return diagrams }
        let moved = diagrams.map { value in
            var result = value
            guard selectedIDs.contains(value.id) else {
                if let attachment = value.startAttachment, let kind = attachment.targetKind,
                   selectedObjectIDs[kind]?.contains(attachment.targetDiagramID) == true {
                    result.start.x += dx; result.start.y += dy
                }
                if let attachment = value.endAttachment, let kind = attachment.targetKind,
                   selectedObjectIDs[kind]?.contains(attachment.targetDiagramID) == true {
                    result.end.x += dx; result.end.y += dy
                }
                return result
            }
            result = resolvedConnector(value, in: diagrams)
            if let attachment = result.startAttachment, !attachment.belongs(to: selectedIDs, objects: selectedObjectIDs) { result.startAttachment = nil }
            if let attachment = result.endAttachment, !attachment.belongs(to: selectedIDs, objects: selectedObjectIDs) { result.endAttachment = nil }
            return translated(result, dx: dx, dy: dy)
        }
        return routedConnectors(in: moved, movedDiagramIDs: selectedIDs, movedObjectIDs: selectedObjectIDs)
    }

    /// Deleting a target preserves surviving connector endpoints in world space.
    public static func removing(ids: Set<UUID>, from diagrams: [PageDiagram],
                                objectIDs: [PageObjectAnchorKind: Set<UUID>] = [:],
                                frames: [PageObjectAnchorKind: [UUID: CGRect]] = [:]) -> [PageDiagram] {
        var changed = Set<UUID>()
        let remaining = diagrams.filter { !ids.contains($0.id) }.map { value in
            let detachStart = value.startAttachment?.belongs(to: ids, objects: objectIDs) == true
            let detachEnd = value.endAttachment?.belongs(to: ids, objects: objectIDs) == true
            guard detachStart || detachEnd else { return value }
            let live = resolvedConnector(value, frames: frames, shape: { id in diagrams.first { $0.id == id && $0.kind != .connector } })
            var result = value
            if detachStart { result.start = live.start; result.startAttachment = nil }
            if detachEnd { result.end = live.end; result.endAttachment = nil }
            if !detachStart && value.startAttachment?.followsTarget == true { result.start = live.start; result.startAttachment = live.startAttachment }
            if !detachEnd && value.endAttachment?.followsTarget == true { result.end = live.end; result.endAttachment = live.endAttachment }
            if result.hasAutomaticPort { changed.insert(result.id) }
            return result
        }
        return routedConnectors(in: remaining, frames: frames, movedDiagramIDs: changed)
    }

    /// Use a mapping containing only copied IDs. Attachments to omitted targets
    /// detach, while copied targets receive the same fresh IDs as their arrows.
    public static func remapped(_ diagrams: [PageDiagram], mapping: [UUID: UUID], dx: Double = 0, dy: Double = 0,
                                resolvingIn page: [PageDiagram] = [],
                                objectMappings: [PageObjectAnchorKind: [UUID: UUID]] = [:],
                                sourceFrames: [PageObjectAnchorKind: [UUID: CGRect]] = [:]) -> [PageDiagram] {
        let source = page.isEmpty ? diagrams : page
        let shapes = Dictionary(source.filter { $0.kind != .connector }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func remap(_ attachment: PageDiagramAttachment?) -> PageDiagramAttachment? {
            guard var attachment else { return nil }
            let target: UUID?
            if let kind = attachment.targetKind { target = objectMappings[kind]?[attachment.targetDiagramID] }
            else { target = mapping[attachment.targetDiagramID] }
            guard let target else { return nil }
            attachment.targetDiagramID = target
            return attachment
        }
        return diagrams.map { value in
            let projected = value.hasExternalAttachment ? page.first { $0.id == value.id } : nil
            var geometry = resolvedConnector(projected ?? value, frames: sourceFrames, shape: { shapes[$0] })
            let detachStart = geometry.startAttachment != nil && remap(geometry.startAttachment) == nil
            let detachEnd = geometry.endAttachment != nil && remap(geometry.endAttachment) == nil
            if detachStart { geometry.startAttachment = nil }
            if detachEnd { geometry.endAttachment = nil }
            if geometry.hasAutomaticPort && (detachStart || detachEnd) {
                geometry = resolvedConnector(geometry, frames: sourceFrames, shape: { shapes[$0] })
            }
            var result = value
            result.id = mapping[value.id] ?? value.id
            result.start = geometry.start; result.end = geometry.end
            result.startAttachment = remap(geometry.startAttachment)
            result.endAttachment = remap(geometry.endAttachment)
            return translated(result, dx: dx, dy: dy)
        }
    }
}

private extension PageDiagram.AnchorSide {
    var isHorizontal: Bool { self == .left || self == .right }
    var opposite: Self {
        switch self {
        case .top: return .bottom
        case .right: return .left
        case .bottom: return .top
        case .left: return .right
        }
    }
    func faces(from port: InkPoint, toward point: InkPoint) -> Bool {
        switch self {
        case .top: return point.y < port.y
        case .right: return point.x > port.x
        case .bottom: return point.y > port.y
        case .left: return point.x < port.x
        }
    }
    func offset(_ point: InkPoint, by amount: Double) -> InkPoint {
        var result = point
        switch self {
        case .top: result.y = max(0, point.y - amount)
        case .right: result.x = min(InkGeometryLimits.maximumPageDimension, point.x + amount)
        case .bottom: result.y = min(InkGeometryLimits.maximumPageDimension, point.y + amount)
        case .left: result.x = max(0, point.x - amount)
        }
        return result
    }
}
