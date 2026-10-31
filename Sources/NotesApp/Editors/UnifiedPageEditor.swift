#if os(macOS)
import SwiftUI
import AppKit
import NotesCore

/// One paper surface: text and pressure ink share coordinates, scrolling and zoom.
struct UnifiedPageEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
    @Binding var strokes: [InkStroke]
    @Binding var pencilKitData: Data?
    @Binding var textBoxes: [PageTextBox]
    @Binding var equations: [NoteEquation]
    var tool: InkTool = .pen
    var colorHex = "#314D43"
    var lineWidth: Double = 2.5
    var paper: InkPaper = .dotted
    var theme: PageTheme = .light
    var onPageChange: ((PageContent) -> Void)? = nil
    var onEquationEdit: ((NoteEquation) -> Void)? = nil
    var onTextChange: ((String, Data?) -> Void)? = nil
    var onInkChange: (([InkStroke], Data?) -> Void)? = nil
    var onInputChange: ((String) -> Void)? = nil

    init(text: Binding<String>, rtfData: Binding<Data?>, strokes: Binding<[InkStroke]>, pencilKitData: Binding<Data?>,
         textBoxes: Binding<[PageTextBox]> = .constant([]), equations: Binding<[NoteEquation]> = .constant([]),
         tool: InkTool = .pen, colorHex: String = "#314D43", lineWidth: Double = 2.5,
         paper: InkPaper = .dotted, theme: PageTheme = .light,
         onTextChange: ((String, Data?) -> Void)? = nil, onInkChange: (([InkStroke], Data?) -> Void)? = nil,
         onInputChange: ((String) -> Void)? = nil, onPageChange: ((PageContent) -> Void)? = nil,
         onEquationEdit: ((NoteEquation) -> Void)? = nil) {
        _text = text; _rtfData = rtfData; _strokes = strokes; _pencilKitData = pencilKitData
        _textBoxes = textBoxes; _equations = equations; self.tool = tool; self.colorHex = colorHex
        self.lineWidth = lineWidth; self.paper = paper; self.theme = theme
        self.onTextChange = onTextChange; self.onInkChange = onInkChange; self.onInputChange = onInputChange
        self.onPageChange = onPageChange; self.onEquationEdit = onEquationEdit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 4
        scroll.backgroundColor = .windowBackgroundColor
        let page = UnifiedMacPageView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
        scroll.documentView = page
        page.theme = theme
        page.textView.delegate = context.coordinator.richText
        page.selectionController = context.coordinator.selection
        page.textView.pageUndoManager = context.coordinator.selection.history
        page.inkView.pageSelectionHistory = context.coordinator.selection.history
        context.coordinator.selection.page = page
        page.selectionView.controller = context.coordinator.selection
        context.coordinator.richText.load(text: text, rtf: rtfData, into: page.textView)
        configure(page, coordinator: context.coordinator, isEnabled: context.environment.isEnabled)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let page = scroll.documentView as? UnifiedMacPageView else { return }
        context.coordinator.parent = self
        context.coordinator.richText.parent = textEditor
        let contentChanged = context.coordinator.richText.lastText != text || context.coordinator.richText.lastRTF != rtfData
        let themeChanged = page.theme != theme
        page.theme = theme
        if contentChanged || themeChanged {
            context.coordinator.richText.load(text: text, rtf: rtfData, into: page.textView)
        }
        configure(page, coordinator: context.coordinator, isEnabled: context.environment.isEnabled)
    }

    private var textEditor: RichTextEditor {
        RichTextEditor(text: $text, rtfData: $rtfData, theme: theme, onChange: onTextChange)
    }

    private func configure(_ page: UnifiedMacPageView, coordinator: Coordinator, isEnabled: Bool) {
        let value = PageContent(text: text, rtfData: rtfData, strokes: strokes, pencilKitData: pencilKitData, textBoxes: textBoxes, equations: equations)
        coordinator.selection.load(value)
        page.textView.pageUndoManager = coordinator.selection.history
        coordinator.richText.parent.onChange = { [weak coordinator] text, rtf in coordinator?.nativeTextChanged(text, rtf: rtf) }
        page.inkView.pageSelectionHistory = coordinator.selection.history
        coordinator.selection.onEquationEdit = onEquationEdit
        coordinator.selection.onRender = { [weak page, weak coordinator] content in
            guard let page, let coordinator else { return }
            coordinator.richText.parent = RichTextEditor(text: .constant(content.text), rtfData: .constant(content.rtfData), theme: theme,
                                                        onChange: { [weak coordinator] text, rtf in coordinator?.nativeTextChanged(text, rtf: rtf) })
            if coordinator.richText.lastText != content.text || coordinator.richText.lastRTF != content.rtfData {
                coordinator.richText.load(text: content.text, rtf: content.rtfData, into: page.textView)
            }
            page.inkView.strokes = content.strokes
            page.inkView.needsDisplay = true
            coordinator.renderObjects(content, on: page, enabled: isEnabled)
            page.resizePaperToContent()
        }
        coordinator.selection.onCommit = { content in
            if let onPageChange { onPageChange(content) }
            else {
                text = content.text; rtfData = content.rtfData; strokes = content.strokes
                pencilKitData = content.pencilKitData; textBoxes = content.textBoxes; equations = content.equations
            }
        }
        page.inkView.isInputEnabled = isEnabled
        page.activeTool = tool
        page.theme = theme
        page.textView.isEditable = isEnabled && tool == .text
        page.textView.isSelectable = isEnabled && tool == .text
        page.inkView.showsTipCursor = tool != .text && tool != .select && tool != .lasso
        page.inkView.tool = tool == .text ? .pen : tool
        page.inkView.colorHex = colorHex
        page.inkView.lineWidth = max(0.5, min(30, lineWidth))
        if page.inkView.paper != paper { page.inkView.paper = paper; page.inkView.needsDisplay = true }
        if page.paperView.paper != paper { page.paperView.paper = paper; page.paperView.needsDisplay = true }
        RuledTextLayout.attach(to: page.textView, paper: paper, pageOriginY: page.textView.frame.minY)
        coordinator.renderObjects(value, on: page, enabled: isEnabled)
        if !page.inkView.isDrawing, page.inkView.strokes != strokes {
            page.inkView.strokes = strokes
            page.inkView.needsDisplay = true
        }
        page.inkView.onChange = { value in
            coordinator.selection.content.strokes = value
            coordinator.selection.content.pencilKitData = nil
            if let onInkChange { onInkChange(value, nil) }
            else { strokes = value; pencilKitData = nil }
        }
        page.inkView.onInputChange = onInputChange
        page.onInputChange = onInputChange
        page.resizePaperToContent()
    }

    @MainActor
    final class Coordinator {
        var parent: UnifiedPageEditor
        let richText: RichTextEditor.Coordinator
        let selection = MacPageSelectionController()
        private var toolFocusObserver: NSObjectProtocol?

        init(_ parent: UnifiedPageEditor) {
            self.parent = parent
            richText = RichTextEditor.Coordinator(parent.textEditor)
            toolFocusObserver = NotificationCenter.default.addObserver(forName: .noteToolFocus, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let page = self.selection.page, page.window?.isKeyWindow == true,
                          let tool = notification.object as? InkTool else { return }
                    page.focus(tool: tool)
                }
            }
        }

        deinit { if let toolFocusObserver { NotificationCenter.default.removeObserver(toolFocusObserver) } }

        func nativeTextChanged(_ text: String, rtf: Data?) {
            selection.content.text = text; selection.content.rtfData = rtf
            if let callback = parent.onTextChange { callback(text, rtf) }
            else { parent.text = text; parent.rtfData = rtf }
        }

        func renderObjects(_ content: PageContent, on page: UnifiedMacPageView, enabled: Bool) {
            page.displayObjects(textBoxes: content.textBoxes, equations: content.equations, editable: enabled,
                                onTextBoxChange: { [weak self, weak page] id, text, rtf in
                guard let self, let page, let index = self.selection.content.textBoxes.firstIndex(where: { $0.id == id }) else { return }
                var value = self.selection.content
                value.textBoxes[index].text = text; value.textBoxes[index].rtfData = rtf
                self.selection.content = value
                self.selection.onCommit?(value)
                page.resizePaperToContent()
            }, onEquationEdit: parent.onEquationEdit)
        }
    }
}

