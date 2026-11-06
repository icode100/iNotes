#if os(iOS)
import SwiftUI
import UIKit
import PencilKit
import NotesCore

/// Text and PencilKit share one document coordinate system and one scroll/zoom
/// surface. Selecting Text changes hit routing, rather than hiding either layer.
struct UnifiedPageEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
    @Binding var strokes: [InkStroke]
    @Binding var pencilKitData: Data?
    @Binding var textBoxes: [PageTextBox]
    @Binding var equations: [NoteEquation]
    @Binding var images: [PageImage]
    @Binding var diagrams: [PageDiagram]
    var tool: InkTool = .pen
    var colorHex: String = "#314D43"
    var lineWidth: Double = InkNibPreset.defaultWidth(for: .pen)
    var paper: InkPaper = .dotted
    var theme: PageTheme = .light
    var linePattern: LinePattern = .solid
    var pageTemplate: PageTemplate = .none
    var templateLinePattern: LinePattern = .solid
    var diagramKind: PageDiagram.Kind = .rectangle
    var connectorRoute: PageDiagram.ConnectorRoute = .straight
    var arrowHeads: PageDiagram.ArrowHeads = .end
    var tableRows = 3
    var tableColumns = 3
    var diagramFill = false
    var onTextChange: ((String, Data?) -> Void)? = nil
    var onInkChange: (([InkStroke], Data?) -> Void)? = nil
    var onInputChange: ((String) -> Void)? = nil
    var onPageChange: ((PageContent) -> Void)? = nil
    var onPageValidate: ((PageContent) -> Bool)? = nil
    var onPageError: ((String) -> Void)? = nil
    var onObjectPlacement: (() -> Void)? = nil
    var onEquationEdit: ((NoteEquation) -> Void)? = nil

    init(text: Binding<String>, rtfData: Binding<Data?>, strokes: Binding<[InkStroke]>, pencilKitData: Binding<Data?>,
         textBoxes: Binding<[PageTextBox]> = .constant([]), equations: Binding<[NoteEquation]> = .constant([]), images: Binding<[PageImage]> = .constant([]), diagrams: Binding<[PageDiagram]> = .constant([]),
         tool: InkTool = .pen, colorHex: String = "#314D43", lineWidth: Double? = nil,
         paper: InkPaper = .dotted, theme: PageTheme = .light,
         linePattern: LinePattern = .solid, pageTemplate: PageTemplate = .none, templateLinePattern: LinePattern = .solid,
         diagramKind: PageDiagram.Kind = .rectangle, connectorRoute: PageDiagram.ConnectorRoute = .straight,
         arrowHeads: PageDiagram.ArrowHeads = .end, tableRows: Int = 3, tableColumns: Int = 3, diagramFill: Bool = false,
         onTextChange: ((String, Data?) -> Void)? = nil, onInkChange: (([InkStroke], Data?) -> Void)? = nil,
         onInputChange: ((String) -> Void)? = nil, onPageChange: ((PageContent) -> Void)? = nil,
         onEquationEdit: ((NoteEquation) -> Void)? = nil, onPageValidate: ((PageContent) -> Bool)? = nil, onPageError: ((String) -> Void)? = nil,
         onObjectPlacement: (() -> Void)? = nil) {
        _text = text; _rtfData = rtfData; _strokes = strokes; _pencilKitData = pencilKitData
        _textBoxes = textBoxes; _equations = equations; _images = images; _diagrams = diagrams; self.tool = tool; self.colorHex = colorHex
        self.lineWidth = lineWidth ?? InkNibPreset.defaultWidth(for: tool); self.paper = paper; self.theme = theme
        self.linePattern = linePattern; self.pageTemplate = pageTemplate; self.templateLinePattern = templateLinePattern
        self.diagramKind = diagramKind; self.connectorRoute = connectorRoute; self.arrowHeads = arrowHeads
        self.tableRows = tableRows; self.tableColumns = tableColumns; self.diagramFill = diagramFill
        self.onTextChange = onTextChange; self.onInkChange = onInkChange; self.onInputChange = onInputChange
        self.onPageChange = onPageChange; self.onEquationEdit = onEquationEdit; self.onPageValidate = onPageValidate; self.onPageError = onPageError
        self.onObjectPlacement = onObjectPlacement
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UnifiedPageScrollView {
        let view = UnifiedPageScrollView()
        view.delegate = context.coordinator
        view.page.canvas.delegate = context.coordinator
        view.page.textView.delegate = context.coordinator
        context.coordinator.attach(view)
        context.coordinator.update(view, enabled: context.environment.isEnabled)
        return view
    }

    func updateUIView(_ view: UnifiedPageScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view, enabled: context.environment.isEnabled)
    }

    static func dismantleUIView(_ view: UnifiedPageScrollView, coordinator: Coordinator) {
        coordinator.detach(view)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UITextViewDelegate, PKCanvasViewDelegate, PKToolPickerObserver {
        var parent: UnifiedPageEditor
        let richTextCoordinator: RichTextEditor.Coordinator
        let selection = IOSPageSelectionController()
        private weak var view: UnifiedPageScrollView?
        private let picker = PKToolPicker()
        private var isLoading = false
        private var nativeToolActive = false
        private var rejectedDrawing = false
        private var showingUnsupportedWarning = false
        private var supportsPageEditing: Bool { parent.images.isEmpty && parent.diagrams.isEmpty }
        private var lastData: Data?
        private var lastStrokes: [InkStroke] = []
        private var expectedDrawingData: Data?
        private var toolConfiguration: String?
        private var previousTool: InkTool?
        private var pendingFocus: InkTool?
        private var appliedTheme: PageTheme?
        private var canonicalColorsByPath: [StrokeColorKey: UIColor] = [:]
        private var configuredCanonicalInk: UIColor?
        private var configuredDisplayInk: UIColor?
        private var adjustingPicker = false
        private var undoObservers: [NSObjectProtocol] = []
        private var lineGesture: PencilLineGestureRecognizer?
        private let linePreview = CAShapeLayer()
        #if DEBUG
        private var didRunDiagnostics = false
        private var isRunningDiagnostics = false
        #endif

        init(_ parent: UnifiedPageEditor) {
            self.parent = parent
            richTextCoordinator = RichTextEditor.Coordinator(RichTextEditor(
                text: parent.$text, rtfData: parent.$rtfData, theme: parent.theme, onChange: parent.onTextChange
            ))
            super.init()
            for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
                undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let view = self.view, let manager = notification.object as? UndoManager else { return }
                        if manager === view.page.textView.undoManager {
                            self.richTextCoordinator.textViewDidChange(view.page.textView)
                            view.resizePage()
                        }
                        if manager === view.page.canvas.undoManager { self.persistInk(view.page.canvas) }
                        for box in view.page.textBoxViews.values where manager === box.editor.undoManager { box.persistNativeUndo() }
                    }
                })
            }
            undoObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view else { return }
                    self.persistInk(view.page.canvas)
                }
            })
            undoObservers.append(NotificationCenter.default.addObserver(forName: .noteToolFocus, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view, let tool = note.object as? InkTool,
                          view.window == nil || view.window?.isKeyWindow == true else { return }
                    self.focus(tool, in: view)
                }
            })
        }

        deinit { for observer in undoObservers { NotificationCenter.default.removeObserver(observer) } }

        func attach(_ view: UnifiedPageScrollView) {
            self.view = view
            selection.page = view.page
            view.page.selectionView.controller = selection
            view.page.prepareForPageSelection = { [weak self, weak view] in
                guard let self, let view, self.supportsPageEditing, !self.nativeToolActive,
                      !self.rejectedDrawing, view.page.isUserInteractionEnabled else { return false }
                self.persistInk(view.page.canvas)
                self.picker.setVisible(false, forFirstResponder: view.page.canvas)
                return true
            }
            selection.onRender = { [weak self, weak view] content in
                guard let self, let view else { return }
                self.render(content, on: view, theme: self.appliedTheme ?? self.parent.theme)
            }
            selection.onCommit = { [weak self] content in self?.publishPage(content) }
            expectedDrawingData = view.page.canvas.drawing.dataRepresentation()
            picker.addObserver(view.page.canvas)
            picker.addObserver(self)
            picker.showsDrawingPolicyControls = false
            let lineGesture = PencilLineGestureRecognizer(target: self, action: #selector(handleLineGesture(_:)))
            lineGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            lineGesture.requiresExclusiveTouchType = true
            lineGesture.isEnabled = false
            view.page.canvas.addGestureRecognizer(lineGesture)
            self.lineGesture = lineGesture
            linePreview.fillColor = nil
            linePreview.lineCap = .round
            view.page.layer.addSublayer(linePreview)
            view.page.onPencil = { [weak self, weak view] in
                guard let self, let view else { return }
                guard self.supportsPageEditing, self.parent.tool != .text else { return }
                self.parent.onInputChange?("Apple Pencil")
                guard self.parent.tool != .select && self.parent.tool != .lasso && self.parent.tool != .diagram else { return }
                self.picker.setVisible(true, forFirstResponder: view.page.canvas)
                view.page.canvas.becomeFirstResponder()
                view.page.canvas.undoManager?.levelsOfUndo = 50
            }
            view.onAttachment = { [weak self, weak view] in
                guard let self, let view else { return }
                self.focus(self.pendingFocus ?? self.parent.tool, in: view)
                #if DEBUG
                self.scheduleDiagnosticsIfRequested()
                #endif
            }
        }

        func update(_ view: UnifiedPageScrollView, enabled externalEnabled: Bool) {
            // Image and diagram authoring are currently Mac-only. Keep every
            // object in snapshots and prevent edits against an incomplete preview.
            let enabled = externalEnabled && supportsPageEditing
            // A system appearance transition waits until the current Pencil
            // gesture completes, preserving in-flight native ink and pressure.
            let theme = nativeToolActive ? (appliedTheme ?? parent.theme) : parent.theme
            let incoming = PageContent(text: parent.text, rtfData: parent.rtfData, strokes: parent.strokes,
                                       pencilKitData: parent.pencilKitData, textBoxes: parent.textBoxes, equations: parent.equations, images: parent.images, diagrams: parent.diagrams)
            if !selection.hasPreview { selection.load(incoming) }
            let content = selection.displayedContent
            selection.onEquationEdit = supportsPageEditing ? parent.onEquationEdit : nil
            selection.onValidate = parent.onPageValidate
            selection.onError = parent.onPageError
            richTextCoordinator.parent = RichTextEditor(text: parent.$text, rtfData: parent.$rtfData, theme: theme, onChange: { [weak self] text, rtf in
                self?.publishText(text, rtf: rtf)
            })
            let editor = view.page.textView
            editor.undoManager?.levelsOfUndo = 50
            view.page.canvas.undoManager?.levelsOfUndo = 50
            editor.isEditable = enabled
            view.isUserInteractionEnabled = externalEnabled
            view.page.isUserInteractionEnabled = enabled
            if !enabled {
                view.page.endEditing(true)
                picker.setVisible(false, forFirstResponder: view.page.canvas)
                view.page.canvas.resignFirstResponder()
            }
            view.page.textToolSelected = parent.tool == .text
            let selecting = parent.tool == .select || parent.tool == .lasso
            view.page.selectionEnabled = selecting
            view.page.selectionView.tool = parent.tool
            view.page.selectionInputAllowed = enabled
            view.page.refreshSelectionPresentation()
            view.panGestureRecognizer.minimumNumberOfTouches = parent.tool == .text || selecting ? 2 : 1
            view.page.paper.style = parent.paper
            view.page.paper.theme = theme
            view.page.paper.pageTemplate = parent.pageTemplate
            view.page.paper.templateLinePattern = parent.templateLinePattern
            view.page.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
            editor.overrideUserInterfaceStyle = view.page.overrideUserInterfaceStyle
            // PencilKit transforms ink colors itself when a canvas is dark.
            // Our semantic resolver already supplies the display color, so
            // render that color in a light-trait canvas to avoid a second tint.
            view.page.canvas.overrideUserInterfaceStyle = .light
            picker.overrideUserInterfaceStyle = view.page.overrideUserInterfaceStyle
            picker.colorUserInterfaceStyle = .light
            if richTextCoordinator.lastText != content.text || richTextCoordinator.lastRTF != content.rtfData || richTextCoordinator.lastTheme != theme {
                richTextCoordinator.load(text: content.text, rtf: content.rtfData, into: editor)
            }
            RuledTextLayout.attach(to: editor, paper: parent.paper, pageOriginY: editor.frame.minY)
            let themeChanged = appliedTheme != theme
            if lastData != content.pencilKitData || lastStrokes != content.strokes {
                let canonical = loadDrawing(content, in: view)
                rememberCanonicalColors(in: canonical)
                show(canonicalDrawing: canonical, on: view.page.canvas, theme: theme)
                lastData = content.pencilKitData
                lastStrokes = content.strokes
            } else if themeChanged {
                let canonical = canonicalDrawing(from: view.page.canvas.drawing, theme: appliedTheme ?? .light)
                rememberCanonicalColors(in: canonical)
                show(canonicalDrawing: canonical, on: view.page.canvas, theme: theme)
            }
            if themeChanged {
                // PencilKit assigns stroke identifiers when replacing a
                // drawing. Old native undo actions must not target stale IDs.
                view.page.canvas.undoManager?.removeAllActions()
            }
            appliedTheme = theme
            configureTool(on: view.page.canvas, theme: theme)
            view.page.canvas.drawingGestureRecognizer.isEnabled = enabled && !rejectedDrawing && parent.tool != .text && parent.tool != .line && parent.tool != .diagram && !selecting
            lineGesture?.isEnabled = enabled && !rejectedDrawing && parent.tool == .line
            view.page.selectionInputAllowed = enabled && !rejectedDrawing
            view.page.refreshSelectionPresentation()
            renderObjects(content, on: view, theme: theme, enabled: enabled)
            if !content.images.isEmpty || !content.diagrams.isEmpty {
                showingUnsupportedWarning = true
                let objects = !content.images.isEmpty && !content.diagrams.isEmpty ? "images and diagrams" : (content.images.isEmpty ? "diagrams" : "images")
                view.setInkError("This sheet contains \(objects). Open it on Mac to view and edit all page objects. Page editing is disabled on iPad; your saved content is preserved.")
                view.panGestureRecognizer.minimumNumberOfTouches = 1
            } else if parent.tool == .diagram {
                showingUnsupportedWarning = true
                view.setInkError("Shapes, connectors and tables are currently created on Mac. Choose another tool to continue editing on iPad.")
            } else if showingUnsupportedWarning {
                showingUnsupportedWarning = false
                view.setInkError(rejectedDrawing ? "This sheet contains unsupported ink and cannot be edited safely. Its saved drawing has been preserved." : nil)
            }
            view.resizePage()
            linePreview.frame = view.page.bounds
            if previousTool != parent.tool {
                previousTool = parent.tool
                if enabled { focus(pendingFocus ?? parent.tool, in: view) }
            }
        }

        private func focus(_ tool: InkTool, in view: UnifiedPageScrollView) {
            guard view.isUserInteractionEnabled, supportsPageEditing else { return }
            guard view.window != nil else { pendingFocus = tool; return }
            pendingFocus = nil
            let page = view.page
            selection.dismissTemporarySelection()
            page.textToolSelected = tool == .text
            page.selectionEnabled = tool == .select || tool == .lasso
            page.selectionView.tool = tool
            page.selectionInputAllowed = !rejectedDrawing
            page.refreshSelectionPresentation()
            view.panGestureRecognizer.minimumNumberOfTouches = tool == .text || page.selectionEnabled ? 2 : 1
            page.canvas.drawingGestureRecognizer.isEnabled = !rejectedDrawing && tool != .text && tool != .line && tool != .diagram && !page.selectionEnabled
            lineGesture?.isEnabled = !rejectedDrawing && tool == .line
            if tool == .diagram {
                page.endEditing(true)
                picker.setVisible(false, forFirstResponder: page.canvas)
                page.canvas.resignFirstResponder()
            } else if tool == .text {
                picker.setVisible(false, forFirstResponder: page.canvas)
                page.canvas.resignFirstResponder()
                let editor = page.activeTextView ?? page.textView
                editor.becomeFirstResponder()
                editor.undoManager?.levelsOfUndo = 50
            } else if page.selectionEnabled {
                page.endEditing(true)
                picker.setVisible(false, forFirstResponder: page.canvas)
                page.canvas.resignFirstResponder()
                page.selectionView.becomeFirstResponder()
            } else {
                page.endEditing(true)
                configureTool(on: page.canvas, theme: appliedTheme ?? parent.theme, tool: tool)
                picker.setVisible(true, forFirstResponder: page.canvas)
                page.canvas.becomeFirstResponder()
                page.canvas.undoManager?.levelsOfUndo = 50
            }
        }

        private func configureTool(on canvas: PKCanvasView, theme: PageTheme, tool requestedTool: InkTool? = nil) {
            let tool = requestedTool ?? parent.tool
            let configuration = "\(tool.rawValue)|\(parent.colorHex)|\(parent.lineWidth)|\(theme.rawValue)"
            guard configuration != toolConfiguration else { return }
            toolConfiguration = configuration
            let canonical = UIColor(noteHex: parent.colorHex)
            let color = UIColor(noteHex: theme.resolvedInkHex(parent.colorHex))
            configuredCanonicalInk = canonical
            configuredDisplayInk = color
            let width = max(0.5, min(30, parent.lineWidth))
            switch tool {
            case .text, .select, .lasso, .diagram: break
            case .pen, .line: canvas.tool = PKInkingTool(.pen, color: color, width: width * InkStyle.pen.widthMultiplier)
            case .pencil: canvas.tool = PKInkingTool(.pencil, color: color, width: width * InkStyle.pencil.widthMultiplier)
            case .marker: canvas.tool = PKInkingTool(.marker, color: color, width: width * InkStyle.marker.widthMultiplier)
            case .highlighter: canvas.tool = PKInkingTool(.marker, color: color.withAlphaComponent(0.3), width: width * InkStyle.highlighter.widthMultiplier)
            case .eraser: canvas.tool = PKEraserTool(.vector)
            }
        }

        func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
            guard !adjustingPicker, let view, let selected = toolPicker.selectedTool as? PKInkingTool else { return }
            let theme = appliedTheme ?? parent.theme
            let canonical = UIColor(noteHex: theme.canonicalInkHex(selected.color.noteHex))
                .withAlphaComponent(selected.color.cgColor.alpha)
            let displayed = UIColor(noteHex: theme.resolvedInkHex(canonical.noteHex))
                .withAlphaComponent(selected.color.cgColor.alpha)
            configuredCanonicalInk = canonical
            configuredDisplayInk = displayed
            adjustingPicker = true
            view.page.canvas.tool = PKInkingTool(selected.inkType, color: displayed, width: selected.width)
            adjustingPicker = false
        }

        private func showToolsIfNeeded() {
            guard supportsPageEditing, let view, view.window != nil, view.isUserInteractionEnabled,
                  parent.tool != .text && parent.tool != .select && parent.tool != .lasso && parent.tool != .diagram else { return }
            picker.setVisible(true, forFirstResponder: view.page.canvas)
            view.page.canvas.becomeFirstResponder()
            view.page.canvas.undoManager?.levelsOfUndo = 50
        }

        func detach(_ view: UnifiedPageScrollView) {
            nativeToolActive = false
            persistInk(view.page.canvas)
            picker.setVisible(false, forFirstResponder: view.page.canvas)
            picker.removeObserver(view.page.canvas)
            picker.removeObserver(self)
            if let lineGesture { view.page.canvas.removeGestureRecognizer(lineGesture) }
            view.page.canvas.undoManager?.removeAllActions(withTarget: view.page.canvas)
            linePreview.removeFromSuperlayer()
            view.page.onPencil = nil
            view.page.prepareForPageSelection = nil
            selection.onRender = nil
            selection.onCommit = nil
            selection.page = nil
            view.onAttachment = nil
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.page }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { view?.centerPage() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { view?.updateVisiblePaper() }

        func textViewDidChange(_ textView: UITextView) {
            textView.undoManager?.levelsOfUndo = 50
            richTextCoordinator.textViewDidChange(textView)
            view?.resizePage()
            revealCaret(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) { revealCaret(textView) }

        private func revealCaret(_ textView: UITextView) {
            guard textView.isFirstResponder, let view, let selected = textView.selectedTextRange else { return }
            let caret = textView.caretRect(for: selected.end).insetBy(dx: -12, dy: -18)
            view.scrollRectToVisible(textView.convert(caret, to: view), animated: false)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            nativeToolActive = true
            parent.onInputChange?("Apple Pencil")
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if !nativeToolActive { persistInk(canvasView) }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            nativeToolActive = false
            persistInk(canvasView)
            if appliedTheme != parent.theme, let view { update(view, enabled: view.isUserInteractionEnabled) }
        }

        @objc private func handleLineGesture(_ gesture: PencilLineGestureRecognizer) {
            guard let view, let start = gesture.startPoint, let end = gesture.currentPoint else { return }
            switch gesture.state {
            case .began, .changed:
                let snapped = InkLineGeometry.snappedEnd(start: start, end: end)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: start.x, y: start.y))
                path.addLine(to: CGPoint(x: snapped.x, y: snapped.y))
                let ink = view.page.canvas.tool as? PKInkingTool
                linePreview.strokeColor = (ink?.color ?? UIColor(noteHex: parent.colorHex)).cgColor
                let selectedWidth = Double(ink?.width ?? CGFloat(parent.lineWidth))
                let pressureFactor = 0.35 + 0.65 * (start.pressure + end.pressure) / 2
                linePreview.lineWidth = CGFloat(selectedWidth * pressureFactor)
                linePreview.lineDashPattern = parent.linePattern == .solid ? nil : parent.linePattern.dashLengths(width: selectedWidth).map { NSNumber(value: $0) }
                linePreview.path = path
            case .ended:
                linePreview.path = nil
                commitLine(start: start, end: end, in: view.page.canvas)
            case .cancelled, .failed: linePreview.path = nil
            default: break
            }
        }

        private func commitLine(start: InkPoint, end: InkPoint, in canvas: PKCanvasView) {
            let end = InkLineGeometry.snappedEnd(start: start, end: end)
            guard hypot(end.x - start.x, end.y - start.y) >= 0.5 else { return }
            let selectedInk = canvas.tool as? PKInkingTool
            let selectedWidth = selectedInk.map { Double($0.width) } ?? parent.lineWidth
            let width = max(0.5, min(100, selectedWidth))
            let portable = InkStroke(points: [start, end], colorHex: (selectedInk?.color ?? UIColor(noteHex: parent.colorHex)).noteHex,
                                     width: width, style: .pen, linePattern: parent.linePattern)
            do {
                let addition = try PortableInkConverter.validatedDrawing(nil, fallback: [portable])
                let combined = PKDrawing(strokes: canvas.drawing.strokes + addition.strokes)
                try PortableInkConverter.validateNativeDrawing(combined)
                replaceDrawing(combined, in: canvas, registerUndo: true)
            } catch {
                view?.setInkError("This line exceeds the supported drawing limits. Try a shorter line or wider spacing.")
            }
        }

        /// Line gestures never enter PencilKit's freehand undo history. Their
        /// complete before/after snapshots form one undoable document operation.
        private func replaceDrawing(_ drawing: PKDrawing, in canvas: PKCanvasView, registerUndo: Bool) {
            if registerUndo, let manager = canvas.undoManager {
                let before = canvas.drawing
                let needsGroup = manager.groupingLevel == 0
                if needsGroup { manager.beginUndoGrouping() }
                manager.registerUndo(withTarget: canvas) { [weak self] target in
                    self?.replaceDrawing(before, in: target, registerUndo: true)
                }
                manager.setActionName("Straight Line")
                if needsGroup { manager.endUndoGrouping() }
            }
            isLoading = true
            canvas.drawing = drawing
            isLoading = false
            persistInk(canvas)
        }

        private func persistInk(_ canvas: PKCanvasView) {
            guard supportsPageEditing, !isLoading, !rejectedDrawing else { return }
            #if DEBUG
            guard !isRunningDiagnostics else { return }
            #endif
            let displayedData = canvas.drawing.dataRepresentation()
            guard displayedData != expectedDrawingData else { return }
            let canonical = canonicalDrawing(from: canvas.drawing, theme: appliedTheme ?? parent.theme)
            guard (try? PortableInkConverter.validateNativeDrawing(canonical)) != nil else {
                // Preserve the last accepted model if a native gesture exceeds
                // the document budget. Never save truncated sampled ink.
                if let view {
                    let accepted = loadDrawing(selection.content, in: view)
                    show(canonicalDrawing: accepted, on: canvas, theme: appliedTheme ?? parent.theme)
                    view.setInkError("This drawing exceeds the supported page limits. The last saved ink has been restored.")
                }
                return
            }
            let data = canonical.dataRepresentation()
            guard let portable = try? portableStrokes(from: canonical) else {
                if let view {
                    let accepted = loadDrawing(selection.content, in: view)
                    show(canonicalDrawing: accepted, on: canvas, theme: appliedTheme ?? parent.theme)
                    view.setInkError("This drawing exceeds the supported sampling limits. The last saved ink has been restored.")
                }
                return
            }
            expectedDrawingData = displayedData
            lastData = data
            lastStrokes = portable
            var content = selection.content
            content.strokes = portable; content.pencilKitData = data
            selection.load(content)
            if parent.onPageChange != nil { publishPage(content) }
            else if let onInkChange = parent.onInkChange { onInkChange(portable, data) }
            else { parent.strokes = portable; parent.pencilKitData = data }
            view?.resizePage()
        }

        private func publishText(_ text: String, rtf: Data?) {
            guard supportsPageEditing else { return }
            var content = selection.content
            content.text = text; content.rtfData = rtf
            selection.load(content)
            if parent.onPageChange != nil { publishPage(content) }
            else if let onTextChange = parent.onTextChange { onTextChange(text, rtf) }
            else { parent.text = text; parent.rtfData = rtf }
        }

        private func publishPage(_ content: PageContent) {
            guard supportsPageEditing, content.images.isEmpty, content.diagrams.isEmpty else { return }
            if let onPageChange = parent.onPageChange { onPageChange(content) }
            else {
                if let onTextChange = parent.onTextChange { onTextChange(content.text, content.rtfData) }
                else { parent.text = content.text; parent.rtfData = content.rtfData }
                if let onInkChange = parent.onInkChange { onInkChange(content.strokes, content.pencilKitData) }
                else { parent.strokes = content.strokes; parent.pencilKitData = content.pencilKitData }
                parent.textBoxes = content.textBoxes; parent.equations = content.equations; parent.images = content.images; parent.diagrams = content.diagrams
            }
        }

        private func loadDrawing(_ content: PageContent, in view: UnifiedPageScrollView) -> PKDrawing {
            do {
                let drawing = try PortableInkConverter.validatedDrawing(content.pencilKitData, fallback: content.strokes)
                rejectedDrawing = false
                view.setInkError(nil)
                return drawing
            } catch {
                // Keep the original bytes intact. A failed native load must not
                // become an empty drawing that is later autosaved over the note.
                rejectedDrawing = true
                view.setInkError("This sheet contains unsupported ink and cannot be edited safely. Its saved drawing has been preserved.")
                return PKDrawing()
            }
        }

        private func render(_ content: PageContent, on view: UnifiedPageScrollView, theme: PageTheme) {
            richTextCoordinator.load(text: content.text, rtf: content.rtfData, into: view.page.textView)
            RuledTextLayout.attach(to: view.page.textView, paper: parent.paper, pageOriginY: view.page.textView.frame.minY)
            if lastData != content.pencilKitData || lastStrokes != content.strokes {
                let canonical = loadDrawing(content, in: view)
                rememberCanonicalColors(in: canonical)
                show(canonicalDrawing: canonical, on: view.page.canvas, theme: theme)
                lastData = content.pencilKitData; lastStrokes = content.strokes
            }
            renderObjects(content, on: view, theme: theme, enabled: view.page.isUserInteractionEnabled)
            view.resizePage()
            view.page.selectionView.setNeedsDisplay()
        }

        private func renderObjects(_ content: PageContent, on view: UnifiedPageScrollView, theme: PageTheme, enabled: Bool) {
            let page = view.page
            page.diagramView.configure(content.diagrams, theme: theme)
            let textIDs = Set(content.textBoxes.map(\.id)), equationIDs = Set(content.equations.map(\.id))
            for id in Array(page.textBoxViews.keys) where !textIDs.contains(id) { page.textBoxViews.removeValue(forKey: id)?.removeFromSuperview() }
            for id in Array(page.equationViews.keys) where !equationIDs.contains(id) { page.equationViews.removeValue(forKey: id)?.removeFromSuperview() }
            for box in content.textBoxes {
                let object = page.textBoxViews[box.id] ?? IOSTextBoxView(box: box, theme: theme)
                if page.textBoxViews[box.id] == nil { page.textBoxViews[box.id] = object; page.insertSubview(object, belowSubview: page.canvas) }
                object.configure(box: box, theme: theme, editable: enabled && parent.tool == .text, paper: parent.paper)
                object.onChange = { [weak self, weak view] changed in
                    guard let self, self.supportsPageEditing, let view, let index = self.selection.content.textBoxes.firstIndex(where: { $0.id == changed.id }) else { return }
                    var value = self.selection.content
                    guard value.textBoxes[index] != changed else { return }
                    value.textBoxes[index] = changed
                    self.selection.load(value)
                    self.publishPage(value)
                    view.resizePage()
                }
            }
            for equation in content.equations {
                let object = page.equationViews[equation.id] ?? EquationDisplayView(frame: .zero)
                if page.equationViews[equation.id] == nil { page.equationViews[equation.id] = object; page.insertSubview(object, belowSubview: page.canvas) }
                object.frame = CGRect(x: equation.x, y: equation.y, width: equation.width, height: equation.height)
                object.isUserInteractionEnabled = enabled && parent.tool == .text
                object.configure(equation: equation, theme: theme, onRequestEdit: { [weak self] in self?.parent.onEquationEdit?(equation) })
            }
        }

        private struct StrokeColorKey: Hashable {
            let creationDate: Date
            let randomSeed: UInt32
            let firstX: CGFloat
            let firstY: CGFloat
            let pointCount: Int

            init(_ stroke: PKStroke) {
                creationDate = stroke.path.creationDate
                randomSeed = stroke.randomSeed
                firstX = stroke.path.first?.location.x ?? 0
                firstY = stroke.path.first?.location.y ?? 0
                pointCount = stroke.path.count
            }
        }

        private func rememberCanonicalColors(in drawing: PKDrawing) {
            canonicalColorsByPath.removeAll(keepingCapacity: true)
            for stroke in drawing.strokes { canonicalColorsByPath[StrokeColorKey(stroke)] = stroke.ink.color }
        }

        private func show(canonicalDrawing: PKDrawing, on canvas: PKCanvasView, theme: PageTheme) {
            let displayed = canonicalDrawing.strokes.map { stroke -> PKStroke in
                let color = UIColor(noteHex: theme.resolvedInkHex(stroke.ink.color.noteHex))
                    .withAlphaComponent(stroke.ink.color.cgColor.alpha)
                let ink = PKInk(stroke.ink.inkType, color: color)
                // PencilKit caches rendered color by stroke ID. A new display
                // projection needs a new ID even when the geometric path is
                // unchanged, otherwise switching back can keep the old tint.
                // Xcode 27 pairs the iOS 27 SDK with Swift 6.4. Older SDKs
                // must not type-check the new stroke identity API.
                #if compiler(>=6.4)
                if #available(iOS 27, *) {
                    return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask,
                                    randomSeed: stroke.randomSeed, id: UUID(),
                                    renderGroupID: stroke.renderGroupID, renderState: stroke.renderState)
                }
                #endif
                return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform,
                                mask: stroke.mask, randomSeed: stroke.randomSeed)
            }
            isLoading = true
            canvas.drawing = PKDrawing(strokes: displayed)
            expectedDrawingData = canvas.drawing.dataRepresentation()
            isLoading = false
        }

        private func canonicalDrawing(from displayed: PKDrawing, theme: PageTheme) -> PKDrawing {
            PKDrawing(strokes: displayed.strokes.map { stroke -> PKStroke in
                let key = StrokeColorKey(stroke)
                let canonical: UIColor
                if let remembered = canonicalColorsByPath[key] {
                    canonical = remembered
                } else if let configuredDisplayInk, let configuredCanonicalInk,
                          stroke.ink.color.hasSameRGB(as: configuredDisplayInk) {
                    canonical = configuredCanonicalInk.withAlphaComponent(stroke.ink.color.cgColor.alpha)
                } else {
                    canonical = UIColor(noteHex: theme.canonicalInkHex(stroke.ink.color.noteHex))
                        .withAlphaComponent(stroke.ink.color.cgColor.alpha)
                }
                canonicalColorsByPath[key] = canonical
                var original = stroke
                original.ink = PKInk(stroke.ink.inkType, color: canonical)
                return original
            })
        }

        private func portableStrokes(from drawing: PKDrawing) throws -> [InkStroke] {
            try PortableInkConverter.validateNativeDrawing(drawing)
            var result: [InkStroke] = []
            var pointCount = 0
            for stroke in drawing.strokes {
                var converted = try PortableInkConverter.validatedStrokes(from: PKDrawing(strokes: [stroke]))
                if stroke.path.count == 2, stroke.mask == nil, stroke.ink.inkType == .pen, converted.count == 1 {
                    converted[0].points = [stroke.path[0], stroke.path[1]].map { point in
                        let location = point.location.applying(stroke.transform)
                        return InkPoint(x: location.x, y: location.y, pressure: Double(max(0, min(1, point.force))))
                    }
                }
                let additionCount = converted.reduce(0) { $0 + $1.points.count }
                guard additionCount <= InkGeometryLimits.maximumPointCount - pointCount,
                      converted.count <= InkGeometryLimits.maximumStrokeCount - result.count else { throw LibraryError.tooLarge }
                pointCount += additionCount
                result.append(contentsOf: converted)
            }
            return result
        }

        #if DEBUG
        private func scheduleDiagnosticsIfRequested() {
            guard !didRunDiagnostics, ProcessInfo.processInfo.environment["INOTES_IOS_EDITOR_DIAGNOSTICS"] == "1" else { return }
            didRunDiagnostics = true
            DispatchQueue.main.async { [weak self] in self?.runLineDiagnostics() }
        }

        private func runLineDiagnostics() {
            guard let view else { return }
            let canvas = view.page.canvas
            let original = canvas.drawing
            let originalPattern = parent.linePattern
            parent.linePattern = .solid
            defer { parent.linePattern = originalPattern }
            var checks = 0
            isRunningDiagnostics = true
            let resultURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("iNotesEditorDiagnostics.json")
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.iPadEditorDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            var result: [String: Any]
            do {
                checks += try runWorkspaceArtworkDiagnostics()
                canvas.becomeFirstResponder()
                guard let manager = canvas.undoManager else { throw CocoaError(.featureUnsupported) }
                let groupsByEvent = manager.groupsByEvent
                manager.removeAllActions()
                manager.groupsByEvent = false
                defer { manager.removeAllActions(); manager.groupsByEvent = groupsByEvent }
                canvas.drawing = PKDrawing()
                commitLine(start: InkPoint(x: 100, y: 100, pressure: 0.4), end: InkPoint(x: 400, y: 103, pressure: 0.7), in: canvas)
                try require(canvas.drawing.strokes.count == 1, "One gesture must add one line")
                let horizontal = canvas.drawing.strokes[0]
                try require(horizontal.path.count == 2, "Straight line must have exactly two control points")
                try require(abs(horizontal.path[0].location.y - horizontal.path[1].location.y) < 0.001, "Nearly horizontal line must snap")
                try require(abs(horizontal.path[0].force - 0.4) < 0.001, "Start pressure must survive")
                try require(manager.canUndo, "Line must register native undo")
                manager.undo()
                try require(canvas.drawing.strokes.isEmpty && !manager.canUndo, "One undo must remove the whole gesture without an extra freehand entry")
                try require(manager.canRedo, "Line undo must register redo")
                manager.redo()
                try require(canvas.drawing.strokes.count == 1 && canvas.drawing.strokes[0].path.count == 2, "Redo must restore the straight line")
                commitLine(start: InkPoint(x: 450, y: 100), end: InkPoint(x: 453, y: 400), in: canvas)
                try require(canvas.drawing.strokes.count == 2, "Second gesture must add a second line")
                let vertical = canvas.drawing.strokes[1].path
                try require(abs(vertical[0].location.x - vertical[1].location.x) < 0.001, "Nearly vertical line must snap")
                manager.undo()
                try require(canvas.drawing.strokes.count == 1, "Undo must keep the earlier line")
                manager.redo()
                try require(canvas.drawing.strokes.count == 2, "Redo must restore the second line")
                let diagonal = InkLineGeometry.snappedEnd(start: InkPoint(x: 0, y: 0), end: InkPoint(x: 100, y: 130))
                try require(diagonal.x == 100 && diagonal.y == 130, "Arbitrary line angle must remain unchanged")
                let portable = try portableStrokes(from: canvas.drawing)
                try require(portable.count == 2 && portable.allSatisfy { $0.style == .pen && $0.points.count == 2 }, "Lines must survive as two-endpoint portable pen strokes")
                checks += try runV1Diagnostics()
                checks += try runThemeDiagnostics()
                checks += try runSelectionDiagnostics()
                checks += try runSelectAllRoutingDiagnostics()
                checks += try runRuledDiagnostics()
                checks += try runToolShortcutDiagnostics()
                checks += try runInputRoutingDiagnostics()
                checks += try runNativeTypingUndoDiagnostics()
                checks += try runDiagramSafetyDiagnostics()
                result = ["passed": true, "checks": checks, "message": "iPad straight lines, themes, ruled text baselines, canonical ink, mixed page selection and Select All routing from every tool, native metadata, clipboard duplication, atomic undo/redo and read-only diagram previews passed"]
            } catch { result = ["passed": false, "checks": checks, "message": error.localizedDescription] }
            isLoading = true
            canvas.drawing = original
            expectedDrawingData = original.dataRepresentation()
            isLoading = false
            isRunningDiagnostics = false
            do {
                try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL, options: .atomic)
                print("iNotes iPad diagnostics: \(result)")
            } catch { print("Could not write iPad diagnostics: \(error)") }
        }

        private func runDiagramSafetyDiagnostics() throws -> Int {
            var checks = 0
            func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
                guard value() else { throw NSError(domain: "iNotes.iPadDiagramDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            let shape = PageDiagram(kind: .roundedRectangle, x: 60, y: 80, width: 180, height: 100, text: "Saved नमस्ते")
            let table = PageDiagram(kind: .table, x: 300, y: 80, width: 240, height: 120, rows: 2, columns: 2,
                cells: ["A", "B", "日本語", "👋"])
            let arrow = PageDiagram(kind: .connector, start: InkPoint(x: 240, y: 130), end: InkPoint(x: 300, y: 140),
                startAttachment: PageDiagramAttachment(targetDiagramID: shape.id, side: .right),
                endAttachment: PageDiagramAttachment(targetDiagramID: table.id, side: .left), route: .elbow, arrowHeads: .both)
            let diagrams = [shape, table, arrow]
            let source = PageContent(text: "Preserved body", strokes: [InkStroke(points: [InkPoint(x: 40, y: 40), InkPoint(x: 80, y: 50)])], diagrams: diagrams)
            var writes = 0
            let parent = UnifiedPageEditor(text: .constant(source.text), rtfData: .constant(nil), strokes: .constant(source.strokes),
                pencilKitData: .constant(nil), diagrams: .constant(diagrams), tool: .text,
                onPageChange: { _ in writes += 1 })
            let coordinator = Coordinator(parent)
            let fixture = UnifiedPageScrollView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            coordinator.attach(fixture)
            defer { coordinator.detach(fixture) }
            coordinator.update(fixture, enabled: true)
            try require(coordinator.selection.content == source && fixture.page.diagramView.diagrams == diagrams,
                "Read-only iPad pages retain complete canonical diagrams alongside body text and ink")
            try require(!fixture.page.isUserInteractionEnabled && !fixture.page.textView.isEditable
                && !fixture.page.canvas.drawingGestureRecognizer.isEnabled && !fixture.page.selectionInputAllowed,
                "Diagram pages disable native text, ink and mixed page selection input")
            try require(fixture.subviews.compactMap { $0 as? UILabel }.contains { $0.text?.contains("Open it on Mac") == true && !$0.isHidden },
                "The actual page displays the Mac-only editing notice")
            try require(fixture.page.inputHitTest(at: CGPoint(x: 100, y: 100), isPencil: true) == nil,
                "Pencil input cannot reach an incomplete editable diagram page")
            var changed = source
            changed.text = "Rejected edit"
            coordinator.selection.commit(changed, action: "Unsupported Edit")
            coordinator.selection.perform(.delete)
            coordinator.publishText("Rejected text callback", rtf: nil)
            try require(writes == 0 && coordinator.selection.content == source,
                "Native and selection publishing paths preserve read-only diagram content")
            func preview(_ theme: PageTheme, values: [PageDiagram]) -> Data? {
                let preview = IOSPageDiagramView(frame: CGRect(x: 0, y: 0, width: 640, height: 300))
                preview.configure(values, theme: theme)
                return UIGraphicsImageRenderer(size: preview.bounds.size).image { _ in preview.draw(preview.bounds) }.pngData()
            }
            let light = preview(.light, values: diagrams), dark = preview(.pitchBlack, values: diagrams), blank = preview(.light, values: [])
            try require(light != nil && dark != nil && light != blank && light != dark,
                "The native iPad renderer draws shapes, connectors and table labels using resolved theme colors")
            coordinator.parent.theme = .pitchBlack
            coordinator.update(fixture, enabled: true)
            try require(coordinator.selection.content == source && fixture.page.diagramView.diagrams == diagrams && writes == 0,
                "Theme projection preserves canonical diagrams without publishing a page edit")
            let plain = UnifiedPageEditor(text: .constant("Editable"), rtfData: .constant(nil), strokes: .constant([]),
                pencilKitData: .constant(nil), tool: .diagram, onPageChange: { _ in writes += 1 })
            coordinator.parent = plain
            coordinator.update(fixture, enabled: true)
            try require(!fixture.page.canvas.drawingGestureRecognizer.isEnabled && fixture.page.diagramView.diagrams.isEmpty,
                "A stored Mac diagram-tool preference never becomes an accidental iPad pen gesture")
            let board = UIPasteboard.general
            let savedItems = board.items
            defer { board.items = savedItems }
            let payload = PageClipboardPayload(diagrams: diagrams)
            board.setData(try JSONEncoder().encode(payload), forPasteboardType: PageClipboardPayload.pasteboardType)
            let beforePaste = coordinator.selection.content
            var rejectedPaste = false
            coordinator.selection.onError = { _ in rejectedPaste = true }
            coordinator.selection.perform(.paste)
            try require(rejectedPaste && coordinator.selection.content == beforePaste && writes == 0,
                "A v4 diagram paste is explicitly rejected without dropping objects or editing the destination")
            rejectedPaste = false
            let nativeText = fixture.page.textView.text
            fixture.page.textView.paste(nil)
            try require(rejectedPaste && fixture.page.textView.text == nativeText && writes == 0,
                "Native body/text-box Paste also rejects unsupported diagram objects before a plain-text fallback")
            var invalid = shape
            invalid.width = .infinity
            let renderer = IOSPageDiagramView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            renderer.configure([invalid], theme: .light)
            try require(renderer.diagrams.isEmpty, "The native preview rejects invalid diagram geometry before rendering")
            renderer.configure(diagrams, theme: .light)
            renderer.show(pageRect: CGRect(x: 10, y: 99_000, width: 300, height: 400))
            try require(renderer.frame.size == CGSize(width: 300, height: 400) && renderer.bounds.origin.y == 99_000,
                "A long read-only page backs only its visible vector viewport")
            return checks
        }

        private func runWorkspaceArtworkDiagnostics() throws -> Int {
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.WorkspaceArtworkDiagnostics", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            try require(WorkspaceTheme(rawValue: "forest") == nil
                        && WorkspaceTheme(preferenceValue: "forest") == .nature
                        && WorkspaceTheme(preferenceValue: "unrecognized") == .classic,
                        "Removed Forest preferences must resolve to Nature and unknown preferences to Classic")
            try require(WorkspaceTheme.photographicThemes.count == 6
                        && WorkspaceTheme.openSkyscape.title == "Open Skyscape"
                        && WorkspaceTheme.rubyHills.title == "Ruby Hills",
                        "The six scenery choices must use their displayed names")
            try require(WorkspaceArtwork.url(theme: .classic, isDark: false) == nil
                        && WorkspaceArtwork.url(theme: .classic, isDark: true) == nil,
                        "Classic must not load photographic artwork")
            for theme in WorkspaceTheme.photographicThemes {
                var variants: [Data] = []
                for dark in [false, true] {
                    guard let url = WorkspaceArtwork.url(theme: theme, isDark: dark) else {
                        throw NSError(domain: "iNotes.WorkspaceArtworkDiagnostics", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Missing bundled \(theme.rawValue) \(dark ? "dark" : "light") artwork"])
                    }
                    let bytes = try Data(contentsOf: url)
                    let image = UIImage(data: bytes)
                    try require(image?.cgImage?.width == 1672 && image?.cgImage?.height == 941,
                                "The original \(theme.rawValue) photograph must decode from the iPad bundle")
                    try require(WorkspaceArtwork.image(theme: theme, isDark: dark) != nil,
                                "The iPad workspace must load its \(theme.rawValue) appearance")
                    variants.append(bytes)
                }
                try require(variants[0] != variants[1], "\(theme.rawValue) must have distinct light and dark photographs")
            }
            return checks
        }

        private func runV1Diagnostics() throws -> Int {
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.V1Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            let fixture = UnifiedPageScrollView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            let fixtureEditor = UnifiedPageEditor(text: .constant(""), rtfData: .constant(nil), strokes: .constant([]), pencilKitData: .constant(nil))
            let fixtureCoordinator = Coordinator(fixtureEditor)
            fixture.delegate = fixtureCoordinator
            fixtureCoordinator.attach(fixture)
            defer { fixtureCoordinator.detach(fixture) }
            fixture.zoomScale = 0.25
            fixture.resizePage()
            fixture.layoutIfNeeded()
            try require(abs(fixture.page.frame.midX - 500) < 0.1, "Zoomed-out paper must stay horizontally centered")
            try require(abs(fixture.page.frame.midY - 400) < 0.1, "Paper shorter than the viewport must stay vertically centered")
            fixture.frame.size.width = 1200
            fixture.layoutIfNeeded()
            try require(abs(fixture.page.frame.midX - 600) < 0.1, "Paper must recenter after the workspace changes size")

            let paper = fixture.page.paper
            paper.theme = .vintage
            try require(UIColor(cgColor: paper.layer.backgroundColor!).noteHex == PageTheme.vintage.paperHex,
                        "Vintage paper must use its own off-white background")
            let templateLayer = paper.layer.sublayers?[1] as? CAShapeLayer
            for style in InkPaper.allCases {
                paper.style = style
                paper.pageTemplate = .centerDivider
                for pattern in LinePattern.allCases {
                    paper.templateLinePattern = pattern
                    paper.layoutIfNeeded()
                    try require(abs((templateLayer?.path?.boundingBox.minX ?? -1) - 800) < 0.01,
                                "Center template must bisect every paper style")
                    try require((templateLayer?.lineDashPattern == nil) == (pattern == .solid),
                                "Template dash setting must match its selected pattern")
                }
                paper.pageTemplate = .leftMargin
                paper.layoutIfNeeded()
                let supported = style == .blank || style == .ruled
                try require((templateLayer?.path?.isEmpty == false) == supported,
                            "Left margin must be available only for plain and ruled paper")
                if supported {
                    try require(abs((templateLayer?.path?.boundingBox.minX ?? -1) - 80) < 0.01,
                                "Left margin must use the shared eighty-point inset")
                }
            }
            paper.frame.size.height = CGFloat(InkGeometryLimits.maximumPageDimension)
            paper.style = .ruled
            paper.visiblePageRect = CGRect(x: 0, y: 50_000, width: 1600, height: 800)
            paper.layoutIfNeeded()
            let rules = paper.layer.sublayers?.first as? CAShapeLayer
            var pathElements = 0
            rules?.path?.applyWithBlock { _ in pathElements += 1 }
            try require(pathElements < 100, "Long pages must build only visible paper guides with overscan")

            for pattern in [LinePattern.dashed, .dotted] {
                let stroke = InkStroke(points: [InkPoint(x: 100, y: 100), InkPoint(x: 400, y: 100)],
                                       width: 2.5, linePattern: pattern)
                let native = try PortableInkConverter.validatedDrawing(nil, fallback: [stroke])
                try require(native.strokes.count > 1, "Patterned ink must retain separate native visible segments")
                let reloaded = try PortableInkConverter.validatedDrawing(native.dataRepresentation(), fallback: [])
                let portable = PortableInkConverter.strokes(from: reloaded)
                try require(portable.count == native.strokes.count, "Pattern gaps must survive native serialization and portable conversion")
                let firstEnd = native.strokes[0].path.last!.location.x
                let secondStart = native.strokes[1].path.first!.location.x
                try require(secondStart > firstEnd + 1, "Dash and dot geometry must contain a real gap")
                guard let view else { continue }
                let canvas = view.page.canvas
                let before = canvas.drawing
                parent.linePattern = pattern
                commitLine(start: InkPoint(x: 100, y: 600), end: InkPoint(x: 400, y: 600), in: canvas)
                let count = canvas.drawing.strokes.count
                try require(count > before.strokes.count + 1, "Patterned line gesture must insert its visible segments")
                canvas.undoManager?.undo()
                try require(canvas.drawing.strokes.count == before.strokes.count, "One undo must remove an entire patterned gesture")
                canvas.undoManager?.redo()
                try require(canvas.drawing.strokes.count == count, "One redo must restore the entire patterned gesture")
            }
            parent.linePattern = .solid
            let excessive = InkStroke(points: [InkPoint(x: 10, y: 1e12), InkPoint(x: 20, y: 1e12)])
            var rejected = false
            do { _ = try PortableInkConverter.validatedDrawing(nil, fallback: [excessive]) } catch { rejected = true }
            try require(rejected, "Archive portable ink must reject extreme coordinates before PencilKit conversion")
            var transformed = PortableInkConverter.drawing(from: [InkStroke(points: [InkPoint(x: 1, y: 1), InkPoint(x: 2, y: 2)])]).strokes[0]
            transformed.transform = CGAffineTransform(translationX: 0, y: 1e12)
            rejected = false
            do { _ = try PortableInkConverter.validatedDrawing(PKDrawing(strokes: [transformed]).dataRepresentation(), fallback: []) } catch { rejected = true }
            try require(rejected, "Archive native ink must reject extreme transforms before rendering or sampling")
            let oversizedPattern = InkStroke(points: [InkPoint(x: 0, y: 0), InkPoint(x: 0, y: 100_000)], width: 0.5, linePattern: .dotted)
            rejected = false
            do { _ = try PortableInkConverter.validatedDrawing(nil, fallback: [oversizedPattern]) } catch { rejected = true }
            try require(rejected, "Pattern expansion must reject excessive native segment counts before allocation")
            return checks
        }

        private func runThemeDiagnostics() throws -> Int {
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.iPadThemeDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            let originalStrokes = [InkStroke(points: [InkPoint(x: 30, y: 40), InkPoint(x: 160, y: 60)], colorHex: "#102040")]
            let originalDrawing = PortableInkConverter.drawing(from: originalStrokes)
            let originalData = originalDrawing.dataRepresentation()
            var savedData: Data? = originalData
            var savedStrokes = originalStrokes
            var writes = 0
            let testEditor = UnifiedPageEditor(text: .constant("Theme preservation"), rtfData: .constant(nil),
                                              strokes: Binding(get: { savedStrokes }, set: { savedStrokes = $0 }),
                                              pencilKitData: Binding(get: { savedData }, set: { savedData = $0 }),
                                              tool: .pen, colorHex: "#30343B", paper: .dotted, theme: .dark,
                                              onInkChange: { strokes, data in savedStrokes = strokes; savedData = data; writes += 1 })
            let coordinator = Coordinator(testEditor)
            let testView = UnifiedPageScrollView()
            coordinator.attach(testView)
            defer { coordinator.detach(testView) }
            coordinator.update(testView, enabled: true)
            testView.page.paper.layoutIfNeeded()
            try require(testView.page.canvas.drawing.strokes[0].ink.color.noteHex != "#102040", "Dark paper must lighten custom navy ink")
            try require(coordinator.canonicalDrawing(from: testView.page.canvas.drawing, theme: .dark).strokes[0].ink.color.noteHex == "#102040", "Custom canonical ink color must survive dark display")
            try require(savedData == originalData && writes == 0, "Rendering a dark page must not save display colors")
            try require(UIColor(cgColor: testView.page.paper.layer.backgroundColor!).noteHex == PageTheme.dark.paperHex, "Dark paper must use its theme background")
            try require(testView.page.canvas.overrideUserInterfaceStyle == .light, "PencilKit must not apply a second dark-ink transform")
            try require(coordinator.picker.overrideUserInterfaceStyle == .dark, "The native tool palette must still use dark UI")
            try require(coordinator.picker.colorUserInterfaceStyle == .light, "Native palette colors must use the canvas display color space")
            let rules = testView.page.paper.layer.sublayers?.first as? CAShapeLayer
            try require(rules?.lineWidth == 3, "Dots must retain a visible three-point diameter")
            for _ in 0..<3 {
                #if compiler(>=6.4)
                let previousDisplayStroke = testView.page.canvas.drawing.strokes[0]
                #endif
                coordinator.parent.theme = .light
                coordinator.update(testView, enabled: true)
                try require(testView.page.canvas.drawing.strokes[0].ink.color.noteHex == "#102040", "Light page must restore the original custom ink")
                #if compiler(>=6.4)
                if #available(iOS 27, *) {
                    try require(testView.page.canvas.drawing.strokes[0].id != previousDisplayStroke.id, "Theme projection must invalidate PencilKit's cached display color")
                }
                #endif
                coordinator.parent.theme = .dark
                coordinator.update(testView, enabled: true)
            }
            try require(savedData == originalData && writes == 0, "Repeated appearance changes must preserve archived PencilKit bytes")
            let selected = testView.page.canvas.tool as? PKInkingTool
            try require(selected?.color.noteHex == PageTheme.dark.resolvedInkHex("#30343B"), "Dark pen tool must use a light display color")
            coordinator.commitLine(start: InkPoint(x: 200, y: 200), end: InkPoint(x: 400, y: 204), in: testView.page.canvas)
            guard let data = savedData else { throw CocoaError(.fileReadCorruptFile) }
            let saved = try PKDrawing(data: data)
            try require(writes == 1 && saved.strokes.count == 2, "A dark ink gesture must persist one atomic edit")
            try require(saved.strokes[0].ink.color.noteHex == "#102040" && saved.strokes[1].ink.color.noteHex == "#30343B", "Saving on dark paper must preserve old custom ink and canonical new pen color")
            return checks
        }

        private func runSelectionDiagnostics() throws -> Int {
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.iPadSelectionDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            let ink = [InkStroke(points: [InkPoint(x: 100, y: 160), InkPoint(x: 280, y: 160)], colorHex: "#102040", width: 4, style: .pencil)]
            let original = PortableInkConverter.drawing(from: ink).strokes[0]
            let masked = PKStroke(ink: original.ink, path: original.path,
                                  transform: CGAffineTransform(translationX: 5, y: 7),
                                  mask: UIBezierPath(rect: CGRect(x: 90, y: 145, width: 210, height: 40)), randomSeed: original.randomSeed)
            let native = PKDrawing(strokes: [masked])
            let source = PageContent(text: "Mixed नमस्ते 👋\nText and handwriting", strokes: PortableInkConverter.strokes(from: native),
                                     pencilKitData: native.dataRepresentation(),
                                     textBoxes: [PageTextBox(x: 420, y: 220, text: "Movable box")],
                                     equations: [NoteEquation(latex: "E=mc^2", x: 330, y: 330, width: 120, height: 50)])
            var saved = source, writes = 0
            let editor = UnifiedPageEditor(text: .constant(source.text), rtfData: .constant(source.rtfData),
                                           strokes: .constant(source.strokes), pencilKitData: .constant(source.pencilKitData),
                                           textBoxes: .constant(source.textBoxes), equations: .constant(source.equations),
                                           tool: .select, theme: .dark, onPageChange: { value in saved = value; writes += 1 })
            let coordinator = Coordinator(editor)
            let view = UnifiedPageScrollView()
            coordinator.attach(view)
            defer { coordinator.detach(view) }
            coordinator.update(view, enabled: true)
            let controller = coordinator.selection
            let polygon = PageSelectionGeometry.rectangle(from: InkPoint(x: 0, y: 0), to: InkPoint(x: 900, y: 500))
            controller.select(polygon: polygon)
            try require(!controller.selection.textRanges.isEmpty, "Selection must include rendered UTF-16 text glyphs")
            try require(controller.selection.nativeStrokes == [0], "The same selection must include canonical native PencilKit ink")
            try require(controller.selection.textBoxes == Set(source.textBoxes.map(\.id)) && controller.selection.equations == Set(source.equations.map(\.id)), "One selection must include movable text and equations")
            try require(controller.selection.textRanges.allSatisfy { NSMaxRange($0) <= (source.text as NSString).length }, "Selected Unicode ranges must stay within the UTF-16 body")
            guard let payload = controller.clipboardPayload(), let payloadData = try? JSONEncoder().encode(payload),
                  let decoded = try? PageClipboardPayload.decodeValidated(payloadData) else { throw CocoaError(.fileReadCorruptFile) }
            try require(decoded.pencilKitData != nil && decoded.textBoxes.count > source.textBoxes.count && decoded.equations == source.equations, "Clipboard preserves native ink and promotes selected body runs into rich text boxes")
            let promoted = controller.promotedContent()
            let moved = controller.translated(promoted.0, selection: promoted.1, dx: 35, dy: 45)
            guard let movedData = moved.pencilKitData else { throw CocoaError(.fileReadCorruptFile) }
            let movedInk = try PKDrawing(data: movedData).strokes[0]
            try require(movedInk.path.count == masked.path.count && movedInk.path.creationDate == masked.path.creationDate, "Moving ink must preserve its native path and creation date")
            try require(movedInk.mask?.bounds == masked.mask?.bounds && movedInk.randomSeed == masked.randomSeed, "Moving ink must preserve mask and texture seed")
            try require(movedInk.ink.color.noteHex == "#102040" && movedInk.ink.inkType == masked.ink.inkType, "A dark-page move must keep canonical ink color and instrument")
            try require(abs(movedInk.transform.tx - masked.transform.tx - 35) < 0.001 && abs(movedInk.transform.ty - masked.transform.ty - 45) < 0.001, "Native ink and page objects use the same translation")
            controller.preview(moved)
            try require(saved == source && writes == 0, "Drag previews must not persist page changes")
            controller.cancelPreview()
            try require(saved == source && controller.content == source && writes == 0, "Cancelling a drag must preserve every original page byte")
            controller.selection = promoted.1
            controller.commit(moved, previous: source, action: "Move Selection")
            try require(saved == moved && writes == 1 && controller.history.canUndo, "Mixed movement must save one atomic PageContent transaction")
            controller.history.undo()
            try require(saved == source && saved.pencilKitData == source.pencilKitData, "One group undo restores original body, objects, and exact canonical ink archive")
            controller.history.redo()
            try require(saved == moved, "One group redo restores the complete moved selection")
            controller.perform(.selectAll)
            controller.perform(.delete)
            try require(saved.text.isEmpty && saved.strokes.isEmpty && saved.textBoxes.isEmpty && saved.equations.isEmpty, "Group delete must remove all selected object types together")
            controller.history.undo()
            try require(saved == moved, "One group-delete undo must restore all object types")
            controller.history.redo()
            try require(saved.text.isEmpty && saved.textBoxes.isEmpty && saved.equations.isEmpty, "One group-delete redo must remove the same selection")
            controller.load(source)
            coordinator.render(source, on: view, theme: .dark)
            controller.selection = IOSPageSelection(equations: Set(source.equations.map(\.id)))
            controller.perform(.duplicate)
            try require(controller.content.equations.count == 2 && controller.content.textBoxes.count == source.textBoxes.count, "Duplicating an equation must not add a duplicate plaintext LaTeX box")
            try require(Set(controller.content.equations.map(\.id)).count == 2, "Duplicated equations must receive a fresh UUID")
            controller.load(source)
            coordinator.render(source, on: view, theme: .dark)
            controller.selection = IOSPageSelection(strokes: Set(source.strokes.map(\.id)), nativeStrokes: [0])
            controller.perform(.duplicate)
            let duplicated = try PKDrawing(data: controller.content.pencilKitData!)
            try require(duplicated.strokes.count == 2 && duplicated.strokes[1].mask?.bounds == masked.mask?.bounds && duplicated.strokes[1].ink.color.noteHex == "#102040", "Duplicating native ink retains its mask and canonical color")
            #if compiler(>=6.4)
            if #available(iOS 27, *) { try require(duplicated.strokes[0].id != duplicated.strokes[1].id, "Duplicated native strokes must receive fresh PencilKit identities") }
            #endif
            controller.load(source)
            coordinator.render(source, on: view, theme: .dark)
            controller.select(polygon: [InkPoint(x: 0, y: 0), InkPoint(x: 400, y: 0), InkPoint(x: 0, y: 400)])
            try require(controller.selection.equations.isEmpty, "Lasso hit-testing must follow its polygon instead of the bounding rectangle")
            coordinator.parent.paper = .ruled
            coordinator.update(view, enabled: true)
            controller.selection = IOSPageSelection(strokes: Set(source.strokes.map(\.id)), nativeStrokes: [0], textBoxes: Set(source.textBoxes.map(\.id)))
            let snapped = controller.translated(source, selection: controller.selection, dx: 15, dy: 45)
            let snappedInk = try PKDrawing(data: snapped.pencilKitData!).strokes[0]
            try require(snapped.textBoxes[0].y == source.textBoxes[0].y + 56 && abs(snappedInk.transform.ty - masked.transform.ty - 56) < 0.001, "Ruled mixed movement must snap text and native ink by the same 28-point delta")
            controller.perform(.duplicate)
            let snappedCopy = try PKDrawing(data: controller.content.pencilKitData!).strokes[1]
            try require(controller.content.textBoxes.last!.y == source.textBoxes[0].y + 28 && abs(snappedCopy.transform.ty - masked.transform.ty - 28) < 0.001, "Ruled mixed duplication must offset text and ink together by one rule")
            coordinator.parent.paper = .blank
            coordinator.update(view, enabled: true)
            let free = controller.translated(source, selection: IOSPageSelection(textBoxes: Set(source.textBoxes.map(\.id))), dx: 0, dy: 45)
            try require(free.textBoxes[0].y == source.textBoxes[0].y + 45, "Non-ruled paper must keep free vertical positioning")
            controller.select(polygon: PageSelectionGeometry.rectangle(from: InkPoint(x: 1200, y: 40), to: InkPoint(x: 1500, y: 90)))
            try require(controller.selection.textRanges.isEmpty, "Selecting the empty tail of a text line must not select its invisible newline")
            let longLines = (0..<10).map { index in
                InkStroke(points: [InkPoint(x: 0, y: Double(index * 10)), InkPoint(x: 100_000, y: Double(index * 10))])
            }
            let longNative = PortableInkConverter.drawing(from: longLines)
            var rejectedLargeSampling = false
            do { _ = try PortableInkConverter.validatedClipboardDrawing(longNative.dataRepresentation(), fallback: []) }
            catch { rejectedLargeSampling = true }
            try require(rejectedLargeSampling, "Native clipboard sampling budget must reject long paths before allocating portable samples")
            let outsideNative = PortableInkConverter.drawing(from: [InkStroke(points: [InkPoint(x: 100_001, y: 10), InkPoint(x: 100_002, y: 20)])])
            var rejectedCoordinates = false
            do { _ = try PortableInkConverter.validatedClipboardDrawing(outsideNative.dataRepresentation(), fallback: []) }
            catch { rejectedCoordinates = true }
            try require(rejectedCoordinates, "Native clipboard must reject unsupported coordinates before paste")
            let mixed = IOSPageSelection(strokes: Set(source.strokes.map(\.id)), nativeStrokes: [0],
                textBoxes: Set(source.textBoxes.map(\.id)), equations: Set(source.equations.map(\.id)))
            let right = controller.translated(source, selection: mixed, dx: 100_000, dy: 0)
            let rightInk = try PKDrawing(data: right.pencilKitData!).strokes[0]
            let actualDX = right.textBoxes[0].x - source.textBoxes[0].x
            try require(right.textBoxes[0].x + right.textBoxes[0].width <= 1600.001
                && abs(right.equations[0].x - source.equations[0].x - actualDX) < 0.001
                && abs(rightInk.transform.tx - masked.transform.tx - actualDX) < 0.001,
                "Right-edge movement must fit full text width and keep the entire mixed group together")
            var imported = source
            imported.textBoxes = [PageTextBox(x: 1550, y: 220, width: 400, text: "Imported position")]
            controller.load(imported)
            coordinator.render(imported, on: view, theme: .dark)
            controller.selection = IOSPageSelection(textBoxes: Set(imported.textBoxes.map(\.id)))
            controller.perform(.duplicate)
            try require(controller.content.textBoxes[0] == imported.textBoxes[0]
                && controller.content.textBoxes.last!.x + controller.content.textBoxes.last!.width <= 1600.001
                && controller.content.textBoxes.last!.width == 400,
                "New pastes fit the page without changing or reflowing imported originals")
            var oversized = source
            oversized.textBoxes = [PageTextBox(x: 40, y: 200, width: 2000, text: "Oversized imported box")]
            controller.load(oversized)
            coordinator.render(oversized, on: view, theme: .dark)
            controller.selection = IOSPageSelection(textBoxes: Set(oversized.textBoxes.map(\.id)))
            let priorWrites = writes
            controller.perform(.duplicate)
            try require(controller.content == oversized && writes == priorWrites, "Oversized new paste must be rejected before modifying any page object")
            return checks
        }

        private func runSelectAllRoutingDiagnostics() throws -> Int {
            guard let originalView = view, let originalWindow = originalView.window, let scene = originalWindow.windowScene else {
                throw CocoaError(.featureUnsupported)
            }
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.iPadSelectAllDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            let ink = [InkStroke(points: [InkPoint(x: 80, y: 140), InkPoint(x: 240, y: 160)])]
            let drawing = PortableInkConverter.drawing(from: ink)
            let source = PageContent(text: "Select all नमस्ते 👋", strokes: ink, pencilKitData: drawing.dataRepresentation(),
                                     textBoxes: [PageTextBox(x: 420, y: 220, text: "Movable text")],
                                     equations: [NoteEquation(latex: "x^2", x: 350, y: 350)])
            var saved = source, writes = 0
            let editor = UnifiedPageEditor(text: .constant(source.text), rtfData: .constant(source.rtfData),
                                          strokes: .constant(source.strokes), pencilKitData: .constant(source.pencilKitData),
                                          textBoxes: .constant(source.textBoxes), equations: .constant(source.equations),
                                          tool: .pen, onPageChange: { saved = $0; writes += 1 })
            let coordinator = Coordinator(editor)
            let testView = UnifiedPageScrollView()
            let host = UIViewController()
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.windowLevel = originalWindow.windowLevel + 1
            host.view.addSubview(testView)
            testView.frame = host.view.bounds
            coordinator.attach(testView)
            window.makeKeyAndVisible()
            defer {
                coordinator.detach(testView)
                window.isHidden = true
                window.rootViewController = nil
                originalWindow.makeKey()
                focus(parent.tool, in: originalView)
            }
            let page = testView.page
            let controller = coordinator.selection
            for tool in InkTool.allCases {
                coordinator.parent.tool = tool
                coordinator.update(testView, enabled: true)
                coordinator.focus(tool, in: testView)
                if tool == .text { page.textView.selectAll(nil) }
                else if tool == .select || tool == .lasso { page.selectionView.selectAll(nil) }
                else { page.canvas.selectAll(nil) }
                try require(controller.selection.strokes == Set(source.strokes.map(\.id)) && controller.selection.nativeStrokes == [0],
                            "Select All from \(tool.rawValue) includes portable and native ink")
                try require(controller.selection.textBoxes == Set(source.textBoxes.map(\.id)) && controller.selection.equations == Set(source.equations.map(\.id)),
                            "Select All from \(tool.rawValue) includes positioned text and equations")
                try require(controller.selection.textRanges == [NSRange(location: 0, length: (source.text as NSString).length)],
                            "Select All from \(tool.rawValue) includes the complete UTF-16 body")
                try require(!page.selectionView.isHidden && page.selectionView.isFirstResponder && coordinator.parent.tool == tool,
                            "Select All from \(tool.rawValue) shows the selection and preserves the chosen tool")
                try require(controller.content == source && saved == source && writes == 0,
                            "Select All from \(tool.rawValue) must not save or rewrite page content")
                let command = page.keyCommands?.first { $0.input == "a" && $0.modifierFlags == .command }
                try require(command?.action == #selector(UnifiedPencilPage.selectAll(_:)) && command?.wantsPriorityOverSystemBehavior == true,
                            "Every page tool exposes the page-local Command-A action")
                page.beginPageInteraction()
                if tool != .select && tool != .lasso {
                    try require(controller.selection.isEmpty && page.selectionView.isHidden,
                                "The next ordinary \(tool.rawValue) gesture clears temporary selection")
                } else {
                    try require(!controller.selection.isEmpty && !page.selectionView.isHidden,
                                "Select and Lasso retain their normal draggable selection")
                }
            }
            coordinator.parent.tool = .text
            coordinator.update(testView, enabled: true)
            coordinator.focus(.text, in: testView)
            guard let box = page.textBoxViews[source.textBoxes[0].id] else { throw CocoaError(.featureUnsupported) }
            try require(box.editor.becomeFirstResponder(), "Movable-text Select All uses a native focused editor")
            box.editor.selectAll(nil)
            try require(controller.selection.textBoxes == Set(source.textBoxes.map(\.id)) && controller.selection.nativeStrokes == [0],
                        "Select All inside movable text selects the entire mixed page")
            controller.perform(.delete)
            try require(saved.text.isEmpty && saved.strokes.isEmpty && saved.textBoxes.isEmpty && saved.equations.isEmpty,
                        "Delete after Select All removes the whole mixed page atomically")
            controller.history.undo()
            try require(saved == source, "One undo restores every page element after Select All and Delete")
            controller.perform(.clear)
            let outside = UITextField(frame: CGRect(x: 20, y: 20, width: 300, height: 40))
            outside.text = "Search and title text"
            host.view.addSubview(outside)
            try require(outside.becomeFirstResponder(), "External input safety uses a real text-field responder")
            outside.selectAll(nil)
            try require(outside.selectedTextRange.map { outside.offset(from: $0.start, to: $0.end) } == outside.text!.utf16.count
                && controller.selection.isEmpty, "Search/title Select All stays in its focused field")
            let equationInput = UITextView(frame: CGRect(x: 20, y: 80, width: 300, height: 80))
            equationInput.text = "\\frac{1}{2}"
            host.view.addSubview(equationInput)
            try require(equationInput.becomeFirstResponder(), "Equation-source safety uses a real external text editor")
            equationInput.selectAll(nil)
            try require(equationInput.selectedRange == NSRange(location: 0, length: equationInput.text.utf16.count)
                && controller.selection.isEmpty && saved == source, "Equation-source Select All preserves ordinary native behavior")
            return checks
        }

        private func runRuledDiagnostics() throws -> Int {
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.iPadRuledDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            func metrics(_ textView: UITextView, pageY: CGFloat) -> [(baseline: CGFloat, height: CGFloat)] {
                let layout = textView.layoutManager
                layout.ensureLayout(for: textView.textContainer)
                var result: [(CGFloat, CGFloat)] = []
                layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, range, _ in
                    guard range.length > 0 else { return }
                    result.append((pageY + textView.textContainerInset.top + rect.minY + layout.location(forGlyphAt: range.location).y, rect.height))
                }
                return result
            }
            func aligned(_ values: [(baseline: CGFloat, height: CGFloat)]) -> Bool {
                !values.isEmpty && values.allSatisfy { abs(($0.baseline + 1) - (($0.baseline + 1) / 28).rounded() * 28) <= 0.75 }
            }
            let text = "Heading\n" + String(repeating: "Wrapped नमस्ते 👋 handwriting and text stay together. ", count: 35)
            let body = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16)])
            body.addAttribute(.font, value: UIFont.systemFont(ofSize: 24, weight: .bold), range: NSRange(location: 0, length: 7))
            let rtf = try body.data(from: NSRange(location: 0, length: body.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let boxText = NSAttributedString(string: String(repeating: "Wrapped movable नमस्ते 👋 text. ", count: 8), attributes: [.font: UIFont.systemFont(ofSize: 16)])
            let boxRTF = try boxText.data(from: NSRange(location: 0, length: boxText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let box = PageTextBox(x: 470, y: 73, width: 250, text: boxText.string, rtfData: boxRTF)
            let source = PageContent(text: text, rtfData: rtf, textBoxes: [box])
            var writes = 0
            let editor = UnifiedPageEditor(text: .constant(text), rtfData: .constant(rtf), strokes: .constant([]), pencilKitData: .constant(nil),
                                           textBoxes: .constant([box]), paper: .blank, onPageChange: { _ in writes += 1 })
            let coordinator = Coordinator(editor)
            let view = UnifiedPageScrollView()
            coordinator.attach(view)
            defer { coordinator.detach(view) }
            coordinator.update(view, enabled: true)
            let canonical = ThemeTextAttributes.canonical(view.page.textView.attributedText, theme: .light)
            coordinator.parent.paper = .ruled
            coordinator.update(view, enabled: true)
            let main = metrics(view.page.textView, pageY: view.page.textView.frame.minY)
            try require(main.count > 3 && aligned(main), "Ruled wrapped body glyph baselines must meet page rules: \(main.map(\.baseline))")
            try require(main.allSatisfy { abs($0.height - ($0.height / 28).rounded() * 28) <= 0.75 }, "Ruled line fragment heights must use complete 28-point rows")
            try require((main.first?.height ?? 0) >= 56, "A 24-point heading must receive sufficient ruled line height")
            let boxView = view.page.textBoxViews[box.id]!
            let boxes = metrics(boxView.editor, pageY: boxView.frame.minY + boxView.editor.frame.minY)
            try require(boxes.count > 1 && aligned(boxes), "Movable textbox wrapped glyphs must align with the same page rules: \(boxes.map(\.baseline))")
            try require(ThemeTextAttributes.canonical(view.page.textView.attributedText, theme: .light).isEqual(to: canonical), "Rule alignment must not rewrite canonical paragraph or font attributes")
            coordinator.parent.theme = .dark
            coordinator.update(view, enabled: true)
            try require(aligned(metrics(view.page.textView, pageY: 40)), "Dark-page text must keep identical ruled baseline alignment")
            try require(writes == 0 && coordinator.selection.content == source, "Changing paper/theme must not persist line metrics or alter rich text bytes")
            coordinator.parent.paper = .blank
            coordinator.update(view, enabled: true)
            try require(view.page.textView.layoutManager.delegate == nil, "Blank paper must restore native free text layout")
            let empty = UITextView(frame: CGRect(x: 0, y: 0, width: 250, height: 100))
            empty.textContainerInset = .zero
            empty.typingAttributes = [.font: UIFont.systemFont(ofSize: 16)]
            RuledTextLayout.attach(to: empty, paper: .ruled, pageOriginY: 73)
            empty.layoutManager.ensureLayout(for: empty.textContainer)
            let caret = empty.caretRect(for: empty.beginningOfDocument)
            let emptyBaseline = 73 + caret.minY + UIFont.systemFont(ofSize: 16).ascender
            try require(abs((emptyBaseline + 1) - ((emptyBaseline + 1) / 28).rounded() * 28) <= 1, "An empty movable textbox caret must start on a ruled baseline: \(emptyBaseline)")
            return checks
        }

        private func runToolShortcutDiagnostics() throws -> Int {
            guard let view else { throw CocoaError(.featureUnsupported) }
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.iPadShortcutDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            func plain(_ commands: [UIKeyCommand]) -> [UIKeyCommand] {
                commands.filter { $0.modifierFlags.intersection([.command, .alternate, .control]).isEmpty }
            }
            let commands = ToolShortcuts.keyCommands(includePlain: true, action: #selector(UnifiedPencilPage.activateToolShortcut(_:)))
            try require(commands.count == ToolShortcuts.all.count * 2 && Set(commands.compactMap { ToolShortcuts.tool(for: $0) }) == Set(ToolShortcuts.all.map(\.tool)), "Every tool shortcut must have plain and safe modified variants")
            try require(ToolShortcuts.match(key: "p", shifted: true) == .pencil && ToolShortcuts.match(key: "l", shifted: true) == .line && ToolShortcuts.match(key: "l", shifted: false) == .lasso, "Shift variants must distinguish pencil and straight line")
            let page = view.page
            let previousTool = parent.tool
            let previousText = page.textView.text
            let previousRTF = richTextCoordinator.lastRTF
            let previousOffset = view.contentOffset
            defer {
                parent.tool = previousTool
                update(view, enabled: true)
                focus(previousTool, in: view)
            }
            parent.tool = .pen
            update(view, enabled: true)
            page.endEditing(true)
            page.canvas.becomeFirstResponder()
            try require(plain(page.keyCommands ?? []).count == ToolShortcuts.all.count, "Focused drawing page must expose plain tool letters")
            try require(page.textView.becomeFirstResponder(), "Shortcut safety must be tested with a real native text responder")
            let bodyCommands = page.keyCommands ?? []
            try require(plain(bodyCommands).isEmpty && bodyCommands.count == ToolShortcuts.all.count + 1, "Typing in body text must preserve ordinary letters and expose modified tools plus page Select All")
            page.textToolSelected = true
            page.textView.resignFirstResponder()
            page.canvas.becomeFirstResponder()
            try require(plain(page.keyCommands ?? []).isEmpty, "Text mode must never reinterpret ordinary letters even while focus is temporarily elsewhere")
            NotificationCenter.default.post(name: .noteToolFocus, object: InkTool.text)
            try require(page.textView.isFirstResponder && page.textToolSelected && !page.canvas.drawingGestureRecognizer.isEnabled,
                        "A requested Text focus must use the notification tool rather than stale parent Pen state")
            page.textView.resignFirstResponder()
            NotificationCenter.default.post(name: .noteToolFocus, object: InkTool.text)
            try require(page.textView.isFirstResponder, "Clicking an already selected Text tool must recover native keyboard focus")
            let box = IOSTextBoxView(box: PageTextBox(x: 60, y: 300, text: "Typing safety"), theme: parent.theme)
            let id = UUID()
            page.textBoxViews[id] = box
            page.insertSubview(box, belowSubview: page.canvas)
            defer {
                box.editor.resignFirstResponder()
                page.textBoxViews.removeValue(forKey: id)
                box.removeFromSuperview()
                page.canvas.becomeFirstResponder()
                view.contentOffset = previousOffset
            }
            try require(box.editor.becomeFirstResponder(), "Shortcut safety must cover a native movable-text editor")
            let boxCommands = page.keyCommands ?? []
            try require(plain(boxCommands).isEmpty && boxCommands.count == ToolShortcuts.all.count + 1, "Typing in a movable textbox must preserve ordinary letters")
            try require(page.textView.text == previousText && richTextCoordinator.lastRTF == previousRTF && box.editor.text == "Typing safety", "Inspecting tool shortcuts must not edit native text or rich-text bytes")
            return checks
        }

        private func runInputRoutingDiagnostics() throws -> Int {
            guard let view else { throw CocoaError(.featureUnsupported) }
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.iPadInputRoutingDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            func belongs(_ hit: UIView?, to target: UIView) -> Bool { hit === target || hit?.isDescendant(of: target) == true }
            let page = view.page
            let oldTool = parent.tool
            let oldCallback = page.onPencil
            var pencilRoutes = 0
            page.onPencil = { pencilRoutes += 1 }
            defer {
                page.onPencil = oldCallback
                parent.tool = oldTool
                update(view, enabled: true)
                focus(oldTool, in: view)
            }
            parent.tool = .text
            update(view, enabled: true)
            focus(.text, in: view)
            try require(page.textView.isFirstResponder && !picker.isVisible, "Text mode must retain native keyboard focus and hide the ink palette")
            let candidates = [CGPoint(x: 100, y: 100), CGPoint(x: 1400, y: 120), CGPoint(x: 1450, y: 1800), CGPoint(x: 100, y: 2100)]
            let point = candidates.first(where: { point in
                !page.textBoxViews.values.contains(where: { $0.frame.contains(point) }) && !page.equationViews.values.contains(where: { $0.frame.contains(point) })
            }) ?? CGPoint(x: 10, y: page.bounds.height - 5)
            try require(belongs(page.inputHitTest(at: point, isPencil: false), to: page.textView), "Text mode routes finger/pointer caret placement to native text")
            try require(belongs(page.inputHitTest(at: point, isPencil: true), to: page.textView)
                && page.textView.isFirstResponder && pencilRoutes == 0,
                "Text mode routes Pencil text entry without activating ink or stealing keyboard focus")
            try require(belongs(page.inputHitTest(at: CGPoint(x: 5, y: page.bounds.height - 5), isPencil: true), to: page.textView) && pencilRoutes == 0,
                        "Text mode page margins must not fall through to the ink canvas")
            let box = IOSTextBoxView(box: PageTextBox(x: 500, y: page.bounds.height - 60, text: "Text routing fixture"), theme: parent.theme)
            let id = UUID()
            page.textBoxViews[id] = box
            page.insertSubview(box, belowSubview: page.canvas)
            defer { page.textBoxViews.removeValue(forKey: id); box.removeFromSuperview() }
            try require(belongs(page.inputHitTest(at: CGPoint(x: 510, y: box.frame.minY + 5), isPencil: true), to: box.editor),
                        "Text mode must also route stylus text entry to movable native text boxes")
            parent.tool = .pen
            update(view, enabled: true)
            focus(.pen, in: view)
            try require(belongs(page.inputHitTest(at: point, isPencil: true), to: page.canvas) && pencilRoutes == 1,
                        "Pen mode routes a Pencil-typed input to the canvas instead of a text editor")
            return checks
        }

        private func runNativeTypingUndoDiagnostics() throws -> Int {
            guard let originalView = view, let originalWindow = originalView.window, let scene = originalWindow.windowScene else {
                throw CocoaError(.featureUnsupported)
            }
            var checks = 0
            func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
                if !condition() { throw NSError(domain: "iNotes.iPadTypingUndoDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                checks += 1
            }
            let originalText = originalView.page.textView.text
            let originalRTF = richTextCoordinator.lastRTF
            let host = UIViewController()
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.windowLevel = originalWindow.windowLevel + 1
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                originalWindow.makeKey()
                focus(parent.tool, in: originalView)
            }
            for theme in [PageTheme.light, .dark] {
                let seed = "Undo seed नमस्ते"
                let attributed = NSAttributedString(string: seed, attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor(noteHex: "#3869B2")
                ])
                let initialRTF = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                var savedText = seed
                var savedRTF: Data? = initialRTF
                let delegate = RichTextEditor.Coordinator(RichTextEditor(text: .constant(seed), rtfData: .constant(initialRTF), theme: theme,
                    onChange: { text, data in savedText = text; savedRTF = data }))
                let editor = UITextView(frame: CGRect(x: 40, y: 40, width: 600, height: 240))
                editor.allowsEditingTextAttributes = true
                editor.delegate = delegate
                host.view.addSubview(editor)
                delegate.load(text: seed, rtf: initialRTF, into: editor)
                try require(editor.becomeFirstResponder(), "Native typing undo must use a real first-responder UITextView in \(theme.rawValue) mode")
                guard let manager = editor.undoManager else { throw CocoaError(.featureUnsupported) }
                if let outside = originalView.page.textView.undoManager, manager === outside {
                    throw NSError(domain: "iNotes.iPadTypingUndoDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "The isolated typing fixture unexpectedly shares the real page's undo manager"])
                }
                let grouped = manager.groupsByEvent
                manager.groupsByEvent = false
                manager.levelsOfUndo = 50
                defer {
                    manager.removeAllActions()
                    manager.groupsByEvent = grouped
                    editor.resignFirstResponder()
                    editor.removeFromSuperview()
                }
                // Normalize the baseline through the same persistence delegate.
                delegate.textViewDidChange(editor)
                let baselineRTF = delegate.lastRTF
                manager.removeAllActions()
                editor.selectedRange = NSRange(location: (seed as NSString).length, length: 0)
                // Native/custom typing attributes may lack our display marker;
                // the delegate must project attributes without replacing text.
                editor.typingAttributes.removeValue(forKey: ThemeTextAttributes.canonicalColorKey)
                manager.beginUndoGrouping()
                editor.insertText(" zé👋")
                editor.delegate?.textViewDidChange?(editor)
                manager.endUndoGrouping()
                let typed = seed + " zé👋"
                let typedRTF = savedRTF
                try require(editor.text == typed && savedText == typed && manager.canUndo,
                            "Actual insertText plus persistence must retain native undo in \(theme.rawValue) mode")
                manager.undo()
                editor.delegate?.textViewDidChange?(editor)
                try require(editor.text == seed && savedText == seed && savedRTF == baselineRTF && manager.canRedo,
                            "Native undo must restore exact canonical rich text after typing in \(theme.rawValue) mode")
                manager.redo()
                editor.delegate?.textViewDidChange?(editor)
                try require(editor.text == typed && savedText == typed && savedRTF == typedRTF,
                            "Native redo must restore the typed Unicode and rich text in \(theme.rawValue) mode")
            }
            try require(originalView.page.textView.text == originalText && richTextCoordinator.lastRTF == originalRTF,
                        "Typing fixtures must leave the original page and rich-text bytes unchanged")
            return checks
        }
        #endif
    }
}

/// A dedicated Pencil-only recognizer avoids creating a temporary curved native
/// stroke, so straight-line undo and redo never depend on private stroke IDs.
@MainActor
private final class PencilLineGestureRecognizer: UIGestureRecognizer {
    private(set) var startPoint: InkPoint?
    private(set) var currentPoint: InkPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else { state = .failed; return }
        startPoint = inkPoint(touch)
        currentPoint = startPoint
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        currentPoint = inkPoint(touch)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { currentPoint = inkPoint(touch) }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }

    override func reset() { super.reset(); startPoint = nil; currentPoint = nil }

    private func inkPoint(_ touch: UITouch) -> InkPoint {
        let point = touch.location(in: view)
        let pressure = touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 1
        return InkPoint(x: point.x, y: point.y, pressure: Double(max(0, min(1, pressure))))
    }
}

@MainActor
final class IOSPageDiagramView: UIView {
    private(set) var diagrams: [PageDiagram] = []
    private var theme = PageTheme.light

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Read-only page diagrams"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(_ values: [PageDiagram], theme: PageTheme) {
        // Archive validation normally precedes this path. Keep the native draw
        // boundary bounded too, including direct programmatic model updates.
        let accepted = (try? PageDiagramLimits.validate(values)) != nil ? values : []
        guard diagrams != accepted || self.theme != theme else { return }
        diagrams = accepted
        self.theme = theme
        accessibilityValue = "\(accepted.count) objects. Open on Mac to edit."
        isHidden = accepted.isEmpty
        setNeedsDisplay()
    }

    func show(pageRect: CGRect) {
        guard !pageRect.isNull, !pageRect.isInfinite,
              [pageRect.minX, pageRect.minY, pageRect.width, pageRect.height].allSatisfy(\.isFinite) else { return }
        // A long page must not allocate one enormous transparent bitmap. The
        // preview keeps world coordinates but backs only its visible viewport.
        guard frame != pageRect || bounds != pageRect else { return }
        frame = pageRect
        bounds = pageRect
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for value in diagrams {
            let bounds = PageDiagramGeometry.bounds(of: value, in: diagrams)
            guard bounds.insetBy(dx: -value.lineWidth, dy: -value.lineWidth).intersects(rect) else { continue }
            let color = UIColor(noteHex: theme.resolvedInkHex(value.colorHex))
            context.saveGState()
            color.setStroke()
            context.setLineWidth(value.lineWidth)
            context.setLineJoin(.round)
            context.setLineCap(value.linePattern == .dotted ? .round : .butt)
            if value.linePattern != .solid {
                context.setLineDash(phase: 0, lengths: value.linePattern.dashLengths(width: value.lineWidth).map { CGFloat($0) })
            }
            let frame = CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
            let path: UIBezierPath
            switch value.kind {
            case .rectangle, .table: path = UIBezierPath(rect: frame)
            case .roundedRectangle: path = UIBezierPath(roundedRect: frame, cornerRadius: min(18, min(frame.width, frame.height) / 5))
            case .ellipse: path = UIBezierPath(ovalIn: frame)
            case .triangle:
                path = polygon([CGPoint(x: frame.midX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)])
            case .diamond:
                path = polygon([CGPoint(x: frame.midX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.midY),
                    CGPoint(x: frame.midX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.midY)])
            case .connector:
                path = UIBezierPath()
                let points = PageDiagramGeometry.connectorPoints(for: value, in: diagrams)
                if let first = points.first { path.move(to: CGPoint(x: first.x, y: first.y)) }
                for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            }
            if value.fill && value.kind != .connector {
                context.setFillColor(color.withAlphaComponent(0.12).cgColor)
                context.addPath(path.cgPath)
                context.fillPath()
            }
            context.addPath(path.cgPath)
            context.strokePath()
            if value.kind == .table {
                for row in 1..<value.rows {
                    let y = frame.minY + frame.height * CGFloat(row) / CGFloat(value.rows)
                    context.move(to: CGPoint(x: frame.minX, y: y)); context.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
                for column in 1..<value.columns {
                    let x = frame.minX + frame.width * CGFloat(column) / CGFloat(value.columns)
                    context.move(to: CGPoint(x: x, y: frame.minY)); context.addLine(to: CGPoint(x: x, y: frame.maxY))
                }
                context.strokePath()
                for row in 0..<value.rows { for column in 0..<value.columns {
                    let cell = CGRect(x: frame.minX + frame.width * CGFloat(column) / CGFloat(value.columns),
                        y: frame.minY + frame.height * CGFloat(row) / CGFloat(value.rows),
                        width: frame.width / CGFloat(value.columns), height: frame.height / CGFloat(value.rows))
                    drawText(value.cells[row * value.columns + column], in: cell.insetBy(dx: 5, dy: 3), color: color)
                } }
            } else if value.kind == .connector {
                context.setLineDash(phase: 0, lengths: [])
                let points = PageDiagramGeometry.connectorPoints(for: value, in: diagrams)
                if value.arrowHeads == .end || value.arrowHeads == .both {
                    if let end = points.last, let previous = points.dropLast().last(where: { $0.x != end.x || $0.y != end.y }) {
                        arrow(at: end, from: previous, width: value.lineWidth, context: context)
                    }
                }
                if value.arrowHeads == .both, let start = points.first,
                   let next = points.dropFirst().first(where: { $0.x != start.x || $0.y != start.y }) {
                    arrow(at: start, from: next, width: value.lineWidth, context: context)
                }
                drawText(value.text, in: bounds.insetBy(dx: 10, dy: 3), color: color)
            } else {
                drawText(value.text, in: frame.insetBy(dx: 10, dy: 5), color: color)
            }
            context.restoreGState()
        }
    }

    private func polygon(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        if let first = points.first { path.move(to: first) }
        for point in points.dropFirst() { path.addLine(to: point) }
        path.close()
        return path
    }

    private func arrow(at point: InkPoint, from previous: InkPoint, width: Double, context: CGContext) {
        let angle = atan2(point.y - previous.y, point.x - previous.x)
        let length = max(10, width * 3)
        context.move(to: CGPoint(x: point.x - cos(angle - .pi / 6) * length, y: point.y - sin(angle - .pi / 6) * length))
        context.addLine(to: CGPoint(x: point.x, y: point.y))
        context.addLine(to: CGPoint(x: point.x - cos(angle + .pi / 6) * length, y: point.y - sin(angle + .pi / 6) * length))
        context.strokePath()
    }

    private func drawText(_ text: String, in rect: CGRect, color: UIColor) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: color, .paragraphStyle: paragraph]
        let measured = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        let textRect = CGRect(x: rect.minX, y: rect.minY + max(0, (rect.height - measured.height) / 2), width: rect.width, height: rect.height)
        context.saveGState()
        context.clip(to: rect)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        context.restoreGState()
    }
}

