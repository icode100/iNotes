import SwiftUI
import NotesCore

enum InkTool: String, CaseIterable { case text, select, lasso, diagram, pen, line, pencil, marker, highlighter, eraser }
enum InkPaper: String, CaseIterable { case blank, ruled, dotted, grid }

enum PageSelectionCommand: String, CaseIterable {
    case copy, cut, paste, delete, duplicate, selectAll, clear, undo, redo
}

extension Notification.Name {
    static let pageSelectionCommand = Notification.Name("iNotes.pageSelectionCommand")
}

enum InkLineGeometry {
    /// Small deviations snap to table axes; Shift can force the closest axis.
    static func snappedEnd(start: InkPoint, end: InkPoint, forceAxis: Bool = false) -> InkPoint {
        var snapped = end
        let dx = abs(end.x - start.x), dy = abs(end.y - start.y)
        let tolerance = tan(8 * Double.pi / 180)
        if (forceAxis && dx >= dy) || dy <= dx * tolerance { snapped.y = start.y }
        else if forceAxis || dx <= dy * tolerance { snapped.x = start.x }
        return snapped
    }
}

extension InkStyle {
    var widthMultiplier: Double {
        switch self {
        case .pen: 1
        case .pencil: 0.8
        case .marker: 1.8
        case .highlighter: 4
        }
    }
}

#if os(macOS)
import AppKit

extension NSEvent {
    /// AppKit can hit-test while currentEvent is a key or cursor update. Its
    /// subtype getter raises an Objective-C exception for those event classes.
    private var supportsTabletMouseSubtype: Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved:
            true
        default:
            false
        }
    }

    var isPenPointEvent: Bool {
        if type == .tabletPoint { return true }
        guard supportsTabletMouseSubtype else { return false }
        return subtype == .tabletPoint
    }

    var isPenProximityEvent: Bool {
        if type == .tabletProximity { return true }
        guard supportsTabletMouseSubtype else { return false }
        return subtype == .tabletProximity
    }

    var safeInkPressure: Float? {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .tabletPoint, .pressure:
            pressure
        default:
            nil
        }
    }
}

struct InkEditor: NSViewRepresentable {
    @Binding var strokes: [InkStroke]
    var colorHex = "#314D43"
    var lineWidth: Double = InkNibPreset.defaultWidth(for: .pen)
    var tool: InkTool = .pen
    var paper: InkPaper = .dotted
    var theme: PageTheme = .light
    var onInputChange: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 4
        scroll.backgroundColor = .windowBackgroundColor
        let canvas = InkDocumentView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
        scroll.documentView = canvas
        configure(canvas, isEnabled: context.environment.isEnabled)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? InkDocumentView else { return }
        configure(canvas, isEnabled: context.environment.isEnabled)
    }

    private func configure(_ canvas: InkDocumentView, isEnabled: Bool) {
        canvas.isInputEnabled = isEnabled
        canvas.colorHex = colorHex
        canvas.lineWidth = max(0.5, min(30, lineWidth))
        canvas.tool = tool
        canvas.theme = theme
        if canvas.paper != paper { canvas.paper = paper; canvas.needsDisplay = true }
        if !canvas.isDrawing, canvas.strokes != strokes {
            canvas.strokes = strokes
            canvas.needsDisplay = true
        }
        canvas.onChange = { value in strokes = value }
        canvas.onInputChange = onInputChange
    }
}

@MainActor
enum InkExport {
    static let paperSize = NSSize(width: 1600, height: 2200)

