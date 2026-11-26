#if os(macOS)
import AppKit
import NotesCore

/// Existing archives may reuse a UUID across object types.
struct QuickAddSource: Equatable {
    let id: UUID
    var kind: PageObjectAnchorKind? = nil

    @MainActor func frame(on page: UnifiedMacPageView) -> CGRect? {
        switch kind {
        case .image: return page.imageViews[id]?.frame
        case .textBox: return page.textBoxViews[id]?.frame
        case .equation: return page.equationViews[id]?.frame
        case nil:
            guard let object = page.diagramView.diagrams.first(where: { $0.id == id }) else { return nil }
            return page.diagramView.visualBounds(of: object)
        }
    }
}

/// A window-local tracking area observes the page without intercepting its input.
/// Only the small, visible button becomes a hit target.
@MainActor
final class MacDiagramQuickAdd: NSObject {
    private weak var page: UnifiedMacPageView?
    let button = NSButton()
    private(set) var source: QuickAddSource?
    private var sourceFrame = CGRect.null
    private var bridge = CGRect.null
    private var hoverRegions: [(diagram: PageDiagram, bounds: CGRect)]?
    private var choosing = false

    init(page: UnifiedMacPageView) {
        self.page = page
        super.init()
        button.title = ""
        button.bezelStyle = .circular
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.controlSize = .small
        button.toolTip = "Add connected object"
        button.setAccessibilityLabel("Add connected object")
        button.target = self
        button.action = #selector(openMenu)
        button.isHidden = true
        page.addSubview(button, positioned: .above, relativeTo: page.selectionView)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        page.addTrackingArea(area)
    }

    /// Recompute regions lazily on the next hover, never during a drawing gesture.
    func contentDidChange() {
        hoverRegions = nil
        if let page, let source, !page.inkView.isInputEnabled || source.frame(on: page) != sourceFrame || page.selectionController?.hasPreview == true {
            hide()
        }
    }

    func hide() {
        source = nil
        sourceFrame = .null
        bridge = .null
        button.isHidden = true
    }

    @objc(mouseEntered:) private func entered(_ event: NSEvent) { moved(event) }
    @objc(mouseMoved:) private func moved(_ event: NSEvent) {
        guard let page, event.window === page.window else { return }
        track(page.convert(event.locationInWindow, from: nil))
    }
    @objc(mouseExited:) private func exited(_ event: NSEvent) { if !choosing { hide() } }

    func buttonHit(at point: CGPoint) -> NSButton? {
        guard !button.isHidden, page?.inkView.isInputEnabled == true,
              page?.inkView.isDrawing == false, page?.selectionController?.hasPreview == false,
              button.frame.contains(point) else { return nil }
        return button
    }