@MainActor
final class UnifiedPageScrollView: UIScrollView {
    let page = UnifiedPencilPage()
    var onAttachment: (() -> Void)?
    private let inkErrorLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        contentInsetAdjustmentBehavior = .never
        minimumZoomScale = 0.25
        maximumZoomScale = 4
        alwaysBounceVertical = true
        alwaysBounceHorizontal = true
        keyboardDismissMode = .interactive
        delaysContentTouches = false
        panGestureRecognizer.allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        addSubview(page)
        inkErrorLabel.numberOfLines = 0
        inkErrorLabel.font = .preferredFont(forTextStyle: .footnote)
        inkErrorLabel.textColor = .label
        inkErrorLabel.backgroundColor = .secondarySystemBackground
        inkErrorLabel.isHidden = true
        inkErrorLabel.accessibilityTraits = .staticText
        addSubview(inkErrorLabel)
        resizePage()
        accessibilityLabel = "Note page"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onAttachment?() }
    }

    func resizePage() {
        let width: CGFloat = 1600
        let textHeight = page.textView.sizeThatFits(CGSize(width: width - 80, height: .greatestFiniteMagnitude)).height
        let inkBottom = page.canvas.drawing.bounds.maxY
        let objectBottom = (Array(page.textBoxViews.values).map { $0.frame.maxY } + Array(page.equationViews.values).map { $0.frame.maxY }
            + page.diagramView.diagrams.map { PageDiagramGeometry.bounds(of: $0, in: page.diagramView.diagrams).maxY }).max() ?? 0
        let desiredHeight = max(2200, textHeight + 80, inkBottom.isFinite ? inkBottom + 80 : 0, objectBottom + 80)
        let height = min(CGFloat(InkGeometryLimits.maximumPageDimension), desiredHeight.isFinite ? desiredHeight : 2200)
        page.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        page.center = CGPoint(x: width * zoomScale / 2, y: height * zoomScale / 2)
        page.paper.frame = page.bounds
        page.canvas.frame = page.bounds
        page.canvas.contentSize = page.bounds.size
        page.selectionView.frame = page.bounds
        page.textView.frame = CGRect(x: 40, y: 40, width: width - 80, height: height - 80)
        contentSize = CGSize(width: width * zoomScale, height: height * zoomScale)
        centerPage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        centerPage()
    }

    func centerPage() {
        let scaled = CGSize(width: page.bounds.width * zoomScale, height: page.bounds.height * zoomScale)
        page.center = CGPoint(x: max(bounds.width, scaled.width) / 2,
                              y: max(bounds.height, scaled.height) / 2)
        let labelWidth = max(0, bounds.width - 32)
        let labelHeight = inkErrorLabel.sizeThatFits(CGSize(width: labelWidth, height: 160)).height
        inkErrorLabel.frame = CGRect(x: bounds.minX + 16, y: bounds.minY + 12, width: labelWidth, height: labelHeight)
        updateVisiblePaper()
    }

    func updateVisiblePaper() {
        let visible = page.convert(bounds, from: self).intersection(page.bounds)
        page.paper.visiblePageRect = visible
        page.diagramView.show(pageRect: visible)
    }

    func setInkError(_ message: String?) {
        inkErrorLabel.text = message
        inkErrorLabel.isHidden = message == nil
        setNeedsLayout()
    }
}

