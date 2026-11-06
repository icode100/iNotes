#if os(macOS)
import AppKit
import PencilKit
import NotesCore

struct MacPageSelection {
    var strokes = Set<UUID>()
    var nativeStrokes = Set<Int>()
    var textBoxes = Set<UUID>()
    var equations = Set<UUID>()
    var images = Set<UUID>()
    var diagrams = Set<UUID>()
    var textRanges: [NSRange] = []
    var isEmpty: Bool { strokes.isEmpty && nativeStrokes.isEmpty && textBoxes.isEmpty && equations.isEmpty && images.isEmpty && diagrams.isEmpty && textRanges.isEmpty }
}

/// A store rejection must leave the same native undo/redo action retryable.
/// UndoManager normally consumes a callback even when it makes no change. A
/// rejected callback installs a no-op inverse that restores that callback; the
/// opposite operation then restores the whole group, including any successful
/// callbacks that preceded the rejection. All content changes still validate.
@MainActor
final class PageUndoManager: UndoManager {
    private var operationInProgress = false
    private var repairNeeded = false
    private var repairActionName: String?
    private(set) var isRejectingRemainingActions = false

    override func undo() {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false; repairNeeded = false; repairActionName = nil; isRejectingRemainingActions = false }
        repairNeeded = false
        let name = undoActionName
        super.undo()
        if repairNeeded {
            repairActionName = name
            repairNeeded = false
            isRejectingRemainingActions = false
            super.redo()
        }
    }

    override func redo() {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false; repairNeeded = false; repairActionName = nil; isRejectingRemainingActions = false }
        repairNeeded = false
        let name = redoActionName
        super.redo()
        if repairNeeded {
            repairActionName = name
            repairNeeded = false
            isRejectingRemainingActions = false
            super.undo()
        }
    }

    override func setActionName(_ actionName: String) {
        super.setActionName(repairActionName ?? actionName)
    }

    func retainRejectedAction<T: AnyObject>(withTarget target: T, actionName: String,
                                           handler: @escaping (T) -> Void) {
        guard isUndoing || isRedoing else { return }
        repairNeeded = true
        isRejectingRemainingActions = true
        registerUndo(withTarget: target) { [weak self] target in
            guard let self else { return }
            self.registerUndo(withTarget: target, handler: handler)
            self.setActionName(actionName)
        }
        setActionName(actionName)
    }
}

@MainActor
final class MacPageSelectionController: NSObject {
    weak var page: UnifiedMacPageView?
    var content = PageContent()
    var selection = MacPageSelection()
    var onRender: ((PageContent) -> Void)?
    var onCommit: ((PageContent) -> Void)?
    var onValidate: ((PageContent) -> Bool)?
    var onPasteError: ((String) -> Void)?
    var onEquationEdit: ((NoteEquation) -> Void)?
    let history = PageUndoManager()
    private var observer: NSObjectProtocol?
    private var isApplying = false
    private var transientContent: PageContent?
    private(set) var hasToolIndependentSelection = false

