#if os(iOS)
import UIKit
import SwiftUI
import PencilKit
import NotesCore

struct IOSPageSelection {
    var strokes = Set<UUID>()
    var nativeStrokes = Set<Int>()
    var textBoxes = Set<UUID>()
    var equations = Set<UUID>()
    var textRanges: [NSRange] = []
    var isEmpty: Bool { strokes.isEmpty && nativeStrokes.isEmpty && textBoxes.isEmpty && equations.isEmpty && textRanges.isEmpty }
}

@MainActor
final class IOSPageSelectionController: NSObject {
    weak var page: UnifiedPencilPage?
    var content = PageContent()
    var selection = IOSPageSelection()
    var onRender: ((PageContent) -> Void)?
    var onCommit: ((PageContent) -> Void)?
    var onEquationEdit: ((NoteEquation) -> Void)?
    let history = UndoManager()
    private var observer: NSObjectProtocol?
    private var isApplying = false
    private var transientContent: PageContent?
    var displayedContent: PageContent { transientContent ?? content }
    var hasPreview: Bool { transientContent != nil }

    override init() {
        super.init()
        history.groupsByEvent = false
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
        selection = IOSPageSelection()
        history.removeAllActions()
        page?.selectionView.setNeedsDisplay()
    }

    func select(polygon: [InkPoint], extending: Bool = false) {
        guard let page else { return }
        var value = extending ? selection : IOSPageSelection()
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
        value.textRanges = merged(value.textRanges + bodyRanges(polygon: polygon))
        selection = value
        page.selectionView.setNeedsDisplay()
    }

