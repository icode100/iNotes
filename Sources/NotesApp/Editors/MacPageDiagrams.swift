#if os(macOS)
import AppKit
import NotesCore

struct MacDiagramOptions {
    var kind: PageDiagram.Kind = .rectangle
    var route: PageDiagram.ConnectorRoute = .straight
    var arrowHeads: PageDiagram.ArrowHeads = .end
    var rows = 3
    var columns = 3
    var fill = false
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
            for row in 1..<value.rows {
                let y = rect.minY + rect.height * Double(row) / Double(value.rows)
                path.move(to: CGPoint(x: rect.minX, y: y)); path.line(to: CGPoint(x: rect.maxX, y: y))
            }
            for column in 1..<value.columns {
                let x = rect.minX + rect.width * Double(column) / Double(value.columns)
                path.move(to: CGPoint(x: x, y: rect.minY)); path.line(to: CGPoint(x: x, y: rect.maxY))
            }
        }
        path.stroke()
        if value.kind == .connector {
            let points = PageDiagramGeometry.connectorPoints(for: value, in: diagrams)
            if value.arrowHeads != .none, let end = points.last,
               let tail = points.dropLast().reversed().first(where: { hypot(end.x - $0.x, end.y - $0.y) > 0.01 }) {
                arrow(at: end, from: tail, width: value.lineWidth, color: color)
            }
            if value.arrowHeads == .both, let start = points.first,
               let tail = points.dropFirst().first(where: { hypot(start.x - $0.x, start.y - $0.y) > 0.01 }) {
                arrow(at: start, from: tail, width: value.lineWidth, color: color)
            }
            if let label = labelBounds(of: value) { drawText(value.text, in: label) }
        } else if value.kind == .table {
            for index in value.cells.indices {
                let cell = cellRect(index, in: value).insetBy(dx: 5, dy: 3)
                drawText(value.cells[index], in: cell)
            }
        } else {
            let label: CGRect
            switch value.kind {
            case .triangle: label = CGRect(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.42, width: rect.width * 0.56, height: rect.height * 0.43)
            case .diamond: label = rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.26)
            case .ellipse: label = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.16)
            default: label = rect.insetBy(dx: 8, dy: 8)
            }
            drawText(value.text, in: label)
        }
    }

    /// Drawing and native selection share this same page-space text container.
    /// Empty connector labels add no invisible selectable region.
    func labelBounds(of value: PageDiagram, in values: [PageDiagram]? = nil) -> CGRect? {
        guard value.kind == .connector, !value.text.isEmpty else { return nil }
        let endpoints = PageDiagramGeometry.resolvedEndpoints(for: value, in: values ?? diagrams)
        let width = min(180, bounds.width), height = min(48, bounds.height)
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
    private func arrow(at tip: InkPoint, from tail: InkPoint, width: Double, color: NSColor) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x), length = max(8, width * 3)
        let base = CGPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let half = length * 0.45
        color.setFill()
        polygon([CGPoint(x: tip.x, y: tip.y), CGPoint(x: base.x - sin(angle) * half, y: base.y + cos(angle) * half),
                 CGPoint(x: base.x + sin(angle) * half, y: base.y - cos(angle) * half)]).fill()
    }
    private func drawText(_ text: String, in rect: CGRect) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: InkRenderer.color(theme.textHex), .paragraphStyle: paragraph]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

func cellRect(_ index: Int, in table: PageDiagram) -> CGRect {
    let width = table.width / Double(max(1, table.columns)), height = table.height / Double(max(1, table.rows))
    return CGRect(x: table.x + Double(index % max(1, table.columns)) * width,
                  y: table.y + Double(index / max(1, table.columns)) * height, width: width, height: height)
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
            diagram.startAttachment = nearestDiagramAnchor(to: diagram.start, in: base.diagrams)
            diagram.endAttachment = nearestDiagramAnchor(to: diagram.end, in: base.diagrams)
        }
        var result = base; result.diagrams.append(diagram)
        return (try? PageDiagramLimits.validate(result.diagrams)) != nil ? result : base
    }

    @discardableResult
    func insertDiagram(from start: InkPoint, to end: InkPoint) -> Bool {
        guard page?.inkView.isInputEnabled == true else { return false }
        let id = UUID(), value = diagramCandidate(from: start, to: end, id: id)
        guard commit(value, action: "Insert Diagram") else { return false }
        finishObjectPlacement(selecting: MacPageSelection(diagrams: [id]))
        return true
    }

    func nearestDiagramAnchor(to point: InkPoint, in diagrams: [PageDiagram], excluding: UUID? = nil) -> PageDiagramAttachment? {
        let tolerance = 18 / Double(page?.enclosingScrollView?.magnification ?? 1)
        var best: (Double, PageDiagramAttachment)?
        for target in diagrams.reversed() where target.id != excluding && target.kind != .connector {
            for side in PageDiagram.AnchorSide.allCases {
                let anchor = PageDiagramGeometry.anchorPoint(on: target, side: side)
                let distance = hypot(anchor.x - point.x, anchor.y - point.y)
                if distance <= tolerance, distance < (best?.0 ?? .infinity) {
                    best = (distance, PageDiagramAttachment(targetDiagramID: target.id, side: side))
                }
            }
        }
        return best?.1
    }

    func resizedDiagram(_ base: PageContent, id: UUID, width: Double, height: Double) -> PageContent {
        guard width.isFinite, height.isFinite, let index = base.diagrams.firstIndex(where: { $0.id == id }),
              base.diagrams[index].kind != .connector else { return base }
        var value = base
        let original = value.diagrams[index]
        value.diagrams[index].width = min(10_000, min(Double(page?.bounds.width ?? InkExport.paperSize.width) - original.x, max(24, width)))
        value.diagrams[index].height = min(10_000, min(100_000 - original.y, max(24, height)))
        return (try? PageDiagramLimits.validate(value.diagrams)) != nil ? value : base
    }

    func reconnectedDiagram(_ base: PageContent, id: UUID, starting: Bool, point: InkPoint) -> PageContent {
        guard point.x.isFinite, point.y.isFinite,
              let index = base.diagrams.firstIndex(where: { $0.id == id && $0.kind == .connector }) else { return base }
        var value = base
        let point = InkPoint(x: max(0, min(Double(page?.bounds.width ?? InkExport.paperSize.width), point.x)), y: max(0, min(100_000, point.y)))
        let attachment = nearestDiagramAnchor(to: point, in: base.diagrams, excluding: id)
        if starting { value.diagrams[index].start = point; value.diagrams[index].startAttachment = attachment }
        else { value.diagrams[index].end = point; value.diagrams[index].endAttachment = attachment }
        return (try? PageDiagramLimits.validate(value.diagrams)) != nil ? value : base
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
            let column = min(value.columns - 1, max(0, Int((point.x - value.x) / (value.width / Double(value.columns)))))
            let row = min(value.rows - 1, max(0, Int((point.y - value.y) / (value.height / Double(value.rows)))))
            cell = row * value.columns + column
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