@MainActor
final class UnifiedPencilPage: UIView {
    let paper = UnifiedPaperView()
    let diagramView = IOSPageDiagramView()
    let canvas = IOSPageCanvasView()
    let textView = IOSPageTextView()
    let selectionView = IOSPageSelectionView()
    var textBoxViews: [UUID: IOSTextBoxView] = [:]
    var equationViews: [UUID: EquationDisplayView] = [:]
    var textToolSelected = false
    var selectionEnabled = false
    var selectionInputAllowed = true
    var prepareForPageSelection: (() -> Bool)?
    var theme: PageTheme { paper.theme }
    var activeTextView: UITextView? {
        if textView.isFirstResponder { return textView }
        return textBoxViews.values.first(where: { $0.editor.isFirstResponder })?.editor
    }
    override var keyCommands: [UIKeyCommand]? {
        let selectAll = UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll(_:)))
        selectAll.discoverabilityTitle = "Select All Page Content"
        selectAll.wantsPriorityOverSystemBehavior = true
        return ToolShortcuts.keyCommands(includePlain: !textToolSelected && activeTextView == nil, action: #selector(activateToolShortcut(_:))) + [selectAll]
    }
    override func selectAll(_ sender: Any?) { selectionView.controller?.perform(.selectAll) }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll(_:)) {
            return isUserInteractionEnabled && selectionInputAllowed && selectionView.controller != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    func refreshSelectionPresentation() {
        let temporary = selectionView.controller.map { $0.selectionIsTemporary && !$0.selection.isEmpty } ?? false
        selectionView.isHidden = !selectionEnabled && !temporary
        selectionView.isUserInteractionEnabled = isUserInteractionEnabled && selectionInputAllowed && !selectionView.isHidden
    }

    func beginPageInteraction() { selectionView.controller?.dismissTemporarySelection() }
    @objc func activateToolShortcut(_ command: UIKeyCommand) {
        if let tool = ToolShortcuts.tool(for: command) { ToolShortcuts.activate(tool) }
    }
    var onPencil: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        paper.isUserInteractionEnabled = false
        addSubview(paper)
        addSubview(diagramView)
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: .black, width: InkNibPreset.defaultWidth(for: .pen))
        canvas.accessibilityLabel = "Handwriting on note page"
        addSubview(canvas)
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isScrollEnabled = false
        textView.allowsEditingTextAttributes = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.accessibilityLabel = "Page text"
        insertSubview(textView, belowSubview: canvas)
        selectionView.isHidden = true
        addSubview(selectionView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let isPencil = event?.allTouches?.contains(where: { $0.type == .pencil }) == true
        return inputHitTest(at: point, isPencil: isPencil, event: event)
    }

    /// The actual UIKit path and native diagnostics use the same routing logic;
    /// diagnostics supply the type without fabricating private UITouch objects.
    func inputHitTest(at point: CGPoint, isPencil: Bool, event: UIEvent? = nil) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        if event?.allTouches?.contains(where: { $0.phase == .began }) == true {
            beginPageInteraction()
        }
        if textToolSelected {
            for object in equationViews.values.reversed() where object.frame.contains(point) {
                if let hit = object.hitTest(convert(point, to: object), with: event) { return hit }
            }
            for object in textBoxViews.values.reversed() where object.frame.contains(point) {
                if let hit = object.hitTest(convert(point, to: object), with: event) { return hit }
            }
            // Even the page margin belongs to text while Text is selected.
            return textView.hitTest(convert(point, to: textView), with: event) ?? textView
        }
        if selectionEnabled { return selectionView.hitTest(convert(point, to: selectionView), with: event) }
        if isPencil { onPencil?() }
        // Exclude text from this hit test only; it stays visible and keeps native
        // selection/keyboard behavior whenever the Text tool is used.
        let textWasInteractive = textView.isUserInteractionEnabled
        textView.isUserInteractionEnabled = false
        defer { textView.isUserInteractionEnabled = textWasInteractive }
        return super.hitTest(point, with: event)
    }
}