    func select(at point: InkPoint, extending: Bool = false) {
        guard let page else { return }
        var value = extending ? selection : IOSPageSelection()
        // The last-drawn ink is on top, matching the page's actual hit order.
        if let stroke = content.strokes.reversed().first(where: { PageSelectionGeometry.hits(stroke: $0, at: point) }) {
            value.strokes.insert(stroke.id)
            if let drawing = nativeDrawing(content) {
                for (index, native) in drawing.strokes.enumerated() where PortableInkConverter.strokes(from: PKDrawing(strokes: [native])).contains(where: { PageSelectionGeometry.hits(stroke: $0, at: point) }) {
                    value.nativeStrokes.insert(index)
                }
            }
        } else if let box = content.textBoxes.reversed().first(where: { page.textBoxViews[$0.id]?.frame.contains(CGPoint(x: point.x, y: point.y)) == true }) {
            value.textBoxes.insert(box.id)
        } else if let equation = content.equations.reversed().first(where: { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(CGPoint(x: point.x, y: point.y)) }) {
            value.equations.insert(equation.id)
        } else {
            let polygon = PageSelectionGeometry.rectangle(from: InkPoint(x: point.x - 2, y: point.y - 2), to: InkPoint(x: point.x + 2, y: point.y + 2))
            let hits = bodyRanges(polygon: polygon)
            if let hit = hits.first, hit.location < (content.text as NSString).length {
                var word = hit
                if let position = page.textView.position(from: page.textView.beginningOfDocument, offset: hit.location),
                   let range = page.textView.tokenizer.rangeEnclosingPosition(position, with: .word,
                       inDirection: UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)) {
                    word = NSRange(location: page.textView.offset(from: page.textView.beginningOfDocument, to: range.start),
                                   length: page.textView.offset(from: range.start, to: range.end))
                }
                value.textRanges = merged(value.textRanges + [word])
            }
        }
        selection = value
        page.selectionView.setNeedsDisplay()
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
        rectangles += selection.textRanges.compactMap { bodyRect(range: $0) }
        return rectangles.reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// Convert only the selected text runs into movable rich-text objects. The
    /// original body and the new objects enter one transaction and one undo.
    func promotedContent() -> (PageContent, IOSPageSelection) {
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

    func translated(_ base: PageContent, selection selected: IOSPageSelection, dx: Double, dy: Double) -> PageContent {
        guard dx.isFinite, dy.isFinite else { return base }
        let ruledText = page?.paper.style == .ruled && (!selected.textBoxes.isEmpty || !selected.textRanges.isEmpty)
        let desiredDy = ruledText ? (dy / 28).rounded() * 28 : dy
        guard let bounds = objectBounds(base, selected: selected), bounds.width <= paperWidth else { return base }
        let dx = max(-bounds.minX, min(paperWidth - bounds.maxX, dx))
        let minimumDy = -bounds.minY, maximumDy = 100_000 - bounds.maxY
        let dy = ruledText
            ? max(ceil(minimumDy / 28) * 28, min(floor(maximumDy / 28) * 28, desiredDy))
            : max(minimumDy, min(maximumDy, desiredDy))
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
            guard let portable = try? PortableInkConverter.validatedStrokes(from: native) else { return base }
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
        return result
    }

    func preview(_ value: PageContent) { transientContent = value; onRender?(value) }

    func cancelPreview() { transientContent = nil; onRender?(content); page?.selectionView.setNeedsDisplay() }

    func commit(_ value: PageContent, previous: PageContent? = nil, action: String) {
        let before = previous ?? content
        guard value != before else { cancelPreview(); return }
        clearNativeUndo()
        let needsGroup = history.groupingLevel == 0
        if needsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { target in target.commit(before, previous: value, action: action) }
        history.setActionName(action)
        if needsGroup { history.endUndoGrouping() }
        transientContent = nil
        content = value
        isApplying = true
        onRender?(value)
        clearNativeUndo()
        onCommit?(value)
        isApplying = false
        page?.selectionView.setNeedsDisplay()
    }

    private func clearNativeUndo() {
        guard let page else { return }
        let managers = [page.textView.undoManager, page.canvas.undoManager] + page.textBoxViews.values.map { $0.editor.undoManager }
        for manager in managers.compactMap({ $0 }) where manager !== history { manager.removeAllActions() }
    }

    func perform(_ command: PageSelectionCommand) {
        guard let page, page.isUserInteractionEnabled else { return }
        if page.textToolSelected, let editor = page.activeTextView {
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
        case .clear: cancelPreview(); selection = IOSPageSelection()
        case .selectAll:
            selection = IOSPageSelection(strokes: Set(content.strokes.map(\.id)), nativeStrokes: Set(nativeDrawing(content)?.strokes.indices ?? 0..<0),
                                         textBoxes: Set(content.textBoxes.map(\.id)), equations: Set(content.equations.map(\.id)),
                                         textRanges: content.text.isEmpty ? [] : [NSRange(location: 0, length: (content.text as NSString).length)])
        case .copy: copySelection()
        case .cut: if copySelection() { deleteSelection() }
        case .delete: deleteSelection()
        case .duplicate: if let payload = clipboardPayload() { paste(payload, offset: 20, action: "Duplicate Selection") }
        case .paste:
            let board = UIPasteboard.general
            if let data = board.data(forPasteboardType: PageClipboardPayload.pasteboardType) {
                guard let value = try? PageClipboardPayload.decodeValidated(data) else { return }
                paste(value, offset: 20, action: "Paste Selection")
            } else if let text = board.string, text.utf8.count <= PageClipboardPayload.maximumBytes {
                let box = PageTextBox(x: 80, y: 80, width: 500, text: text)
                paste(PageClipboardPayload(textBoxes: [box]), offset: 0, action: "Paste Text")
            }
        }
        page.selectionView.becomeFirstResponder()
        page.selectionView.setNeedsDisplay()
    }

    @discardableResult private func copySelection() -> Bool {
        guard let payload = clipboardPayload(), let data = try? JSONEncoder().encode(payload), data.count <= PageClipboardPayload.maximumBytes else { return false }
        let board = UIPasteboard.general
        var item: [String: Any] = [PageClipboardPayload.pasteboardType: data, "public.utf8-plain-text": payload.text]
        if let rtfData = payload.rtfData { item["public.rtf"] = rtfData }
        board.setItems([item])
        return true
    }

    func clipboardPayload() -> PageClipboardPayload? {
        guard !selection.isEmpty else { return nil }
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
        return PageClipboardPayload(text: plain, rtfData: rtf(text), strokes: ink, pencilKitData: native, textBoxes: boxes, equations: equations)
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        var value = content
        value.strokes.removeAll { selection.strokes.contains($0.id) }
        if let drawing = nativeDrawing(content), !selection.nativeStrokes.isEmpty {
            let native = PKDrawing(strokes: drawing.strokes.enumerated().filter { !selection.nativeStrokes.contains($0.offset) }.map(\.element))
            guard let portable = try? PortableInkConverter.validatedStrokes(from: native) else { return }
            value.pencilKitData = native.dataRepresentation(); value.strokes = portable
        }
        value.textBoxes.removeAll { selection.textBoxes.contains($0.id) }
        value.equations.removeAll { selection.equations.contains($0.id) }
        if !selection.textRanges.isEmpty {
            let body = NSMutableAttributedString(attributedString: canonicalBody())
            for range in selection.textRanges.reversed() where NSMaxRange(range) <= body.length { body.deleteCharacters(in: range) }
            value.text = body.string; value.rtfData = rtf(body)
        }
        selection = IOSPageSelection()
        commit(value, action: "Delete Selection")
    }

    private func paste(_ payload: PageClipboardPayload, offset: Double, action: String) {
        guard (try? PortableInkConverter.validatedDrawing(content.pencilKitData, fallback: content.strokes)) != nil else { return }
        var payload = payload
        let nativeAddition: PKDrawing?
        if payload.pencilKitData != nil {
            guard let validated = try? PortableInkConverter.validatedClipboardDrawing(payload.pencilKitData, fallback: payload.strokes) else { return }
            nativeAddition = validated
        } else { nativeAddition = nil }
        if payload.textBoxes.isEmpty && payload.equations.isEmpty && !payload.text.isEmpty {
            payload.textBoxes = [PageTextBox(x: 80, y: 80, width: 500, text: payload.text, rtfData: payload.rtfData)]
        }
        let containsText = !payload.textBoxes.isEmpty || (payload.equations.isEmpty && !payload.text.isEmpty)
        let offset = offset != 0 && page?.paper.style == .ruled && containsText ? 28 : offset
        let payloadContent = PageContent(strokes: payload.strokes, pencilKitData: payload.pencilKitData,
                                         textBoxes: payload.textBoxes, equations: payload.equations)
        let payloadSelection = IOSPageSelection(strokes: Set(payload.strokes.map(\.id)),
            nativeStrokes: Set(nativeAddition?.strokes.indices ?? 0..<0), textBoxes: Set(payload.textBoxes.map(\.id)), equations: Set(payload.equations.map(\.id)))
        let payloadBounds = objectBounds(payloadContent, selected: payloadSelection, native: nativeAddition)
        if let payloadBounds, payloadBounds.width > paperWidth { return }
        let dx = payloadBounds.map { max(-$0.minX, min(paperWidth - $0.maxX, offset)) } ?? offset
        var value = content, selected = IOSPageSelection()
        for var stroke in payload.strokes {
            stroke.id = UUID(); stroke = PageSelectionGeometry.translated(stroke, dx: dx, dy: offset)
            value.strokes.append(stroke); selected.strokes.insert(stroke.id)
        }
        if (content.pencilKitData != nil || payload.pencilKitData != nil) && (!payload.strokes.isEmpty || payload.pencilKitData != nil) {
            let before = nativeDrawing(content) ?? PortableInkConverter.drawing(from: content.strokes)
            guard let addition = nativeAddition ?? (try? PortableInkConverter.validatedClipboardDrawing(nil, fallback: payload.strokes)) else { return }
            let moved = addition.strokes.map { stroke -> PKStroke in
                let transform = stroke.transform.concatenating(CGAffineTransform(translationX: dx, y: offset))
                #if compiler(>=6.4)
                if #available(iOS 27, *) {
                    return PKStroke(ink: stroke.ink, path: stroke.path, transform: transform, mask: stroke.mask,
                                    randomSeed: stroke.randomSeed, id: UUID(), renderGroupID: stroke.renderGroupID,
                                    renderState: stroke.renderState)
                }
                #endif
                return PKStroke(ink: stroke.ink, path: stroke.path, transform: transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
            }
            let combined = PKDrawing(strokes: before.strokes + moved)
            guard (try? PortableInkConverter.validateNativeDrawing(combined)) != nil else { return }
            guard let portable = try? PortableInkConverter.validatedStrokes(from: combined) else { return }
            value.pencilKitData = combined.dataRepresentation(); value.strokes = portable
            selected.nativeStrokes = Set(before.strokes.count..<combined.strokes.count)
            selected.strokes = Set(value.strokes.suffix(payload.strokes.count).map(\.id))
        }
        for var box in payload.textBoxes {
            box.id = UUID(); box.x += dx; box.y = max(0, min(100_000, box.y + offset))
            value.textBoxes.append(box); selected.textBoxes.insert(box.id)
        }
        for var equation in payload.equations {
            equation.id = UUID(); equation.x += dx; equation.y = max(0, min(100_000, equation.y + offset))
            value.equations.append(equation); selected.equations.insert(equation.id)
        }
        // Validate the resulting page too: multiple individually bounded pastes
        // must not bypass the archive's aggregate object and byte limits.
        let candidate = PageClipboardPayload(text: value.text, rtfData: value.rtfData, strokes: value.strokes, pencilKitData: value.pencilKitData, textBoxes: value.textBoxes, equations: value.equations)
        guard let encoded = try? JSONEncoder().encode(candidate), (try? PageClipboardPayload.decodeValidated(encoded)) != nil else { return }
        selection = selected
        commit(value, action: action)
    }

    private func nativeDrawing(_ content: PageContent) -> PKDrawing? {
        guard content.pencilKitData != nil else { return nil }
        return try? PortableInkConverter.validatedDrawing(content.pencilKitData, fallback: content.strokes)
    }

    private var paperWidth: CGFloat {
        let width = page?.bounds.width ?? 1600
        return width.isFinite && width > 0 ? width : 1600
    }

    private func objectBounds(_ value: PageContent, selected: IOSPageSelection, native: PKDrawing? = nil) -> CGRect? {
        var rectangles: [CGRect] = []
        for stroke in value.strokes where selected.strokes.contains(stroke.id) {
            if let bounds = PageSelectionGeometry.bounds(of: stroke.points, padding: max(1, stroke.width * stroke.style.widthMultiplier / 2)) { rectangles.append(bounds) }
        }
        if let drawing = native ?? nativeDrawing(value) {
            rectangles += drawing.strokes.enumerated().filter { selected.nativeStrokes.contains($0.offset) }.map { $0.element.renderBounds }
        }
        rectangles += value.textBoxes.filter { selected.textBoxes.contains($0.id) }.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: Double(page?.textBoxViews[$0.id]?.frame.height ?? 32))
        }
        rectangles += value.equations.filter { selected.equations.contains($0.id) }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return rectangles.filter { !$0.isNull && !$0.isInfinite && [$0.minX, $0.maxX, $0.minY, $0.maxY].allSatisfy(\.isFinite) }
            .reduce(nil) { $0?.union($1) ?? $1 }
    }

    private func canonicalBody() -> NSAttributedString {
        if let page, page.textView.text == content.text { return ThemeTextAttributes.canonical(page.textView.attributedText, theme: page.theme) }
        return attributed(text: content.text, data: content.rtfData)
    }

    private func attributed(text: String, data: Data?) -> NSAttributedString {
        if let data, let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil), value.string == text { return value }
        return NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: ThemeTextAttributes.color(PageTheme.light.textHex)])
    }

    private func rtf(_ text: NSAttributedString) -> Data? { try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) }

    func bodyRect(range: NSRange) -> CGRect? {
        guard let page, NSMaxRange(range) <= (page.textView.text as NSString).length, range.length > 0 else { return nil }
        let layout = page.textView.layoutManager, container = page.textView.textContainer
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.offsetBy(dx: page.textView.frame.minX + page.textView.textContainerInset.left,
                             dy: page.textView.frame.minY + page.textView.textContainerInset.top)
    }

    private func bodyRanges(polygon: [InkPoint]) -> [NSRange] {
        guard let page, let bounds = PageSelectionGeometry.bounds(of: polygon) else { return [] }
        let layout = page.textView.layoutManager, container = page.textView.textContainer
        layout.ensureLayout(for: container)
        let origin = CGPoint(x: page.textView.frame.minX + page.textView.textContainerInset.left,
                             y: page.textView.frame.minY + page.textView.textContainerInset.top)
        let local = bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let candidates = layout.glyphRange(forBoundingRect: local, in: container)
        let characters = layout.characterRange(forGlyphRange: candidates, actualGlyphRange: nil)
        let text = page.textView.text as NSString
        var result: [NSRange] = [], index = characters.location
        while index < min(text.length, NSMaxRange(characters)) {
            let range = text.rangeOfComposedCharacterSequence(at: index)
            if text.substring(with: range).rangeOfCharacter(from: .newlines) != nil {
                index = NSMaxRange(range)
                continue
            }
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
final class IOSPageSelectionView: UIView, UIContextMenuInteractionDelegate {
    weak var controller: IOSPageSelectionController?
    var tool: InkTool = .select
    private var polygon: [InkPoint] = []
    private var start: InkPoint?
    private var before: PageContent?
    private var moveBase: PageContent?
    private var moveSelection = IOSPageSelection()
    private var lastPreview: PageContent?
    private var beforeSelection: IOSPageSelection?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        addInteraction(UIContextMenuInteraction(delegate: self))
        accessibilityLabel = "Select text, handwriting, and equations on this page"
        accessibilityHint = "Drag to select. Drag a selected group to move it. Use two fingers to scroll."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { controller?.history }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard event?.allTouches?.filter({ $0.phase != .ended && $0.phase != .cancelled }).count ?? 1 == 1,
              let touch = touches.first, let controller else { cancelGesture(); return }
        controller.page?.endEditing(true)
        becomeFirstResponder()
        let point = pagePoint(touch)
        start = point
        before = controller.content
        beforeSelection = controller.selection
        if let bounds = controller.selectionBounds(), bounds.insetBy(dx: -8, dy: -8).contains(CGPoint(x: point.x, y: point.y)) {
            let promoted = controller.promotedContent()
            moveBase = promoted.0; moveSelection = promoted.1
            controller.selection = promoted.1
        } else {
            moveBase = nil
            polygon = [point]
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let start, let controller else { return }
        let point = pagePoint(touch)
        if let moveBase {
            let value = controller.translated(moveBase, selection: moveSelection, dx: point.x - start.x, dy: point.y - start.y)
            lastPreview = value
            controller.preview(value)
        } else if tool == .lasso {
            if polygon.count < 4096 { polygon.append(point) }
        } else { polygon = PageSelectionGeometry.rectangle(from: start, to: point) }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let start, let controller else { cancelGesture(); return }
        let point = pagePoint(touch)
        if moveBase != nil, let lastPreview, let before {
            controller.commit(lastPreview, previous: before, action: "Move Selection")
        } else if hypot(point.x - start.x, point.y - start.y) < 4 {
            controller.select(at: point)
        } else {
            if tool != .lasso { polygon = PageSelectionGeometry.rectangle(from: start, to: point) }
            else if polygon.count < 4096 { polygon.append(point) }
            controller.select(polygon: polygon)
        }
        resetGesture()
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelGesture() }
    private func cancelGesture() {
        if let beforeSelection { controller?.selection = beforeSelection }
        controller?.cancelPreview(); resetGesture(); setNeedsDisplay()
    }
    private func resetGesture() { start = nil; before = nil; moveBase = nil; lastPreview = nil; beforeSelection = nil; polygon = [] }
    private func pagePoint(_ touch: UITouch) -> InkPoint { let p = touch.location(in: self); return InkPoint(x: p.x, y: p.y) }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        if let bounds = controller?.selectionBounds(), !bounds.isNull, !bounds.isInfinite {
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.08).cgColor)
            context.fill(bounds.insetBy(dx: -4, dy: -4))
            context.stroke(bounds.insetBy(dx: -4, dy: -4))
        }
        if let first = polygon.first {
            context.move(to: CGPoint(x: first.x, y: first.y))
            for point in polygon.dropFirst() { context.addLine(to: CGPoint(x: point.x, y: point.y)) }
            if polygon.count > 2 { context.closePath() }
            context.strokePath()
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let controller else { return nil }
        if controller.selection.isEmpty { controller.select(at: InkPoint(x: location.x, y: location.y)) }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak controller] _ in
            let commands: [(String, PageSelectionCommand)] = [("Copy", .copy), ("Cut", .cut), ("Paste", .paste),
                ("Duplicate", .duplicate), ("Delete", .delete), ("Select All", .selectAll), ("Undo", .undo), ("Redo", .redo)]
            return UIMenu(children: commands.map { title, command in
                UIAction(title: title, attributes: command == .delete ? .destructive : []) { _ in controller?.perform(command) }
            })
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copy(_:))),
         UIKeyCommand(input: "x", modifierFlags: .command, action: #selector(cut(_:))),
         UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:))),
         UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll(_:))),
         UIKeyCommand(input: "d", modifierFlags: .command, action: #selector(duplicateSelection)),
         UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoSelection)),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoSelection)),
         UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(delete(_:))),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(clearSelection))]
    }
    override func copy(_ sender: Any?) { controller?.perform(.copy) }
    override func cut(_ sender: Any?) { controller?.perform(.cut) }
    override func paste(_ sender: Any?) { controller?.perform(.paste) }
    override func selectAll(_ sender: Any?) { controller?.perform(.selectAll) }
    override func delete(_ sender: Any?) { controller?.perform(.delete) }
    @objc private func duplicateSelection() { controller?.perform(.duplicate) }
    @objc private func undoSelection() { controller?.perform(.undo) }
    @objc private func redoSelection() { controller?.perform(.redo) }
    @objc private func clearSelection() { controller?.perform(.clear) }
}