    static func png(strokes: [InkStroke], paper: InkPaper = .dotted, theme: PageTheme = .light, pageTemplate: PageTemplate = .none, templateLinePattern: LinePattern = .solid) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(paperSize.width), pixelsHigh: Int(paperSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: paperSize.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        InkRenderer.draw(strokes: strokes, paper: paper, in: NSRect(origin: .zero, size: paperSize), theme: theme, pageTemplate: pageTemplate, templateLinePattern: templateLinePattern)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    static func pdf(strokes: [InkStroke], paper: InkPaper = .dotted, theme: PageTheme = .light) -> Data {
        let canvas = InkDocumentView(frame: NSRect(origin: .zero, size: paperSize))
        canvas.strokes = strokes
        canvas.paper = paper
        canvas.theme = theme
        return canvas.dataWithPDF(inside: canvas.bounds)
    }
}

@MainActor
enum InkRenderer {
    static func bounds(of stroke: InkStroke) -> NSRect? {
        guard let first = stroke.points.first, stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let width = max(0.5, min(100, stroke.width.isFinite ? stroke.width : 2.5)) * stroke.style.widthMultiplier
        if stroke.points.count == 1 { return NSRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width) }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: first.x, y: first.y))
        for index in 1..<stroke.points.count { appendCurve(to: path, points: stroke.points, at: index) }
        return path.bounds.insetBy(dx: -width / 2, dy: -width / 2)
    }

    static func draw(strokes: [InkStroke], paper: InkPaper, in requestedRect: NSRect, drawsPaper: Bool = true, theme: PageTheme = .light, pageTemplate: PageTemplate = .none, templateLinePattern: LinePattern = .solid, pageBounds: NSRect? = nil) {
        // Layer-backed offscreen rendering can request an effectively infinite
        // dirty rectangle. Intersect the real clip before constructing a grid.
        var dirtyRect = requestedRect
        if let clip = NSGraphicsContext.current?.cgContext.boundingBoxOfClipPath,
           !clip.isNull, !clip.isInfinite,
           [clip.minX, clip.minY, clip.width, clip.height].allSatisfy(\.isFinite) {
            dirtyRect = dirtyRect.intersection(clip)
        }
        guard !dirtyRect.isEmpty, !dirtyRect.isNull, !dirtyRect.isInfinite,
              [dirtyRect.minX, dirtyRect.minY, dirtyRect.width, dirtyRect.height].allSatisfy(\.isFinite) else { return }
        if drawsPaper {
            color(theme.paperHex).setFill()
            dirtyRect.fill()
            color(theme.ruleHex).set()
            let spacing: CGFloat = 28
            // Keep a one-point rule on device-pixel boundaries. At 1x an
            // integer-centered stroke would blur into two faint half pixels.
            let transform = NSGraphicsContext.current?.cgContext.ctm ?? .identity
            let scaleX = max(0.01, abs(transform.a)), scaleY = max(0.01, abs(transform.d))
            let offsetX = Int(scaleX.rounded()) % 2 == 1 ? 0.5 / scaleX : 0
            let offsetY = Int(scaleY.rounded()) % 2 == 1 ? 0.5 / scaleY : 0
            switch paper {
        case .blank: break
        case .ruled, .grid:
            let path = NSBezierPath()
            for y in stride(from: floor(dirtyRect.minY / spacing) * spacing, through: dirtyRect.maxY, by: spacing) {
                path.move(to: NSPoint(x: dirtyRect.minX, y: y + offsetY))
                path.line(to: NSPoint(x: dirtyRect.maxX, y: y + offsetY))
            }
            if paper == .grid {
                for x in stride(from: floor(dirtyRect.minX / spacing) * spacing, through: dirtyRect.maxX, by: spacing) {
                    path.move(to: NSPoint(x: x + offsetX, y: dirtyRect.minY))
                    path.line(to: NSPoint(x: x + offsetX, y: dirtyRect.maxY))
                }
            }
            path.lineWidth = 1.0
            path.stroke()
        case .dotted:
            for y in stride(from: floor(dirtyRect.minY / spacing) * spacing, through: dirtyRect.maxY, by: spacing) {
                for x in stride(from: floor(dirtyRect.minX / spacing) * spacing, through: dirtyRect.maxX, by: spacing) {
                    NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)).fill()
                }
            }
            }
        }
        if drawsPaper {
            let extent = pageBounds ?? NSRect(origin: .zero, size: InkExport.paperSize)
            let effective = pageTemplate.effective(on: PaperStyle(rawValue: paper.rawValue) ?? .blank)
            if effective != .none {
                let x = effective == .centerDivider ? extent.midX : extent.minX + 80
                if x >= dirtyRect.minX - 2 && x <= dirtyRect.maxX + 2 {
                    let divider = NSBezierPath()
                    divider.move(to: NSPoint(x: x, y: extent.minY))
                    divider.line(to: NSPoint(x: x, y: min(extent.maxY, InkGeometryLimits.maximumPageDimension)))
                    divider.lineWidth = 2
                    divider.lineCapStyle = .round
                    applyPattern(templateLinePattern, width: 2, to: divider)
                    color(theme.templateHex).setStroke()
                    divider.stroke()
                }
            }
        }
        var patternBudget = InkGeometryLimits.maximumPatternSegments
        for stroke in strokes {
            // Validate work before constructing the native path, including
            // transient/direct renderer input that has not reached storage.
            guard InkGeometryLimits.consumePatternBudget(for: stroke, remaining: &patternBudget) else { break }
            draw(stroke, theme: theme)
        }
    }

    private static func draw(_ stroke: InkStroke, theme: PageTheme) {
        guard let first = stroke.points.first, first.x.isFinite, first.y.isFinite else { return }
        let inkColor = color(theme.resolvedInkHex(stroke.colorHex))
        let highlighterAlpha: CGFloat = theme.isDark ? 0.36 : 0.25
        let baseWidth = (stroke.width.isFinite ? max(0.5, min(100, stroke.width)) : 2.5) * stroke.style.widthMultiplier
        if stroke.points.count == 1 {
            let width = baseWidth * pressure(first.pressure)
            inkColor.withAlphaComponent(stroke.style == .highlighter ? highlighterAlpha : stroke.style == .pencil ? 0.7 : 1).set()
            NSBezierPath(ovalIn: NSRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)).fill()
            return
        }
        if stroke.linePattern != .solid {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: first.x, y: first.y))
            for index in 1..<stroke.points.count { appendCurve(to: path, points: stroke.points, at: index) }
            path.lineWidth = baseWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            applyPattern(stroke.linePattern, width: baseWidth, to: path)
            inkColor.withAlphaComponent(stroke.style == .highlighter ? highlighterAlpha : 1).setStroke()
            path.stroke()
            return
        }
        // Translucent tools are drawn in ONE operation, so neighboring segments
        // and self-intersections do not acquire dark seams from repeated alpha.
        if stroke.style == .highlighter || stroke.style == .marker {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: first.x, y: first.y))
            for index in 1..<stroke.points.count { appendCurve(to: path, points: stroke.points, at: index) }
            let meanPressure = stroke.points.reduce(0.0) { $0 + max(0, min(1, $1.pressure)) } / Double(stroke.points.count)
            path.lineWidth = baseWidth * (0.7 + 0.3 * meanPressure)
            path.lineCapStyle = stroke.style == .highlighter ? .butt : .round
            path.lineJoinStyle = .round
            inkColor.withAlphaComponent(stroke.style == .highlighter ? highlighterAlpha : 0.96).set()
            path.stroke()
            return
        }
        for index in 1..<stroke.points.count {
            let previous = stroke.points[index - 1]
            let point = stroke.points[index]
            guard previous.x.isFinite, previous.y.isFinite, point.x.isFinite, point.y.isFinite else { continue }
            let path = NSBezierPath()
            path.move(to: NSPoint(x: previous.x, y: previous.y))
            appendCurve(to: path, points: stroke.points, at: index)
            let force = (previous.pressure + point.pressure) / 2
            path.lineWidth = baseWidth * pressure(force)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let pencilAlpha = (theme.isDark ? 0.55 : 0.3) + (theme.isDark ? 0.4 : 0.58) * max(0, min(1, force))
            inkColor.withAlphaComponent(stroke.style == .pencil ? CGFloat(pencilAlpha) : 1).set()
            path.stroke()
        }
    }

    private static func applyPattern(_ pattern: LinePattern, width: Double, to path: NSBezierPath) {
        let lengths = pattern.dashLengths(width: width).map { CGFloat($0) }
        if !lengths.isEmpty { path.setLineDash(lengths, count: lengths.count, phase: 0) }
    }

    private static func appendCurve(to path: NSBezierPath, points: [InkPoint], at index: Int) {
        let p0 = points[max(0, index - 2)], p1 = points[index - 1]
        let p2 = points[index], p3 = points[min(points.count - 1, index + 1)]
        guard [p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y].allSatisfy(\.isFinite) else { return }
        path.curve(to: NSPoint(x: p2.x, y: p2.y),
                   controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                   controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }

    private static func pressure(_ value: Double) -> Double {
        value.isFinite ? 0.35 + 0.65 * max(0, min(1, value)) : 1
    }

    static func color(_ hex: String) -> NSColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .black }
        return NSColor(red: Double((value >> 16) & 255) / 255,
                       green: Double((value >> 8) & 255) / 255,
                       blue: Double(value & 255) / 255, alpha: 1)
    }
}