/// Only note-page native responders share the page-wide Select All action.
/// Search, titles, and equation-source editors use their normal UIKit behavior.
@MainActor
final class IOSPageTextView: UITextView {
    override func paste(_ sender: Any?) {
        if let page = enclosingNotePage {
            guard page.isUserInteractionEnabled && page.selectionInputAllowed else { return }
            let board = UIPasteboard.general
            if let data = board.data(forPasteboardType: PageClipboardPayload.pasteboardType)
                ?? board.data(forPasteboardType: PageClipboardPayload.imagePasteboardType)
                ?? board.data(forPasteboardType: PageClipboardPayload.legacyPasteboardType) {
                guard let payload = try? PageClipboardPayload.decodeValidated(data) else {
                    page.selectionView.controller?.onError?("The copied page content could not be pasted safely. Your sheet has not been changed.")
                    return
                }
                guard payload.images.isEmpty && payload.diagrams.isEmpty else {
                    page.selectionView.controller?.onError?("Pasting page images or diagrams is currently available on Mac. Your sheet has not been changed.")
                    return
                }
            }
        }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll(_:)), let page = enclosingNotePage {
            return page.canPerformAction(action, withSender: sender)
        }
        return super.canPerformAction(action, withSender: sender)
    }
    override func selectAll(_ sender: Any?) {
        if let page = enclosingNotePage { page.selectAll(sender) }
        else { super.selectAll(sender) }
    }
}