@MainActor
final class IOSTextBoxView: UIView {
    let editor = UITextView()
    private let richText: RichTextEditor.Coordinator
    private var box: PageTextBox
    var onChange: ((PageTextBox) -> Void)?

    init(box: PageTextBox, theme: PageTheme) {
        self.box = box
        richText = RichTextEditor.Coordinator(RichTextEditor(text: .constant(box.text), rtfData: .constant(box.rtfData), theme: theme))
        super.init(frame: .zero)
        editor.backgroundColor = .clear
        editor.isOpaque = false
        editor.isScrollEnabled = false
        editor.allowsEditingTextAttributes = true
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.accessibilityLabel = "Movable page text"
        editor.delegate = richText
        addSubview(editor)
        configure(box: box, theme: theme, editable: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(box: PageTextBox, theme: PageTheme, editable: Bool, paper: InkPaper = .dotted) {
        self.box = box
        editor.isEditable = editable
        editor.isSelectable = editable
        editor.undoManager?.levelsOfUndo = 50
        editor.overrideUserInterfaceStyle = theme == .dark ? .dark : .light
        richText.parent = RichTextEditor(text: .constant(box.text), rtfData: .constant(box.rtfData), theme: theme, onChange: { [weak self] text, rtf in
            guard let self else { return }
            self.editor.undoManager?.levelsOfUndo = 50
            self.box.text = text; self.box.rtfData = rtf
            self.resize()
            self.onChange?(self.box)
        })
        if richText.lastText != box.text || richText.lastRTF != box.rtfData || richText.lastTheme != theme {
            richText.load(text: box.text, rtf: box.rtfData, into: editor)
        }
        RuledTextLayout.attach(to: editor, paper: paper, pageOriginY: CGFloat(box.y) + editor.frame.minY)
        resize()
    }

    func persistNativeUndo() { richText.textViewDidChange(editor) }
    private func resize() {
        let width = CGFloat(max(20, min(10_000, box.width)))
        let height = max(32, editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        frame = CGRect(x: box.x, y: box.y, width: width, height: height)
        editor.frame = bounds
    }
}

#endif