    func track(_ point: CGPoint) {
        guard !choosing else { return }
        guard let page, page.inkView.isInputEnabled, !page.inkView.isDrawing,
              let controller = page.selectionController, !controller.hasPreview,
              page.visibleRect.contains(point) else { hide(); return }
        if buttonHit(at: point) != nil { return }
        let zoom = max(0.25, page.enclosingScrollView?.magnification ?? 1)
        let location = InkPoint(x: point.x, y: point.y)
        if hoverRegions == nil {
            let diagrams = page.diagramView.diagrams
            guard diagrams.count <= PageDiagramLimits.maximumObjects else { hide(); return }
            let targets = Dictionary(diagrams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            hoverRegions = diagrams.map { value in
                // Resolve each arrow once per updated snapshot. Pointer moves
                // then test its bounds and reuse the renderer’s path/label hit.
                var hit = value
                if value.kind == .connector {
                    if let end = value.endAttachment, end.targetKind == nil, let target = targets[end.targetDiagramID] {
                        hit.end = PageDiagramGeometry.anchorPoint(on: target, side: end.side)
                    }
                    if let start = value.startAttachment, start.targetKind == nil, let target = targets[start.targetDiagramID] {
                        hit.start = PageDiagramGeometry.anchorPoint(on: target, side: start.side)
                    }
                    // The hover test uses the cached coordinates with an empty
                    // target list. Keep port directions for the elbow legs.
                }
                return (hit, page.diagramView.visualBounds(of: hit, in: []))
            }
        }
        let hitDiagram = hoverRegions?.reversed().first(where: {
            $0.bounds.insetBy(dx: -5, dy: -5).contains(point) && page.diagramView.hitTestDiagram($0.diagram, at: location, in: [])
        })?.diagram
        let hit: QuickAddSource
        // Text boxes and equations sit above diagrams, which sit above images.
        if let box = controller.content.textBoxes.reversed().first(where: { page.textBoxViews[$0.id]?.frame.contains(point) == true }) {
            hit = QuickAddSource(id: box.id, kind: .textBox)
        } else if let equation = controller.content.equations.reversed().first(where: { page.equationViews[$0.id]?.frame.contains(point) == true }) {
            hit = QuickAddSource(id: equation.id, kind: .equation)
        } else if let hitDiagram {
            hit = QuickAddSource(id: hitDiagram.id)
        } else if let image = controller.content.images.reversed().first(where: { page.imageViews[$0.id]?.frame.contains(point) == true }) {
            hit = QuickAddSource(id: image.id, kind: .image)
        } else {
            if !bridge.contains(point) { hide() }
            return
        }
        if source == hit && bridge.contains(point) { return }
        let visible = page.visibleRect
        let size = 24 / zoom, gap = 4 / zoom
        guard visible.width >= size, visible.height >= size, let rect = hit.frame(on: page) else { hide(); return }
        // Use an actual side port (including a triangle's inset ports). For a
        // long arrow, keep the control beside the part the user is pointing at.
        func port(_ side: PageDiagram.AnchorSide) -> InkPoint {
            if hit.kind == nil, let hitDiagram {
                return hitDiagram.kind == .connector ? location : PageDiagramGeometry.anchorPoint(on: hitDiagram, side: side)
            }
            return PageDiagramGeometry.anchorPoint(in: rect, side: side)
        }
        var anchor = port(.right)
        var x = anchor.x + gap
        if x + size > visible.maxX {
            anchor = port(.left)
            x = anchor.x - gap - size
        }
        let frame = CGRect(x: max(visible.minX, min(visible.maxX - size, x)),
                           y: max(visible.minY, min(visible.maxY - size, anchor.y - size / 2)),
                           width: size, height: size)
        bridge = frame.union(CGRect(x: anchor.x, y: anchor.y, width: 1, height: 1)).insetBy(dx: -gap, dy: -gap)
        source = hit
        sourceFrame = rect
        button.frame = frame
        button.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        button.isHidden = false
    }

    @objc private func openMenu() {
        guard let source, let page, page.inkView.isInputEnabled, source.frame(on: page) != nil else {
            hide(); return
        }
        choosing = true
        let menu = menu(for: source)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
        choosing = false
        hide()
    }

    func menu(for source: QuickAddSource) -> NSMenu {
        let menu = NSMenu(title: "Add connected object")
        for (kind, title, symbol) in Self.choices {
            let item = NSMenuItem(title: title, action: #selector(addObject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Choice(source: source, kind: kind)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    private struct Choice { let source: QuickAddSource; let kind: PageDiagram.Kind }
    private static let choices: [(PageDiagram.Kind, String, String)] = [
        (.rectangle, "Rectangle", "rectangle"), (.roundedRectangle, "Rounded rectangle", "capsule"),
        (.ellipse, "Ellipse", "oval"), (.triangle, "Triangle", "triangle"),
        (.diamond, "Diamond", "diamond"), (.table, "Table", "tablecells")
    ]

    @objc func addObject(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? Choice else { return }
        _ = page?.selectionController?.addConnectedObject(from: choice.source, kind: choice.kind)
    }
}

@MainActor
extension MacPageSelectionController {
    /// Attach both objects before committing so limit failures and Undo cannot
    /// leave a shape without its arrow. A free-ended arrow is completed in place.
    @discardableResult
    func addConnectedObject(from source: QuickAddSource, kind: PageDiagram.Kind) -> Bool {
        guard let page, page.inkView.isInputEnabled, !hasPreview, !page.inkView.isDrawing, kind != .connector,
              var sourceFrame = source.frame(on: page) else { return false }
        let arrowIndex = source.kind == nil ? content.diagrams.firstIndex(where: { $0.id == source.id && $0.kind == .connector }) : nil
        var anchor: QuickAddSource? = source
        if let arrowIndex {
            let arrow = content.diagrams[arrowIndex]
            if let attachment = arrow.endAttachment {
                anchor = QuickAddSource(id: attachment.targetDiagramID, kind: attachment.targetKind)
                guard let rect = anchor?.frame(on: page) else { return false }
                sourceFrame = rect
            } else {
                anchor = nil
                sourceFrame = CGRect(x: arrow.end.x, y: arrow.end.y, width: 0, height: 0)
            }
        }
        let size = kind == .table ? CGSize(width: 360, height: 180) : CGSize(width: 240, height: 140)
        var obstacles = content.diagrams.filter { $0.kind != .connector }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        obstacles.append(contentsOf: page.imageViews.values.map(\.frame))
        obstacles.append(contentsOf: page.equationViews.values.map(\.frame))
        obstacles.append(contentsOf: page.textBoxViews.values.map(\.frame))
        guard let (frame, sides) = connectedPlacement(near: sourceFrame, size: size, pageWidth: page.bounds.width, obstacles: obstacles) else {
            onPasteError?("There isn’t room for another connected object here."); return false
        }
        let options = page.diagramOptions
        let object = PageDiagram(kind: kind, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                                 colorHex: page.inkView.colorHex, lineWidth: page.inkView.lineWidth,
                                 linePattern: page.inkView.linePattern, fill: options.fill,
                                 rows: min(PageDiagramLimits.maximumRows, max(1, options.rows)),
                                 columns: min(PageDiagramLimits.maximumColumns, max(1, options.columns)))
        let end = PageDiagramGeometry.anchorPoint(on: object, side: sides.1)
        let endAttachment = PageDiagramAttachment(targetDiagramID: object.id, side: sides.1, followsTarget: true)
        var next = content
        next.diagrams.append(object)
        if let anchor {
            let start: InkPoint
            if anchor.kind == nil, let shape = content.diagrams.first(where: { $0.id == anchor.id }) {
                start = PageDiagramGeometry.anchorPoint(on: shape, side: sides.0)
            } else {
                start = PageDiagramGeometry.anchorPoint(in: sourceFrame, side: sides.0)
            }
            let connector = PageDiagram(kind: .connector, colorHex: page.inkView.colorHex,
                lineWidth: page.inkView.lineWidth, linePattern: page.inkView.linePattern,
                start: start, end: end,
                startAttachment: PageDiagramAttachment(targetDiagramID: anchor.id, side: sides.0,
                                                      targetKind: anchor.kind, followsTarget: true),
                endAttachment: endAttachment, route: options.route, arrowHeads: .end)
            next.diagrams.append(connector)
        } else if let arrowIndex {
            next.diagrams[arrowIndex].end = end
            next.diagrams[arrowIndex].endAttachment = endAttachment
        } else { return false }
        next.diagrams = PageDiagramGeometry.routedConnectors(in: next.diagrams, frames: page.externalAnchorFrames(in: next),
                                                           movedDiagramIDs: [object.id])
        do { try PageDiagramLimits.validate(next) }
        catch { onPasteError?(error.localizedDescription); return false }
        guard commit(next, action: "Add Connected Object") else { return false }
        finishObjectPlacement(selecting: MacPageSelection(diagrams: [object.id]))
        page.scrollToVisible(frame.insetBy(dx: -12, dy: -12))
        return true
    }

    private func connectedPlacement(near source: CGRect, size: CGSize, pageWidth: CGFloat, obstacles: [CGRect])
        -> (CGRect, (PageDiagram.AnchorSide, PageDiagram.AnchorSide))? {
        let gap: CGFloat = 56, margin: CGFloat = 12
        guard pageWidth >= size.width + 2 * margin else { return nil }
        let x = min(max(source.midX - size.width / 2, margin), pageWidth - margin - size.width)
        let y = max(margin, source.midY - size.height / 2)
        let candidates: [(CGPoint, PageDiagram.AnchorSide, PageDiagram.AnchorSide)] = [
            (CGPoint(x: source.maxX + gap, y: y), .right, .left),
            (CGPoint(x: x, y: source.maxY + gap), .bottom, .top),
            (CGPoint(x: source.minX - gap - size.width, y: y), .left, .right),
            (CGPoint(x: x, y: source.minY - gap - size.height), .top, .bottom)
        ]
        let allowed = CGRect(x: margin, y: margin, width: pageWidth - 2 * margin, height: 100_000 - 2 * margin)
        func fits(_ rect: CGRect) -> Bool {
            allowed.contains(rect) && !obstacles.contains { $0.insetBy(dx: -margin, dy: -margin).intersects(rect) }
        }
        for (origin, from, to) in candidates {
            let rect = CGRect(origin: origin, size: size)
            if fits(rect) { return (rect, (from, to)) }
        }
        // A crowded diagram can expand vertically. Skip occupied rows in one
        // sorted pass rather than retrying arbitrary offsets until one works.
        var below = CGRect(x: x, y: source.maxY + gap, width: size.width, height: size.height)
        for obstacle in obstacles.sorted(by: { $0.minY < $1.minY }) {
            let padded = obstacle.insetBy(dx: -margin, dy: -margin)
            if padded.intersects(below) { below.origin.y = padded.maxY + gap }
        }
        return fits(below) ? (below, (.bottom, .top)) : nil
    }
}
#endif