@MainActor
final class InkDocumentView: NSView {
    var strokes: [InkStroke] = []
    var colorHex = "#314D43" { didSet { if colorHex != oldValue { invalidateTipCursor() } } }
    var lineWidth: Double = InkNibPreset.defaultWidth(for: .pen) { didSet { if lineWidth != oldValue { invalidateTipCursor() } } }
    var linePattern: LinePattern = .solid
    var tool: InkTool = .pen { didSet { if tool != oldValue { invalidateTipCursor() } } }
    var paper: InkPaper = .dotted
    var theme: PageTheme = .light {
        didSet { if theme != oldValue { needsDisplay = true; invalidateTipCursor() } }
    }
    var drawsPaper = true
    var onChange: (([InkStroke]) -> Void)?
    var onInputChange: ((String) -> Void)?
    var onTipCursorChange: (() -> Void)?
    weak var pageSelectionHistory: UndoManager?
    var isInputEnabled = true {
        didSet {
            setAccessibilityEnabled(isInputEnabled)
            if !isInputEnabled, isDrawing {
                strokes = beforeGesture
                activeStroke = nil
                isLineGesture = false
                isDrawing = false
                beforeGesture = []
                needsDisplay = true
            }
        }
    }
    private(set) var isDrawing = false
    private var activeStroke: InkStroke?
    private var isLineGesture = false
    private var beforeGesture: [InkStroke] = []
    private var tabletEraserInProximity = false
    private var lastInputDescription: String?
    private let localUndoManager = UndoManager()
    private var magnificationObservation: NSKeyValueObservation?
    private var tipTrackingArea: NSTrackingArea?
    var showsTipCursor = true {
        didSet {
            if showsTipCursor != oldValue { updateTrackingAreas(); invalidateTipCursor() }
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { drawsPaper }
    override var acceptsFirstResponder: Bool { isInputEnabled }
    override var undoManager: UndoManager? { pageSelectionHistory ?? localUndoManager }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Drawing canvas")
        setAccessibilityHelp("Draw with a mouse or pressure sensitive pen tablet. Pinch to zoom. Use the eraser to remove a stroke. Undo is available with Command Z.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func resetCursorRects() { if showsTipCursor { addCursorRect(visibleRect, cursor: tipCursor()) } }

    override func updateTrackingAreas() {
        if let tipTrackingArea { removeTrackingArea(tipTrackingArea) }
        tipTrackingArea = nil
        super.updateTrackingAreas()
        if showsTipCursor {
            let area = NSTrackingArea(rect: .zero,
                                      options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tipTrackingArea = area
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if showsTipCursor { tipCursor().set() }
        else { super.cursorUpdate(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        if showsTipCursor { tipCursor().set() }
        else { super.mouseEntered(with: event) }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeMagnification() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeMagnification() }

    func tipCursor(magnification: CGFloat? = nil) -> NSCursor {
        InkTipCursor.cursor(tool: tool, width: lineWidth, colorHex: colorHex, theme: theme,
                            magnification: magnification ?? enclosingScrollView?.magnification ?? 1)
    }

    private func observeMagnification() {
        magnificationObservation = enclosingScrollView?.observe(\.magnification, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.invalidateTipCursor() }
        }
        invalidateTipCursor()
    }

    private func invalidateTipCursor() {
        window?.invalidateCursorRects(for: self)
        onTipCursorChange?()
        if showsTipCursor, let window, window.isKeyWindow,
           !isHiddenOrHasHiddenAncestor,
           visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            tipCursor().set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        InkRenderer.draw(strokes: activeStroke.map { strokes + [$0] } ?? strokes, paper: paper, in: dirtyRect.intersection(bounds), drawsPaper: drawsPaper, theme: theme)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInputEnabled, tool != .select, tool != .lasso, tool != .diagram else { return }
        reportInput(event)
        window?.makeFirstResponder(self)
        beforeGesture = strokes
        isDrawing = true
        isLineGesture = false
        let point = inkPoint(event)
        if tool == .eraser || tabletEraserInProximity {
            erase(at: point)
        } else {
            isLineGesture = tool == .line
            activeStroke = InkStroke(points: [point], colorHex: colorHex, width: lineWidth,
                                     style: InkStyle(rawValue: tool.rawValue) ?? .pen,
                                     linePattern: tool == .line ? linePattern : .solid)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputEnabled, isDrawing else { return }
        reportInput(event)
        continueGesture(event)
    }

    private func continueGesture(_ event: NSEvent) {
        let point = inkPoint(event)
        if activeStroke != nil {
            if isLineGesture { updateLineEnd(event); return }
            guard let previous = activeStroke?.points.last else { return }
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            guard distance >= 0.4, (activeStroke?.points.count ?? 0) < 100_000 else { return }
            activeStroke?.points.append(point)
            let padding = lineWidth * (activeStroke?.style.widthMultiplier ?? 1) + 8
            let recent = Array(activeStroke?.points.suffix(4) ?? [])
            let minX = recent.map(\.x).min() ?? point.x, maxX = recent.map(\.x).max() ?? point.x
            let minY = recent.map(\.y).min() ?? point.y, maxY = recent.map(\.y).max() ?? point.y
            setNeedsDisplay(NSRect(x: minX - padding, y: minY - padding,
                                  width: maxX - minX + padding * 2, height: maxY - minY + padding * 2))
        } else {
            erase(at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputEnabled, isDrawing else { return }
        if isLineGesture { updateLineEnd(event) }
        let actionName = isLineGesture ? "Straight Line" : "Drawing"
        if let activeStroke { strokes.append(activeStroke) }
        activeStroke = nil
        isLineGesture = false
        isDrawing = false
        if strokes != beforeGesture {
            registerUndo(previous: beforeGesture, actionName: actionName)
            onChange?(strokes)
        }
        beforeGesture = []
        needsDisplay = true
    }

    override func tabletProximity(with event: NSEvent) {
        guard event.isPenProximityEvent else { return }
        tabletEraserInProximity = event.isEnteringProximity && event.pointingDeviceType == .eraser
        if event.isEnteringProximity { reportInputDescription(tabletEraserInProximity ? "Tablet eraser detected" : "Pen tablet detected") }
    }

    override func tabletPoint(with event: NSEvent) {
        guard event.isPenPointEvent else { return }
        reportInputDescription("Pen tablet detected")
        if isInputEnabled, isDrawing { continueGesture(event) }
    }

    private func reportInput(_ event: NSEvent) {
        reportInputDescription(event.isPenPointEvent ? "Pen tablet detected" : "Mouse / trackpad")
    }

    private func reportInputDescription(_ description: String) {
        guard lastInputDescription != description else { return }
        lastInputDescription = description
        onInputChange?(description)
    }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    private func registerUndo(previous: [InkStroke], actionName: String = "Drawing") {
        let manager = undoManager ?? localUndoManager
        let needsGroup = manager.groupingLevel == 0
        if needsGroup { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { target in
            let current = target.strokes
            target.strokes = previous
            target.registerUndo(previous: current, actionName: actionName)
            target.onChange?(previous)
            target.needsDisplay = true
        }
        manager.setActionName(actionName)
        if needsGroup { manager.endUndoGrouping() }
    }

    private func updateLineEnd(_ event: NSEvent) {
        guard let start = activeStroke?.points.first else { return }
        let oldEnd = activeStroke?.points.last ?? start
        var end = inkPoint(event)
        if (event.safeInkPressure ?? 0) <= 0 { end.pressure = oldEnd.pressure }
        end = InkLineGeometry.snappedEnd(start: start, end: end, forceAxis: event.modifierFlags.contains(.shift))
        activeStroke?.points = [start, end]
        let padding = lineWidth + 8
        let minX = min(start.x, oldEnd.x, end.x), maxX = max(start.x, oldEnd.x, end.x)
        let minY = min(start.y, oldEnd.y, end.y), maxY = max(start.y, oldEnd.y, end.y)
        setNeedsDisplay(NSRect(x: minX - padding, y: minY - padding,
                              width: maxX - minX + padding * 2, height: maxY - minY + padding * 2))
    }

    private func inkPoint(_ event: NSEvent) -> InkPoint {
        let location = convert(event.locationInWindow, from: nil)
        let pressure = event.safeInkPressure ?? 0
        return InkPoint(x: max(0, min(bounds.width, location.x)), y: max(0, min(bounds.height, location.y)),
                        pressure: pressure > 0 ? Double(pressure) : 1)
    }

    private func erase(at point: InkPoint) {
        let previousCount = strokes.count
        strokes.removeAll { stroke in
            // Defensive consumer guard for legacy or in-memory malformed data.
            guard !stroke.points.isEmpty else { return true }
            let radius = max(12, stroke.width / 2 + 8)
            if stroke.points.count == 1, let only = stroke.points.first {
                return hypot(only.x - point.x, only.y - point.y) <= radius
            }
            for index in 1..<stroke.points.count {
                let a = stroke.points[index - 1], b = stroke.points[index]
                let dx = b.x - a.x, dy = b.y - a.y
                let lengthSquared = dx * dx + dy * dy
                let fraction = lengthSquared > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
                if hypot(point.x - (a.x + fraction * dx), point.y - (a.y + fraction * dy)) <= radius { return true }
            }
            return false
        }
        if strokes.count != previousCount { needsDisplay = true }
    }
}

/// Native cursor artwork is measured in screen points. A bounded cache avoids
/// regenerating bitmaps for every hover while honoring note zoom and nib width.
@MainActor
enum InkTipCursor {
    private struct Entry { let key: String; let cursor: NSCursor; let cost: Int }
    private static var entries: [Entry] = []
    private static let budget = 2 * 1_024 * 1_024

    static func cursor(tool: InkTool, width: Double, colorHex: String, theme: PageTheme, magnification: CGFloat) -> NSCursor {
        switch tool {
        case .text: return .iBeam
        case .select: return .arrow
        case .lasso, .diagram, .eraser: return .crosshair
        default: break
        }
        let style = InkStyle(rawValue: tool.rawValue) ?? .pen
        let zoom = magnification.isFinite ? max(0.25, min(4, magnification)) : 1
        let nib = width.isFinite ? max(0.5, min(30, width)) : 2.5
        let diameter = max(2, nib * style.widthMultiplier * Double(zoom))
        let resolved = theme.resolvedInkHex(colorHex)
        let key = "\(tool.rawValue)|\(resolved)|\(theme.rawValue)|\(diameter)"
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index); entries.append(entry); return entry.cursor
        }
        let edge: CGFloat = 0.8
        let extent = CGFloat(ceil(diameter + 6))
        let center = CGPoint(x: extent / 2, y: extent / 2)
        let image = NSImage(size: CGSize(width: extent, height: extent), flipped: true) { _ in
            let path: NSBezierPath
            if tool == .highlighter {
                // A slanted chisel nib, rather than a round pen tip.
                let half = CGFloat(diameter) / (2 * sqrt(2))
                let thickness = max(1.5, CGFloat(diameter) * 0.08)
                path = NSBezierPath()
                path.move(to: CGPoint(x: center.x - half - thickness, y: center.y + half - thickness))
                path.line(to: CGPoint(x: center.x + half - thickness, y: center.y - half - thickness))
                path.line(to: CGPoint(x: center.x + half + thickness, y: center.y - half + thickness))
                path.line(to: CGPoint(x: center.x - half + thickness, y: center.y + half + thickness))
                path.close()
            } else {
                path = NSBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                  width: diameter, height: diameter))
            }
            InkRenderer.color(resolved).setFill(); path.fill()
            (theme.isDark ? NSColor.black : NSColor.white).withAlphaComponent(0.9).setStroke()
            path.lineWidth = edge; path.lineJoinStyle = .round; path.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: center)
        // Retina RGBA estimate; at most one oversize cursor may exceed budget.
        let cost = Int(extent * extent * 16)
        while !entries.isEmpty && (entries.count >= 16 || entries.reduce(cost, { $0 + $1.cost }) > budget) { entries.removeFirst() }
        entries.append(Entry(key: key, cursor: cursor, cost: cost))
        return cursor
    }
}
#endif