    override init() {
        super.init()
        history.groupsByEvent = true
        history.levelsOfUndo = 50
        observer = NotificationCenter.default.addObserver(forName: .pageSelectionCommand, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let page = self.page, page.window?.isKeyWindow == true,
                      let command = note.object as? PageSelectionCommand else { return }
                self.perform(command)
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func load(_ content: PageContent) {
        guard !isApplying, self.content != content else { return }
        self.content = content
        transientContent = nil
        selection = MacPageSelection()
        hasToolIndependentSelection = false
        page?.selectionView.needsDisplay = true
    }

    /// Cmd-A temporarily focuses the page selection while retaining the chosen
    /// tool. The next page gesture or explicit tool choice resumes that tool.
    func clearToolIndependentSelection() {
        guard hasToolIndependentSelection else { return }
        hasToolIndependentSelection = false
        cancelPreview()
        selection = MacPageSelection()
        page?.selectionView.needsDisplay = true
    }

    func select(polygon: [InkPoint], extending: Bool = false) {
        guard let page else { return }
        var value = extending ? selection : MacPageSelection()
        for stroke in content.strokes where PageSelectionGeometry.intersects(stroke: stroke, polygon: polygon) { value.strokes.insert(stroke.id) }
        if let drawing = nativeDrawing(content) {
            for (index, stroke) in drawing.strokes.enumerated() {
                if PortableInkConverter.strokes(from: PKDrawing(strokes: [stroke])).contains(where: { PageSelectionGeometry.intersects(stroke: $0, polygon: polygon) }) {
                    value.nativeStrokes.insert(index)
                }
            }
        }
        for box in content.textBoxes {
            if let frame = page.textBoxViews[box.id]?.frame, PageSelectionGeometry.intersects(rect: frame, polygon: polygon) { value.textBoxes.insert(box.id) }
        }
        for equation in content.equations where PageSelectionGeometry.intersects(rect: CGRect(x: equation.x, y: equation.y, width: equation.width, height: equation.height), polygon: polygon) {
            value.equations.insert(equation.id)
        }
        for image in content.images where PageSelectionGeometry.intersects(rect: CGRect(x: image.x, y: image.y, width: image.width, height: image.height), polygon: polygon) {
            value.images.insert(image.id)
        }
        for diagram in content.diagrams {
            let hit: Bool
            if diagram.kind == .connector {
                let stroke = InkStroke(points: PageDiagramGeometry.connectorPoints(for: diagram, in: content.diagrams), width: diagram.lineWidth)
                hit = PageSelectionGeometry.intersects(stroke: stroke, polygon: polygon)
                    || page.diagramView.labelBounds(of: diagram, in: content.diagrams).map {
                        PageSelectionGeometry.intersects(rect: $0, polygon: polygon)
                    } == true
            } else { hit = PageSelectionGeometry.intersects(rect: PageDiagramGeometry.bounds(of: diagram, in: content.diagrams), polygon: polygon) }
            if hit { value.diagrams.insert(diagram.id) }
        }
        value.textRanges = merged(value.textRanges + bodyRanges(polygon: polygon))
        selection = value
        page.selectionView.needsDisplay = true
    }

    func select(at point: InkPoint, extending: Bool = false) {
        guard let page else { return }
        var value = extending ? selection : MacPageSelection()
        // The last-drawn ink is on top, matching the page's actual hit order.
        if let stroke = content.strokes.reversed().first(where: { PageSelectionGeometry.hits(stroke: $0, at: point) }) {
            value.strokes.insert(stroke.id)
            if let drawing = nativeDrawing(content) {
                for (index, native) in drawing.strokes.enumerated() where PortableInkConverter.strokes(from: PKDrawing(strokes: [native])).contains(where: { PageSelectionGeometry.hits(stroke: $0, at: point) }) {
                    value.nativeStrokes.insert(index)
                }
            }
        } else if let box = content.textBoxes.reversed().first(where: { page.textBoxViews[$0.id]?.frame.contains(NSPoint(x: point.x, y: point.y)) == true }) {
            value.textBoxes.insert(box.id)
        } else if let equation = content.equations.reversed().first(where: { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(CGPoint(x: point.x, y: point.y)) }) {
            value.equations.insert(equation.id)
        } else {
            let polygon = PageSelectionGeometry.rectangle(from: InkPoint(x: point.x - 2, y: point.y - 2), to: InkPoint(x: point.x + 2, y: point.y + 2))
            let hits = bodyRanges(polygon: polygon)
            if let hit = hits.first, hit.location < (content.text as NSString).length {
                let word = page.textView.selectionRange(forProposedRange: hit, granularity: .selectByWord)
                value.textRanges = merged(value.textRanges + [word])
            } else if let diagram = content.diagrams.reversed().first(where: {
                page.diagramView.hitTestDiagram($0, at: point, in: content.diagrams)
            }) {
                value.diagrams.insert(diagram.id)
            } else if let image = content.images.reversed().first(where: {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(CGPoint(x: point.x, y: point.y))
            }) {
                // Images sit behind both native text and handwriting.
                value.images.insert(image.id)
            }
        }
        selection = value
        page.selectionView.needsDisplay = true
    }

    func selectionBounds() -> CGRect? {
        guard let page else { return nil }
        let content = transientContent ?? content
        var rectangles: [CGRect] = []
        for stroke in content.strokes where selection.strokes.contains(stroke.id) {
            if let bounds = PageSelectionGeometry.bounds(of: stroke.points, padding: max(3, stroke.width * stroke.style.widthMultiplier / 2)) { rectangles.append(bounds) }
        }
        if let drawing = nativeDrawing(content) {
            rectangles += drawing.strokes.enumerated().filter { selection.nativeStrokes.contains($0.offset) }.map { $0.element.renderBounds }
        }
        rectangles += content.textBoxes.filter { selection.textBoxes.contains($0.id) }.compactMap { page.textBoxViews[$0.id]?.frame }
        rectangles += content.equations.filter { selection.equations.contains($0.id) }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        rectangles += content.images.filter { selection.images.contains($0.id) }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        rectangles += content.diagrams.filter { selection.diagrams.contains($0.id) }.map {
            page.diagramView.visualBounds(of: $0, in: content.diagrams)
        }
        rectangles += selection.textRanges.compactMap { bodyRect(range: $0) }
        return rectangles.reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// Convert only the selected text runs into movable rich-text objects. The
    /// original body and the new objects enter one transaction and one undo.
    func promotedContent() -> (PageContent, MacPageSelection) {
        var result = content, selected = selection
        let canonical = canonicalBody()
        let mutable = NSMutableAttributedString(attributedString: canonical)
        for range in selection.textRanges.reversed() where NSMaxRange(range) <= canonical.length {
            guard let rect = bodyRect(range: range) else { continue }
            let text = canonical.attributedSubstring(from: range)
            let box = PageTextBox(x: max(0, rect.minX), y: max(0, rect.minY), width: max(40, min(1520, rect.width + 16)),
                                  text: text.string, rtfData: rtf(text))
            result.textBoxes.append(box); selected.textBoxes.insert(box.id)
            mutable.deleteCharacters(in: range)
        }
        if !selection.textRanges.isEmpty { result.text = mutable.string; result.rtfData = rtf(mutable) }
        selected.textRanges = []
        return (result, selected)
    }

    func translated(_ base: PageContent, selection selected: MacPageSelection, dx: Double, dy: Double) -> PageContent {
        guard dx.isFinite, dy.isFinite else { return base }
        if base.pencilKitData != nil, nativeDrawing(base) == nil { return content }
        var points = base.strokes.filter { selected.strokes.contains($0.id) }.flatMap(\.points)
        points += base.textBoxes.filter { selected.textBoxes.contains($0.id) }.map { InkPoint(x: $0.x, y: $0.y) }
        points += base.equations.filter { selected.equations.contains($0.id) }.map { InkPoint(x: $0.x, y: $0.y) }
        points += base.images.filter { selected.images.contains($0.id) }.flatMap {
            [InkPoint(x: $0.x, y: $0.y), InkPoint(x: $0.x + $0.width, y: $0.y + $0.height)]
        }
        points += base.diagrams.filter { selected.diagrams.contains($0.id) }.flatMap {
            let bounds = page?.diagramView.visualBounds(of: $0, in: base.diagrams)
                ?? PageDiagramGeometry.bounds(of: $0, in: base.diagrams)
            return [InkPoint(x: bounds.minX, y: bounds.minY), InkPoint(x: bounds.maxX, y: bounds.maxY)]
        }
        let bounds = PageSelectionGeometry.bounds(of: points)
        let horizontal = horizontalBounds(base, selection: selected)
        let paperWidth = Double(page?.bounds.width ?? InkExport.paperSize.width)
        guard (horizontal?.width ?? 0) <= paperWidth else { return content }
        let dx = max(-Double(horizontal?.minX ?? 0), min(paperWidth - Double(horizontal?.maxX ?? 0), dx))
        let requestedY = dy
        let lowerY = -Double(bounds?.minY ?? 0), upperY = 100_000 - Double(bounds?.maxY ?? 0)
        let hasTypedText = !selected.textBoxes.isEmpty || !selected.textRanges.isEmpty
        let dy: Double
        if page?.paperView.paper == .ruled, hasTypedText {
            let spacing = Double(RuledTextLayout.spacing)
            dy = max(ceil(lowerY / spacing) * spacing, min(floor(upperY / spacing) * spacing, (requestedY / spacing).rounded() * spacing))
        } else { dy = max(lowerY, min(upperY, requestedY)) }
        var result = base
        result.strokes = base.strokes.map { selected.strokes.contains($0.id) ? PageSelectionGeometry.translated($0, dx: dx, dy: dy) : $0 }
        if let drawing = nativeDrawing(base), !selected.nativeStrokes.isEmpty {
            let moved = drawing.strokes.enumerated().map { index, stroke -> PKStroke in
                guard selected.nativeStrokes.contains(index) else { return stroke }
                var value = stroke
                value.transform = stroke.transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
                return value
            }
            let native = PKDrawing(strokes: moved)
            guard let portable = try? PortableInkConverter.validatedStrokes(from: native) else { return content }
            result.pencilKitData = native.dataRepresentation()
            result.strokes = portable
        }
        for index in result.textBoxes.indices where selected.textBoxes.contains(result.textBoxes[index].id) {
            result.textBoxes[index].x = max(0, min(100_000, base.textBoxes[index].x + dx))
            result.textBoxes[index].y = max(0, min(100_000, base.textBoxes[index].y + dy))
        }
        for index in result.equations.indices where selected.equations.contains(result.equations[index].id) {
            result.equations[index].x = max(0, min(100_000, base.equations[index].x + dx))
            result.equations[index].y = max(0, min(100_000, base.equations[index].y + dy))
        }
        for index in result.images.indices where selected.images.contains(result.images[index].id) {
            result.images[index].x = base.images[index].x + dx
            result.images[index].y = base.images[index].y + dy
        }
        result.diagrams = PageDiagramGeometry.translated(base.diagrams, selectedIDs: selected.diagrams, dx: dx, dy: dy)
        return result
    }

    var singleSelectedImageID: UUID? {
        guard selection.images.count == 1, selection.strokes.isEmpty, selection.nativeStrokes.isEmpty,
              selection.textBoxes.isEmpty, selection.equations.isEmpty, selection.diagrams.isEmpty, selection.textRanges.isEmpty else { return nil }
        return selection.images.first
    }

    /// Resize only the image; annotations remain independent page content.
    func resizedImage(_ base: PageContent, id: UUID, width: Double) -> PageContent {
        guard width.isFinite, let index = base.images.firstIndex(where: { $0.id == id }) else { return base }
        let image = base.images[index]
        guard image.width > 0, image.height > 0 else { return base }
        let ratio = image.height / image.width
        let maximumWidth = min(Double(page?.bounds.width ?? InkExport.paperSize.width) - image.x,
                               10_000, 10_000 / ratio, (100_000 - image.y) / ratio)
        let minimumWidth = max(1, 1 / ratio)
        guard maximumWidth >= minimumWidth else { return base }
        var value = base
        value.images[index].width = min(maximumWidth, max(min(max(24, minimumWidth), maximumWidth), width))
        value.images[index].height = value.images[index].width * ratio
        guard (try? PageImageLimits.validate(value.images)) != nil else { return base }
        return value
    }

    func canMoveSelection() -> Bool {
        (horizontalBounds(content, selection: selection)?.width ?? 0) <= (page?.bounds.width ?? InkExport.paperSize.width)
    }

    private func horizontalBounds(_ value: PageContent, selection selected: MacPageSelection? = nil) -> CGRect? {
        var rectangles = value.strokes.filter { selected == nil || selected!.strokes.contains($0.id) }.compactMap { InkRenderer.bounds(of: $0) }
        rectangles += value.textBoxes.filter { selected == nil || selected!.textBoxes.contains($0.id) }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: 24) }
        rectangles += value.equations.filter { selected == nil || selected!.equations.contains($0.id) }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        rectangles += value.images.filter { selected == nil || selected!.images.contains($0.id) }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        rectangles += value.diagrams.filter { selected == nil || selected!.diagrams.contains($0.id) }.map {
            page?.diagramView.visualBounds(of: $0, in: value.diagrams)
                ?? PageDiagramGeometry.bounds(of: $0, in: value.diagrams)
        }
        if let drawing = nativeDrawing(value) {
            rectangles += drawing.strokes.enumerated().filter { selected == nil || selected!.nativeStrokes.contains($0.offset) }.map { $0.element.renderBounds }
        }
        if let selected { rectangles += selected.textRanges.compactMap { bodyRect(range: $0) } }
        return rectangles.filter { !$0.isNull && !$0.isInfinite }.reduce(nil) { $0?.union($1) ?? $1 }
    }

    func preview(_ value: PageContent) { transientContent = value; onRender?(value) }
    func cancelPreview() { transientContent = nil; onRender?(content) }

    @discardableResult
    func commit(_ value: PageContent, previous: PageContent? = nil, action: String) -> Bool {
        let before = previous ?? content
        if history.isRejectingRemainingActions {
            // Stop at the first rejected snapshot. Later callbacks in this
            // native group must not jump across it to an unrelated older state.
            history.retainRejectedAction(withTarget: self, actionName: action) {
                $0.commit(value, previous: before, action: action)
            }
            cancelPreview()
            return false
        }
        guard value != before else { cancelPreview(); return false }
        // Reject the whole transaction before history, view or persisted data
        // change. A failed native conversion must never become empty ink.
        func reject() -> Bool {
            history.retainRejectedAction(withTarget: self, actionName: action) { target in
                target.commit(value, previous: before, action: action)
            }
            cancelPreview()
            return false
        }
        guard (try? InkGeometryLimits.validate(value.strokes)) != nil,
              (try? PageImageLimits.validate(value.images)) != nil,
              (try? PageDiagramLimits.validate(value.diagrams)) != nil else { NSSound.beep(); return reject() }
        if value.pencilKitData != nil, nativeDrawing(value) == nil { NSSound.beep(); return reject() }
        guard onValidate?(value) != false else { return reject() }
        let needsGroup = history.groupingLevel == 0
        if needsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { target in target.commit(before, previous: value, action: action) }
        history.setActionName(action)
        if needsGroup { history.endUndoGrouping() }
        transientContent = nil
        content = value
        isApplying = true
        onRender?(value)
        onCommit?(value)
        isApplying = false
        page?.selectionView.needsDisplay = true
        return true
    }

    func perform(_ command: PageSelectionCommand) {
        guard let page, page.inkView.isInputEnabled else { return }
        let hadToolIndependentSelection = hasToolIndependentSelection
        if command == .paste {
            let board = NSPasteboard.general
            if let data = board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.pasteboardType))
                ?? board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.imagePasteboardType))
                ?? board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.legacyPasteboardType)) {
                guard let payload = try? PageClipboardPayload.decodeValidated(data) else { NSSound.beep(); return }
                if payload.images.isEmpty && payload.diagrams.isEmpty, page.activeTool == .text,
                   let editor = page.window?.firstResponder as? NSTextView,
                   editor === page.textView || page.textBoxViews.values.contains(where: { $0.editor === editor }) {
                    // Native text paste uses the RTF/string fallback at the caret.
                    // The text-view page-paste hook declines image-free payloads.
                    editor.paste(nil)
                    return
                }
                paste(payload, offset: 20, action: "Paste Selection")
                if page.activeTool != .text || payload.images.isEmpty || !payload.diagrams.isEmpty {
                    page.window?.makeFirstResponder(page.selectionView)
                }
                page.selectionView.needsDisplay = true
                return
            }
            if pasteImage(from: board) { return }
        }
        if page.activeTool == .text, let editor = page.window?.firstResponder as? NSTextView,
           editor === page.textView || page.textBoxViews.values.contains(where: { $0.editor === editor }) {
            switch command {
            case .copy: editor.copy(nil); return
            case .cut: editor.cut(nil); return
            case .paste: editor.paste(nil); return
            case .delete: editor.delete(nil); return
            case .undo: editor.undoManager?.undo(); return
            case .redo: editor.undoManager?.redo(); return
            default: break
            }
        }
        switch command {
        case .undo: history.undo()
        case .redo: history.redo()
        case .clear: cancelPreview(); selection = MacPageSelection()
        case .selectAll:
            page.textView.breakUndoCoalescing()
            for box in page.textBoxViews.values { box.editor.breakUndoCoalescing() }
            // Resigning the native editor can commit marked/composed text and
            // update content. Select only after it accepts the focus change.
            if let window = page.window, !window.makeFirstResponder(page.selectionView) { return }
            hasToolIndependentSelection = page.activeTool != .select && page.activeTool != .lasso
            selection = MacPageSelection(strokes: Set(content.strokes.map(\.id)), nativeStrokes: Set(nativeDrawing(content)?.strokes.indices ?? 0..<0),
                                         textBoxes: Set(content.textBoxes.map(\.id)), equations: Set(content.equations.map(\.id)),
                                         images: Set(content.images.map(\.id)), diagrams: Set(content.diagrams.map(\.id)),
                                         textRanges: content.text.isEmpty ? [] : [NSRange(location: 0, length: (content.text as NSString).length)])
        case .copy: copySelection()
        case .cut: if copySelection() { deleteSelection() }
        case .delete: deleteSelection()
        case .duplicate: if let payload = clipboardPayload() { paste(payload, offset: 20, action: "Duplicate Selection") }
        case .paste:
            let board = NSPasteboard.general
            if let text = board.string(forType: .string), text.utf8.count <= PageClipboardPayload.maximumBytes {
                let box = PageTextBox(x: 80, y: 80, width: 500, text: text)
                paste(PageClipboardPayload(textBoxes: [box]), offset: 0, action: "Paste Text")
            }
        }
        if selection.isEmpty { hasToolIndependentSelection = false }
        if hadToolIndependentSelection && selection.isEmpty {
            page.focus(tool: page.activeTool)
        } else {
            page.window?.makeFirstResponder(page.selectionView)
        }
        page.selectionView.needsDisplay = true
    }

    @discardableResult func copySelection(to board: NSPasteboard = .general) -> Bool {
        guard let payload = clipboardPayload(), let data = try? JSONEncoder().encode(payload), data.count <= PageClipboardPayload.maximumBytes else { return false }
        board.clearContents()
        board.setData(data, forType: NSPasteboard.PasteboardType(PageClipboardPayload.pasteboardType))
        if payload.diagrams.isEmpty {
            board.setData(data, forType: NSPasteboard.PasteboardType(PageClipboardPayload.imagePasteboardType))
        }
        if payload.images.isEmpty && payload.diagrams.isEmpty {
            board.setData(data, forType: NSPasteboard.PasteboardType(PageClipboardPayload.legacyPasteboardType))
        } else if payload.diagrams.isEmpty && payload.images.count == 1, payload.strokes.isEmpty, payload.pencilKitData == nil,
                  payload.textBoxes.isEmpty, payload.equations.isEmpty, payload.text.isEmpty {
            board.setData(payload.images[0].imageData, forType: .png)
        }
        let fallback = NSMutableAttributedString(attributedString: attributed(text: payload.text, data: payload.rtfData))
        for label in payload.diagrams.map(\.plainText) where !label.isEmpty {
            if fallback.length > 0 { fallback.append(NSAttributedString(string: "\n")) }
            fallback.append(NSAttributedString(string: label))
        }
        board.setString(fallback.string, forType: .string)
        if let rich = rtf(fallback) { board.setData(rich, forType: .rtf) }
        return true
    }

    func clipboardPayload() -> PageClipboardPayload? {
        guard !selection.isEmpty else { return nil }
        if content.pencilKitData != nil, nativeDrawing(content) == nil { return nil }
        let promoted = promotedContent()
        let boxes = promoted.0.textBoxes.filter { promoted.1.textBoxes.contains($0.id) }
        let text = NSMutableAttributedString(string: "")
        for box in boxes.sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(attributed(text: box.text, data: box.rtfData))
        }
        let equations = content.equations.filter { selection.equations.contains($0.id) }
        let plain = ([text.string] + equations.map(\.latex)).filter { !$0.isEmpty }.joined(separator: "\n")
        var ink = content.strokes.filter { selection.strokes.contains($0.id) }
        var native: Data?
        if let drawing = nativeDrawing(content), !selection.nativeStrokes.isEmpty {
            let selected = PKDrawing(strokes: drawing.strokes.enumerated().filter { selection.nativeStrokes.contains($0.offset) }.map(\.element))
            guard let portable = try? PortableInkConverter.validatedStrokes(from: selected) else { return nil }
            native = selected.dataRepresentation(); ink = portable
        }
        let diagrams = content.diagrams.filter { selection.diagrams.contains($0.id) }
        let identities = Dictionary(uniqueKeysWithValues: diagrams.map { ($0.id, $0.id) })
        let copiedDiagrams = PageDiagramGeometry.remapped(diagrams, mapping: identities, resolvingIn: content.diagrams)
        return PageClipboardPayload(text: plain, rtfData: rtf(text), strokes: ink, pencilKitData: native, textBoxes: boxes, equations: equations, images: content.images.filter { selection.images.contains($0.id) }, diagrams: copiedDiagrams)
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        if content.pencilKitData != nil, nativeDrawing(content) == nil { NSSound.beep(); return }
        var value = content
        value.strokes.removeAll { selection.strokes.contains($0.id) }
        if let drawing = nativeDrawing(content), !selection.nativeStrokes.isEmpty {
            let native = PKDrawing(strokes: drawing.strokes.enumerated().filter { !selection.nativeStrokes.contains($0.offset) }.map(\.element))
            guard let portable = try? PortableInkConverter.validatedStrokes(from: native) else { NSSound.beep(); return }
            value.pencilKitData = native.dataRepresentation(); value.strokes = portable
        }
        value.textBoxes.removeAll { selection.textBoxes.contains($0.id) }
        value.equations.removeAll { selection.equations.contains($0.id) }
        value.images.removeAll { selection.images.contains($0.id) }
        value.diagrams = PageDiagramGeometry.removing(ids: selection.diagrams, from: value.diagrams)
        if !selection.textRanges.isEmpty {
            let body = NSMutableAttributedString(attributedString: canonicalBody())
            for range in selection.textRanges.reversed() where NSMaxRange(range) <= body.length { body.deleteCharacters(in: range) }
            value.text = body.string; value.rtfData = rtf(body)
        }
        if commit(value, action: "Delete Selection") { selection = MacPageSelection() }
    }

    func paste(_ payload: PageClipboardPayload, offset: Double, action: String) {
        do { try PageDiagramLimits.validate(payload.diagrams) }
        catch {
            onPasteError?(error.localizedDescription)
            NSSound.beep()
            return
        }
        let nativeAddition: PKDrawing?
        if content.pencilKitData != nil || payload.pencilKitData != nil {
            guard let drawing = try? PortableInkConverter.validatedClipboardDrawing(payload.pencilKitData, fallback: payload.strokes) else { NSSound.beep(); return }
            nativeAddition = drawing
        } else { nativeAddition = nil }
        let containsTypedText = !payload.textBoxes.isEmpty || (!payload.text.isEmpty && payload.equations.isEmpty && payload.diagrams.isEmpty)
        let offset = page?.paperView.paper == .ruled && containsTypedText && offset > 0 ? Double(RuledTextLayout.spacing) : offset
        var payloadContent = PageContent(strokes: payload.strokes, pencilKitData: payload.pencilKitData, textBoxes: payload.textBoxes, equations: payload.equations, images: payload.images, diagrams: payload.diagrams)
        if payload.textBoxes.isEmpty && payload.equations.isEmpty && payload.diagrams.isEmpty && !payload.text.isEmpty { payloadContent.textBoxes = [PageTextBox(x: 80, y: 80, width: 500, text: payload.text)] }
        let horizontal = horizontalBounds(payloadContent)
        let paperWidth = Double(page?.bounds.width ?? InkExport.paperSize.width)
        guard (horizontal?.width ?? 0) <= paperWidth else { NSSound.beep(); return }
        let offsetX = max(-Double(horizontal?.minX ?? 0), min(paperWidth - Double(horizontal?.maxX ?? 0), offset))
        var value = content, selected = MacPageSelection()
        for var stroke in payload.strokes {
            stroke.id = UUID(); stroke = PageSelectionGeometry.translated(stroke, dx: offsetX, dy: offset)
            value.strokes.append(stroke); selected.strokes.insert(stroke.id)
        }
        if let addition = nativeAddition {
            guard let before = try? PortableInkConverter.validatedDrawing(content.pencilKitData, fallback: content.strokes) else { NSSound.beep(); return }
            let moved = addition.strokes.map { stroke -> PKStroke in
                let transform = stroke.transform.concatenating(CGAffineTransform(translationX: offsetX, y: offset))
                #if compiler(>=6.4)
                if #available(macOS 27, *) {
                    return PKStroke(ink: stroke.ink, path: stroke.path, transform: transform, mask: stroke.mask,
                                    randomSeed: stroke.randomSeed, id: UUID(), renderGroupID: stroke.renderGroupID,
                                    renderState: stroke.renderState)
                }
                #endif
                return PKStroke(ink: stroke.ink, path: stroke.path, transform: transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
            }
            let combined = PKDrawing(strokes: before.strokes + moved)
            guard let portable = try? PortableInkConverter.validatedStrokes(from: combined) else { NSSound.beep(); return }
            value.pencilKitData = combined.dataRepresentation(); value.strokes = portable
            selected.nativeStrokes = Set(before.strokes.count..<combined.strokes.count)
            selected.strokes = Set(value.strokes.suffix(payload.strokes.count).map(\.id))
        }
        for var box in payload.textBoxes {
            box.id = UUID(); box.x += offsetX; box.y = max(0, min(100_000, box.y + offset))
            value.textBoxes.append(box); selected.textBoxes.insert(box.id)
        }
        if payload.textBoxes.isEmpty && payload.equations.isEmpty && payload.diagrams.isEmpty && !payload.text.isEmpty {
            let box = PageTextBox(x: 80 + offsetX, y: 80 + offset, width: 500, text: payload.text, rtfData: payload.rtfData)
            value.textBoxes.append(box); selected.textBoxes.insert(box.id)
        }
        for var equation in payload.equations {
            equation.id = UUID(); equation.x += offsetX; equation.y = max(0, min(100_000, equation.y + offset))
            value.equations.append(equation); selected.equations.insert(equation.id)
        }
        for var image in payload.images {
            image.id = UUID(); image.x += offsetX; image.y += offset
            value.images.append(image); selected.images.insert(image.id)
        }
        let mapping = Dictionary(uniqueKeysWithValues: payload.diagrams.map { ($0.id, UUID()) })
        let diagrams = PageDiagramGeometry.remapped(payload.diagrams, mapping: mapping, dx: offsetX, dy: offset)
        value.diagrams.append(contentsOf: diagrams)
        selected.diagrams = Set(diagrams.map(\.id))
        // Validate the resulting page too: multiple individually bounded pastes
        // must not bypass the archive's aggregate object and byte limits.
        let candidate = PageClipboardPayload(text: value.text, rtfData: value.rtfData, strokes: value.strokes, pencilKitData: value.pencilKitData, textBoxes: value.textBoxes, equations: value.equations, images: value.images, diagrams: value.diagrams)
        do { try candidate.validatePageContent() }
        catch {
            onPasteError?(error.localizedDescription)
            NSSound.beep()
            return
        }
        if commit(value, action: action) { selection = selected }
    }

    private func nativeDrawing(_ content: PageContent) -> PKDrawing? {
        guard content.pencilKitData != nil else { return nil }
        return try? PortableInkConverter.validatedDrawing(content.pencilKitData, fallback: content.strokes)
    }

    private func canonicalBody() -> NSAttributedString {
        if let page, page.textView.string == content.text { return ThemeTextAttributes.canonical(page.textView.attributedString(), theme: page.theme) }
        return attributed(text: content.text, data: content.rtfData)
    }

    private func attributed(text: String, data: Data?) -> NSAttributedString {
        if let data, let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil), value.string == text { return value }
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: ThemeTextAttributes.color(PageTheme.light.textHex)])
    }

    private func rtf(_ text: NSAttributedString) -> Data? { try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) }

    func bodyRect(range: NSRange) -> CGRect? {
        guard let page, let layout = page.textView.layoutManager, let container = page.textView.textContainer,
              NSMaxRange(range) <= (page.textView.string as NSString).length, range.length > 0 else { return nil }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.offsetBy(dx: page.textView.frame.minX + page.textView.textContainerOrigin.x,
                             dy: page.textView.frame.minY + page.textView.textContainerOrigin.y)
    }

    private func bodyRanges(polygon: [InkPoint]) -> [NSRange] {
        guard let page, let layout = page.textView.layoutManager, let container = page.textView.textContainer,
              let bounds = PageSelectionGeometry.bounds(of: polygon) else { return [] }
        layout.ensureLayout(for: container)
        let origin = NSPoint(x: page.textView.frame.minX + page.textView.textContainerOrigin.x,
                             y: page.textView.frame.minY + page.textView.textContainerOrigin.y)
        let local = bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let candidates = layout.glyphRange(forBoundingRect: local, in: container)
        let characters = layout.characterRange(forGlyphRange: candidates, actualGlyphRange: nil)
        let text = page.textView.string as NSString
        var result: [NSRange] = [], index = characters.location
        while index < min(text.length, NSMaxRange(characters)) {
            let range = text.rangeOfComposedCharacterSequence(at: index)
            // A paragraph terminator's glyph rectangle may span the rest of
            // the text container. Select visible glyphs, not that empty tail.
            if text.substring(with: range).rangeOfCharacter(from: .newlines) != nil { index = NSMaxRange(range); continue }
            let glyph = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: origin.x, dy: origin.y)
            if PageSelectionGeometry.intersects(rect: rect, polygon: polygon) { result.append(range) }
            index = NSMaxRange(range)
        }
        return merged(result)
    }

    private func merged(_ values: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in values.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, NSMaxRange(last) >= range.location { result[result.count - 1] = NSUnionRange(last, range) }
            else { result.append(range) }
        }
        return result
    }
}

