#if os(macOS)
import AppKit
import Combine
import NotesCore

struct MacDiagramOptions {
    var kind: PageDiagram.Kind = .rectangle
    var route: PageDiagram.ConnectorRoute = .straight
    var arrowHeads: PageDiagram.ArrowHeads = .end
    var rows = 3
    var columns = 3
    var fill = false
}

/// Sheet-local bridge between native selection and the selected-shape controls.
/// Never publishes while SwiftUI is configuring its representable, and never
/// retains the page/controller or changes the creation defaults.
@MainActor
final class MacDiagramSelectionStyle: ObservableObject {
    @Published private(set) var selectedCount = 0
    @Published private(set) var fill: Bool? = nil
    @Published private(set) var canEdit = false
    @Published private(set) var editableConnector: PageDiagram?
    private weak var controller: MacPageSelectionController?
    private var refreshPending = false

    var accessibilityValue: String {
        guard selectedCount > 0 else { return "No shapes selected" }
        return fill.map { $0 ? "Filled" : "No fill" } ?? "Mixed"
    }

    func bind(_ controller: MacPageSelectionController) {
        self.controller = controller
        scheduleRefresh()
    }

    func textBoxHeight(_ id: UUID) -> CGFloat? { controller?.page?.textBoxViews[id]?.frame.height }

    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshPending = false
            let shapes = controller?.selectedFillableDiagrams ?? []
            let currentFill: Bool? = shapes.first.flatMap { first in
                shapes.allSatisfy { $0.fill == first.fill } ? first.fill : nil
            }
            let editable = !shapes.isEmpty && controller?.page?.inkView.isInputEnabled == true
            if selectedCount != shapes.count { selectedCount = shapes.count }
            if fill != currentFill { fill = currentFill }
            if canEdit != editable { canEdit = editable }
            let arrow = controller.flatMap { controller in
                controller.page?.inkView.isInputEnabled == true ? controller.selectedConnector : nil
            }
            if editableConnector != arrow { editableConnector = arrow }
        }
    }

    @discardableResult
    func setFill(_ filled: Bool) -> Bool {
        controller?.setSelectedDiagramFill(filled) ?? false
    }

    @discardableResult
    func apply(_ appearance: ConnectorAppearance, to id: UUID) -> Bool {
        controller?.applyConnectorAppearance(appearance, to: id) ?? false
    }
}