@MainActor
final class IOSPageCanvasView: PKCanvasView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll(_:)), let page = enclosingNotePage {
            return page.canPerformAction(action, withSender: sender)
        }
        return super.canPerformAction(action, withSender: sender)
    }
    override func selectAll(_ sender: Any?) {
        if let page = enclosingNotePage { page.selectAll(sender) }
        else { super.selectAll(sender) }
    }
}

private extension UIView {
    var enclosingNotePage: UnifiedPencilPage? {
        var ancestor = superview
        while let view = ancestor {
            if let page = view as? UnifiedPencilPage { return page }
            ancestor = view.superview
        }
        return nil
    }
}

@MainActor
final class UnifiedPaperView: UIView {
    var style: InkPaper = .dotted { didSet { if style != oldValue { setNeedsLayout() } } }
    var theme: PageTheme = .light { didSet { if theme != oldValue { updateColors(); setNeedsLayout() } } }
    var pageTemplate: PageTemplate = .none { didSet { if pageTemplate != oldValue { setNeedsLayout() } } }
    var templateLinePattern: LinePattern = .solid { didSet { if templateLinePattern != oldValue { setNeedsLayout() } } }
    var visiblePageRect: CGRect = .zero { didSet { if visiblePageRect != oldValue { setNeedsLayout() } } }
    private let rules = CAShapeLayer()
    private let template = CAShapeLayer()
    private var previousConfiguration = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        rules.fillColor = UIColor.clear.cgColor
        rules.lineWidth = 1
        template.fillColor = UIColor.clear.cgColor
        template.lineWidth = 2
        template.lineCap = .round
        layer.addSublayer(rules)
        layer.addSublayer(template)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func updateColors() {
        layer.backgroundColor = UIColor(noteHex: theme.paperHex).cgColor
        rules.strokeColor = UIColor(noteHex: theme.ruleHex).cgColor
        template.strokeColor = UIColor(noteHex: theme.templateHex).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let configuration = "\(bounds)|\(visiblePageRect)|\(style.rawValue)|\(pageTemplate.rawValue)|\(templateLinePattern.rawValue)"
        guard configuration != previousConfiguration else { return }
        previousConfiguration = configuration
        let path = CGMutablePath()
        let spacing: CGFloat = 28
        // Render a bounded viewport plus overscan. Never allocate a path for
        // every rule in a potentially tall document, even if a caller bypasses
        // the import validator or sets an unsupported frame.
        let raw = visiblePageRect.isEmpty ? bounds : visiblePageRect
        let maxDimension = CGFloat(InkGeometryLimits.maximumPageDimension)
        let safeBounds = CGRect(x: 0, y: 0, width: min(maxDimension, max(0, bounds.width)),
                                height: min(maxDimension, max(0, bounds.height)))
        let clipped = raw.insetBy(dx: -56, dy: -56).intersection(safeBounds)
        guard !clipped.isNull, !clipped.isInfinite, clipped.minX.isFinite, clipped.minY.isFinite else {
            rules.path = nil; template.path = nil; return
        }
        let firstY = max(spacing, floor(clipped.minY / spacing) * spacing)
        let lastY = min(clipped.maxY, firstY + spacing * 2_000)
        if style != .blank {
            for y in stride(from: firstY, through: lastY, by: spacing) {
                path.move(to: CGPoint(x: style == .dotted ? spacing : 0, y: y))
                path.addLine(to: CGPoint(x: safeBounds.width, y: y))
            }
            if style == .grid {
                let firstX = max(spacing, floor(clipped.minX / spacing) * spacing)
                let lastX = min(clipped.maxX, firstX + spacing * 2_000)
                for x in stride(from: firstX, through: lastX, by: spacing) {
                    path.move(to: CGPoint(x: x, y: clipped.minY)); path.addLine(to: CGPoint(x: x, y: lastY))
                }
            }
        }
        rules.frame = bounds
        rules.path = path
        rules.lineWidth = style == .dotted ? 3 : 1
        rules.lineDashPattern = style == .dotted ? [0.1, 27.9] : nil
        rules.lineCap = style == .dotted ? .round : .butt
        let guide = CGMutablePath()
        let effective = pageTemplate.effective(on: PaperStyle(rawValue: style.rawValue) ?? .blank)
        if effective != .none {
            let x: CGFloat = effective == .centerDivider ? safeBounds.width / 2 : 80
            guide.move(to: CGPoint(x: x, y: clipped.minY))
            guide.addLine(to: CGPoint(x: x, y: lastY))
        }
        template.frame = bounds
        template.path = guide
        let lengths = templateLinePattern.dashLengths(width: 2)
        template.lineDashPattern = lengths.isEmpty ? nil : lengths.map { NSNumber(value: $0) }
        template.lineDashPhase = clipped.minY
    }
}

private extension UIColor {
    convenience init(noteHex: String) {
        let value = UInt64(noteHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    var noteHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#30343B" }
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    func hasSameRGB(as other: UIColor) -> Bool { noteHex == other.noteHex }
}
#endif
