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
    var tool: InkTool = .pen
    var colorHex = "#314D43"
    var lineWidth: Double = 2.5
    var paper: InkPaper = .dotted
    var theme: PageTheme = .light
    var onTextChange: ((String, Data?) -> Void)? = nil
    var onInkChange: (([InkStroke], Data?) -> Void)? = nil
    var onInputChange: ((String) -> Void)? = nil

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
            if contentChanged { page.textView.undoManager?.removeAllActions() }
        }
        configure(page, coordinator: context.coordinator, isEnabled: context.environment.isEnabled)
    }

    private var textEditor: RichTextEditor {
        RichTextEditor(text: $text, rtfData: $rtfData, theme: theme, onChange: onTextChange)
    }

    private func configure(_ page: UnifiedMacPageView, coordinator: Coordinator, isEnabled: Bool) {
        page.activeTool = tool
        page.theme = theme
        page.textView.isEditable = isEnabled
        page.textView.isSelectable = isEnabled
        page.inkView.isInputEnabled = isEnabled
        page.inkView.tool = tool == .text ? .pen : tool
        page.inkView.colorHex = colorHex
        page.inkView.lineWidth = max(0.5, min(30, lineWidth))
        if page.inkView.paper != paper { page.inkView.paper = paper; page.inkView.needsDisplay = true }
        if page.paperView.paper != paper { page.paperView.paper = paper; page.paperView.needsDisplay = true }
        if !page.inkView.isDrawing, page.inkView.strokes != strokes {
            page.inkView.strokes = strokes
            page.inkView.undoManager?.removeAllActions()
            page.inkView.needsDisplay = true
        }
        page.inkView.onChange = { value in
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

        init(_ parent: UnifiedPageEditor) {
            self.parent = parent
            richText = RichTextEditor.Coordinator(parent.textEditor)
        }
    }
}

@MainActor
enum UnifiedPageExport {
    static func pdf(text: String, rtfData: Data?, strokes: [InkStroke], paper: InkPaper, theme: PageTheme = .light) -> Data {
        let page = makePage(text: text, rtfData: rtfData, strokes: strokes, paper: paper, theme: theme)
        return page.dataWithPDF(inside: page.bounds)
    }

    static func png(text: String, rtfData: Data?, strokes: [InkStroke], paper: InkPaper, theme: PageTheme = .light) -> Data? {
        let page = makePage(text: text, rtfData: rtfData, strokes: strokes, paper: paper, theme: theme)
        guard let bitmap = page.bitmapImageRepForCachingDisplay(in: page.bounds) else { return nil }
        page.cacheDisplay(in: page.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func makePage(text: String, rtfData: Data?, strokes: [InkStroke], paper: InkPaper, theme: PageTheme) -> UnifiedMacPageView {
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
        page.resizePaperToContent()
        return page
    }
}

@MainActor
final class UnifiedMacPageView: NSView {
    let paperView = UnifiedMacPaperView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
    let inkView = InkDocumentView(frame: NSRect(origin: .zero, size: InkExport.paperSize))
    let textView = RichTextEditor.makeNativeTextView()
    var activeTool: InkTool = .pen
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
        inkView.drawsPaper = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.appearance = NSAppearance(named: .aqua)
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.textColor = InkRenderer.color(theme.textHex)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = true
        textView.onTabletProximity = { [weak inkView] event in inkView?.tabletProximity(with: event) }
        positionLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let location = convert(point, from: superview)
        return inputView(at: location, event: NSApp.currentEvent)
    }

    static func inputIsTablet(event: NSEvent?) -> Bool {
        event.map { $0.isPenPointEvent || $0.isPenProximityEvent } ?? false
    }

    func inputView(at location: NSPoint, event: NSEvent?) -> NSView? {
        guard bounds.contains(location) else { return nil }
        let tablet = Self.inputIsTablet(event: event)
        // A stylus always writes. The text tool changes mouse/trackpad input;
        // text and handwriting remain visible on the same sheet in either case.
        if activeTool == .text, !tablet, textView.frame.contains(location) {
            onInputChange?("Keyboard / text")
            return textView
        }
        return inkView
    }

    override func tabletProximity(with event: NSEvent) { inkView.tabletProximity(with: event) }

    func resizePaperToContent() {
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
        let height = max(InkExport.paperSize.height, textHeight, inkHeight)
        if abs(frame.height - height) > 1 { setFrameSize(NSSize(width: InkExport.paperSize.width, height: height)) }
        positionLayers()
    }

    private func positionLayers() {
        paperView.frame = bounds
        inkView.frame = bounds
        textView.frame = NSRect(x: 40, y: 40, width: bounds.width - 80, height: bounds.height - 80)
        textView.textContainer?.containerSize = NSSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
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