/// One bounded vector layer shares the page's coordinates and export path.
/// Input stays with the page's native selection/creation overlay.
@MainActor
final class MacPageDiagramView: NSView {
    var diagrams: [PageDiagram] = [] {
        didSet { if diagrams != oldValue { needsDisplay = true; setAccessibilityValue("\(diagrams.count) objects") } }
    }
    var theme: PageTheme = .light { didSet { if theme != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var contentBounds: CGRect? {
        guard (try? PageDiagramLimits.validate(diagrams)) != nil else { return nil }
        return diagrams.map { visualBounds(of: $0) }.reduce(nil) { $0?.union($1) ?? $1 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Page shapes, connectors and tables")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        // The renderer remains defensive when called without a store/import.
        guard (try? PageDiagramLimits.validate(diagrams)) != nil else { return }
        for value in diagrams where visualBounds(of: value).intersects(dirtyRect) {
            draw(value)
        }
    }

    private func draw(_ value: PageDiagram) {
        let color = InkRenderer.color(theme.resolvedInkHex(value.colorHex))
        let rect = CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
        let path: NSBezierPath
        switch value.kind {
        case .rectangle, .table: path = NSBezierPath(rect: rect)
        case .roundedRectangle:
            let radius = min(16, min(rect.width, rect.height) * 0.16)
            path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        case .ellipse: path = NSBezierPath(ovalIn: rect)
        case .triangle:
            path = polygon([CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
        case .diamond:
            path = polygon([CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)])
        case .connector:
            let points = PageDiagramGeometry.connectorPoints(for: value, in: diagrams)
            path = NSBezierPath()
            if let first = points.first {
                path.move(to: CGPoint(x: first.x, y: first.y))
                for point in points.dropFirst() { path.line(to: CGPoint(x: point.x, y: point.y)) }
            }
        }
        if value.fill && value.kind != .connector {
            color.withAlphaComponent(theme.isDark ? 0.18 : 0.10).setFill()
            path.fill()
        }
        color.setStroke(); path.lineWidth = value.lineWidth
        path.lineJoinStyle = .round; path.lineCapStyle = .round
        if value.linePattern != .solid {
            let dash = value.linePattern.dashLengths(width: value.lineWidth).map { CGFloat($0) }
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        if value.kind == .table {
            for y in PageTableGeometry.edges(in: value, axis: .row).dropFirst().dropLast() {
                path.move(to: CGPoint(x: rect.minX, y: y)); path.line(to: CGPoint(x: rect.maxX, y: y))
            }
            for x in PageTableGeometry.edges(in: value, axis: .column).dropFirst().dropLast() {
                path.move(to: CGPoint(x: x, y: rect.minY)); path.line(to: CGPoint(x: x, y: rect.maxY))
            }
        }
        path.stroke()
        if value.kind == .connector {
            let points = PageDiagramGeometry.connectorPoints(for: value, in: diagrams)
            if value.arrowHeads != .none, let end = points.last,
               let tail = points.dropLast().reversed().first(where: { hypot(end.x - $0.x, end.y - $0.y) > 0.01 }) {
                arrow(at: end, from: tail, width: value.lineWidth, color: color, open: value.openArrowheads == true)
            }
            if value.arrowHeads == .both, let start = points.first,
               let tail = points.dropFirst().first(where: { hypot(start.x - $0.x, start.y - $0.y) > 0.01 }) {
                arrow(at: start, from: tail, width: value.lineWidth, color: color, open: value.openArrowheads == true)
            }
            if let label = labelBounds(of: value) { drawText(value.text, in: label, diagram: value) }
        } else if value.kind == .table {
            for index in value.cells.indices {
                let cell = PageTableGeometry.cellRect(index, in: value).insetBy(dx: 5, dy: 3)
                drawText(value.cells[index], in: cell, diagram: value)
            }
        } else {
            let label: CGRect
            switch value.kind {
            case .triangle: label = CGRect(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.42, width: rect.width * 0.56, height: rect.height * 0.43)
            case .diamond: label = rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.26)
            case .ellipse: label = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.16)
            default: label = rect.insetBy(dx: 8, dy: 8)
            }
            drawText(value.text, in: label, diagram: value)
        }
    }

    /// Drawing and native selection share this same page-space text container.
    /// Empty connector labels add no invisible selectable region.
    func labelBounds(of value: PageDiagram, in values: [PageDiagram]? = nil) -> CGRect? {
        guard value.kind == .connector, !value.text.isEmpty else { return nil }
        let endpoints = PageDiagramGeometry.resolvedEndpoints(for: value, in: values ?? diagrams)
        let pointSize = value.labelFontSize ?? 14
        let width = min(max(180, pointSize * 10), bounds.width)
        let height = min(max(48, pointSize * 2.5), bounds.height)
        let x = max(0, min(bounds.maxX - width, (endpoints.start.x + endpoints.end.x) / 2 - width / 2))
        let y = max(0, min(bounds.maxY - height, (endpoints.start.y + endpoints.end.y) / 2 + 5))
        return CGRect(x: x, y: y, width: width, height: height)
    }
    func visualBounds(of value: PageDiagram, in values: [PageDiagram]? = nil) -> CGRect {
        let geometry = PageDiagramGeometry.bounds(of: value, in: values ?? diagrams)
        return labelBounds(of: value, in: values).map { geometry.union($0) } ?? geometry
    }

    func hitTestDiagram(_ value: PageDiagram, at point: InkPoint, in values: [PageDiagram]? = nil) -> Bool {
        PageDiagramGeometry.hitTest(value, at: point, in: values ?? diagrams)
            || labelBounds(of: value, in: values)?.contains(CGPoint(x: point.x, y: point.y)) == true
    }

    private func polygon(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        if let first = points.first { path.move(to: first); for point in points.dropFirst() { path.line(to: point) }; path.close() }
        return path
    }
    private func arrow(at tip: InkPoint, from tail: InkPoint, width: Double, color: NSColor, open: Bool) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x), length = max(8, width * 3)
        let base = CGPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let half = length * 0.45
        let left = CGPoint(x: base.x - sin(angle) * half, y: base.y + cos(angle) * half)
        let right = CGPoint(x: base.x + sin(angle) * half, y: base.y - cos(angle) * half)
        let point = CGPoint(x: tip.x, y: tip.y)
        if open {
            let head = NSBezierPath()
            head.move(to: left); head.line(to: point); head.line(to: right)
            head.lineWidth = width; head.lineJoinStyle = .round
            color.setStroke(); head.stroke()
        } else {
            color.setFill()
            polygon([point, left, right]).fill()
        }
    }
    private func drawText(_ text: String, in rect: CGRect, diagram: PageDiagram) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: diagram.labelFontSize ?? 14),
            .foregroundColor: InkRenderer.color(diagram.labelColorHex.map(theme.resolvedInkHex) ?? theme.textHex), .paragraphStyle: paragraph]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