@MainActor
final class MacPageSelectionView: NSView {
    weak var controller: MacPageSelectionController?
    var polygon: [InkPoint] = []
    private var start: InkPoint?
    private var moving = false
    private var resizingImageID: UUID?
    private var resizingDiagramID: UUID?
    private var reconnectingDiagram: (id: UUID, starting: Bool)?
    private var creatingDiagramID: UUID?
    private var before: PageContent?
    private var moveBase: PageContent?
    private var moveSelection = MacPageSelection()
    private var lastPreview: PageContent?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { controller?.history }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Shared page selection")
        setAccessibilityHelp("Drag a rectangle or lasso around text, images and handwriting, then drag the selection to move it. Drag the lower-right handle of a selected image, shape or table to resize it, or an arrow endpoint to reconnect it. Double-click a shape label or table cell to edit its text. Copy, cut, paste, delete and undo work on the whole selection.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func resetCursorRects() {
        guard let tool = controller?.page?.activeTool, tool == .select || tool == .lasso || tool == .diagram else { return }
        addCursorRect(bounds, cursor: tool == .select ? .arrow : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, controller.page?.inkView.isInputEnabled == true else { return }
        let point = pagePoint(event)
        if controller.page?.activeTool == .diagram {
            controller.clearToolIndependentSelection()
            window?.makeFirstResponder(self)
            start = point; before = controller.content; creatingDiagramID = UUID()
            resizingImageID = nil; resizingDiagramID = nil; reconnectingDiagram = nil; moving = false
            polygon = []; moveBase = nil; lastPreview = nil
            return
        }
        if event.clickCount == 2, let page = controller.page {
            if let equation = controller.content.equations.reversed().first(where: { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(CGPoint(x: point.x, y: point.y)) }) {
                controller.onEquationEdit?(equation); return
            }
            if let diagram = controller.content.diagrams.reversed().first(where: {
                page.diagramView.hitTestDiagram($0, at: point, in: controller.content.diagrams)
            }) {
                controller.requestDiagramTextEdit(id: diagram.id, at: point); return
            }
            if let box = controller.content.textBoxes.reversed().first(where: { page.textBoxViews[$0.id]?.frame.contains(CGPoint(x: point.x, y: point.y)) == true }), let view = page.textBoxViews[box.id] {
                // Explicit double-click editing selects Text in the toolbar
                // too, so subsequent model refreshes keep this editor active.
                page.activeTool = .text
                ToolShortcuts.activate(.text)
                window?.makeFirstResponder(view.editor)
                view.editor.setSelectedRange(NSRange(location: 0, length: (view.editor.string as NSString).length))
                return
            }
        }
        window?.makeFirstResponder(self)
        start = point; before = controller.content; moveBase = nil; lastPreview = nil
        resizingImageID = nil; resizingDiagramID = nil; reconnectingDiagram = nil; creatingDiagramID = nil
        if let id = controller.singleSelectedDiagramID,
           let diagram = controller.content.diagrams.first(where: { $0.id == id }) {
            if diagram.kind == .connector {
                let ends = PageDiagramGeometry.resolvedEndpoints(for: diagram, in: controller.content.diagrams)
                let tolerance = 10 / Double(controller.page?.enclosingScrollView?.magnification ?? 1)
                if hypot(point.x - ends.start.x, point.y - ends.start.y) <= tolerance { reconnectingDiagram = (id, true) }
                else if hypot(point.x - ends.end.x, point.y - ends.end.y) <= tolerance { reconnectingDiagram = (id, false) }
            } else {
                let bounds = PageDiagramGeometry.bounds(of: diagram, in: controller.content.diagrams)
                if CGRect(x: bounds.maxX - 3, y: bounds.maxY - 3, width: 16, height: 16).contains(CGPoint(x: point.x, y: point.y)) { resizingDiagramID = id }
            }
        }
        if let id = controller.singleSelectedImageID, let bounds = controller.selectionBounds() {
            let handle = CGRect(x: bounds.maxX - 3, y: bounds.maxY - 3, width: 16, height: 16)
            if handle.contains(CGPoint(x: point.x, y: point.y)) { resizingImageID = id }
        }
        moving = resizingImageID == nil && resizingDiagramID == nil && reconnectingDiagram == nil && !controller.selection.isEmpty && controller.selectionBounds()?.insetBy(dx: -5, dy: -5).contains(CGPoint(x: point.x, y: point.y)) == true
        if !moving && resizingImageID == nil && resizingDiagramID == nil && reconnectingDiagram == nil { polygon = [point]; if !event.modifierFlags.contains(.shift) { controller.selection = MacPageSelection() } }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let controller else { return }
        let point = pagePoint(event)
        if let id = creatingDiagramID, let before {
            let value = controller.diagramCandidate(from: start, to: point, id: id, base: before)
            lastPreview = value; controller.preview(value)
        } else if let reconnectingDiagram, let before {
            let value = controller.reconnectedDiagram(before, id: reconnectingDiagram.id, starting: reconnectingDiagram.starting, point: point)
            lastPreview = value; controller.preview(value)
        } else if let id = resizingDiagramID, let before,
                  let diagram = before.diagrams.first(where: { $0.id == id }) {
            let value = controller.resizedDiagram(before, id: id, width: diagram.width + point.x - start.x, height: diagram.height + point.y - start.y)
            lastPreview = value; controller.preview(value)
        } else if let id = resizingImageID, let before,
           let image = before.images.first(where: { $0.id == id }) {
            let ratio = image.height / image.width
            let delta = ((point.x - start.x) + (point.y - start.y) * ratio) / (1 + ratio * ratio)
            let value = controller.resizedImage(before, id: id, width: image.width + delta)
            lastPreview = value; controller.preview(value)
        } else if moving {
            guard hypot(point.x - start.x, point.y - start.y) >= 2 else { return }
            if moveBase == nil {
                guard controller.canMoveSelection() else { return }
                (moveBase, moveSelection) = controller.promotedContent()
            }
            guard let moveBase else { return }
            controller.selection = moveSelection
            let value = controller.translated(moveBase, selection: moveSelection, dx: point.x - start.x, dy: point.y - start.y)
            lastPreview = value; controller.preview(value)
        } else if controller.page?.activeTool == .lasso {
            if let last = polygon.last, hypot(point.x - last.x, point.y - last.y) >= 2, polygon.count < 2_048 { polygon.append(point) }
        } else { polygon = PageSelectionGeometry.rectangle(from: start, to: point) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start, let controller else { return }
        let end = pagePoint(event)
        if let id = creatingDiagramID, let before {
            let value = controller.diagramCandidate(from: start, to: end, id: id, base: before)
            if controller.commit(value, previous: before, action: "Insert Diagram") { controller.selection = MacPageSelection(diagrams: [id]) }
        } else if reconnectingDiagram != nil {
            if let value = lastPreview, let before { controller.commit(value, previous: before, action: "Reconnect Arrow") }
        } else if resizingDiagramID != nil {
            if let value = lastPreview, let before { controller.commit(value, previous: before, action: "Resize Diagram") }
        } else if resizingImageID != nil {
            if let value = lastPreview, let before { controller.commit(value, previous: before, action: "Resize Image") }
        } else if moving {
            if let value = lastPreview, let before {
                controller.selection = moveSelection
                controller.commit(value, previous: before, action: "Move Selection")
            }
        } else if hypot(end.x - start.x, end.y - start.y) < 4 { controller.select(at: end, extending: event.modifierFlags.contains(.shift)) }
        else { controller.select(polygon: polygon, extending: event.modifierFlags.contains(.shift)) }
        self.start = nil; before = nil; moveBase = nil; lastPreview = nil; polygon = []; moving = false; resizingImageID = nil; resizingDiagramID = nil; reconnectingDiagram = nil; creatingDiagramID = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        NSColor.controlAccentColor.setStroke()
        if controller.page?.activeTool == .diagram && controller.page?.diagramOptions.kind == .connector {
            for diagram in controller.content.diagrams where diagram.kind != .connector {
                for side in PageDiagram.AnchorSide.allCases {
                    let point = PageDiagramGeometry.anchorPoint(on: diagram, side: side)
                    NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
                    NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
                }
            }
        }
        if let id = controller.singleSelectedDiagramID,
           let diagram = (lastPreview ?? controller.content).diagrams.first(where: { $0.id == id && $0.kind == .connector }) {
            let endpoints = PageDiagramGeometry.resolvedEndpoints(for: diagram, in: (lastPreview ?? controller.content).diagrams)
            for point in [endpoints.start, endpoints.end] {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).fill()
            }
        }
        if polygon.count > 1 {
            let path = NSBezierPath(); path.move(to: NSPoint(x: polygon[0].x, y: polygon[0].y))
            for point in polygon.dropFirst() { path.line(to: NSPoint(x: point.x, y: point.y)) }
            path.close(); path.lineWidth = 1.5; path.setLineDash([5, 3], count: 2, phase: 0); path.stroke()
        }
        if let bounds = controller.selectionBounds(), !controller.selection.isEmpty {
            let rect = bounds.insetBy(dx: -5, dy: -5)
            NSColor.controlAccentColor.withAlphaComponent(0.09).setFill(); rect.fill()
            let path = NSBezierPath(rect: rect); path.lineWidth = 1.5; path.setLineDash([5, 3], count: 2, phase: 0); path.stroke()
            for point in [rect.origin, NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)] {
                NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if [51,117].contains(event.keyCode) { controller?.perform(.delete) }
        else if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) {
        controller?.perform(.clear)
        start = nil; before = nil; moveBase = nil; lastPreview = nil; polygon = []; moving = false; resizingImageID = nil; resizingDiagramID = nil; reconnectingDiagram = nil; creatingDiagramID = nil
        needsDisplay = true
    }
    @objc func copy(_ sender: Any?) { controller?.perform(.copy) }
    @objc func cut(_ sender: Any?) { controller?.perform(.cut) }
    @objc func paste(_ sender: Any?) { controller?.perform(.paste) }
    override func selectAll(_ sender: Any?) { controller?.perform(.selectAll) }
    @objc func delete(_ sender: Any?) { controller?.perform(.delete) }
    @objc func undo(_ sender: Any?) { controller?.history.undo() }
    @objc func redo(_ sender: Any?) { controller?.history.redo() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, command) in [("Copy",PageSelectionCommand.copy),("Cut",.cut),("Paste",.paste),("Duplicate",.duplicate),("Delete",.delete),("Select All",.selectAll)] {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command; menu.addItem(item)
        }
        if controller?.singleSelectedImageID != nil {
            menu.addItem(.separator())
            for (title, scale) in [("Make Image Larger", 1.25), ("Make Image Smaller", 0.8)] {
                let item = NSMenuItem(title: title, action: #selector(resizeImageCommand(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = scale; menu.addItem(item)
            }
        }
        return menu
    }
    @objc private func resizeImageCommand(_ sender: NSMenuItem) {
        guard let controller, let id = controller.singleSelectedImageID,
              let image = controller.content.images.first(where: { $0.id == id }),
              let scale = sender.representedObject as? Double else { return }
        controller.commit(controller.resizedImage(controller.content, id: id, width: image.width * scale), action: "Resize Image")
    }
    @objc private func menuCommand(_ sender: NSMenuItem) { if let command = sender.representedObject as? PageSelectionCommand { controller?.perform(command) } }
    private func pagePoint(_ event: NSEvent) -> InkPoint { let point = convert(event.locationInWindow, from: nil); return InkPoint(x: point.x, y: point.y) }
}
#endif