@MainActor
enum UnifiedPageExport {
    static func pdf(text: String, rtfData: Data?, strokes: [InkStroke], paper: InkPaper, theme: PageTheme = .light, textBoxes: [PageTextBox] = [], equations: [NoteEquation] = []) -> Data {
        let page = makePage(text: text, rtfData: rtfData, strokes: strokes, paper: paper, theme: theme, textBoxes: textBoxes, equations: equations)
        return page.dataWithPDF(inside: page.bounds)
    }

    static func png(text: String, rtfData: Data?, strokes: [InkStroke], paper: InkPaper, theme: PageTheme = .light, textBoxes: [PageTextBox] = [], equations: [NoteEquation] = []) -> Data? {
        let page = makePage(text: text, rtfData: rtfData, strokes: strokes, paper: paper, theme: theme, textBoxes: textBoxes, equations: equations)
        // AppKit caches at the current backing scale (normally 2x Retina).
        // Bound actual raster pixels before allocating a giant object page.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard page.bounds.width.isFinite, page.bounds.height.isFinite,
              page.bounds.width * page.bounds.height * scale * scale <= 40_000_000 else { return nil }
        guard let bitmap = page.bitmapImageRepForCachingDisplay(in: page.bounds) else { return nil }
        page.cacheDisplay(in: page.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func makePage(text: String, rtfData: Data?, strokes: [InkStroke], paper: InkPaper, theme: PageTheme, textBoxes: [PageTextBox], equations: [NoteEquation]) -> UnifiedMacPageView {
        let page = UnifiedMacPageView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
        page.theme = theme
        let richText = RichTextEditor(text: .constant(text), rtfData: .constant(rtfData), theme: theme)
        let coordinator = RichTextEditor.Coordinator(richText)
        coordinator.load(text: text, rtf: rtfData, into: page.textView)
        page.textView.isEditable = false
        page.textView.isSelectable = false
        page.inkView.strokes = strokes
        page.inkView.paper = paper
        page.paperView.paper = paper
        page.inkView.isInputEnabled = false
        page.displayObjects(textBoxes: textBoxes, equations: equations, editable: false, onTextBoxChange: { _,_,_ in }, onEquationEdit: nil)
        page.resizePaperToContent()
        return page
    }
}

@MainActor
final class UnifiedMacPageView: NSView {
    let paperView = UnifiedMacPaperView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
    let inkView = InkDocumentView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
    let textView = RichTextEditor.makeNativeTextView()
    let selectionView = MacPageSelectionView(frame: .zero)
    weak var selectionController: MacPageSelectionController?
    var textBoxViews: [UUID: MacPageTextBoxView] = [:]
    var equationViews: [UUID: EquationDisplayView] = [:]
    private var toolTrackingArea: NSTrackingArea?
    var activeTool: InkTool = .pen {
        didSet {
            guard activeTool != oldValue else { return }
            focus(tool: activeTool)
        }
    }
    var theme: PageTheme = .light {
        didSet {
            guard theme != oldValue else { return }
            paperView.theme = theme
            inkView.theme = theme
            textView.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        }
    }
    var onInputChange: ((String) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Shared note page")
        addSubview(paperView)
        addSubview(textView)
        addSubview(inkView)
        addSubview(selectionView)
        inkView.drawsPaper = false
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.appearance = NSAppearance(named: .aqua)
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.textColor = InkRenderer.color(theme.textHex)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = true
        textView.onTabletProximity = { [weak inkView] event in inkView?.tabletProximity(with: event) }
        textView.pageCursorProvider = { [weak self] in self?.activePageCursor }
        textView.allowsPageTextUndo = { [weak self] in self?.inkView.isInputEnabled == true }
        textView.onPageUndoComplete = { [weak self] in self?.refreshToolCursor() }
        inkView.onTipCursorChange = { [weak self] in self?.updateDocumentCursor() }
        positionLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshToolCursor()
    }

    override func updateTrackingAreas() {
        if let toolTrackingArea { removeTrackingArea(toolTrackingArea) }
        toolTrackingArea = nil
        super.updateTrackingAreas()
        if activeTool != .text {
            let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            toolTrackingArea = area
        }
    }

    override func resetCursorRects() {
        if let cursor = activePageCursor { addCursorRect(visibleRect, cursor: cursor) }
    }

    override func cursorUpdate(with event: NSEvent) {
        // Updates from the top selection layer travel through this parent,
        // not through its sibling ink view.
        if let cursor = activePageCursor { cursor.set() }
        else { super.cursorUpdate(with: event) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let location = convert(point, from: superview)
        return inputView(at: location, event: NSApp.currentEvent)
    }

    static func inputIsTablet(event: NSEvent?) -> Bool {
        event.map { $0.isPenPointEvent || $0.isPenProximityEvent } ?? false
    }

    func inputView(at location: NSPoint, event: NSEvent?) -> NSView? {
        guard bounds.contains(location) else { return nil }
        if activeTool == .select || activeTool == .lasso { return selectionView }
        // The active tool owns pointer routing. Text accepts mouse and tablet
        // caret selection; an attached or hovering pen never changes the tool.
        // Both native text and handwriting remain visible on the same paper.
        if activeTool == .text {
            onInputChange?("Keyboard / text")
            if let box = textBoxViews.values.first(where: { $0.frame.contains(location) }) { return box.editor }
            if let equation = equationViews.values.first(where: { $0.frame.contains(location) }) { return equation }
            return textView
        }
        return inkView
    }

    func focus(tool: InkTool) {
        textView.breakUndoCoalescing()
        for box in textBoxViews.values { box.editor.breakUndoCoalescing() }
        // NSTextView's internal hover tracking also sets an I-beam. Retire
        // native text interaction while another tool owns the shared page.
        let editsText = inkView.isInputEnabled && tool == .text
        for editor in [textView] + textBoxViews.values.map(\.editor) {
            editor.isEditable = editsText
            editor.isSelectable = editsText
        }
        if tool == .text { window?.makeFirstResponder(textView) }
        else if tool == .select || tool == .lasso { window?.makeFirstResponder(selectionView) }
        else { window?.makeFirstResponder(inkView) }
        refreshToolCursor()
    }

    /// Text keeps AppKit's native cursor handling. Every other tool owns the
    /// cursor over both blank paper and the text layers underneath its ink.
    var activePageCursor: NSCursor? {
        switch activeTool {
        case .text: nil
        case .select: .arrow
        case .lasso: .crosshair
        default: inkView.tipCursor()
        }
    }

    func refreshToolCursor() {
        inkView.tool = activeTool == .text ? .pen : activeTool
        inkView.showsTipCursor = activeTool != .text && activeTool != .select && activeTool != .lasso
        updateTrackingAreas()
        updateDocumentCursor()
        let cursorViews: [NSView] = [textView, inkView, selectionView] + textBoxViews.values.map(\.editor)
        for view in cursorViews {
            window?.invalidateCursorRects(for: view)
        }
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        (activePageCursor ?? .iBeam).set()
    }

    private func updateDocumentCursor() {
        // AppKit also resolves document hover through NSClipView. Keep that
        // owner synchronized with tool, nib, color, theme and magnification.
        enclosingScrollView?.documentCursor = activePageCursor ?? .iBeam
        window?.invalidateCursorRects(for: self)
    }

    override func tabletProximity(with event: NSEvent) { inkView.tabletProximity(with: event) }

    func resizePaperToContent() {
        RuledTextLayout.attach(to: textView, paper: paperView.paper, pageOriginY: textView.frame.minY)
        let manager = textView.layoutManager
        if let container = textView.textContainer { manager?.ensureLayout(for: container) }
        let usedHeight = textView.textContainer.flatMap { manager?.usedRect(for: $0).height } ?? 0
        // AppKit may defer its layout manager's usedRect until a window draws.
        // Measure the attributed text too, so imports and offscreen PDF exports
        // grow correctly before their first display pass.
        let width = max(100, textView.bounds.width - textView.textContainerInset.width * 2
                        - (textView.textContainer?.lineFragmentPadding ?? 0) * 2)
        let measuredHeight = textView.attributedString().boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let textHeight = max(usedHeight, measuredHeight) + 104
        let inkHeight = inkView.strokes.lazy.flatMap(\.points).map(\.y).max().map { $0 + 80 } ?? 0
        let objectHeight = max(textBoxViews.values.map { $0.frame.maxY + 80 }.max() ?? 0,
                               equationViews.values.map { $0.frame.maxY + 80 }.max() ?? 0)
        let height = max(InkExport.paperSize.height, textHeight, inkHeight, objectHeight)
        if abs(frame.height - height) > 1 { setFrameSize(NSSize(width: InkExport.paperSize.width, height: height)) }
        positionLayers()
    }

    private func positionLayers() {
        paperView.frame = bounds
        inkView.frame = bounds
        selectionView.frame = bounds
        textView.frame = NSRect(x: 40, y: 40, width: bounds.width - 80, height: bounds.height - 80)
        textView.textContainer?.containerSize = NSSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        RuledTextLayout.attach(to: textView, paper: paperView.paper, pageOriginY: textView.frame.minY)
    }
}

@MainActor
final class UnifiedMacPaperView: NSView {
    var paper: InkPaper = .dotted
    var theme: PageTheme = .light {
        didSet { if theme != oldValue { needsDisplay = true } }
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { InkRenderer.draw(strokes: [], paper: paper, in: dirtyRect.intersection(bounds), theme: theme) }
}
#endif