extension MacPageSelectionController {
    var singleSelectedDiagramID: UUID? {
        guard selection.diagrams.count == 1, selection.strokes.isEmpty, selection.nativeStrokes.isEmpty,
              selection.textBoxes.isEmpty, selection.equations.isEmpty, selection.images.isEmpty, selection.textRanges.isEmpty else { return nil }
        return selection.diagrams.first
    }

    func diagramCandidate(from start: InkPoint, to end: InkPoint, id: UUID, base: PageContent? = nil) -> PageContent {
        let base = base ?? content
        guard let page, start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return base }
        let options = page.diagramOptions
        let paperWidth = Double(page.bounds.width)
        func bounded(_ point: InkPoint) -> InkPoint {
            InkPoint(x: min(paperWidth - 1, max(0, point.x)), y: min(99_999, max(0, point.y)))
        }
        let first = bounded(start), last = bounded(end)
        let click = hypot(first.x - last.x, first.y - last.y) < 4
        let x = min(first.x, last.x), y = min(first.y, last.y)
        let width = min(paperWidth - x, max(24, click ? (options.kind == .table ? 360 : 240) : abs(last.x - first.x)))
        let height = min(100_000 - y, max(24, click ? (options.kind == .table ? 180 : 140) : abs(last.y - first.y)))
        var diagram = PageDiagram(id: id, kind: options.kind, x: x, y: y, width: width, height: height,
                                  colorHex: page.inkView.colorHex, lineWidth: page.inkView.lineWidth,
                                  linePattern: page.inkView.linePattern, fill: options.fill,
                                  rows: min(20, max(1, options.rows)), columns: min(12, max(1, options.columns)),
                                  route: options.route, arrowHeads: options.arrowHeads)
        if options.kind == .connector {
            diagram.start = first
            diagram.end = click ? bounded(InkPoint(x: first.x + 180, y: first.y + 80)) : last
            (diagram.start, diagram.startAttachment) = snappedEndpoint(at: diagram.start, in: base)
            (diagram.end, diagram.endAttachment) = snappedEndpoint(at: diagram.end, in: base)
        }
        var result = base; result.diagrams.append(diagram)
        return (try? PageDiagramLimits.validate(result)) != nil ? result : base
    }

    @discardableResult
    func insertDiagram(from start: InkPoint, to end: InkPoint) -> Bool {
        guard page?.inkView.isInputEnabled == true else { return false }
        let id = UUID(), value = diagramCandidate(from: start, to: end, id: id)
        guard commit(value, action: "Insert Diagram") else { return false }
        finishObjectPlacement(selecting: MacPageSelection(diagrams: [id]))
        return true
    }

    private func snappedEndpoint(at point: InkPoint, in base: PageContent) -> (InkPoint, PageDiagramAttachment?) {
        guard point.x.isFinite, point.y.isFinite else { return (point, nil) }
        let scale = Double(page?.enclosingScrollView?.magnification ?? 1)
        let tolerance = 18 / (scale.isFinite && scale > 0 ? scale : 1)
        typealias Candidate = (distance: Double, port: InkPoint, attachment: PageDiagramAttachment)
        var bestPort: Candidate?, bestEdge: Candidate?
        func consider(_ id: UUID, _ kind: PageObjectAnchorKind?, _ frame: CGRect, shape: PageDiagram? = nil) {
            guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(CGPoint(x: point.x, y: point.y)) else { return }
            func port(_ side: PageDiagram.AnchorSide) -> InkPoint {
                if let shape { return PageDiagramGeometry.anchorPoint(on: shape, side: side) }
                return PageDiagramGeometry.anchorPoint(in: frame, side: side)
            }
            for side in PageDiagram.AnchorSide.allCases {
                let anchor = port(side), distance = hypot(anchor.x - point.x, anchor.y - point.y)
                if distance <= tolerance && distance < (bestPort?.distance ?? .infinity) {
                    bestPort = (distance, anchor, PageDiagramAttachment(targetDiagramID: id, side: side, targetKind: kind))
                }
            }
            if bestPort == nil {
                let edge = diagramEdge(to: point, in: frame, kind: shape?.kind ?? .rectangle)
                if edge.distance <= tolerance && edge.distance < (bestEdge?.distance ?? .infinity) {
                    bestEdge = (edge.distance, port(edge.side), PageDiagramAttachment(targetDiagramID: id, side: edge.side, targetKind: kind))
                }
            }
        }
        // Text boxes and equations are drawn over diagrams, and images are
        // underneath. Equal-distance ports keep the first visible candidate.
        for box in base.textBoxes.reversed() {
            if let frame = page?.textBoxViews[box.id]?.frame { consider(box.id, .textBox, frame) }
        }
        for eq in base.equations.reversed() { consider(eq.id, .equation, CGRect(x: eq.x, y: eq.y, width: eq.width, height: eq.height)) }
        for target in base.diagrams.reversed() where target.kind != .connector {
            consider(target.id, nil, PageDiagramGeometry.bounds(of: target, in: base.diagrams), shape: target)
        }
        for image in base.images.reversed() { consider(image.id, .image, CGRect(x: image.x, y: image.y, width: image.width, height: image.height)) }
        guard let hit = bestPort ?? bestEdge else { return (point, nil) }
        return (hit.port, hit.attachment)
    }

    private func diagramEdge(to point: InkPoint, in frame: CGRect, kind: PageDiagram.Kind) -> (side: PageDiagram.AnchorSide, distance: Double) {
        let x = frame.minX, y = frame.minY, w = frame.width, h = frame.height
        func segment(_ a: InkPoint, _ b: InkPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
            return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
        }
        if kind == .ellipse {
            let rx = w / 2, ry = h / 2, dx = point.x - x - rx, dy = point.y - y - ry
            let angle = atan2(dy / ry, dx / rx)
            let distance = hypot(dx - cos(angle) * rx, dy - sin(angle) * ry)
            let side: PageDiagram.AnchorSide = abs(dx / rx) >= abs(dy / ry)
                ? (dx >= 0 ? .right : .left) : (dy >= 0 ? .bottom : .top)
            return (side, distance)
        }
        if kind == .triangle {
            let top = InkPoint(x: x + w / 2, y: y), left = InkPoint(x: x, y: y + h), right = InkPoint(x: x + w, y: y + h)
            return [(PageDiagram.AnchorSide.left, segment(top, left)), (.right, segment(top, right)), (.bottom, segment(left, right))]
                .min { $0.1 < $1.1 }.map { ($0.0, $0.1) }!
        }
        if kind == .diamond {
            let points = [InkPoint(x: x + w / 2, y: y), InkPoint(x: x + w, y: y + h / 2),
                          InkPoint(x: x + w / 2, y: y + h), InkPoint(x: x, y: y + h / 2)]
            let distance = points.indices.map { segment(points[$0], points[($0 + 1) % points.count]) }.min()!
            let side = PageDiagram.AnchorSide.allCases.min {
                let a = PageDiagramGeometry.anchorPoint(in: frame, side: $0), b = PageDiagramGeometry.anchorPoint(in: frame, side: $1)
                return hypot(point.x - a.x, point.y - a.y) < hypot(point.x - b.x, point.y - b.y)
            }!
            return (side, distance)
        }
        return [(PageDiagram.AnchorSide.top, segment(InkPoint(x: x, y: y), InkPoint(x: x + w, y: y))),
                (.right, segment(InkPoint(x: x + w, y: y), InkPoint(x: x + w, y: y + h))),
                (.bottom, segment(InkPoint(x: x, y: y + h), InkPoint(x: x + w, y: y + h))),
                (.left, segment(InkPoint(x: x, y: y), InkPoint(x: x, y: y + h)))]
            .min { $0.1 < $1.1 }.map { ($0.0, $0.1) }!
    }

    func resizedDiagram(_ base: PageContent, id: UUID, width: Double, height: Double) -> PageContent {
        guard width.isFinite, height.isFinite, let index = base.diagrams.firstIndex(where: { $0.id == id }),
              base.diagrams[index].kind != .connector else { return base }
        var value = base
        let original = value.diagrams[index]
        value.diagrams[index].width = min(10_000, min(Double(page?.bounds.width ?? InkExport.paperSize.width) - original.x, max(24, width)))
        value.diagrams[index].height = min(10_000, min(100_000 - original.y, max(24, height)))
        value.diagrams = projectedDiagrams(in: value, changedDiagrams: [id])
        return (try? PageDiagramLimits.validate(value.diagrams)) != nil ? value : base
    }

    func reconnectedDiagram(_ base: PageContent, id: UUID, starting: Bool, point: InkPoint) -> PageContent {
        guard point.x.isFinite, point.y.isFinite,
              let index = base.diagrams.firstIndex(where: { $0.id == id && $0.kind == .connector }) else { return base }
        var value = base
        let point = InkPoint(x: max(0, min(Double(page?.bounds.width ?? InkExport.paperSize.width), point.x)), y: max(0, min(100_000, point.y)))
        let endpoint = snappedEndpoint(at: point, in: base)
        if starting { (value.diagrams[index].start, value.diagrams[index].startAttachment) = endpoint }
        else { (value.diagrams[index].end, value.diagrams[index].endAttachment) = endpoint }
        // Snapping explicitly pins the dragged end. The opposite end keeps its
        // policy and can face the new attached target or free endpoint.
        value.diagrams = projectedDiagrams(in: value, changedDiagrams: [id])
        return (try? PageDiagramLimits.validate(value)) != nil ? value : base
    }

    var selectedFillableDiagrams: [PageDiagram] {
        content.diagrams.filter { selection.diagrams.contains($0.id) && $0.kind != .connector }
    }

    /// Mixed selections apply only to their closed shapes/tables. A single
    /// validated page snapshot gives the whole fill change one undo transaction.
    @discardableResult
    func setSelectedDiagramFill(_ filled: Bool) -> Bool {
        guard let page, page.inkView.isInputEnabled else { return false }
        let ids = Set(selectedFillableDiagrams.map(\.id))
        guard !ids.isEmpty else { return false }
        var value = content
        for index in value.diagrams.indices where ids.contains(value.diagrams[index].id) {
            value.diagrams[index].fill = filled
        }
        return commit(value, action: filled ? "Fill Shapes" : "Remove Shape Fill")
    }

    @discardableResult
    func editDiagramText(id: UUID, cell: Int? = nil, text: String) -> Bool {
        guard let page, page.inkView.isInputEnabled,
              let index = content.diagrams.firstIndex(where: { $0.id == id }) else { return false }
        var value = content
        if let cell {
            guard value.diagrams[index].kind == .table, value.diagrams[index].cells.indices.contains(cell) else { return false }
            value.diagrams[index].cells[cell] = text
        } else { value.diagrams[index].text = text }
        do { try PageDiagramLimits.validate(value.diagrams) }
        catch { onPasteError?(error.localizedDescription); return false }
        return commit(value, action: cell == nil ? "Edit Diagram Label" : "Edit Table Cell")
    }

    func requestDiagramTextEdit(id: UUID, at point: InkPoint) {
        guard let page, page.inkView.isInputEnabled, let window = page.window, window.attachedSheet == nil,
              let value = content.diagrams.first(where: { $0.id == id }) else { return }
        let cell: Int?
        if value.kind == .table {
            guard let index = PageTableGeometry.cellIndex(at: point, in: value) else { return }
            cell = index
        } else { cell = nil }
        let text = cell.map { value.cells[$0] } ?? value.text
        let alert = NSAlert(); alert.messageText = cell == nil ? "Diagram label" : "Table cell"
        alert.informativeText = cell == nil ? "Edit the text on this object." : "Edit the selected cell. Rows and columns keep their size."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds); editor.string = text; editor.font = .systemFont(ofSize: 14)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.allowsUndo = true
        editor.textContainer?.widthTracksTextView = true; scroll.documentView = editor; alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if self?.editDiagramText(id: id, cell: cell, text: editor.string) != true { NSSound.beep() }
        }
        alert.window.makeFirstResponder(editor)
    }
}
#endif
