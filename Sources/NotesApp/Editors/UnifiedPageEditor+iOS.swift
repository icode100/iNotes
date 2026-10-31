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
    var tool: InkTool = .pen
    var colorHex: String = "#314D43"
    var lineWidth: Double = 2.5
    var paper: InkPaper = .dotted
    var theme: PageTheme = .light
    var onTextChange: ((String, Data?) -> Void)? = nil
    var onInkChange: (([InkStroke], Data?) -> Void)? = nil
    var onInputChange: ((String) -> Void)? = nil

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
        private weak var view: UnifiedPageScrollView?
        private let picker = PKToolPicker()
        private var isLoading = false
        private var nativeToolActive = false
        private var lastData: Data?
        private var lastStrokes: [InkStroke] = []
        private var expectedDrawingData: Data?
        private var toolConfiguration: String?
        private var previousTool: InkTool?
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
                    }
                })
            }
            undoObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view else { return }
                    self.persistInk(view.page.canvas)
                }
            })
        }

        deinit { for observer in undoObservers { NotificationCenter.default.removeObserver(observer) } }

        func attach(_ view: UnifiedPageScrollView) {
            self.view = view
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
                self.parent.onInputChange?("Apple Pencil")
                self.picker.setVisible(true, forFirstResponder: view.page.canvas)
                view.page.canvas.becomeFirstResponder()
            }
            view.onAttachment = { [weak self] in
                self?.showToolsIfNeeded()
                #if DEBUG
                self?.scheduleDiagnosticsIfRequested()
                #endif
            }
        }

        func update(_ view: UnifiedPageScrollView, enabled: Bool) {
            // A system appearance transition waits until the current Pencil
            // gesture completes, preserving in-flight native ink and pressure.
            let theme = nativeToolActive ? (appliedTheme ?? parent.theme) : parent.theme
            richTextCoordinator.parent = RichTextEditor(text: parent.$text, rtfData: parent.$rtfData, theme: theme, onChange: parent.onTextChange)
            let editor = view.page.textView
            editor.isEditable = enabled
            view.isUserInteractionEnabled = enabled
            view.page.textToolSelected = parent.tool == .text
            view.panGestureRecognizer.minimumNumberOfTouches = parent.tool == .text ? 2 : 1
            view.page.paper.style = parent.paper
            view.page.paper.theme = theme
            view.page.overrideUserInterfaceStyle = theme == .dark ? .dark : .light
            editor.overrideUserInterfaceStyle = view.page.overrideUserInterfaceStyle
            // PencilKit transforms ink colors itself when a canvas is dark.
            // Our semantic resolver already supplies the display color, so
            // render that color in a light-trait canvas to avoid a second tint.
            view.page.canvas.overrideUserInterfaceStyle = .light
            picker.overrideUserInterfaceStyle = view.page.overrideUserInterfaceStyle
            picker.colorUserInterfaceStyle = .light
            if richTextCoordinator.lastText != parent.text || richTextCoordinator.lastRTF != parent.rtfData || richTextCoordinator.lastTheme != theme {
                richTextCoordinator.load(text: parent.text, rtf: parent.rtfData, into: editor)
            }
            let themeChanged = appliedTheme != theme
            if lastData != parent.pencilKitData || lastStrokes != parent.strokes {
                let canonical = parent.pencilKitData.flatMap { try? PKDrawing(data: $0) }
                    ?? PortableInkConverter.drawing(from: parent.strokes)
                rememberCanonicalColors(in: canonical)
                show(canonicalDrawing: canonical, on: view.page.canvas, theme: theme)
                lastData = parent.pencilKitData
                lastStrokes = parent.strokes
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
            view.page.canvas.drawingGestureRecognizer.isEnabled = parent.tool != .line
            lineGesture?.isEnabled = enabled && parent.tool == .line
            view.resizePage()
            linePreview.frame = view.page.bounds
            if previousTool != parent.tool {
                previousTool = parent.tool
                if enabled, view.window != nil {
                    if parent.tool == .text {
                        picker.setVisible(false, forFirstResponder: view.page.canvas)
                        editor.becomeFirstResponder()
                    } else {
                        editor.resignFirstResponder()
                        picker.setVisible(true, forFirstResponder: view.page.canvas)
                        view.page.canvas.becomeFirstResponder()
                    }
                }
            }
        }

        private func configureTool(on canvas: PKCanvasView, theme: PageTheme) {
            let configuration = "\(parent.tool.rawValue)|\(parent.colorHex)|\(parent.lineWidth)|\(theme.rawValue)"
            guard configuration != toolConfiguration else { return }
            toolConfiguration = configuration
            let canonical = UIColor(noteHex: parent.colorHex)
            let color = UIColor(noteHex: theme.resolvedInkHex(parent.colorHex))
            configuredCanonicalInk = canonical
            configuredDisplayInk = color
            let width = max(0.5, min(30, parent.lineWidth))
            switch parent.tool {
            case .text: break // Pencil keeps its selected ink while fingers can edit text.
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
            guard let view, view.window != nil, view.isUserInteractionEnabled, parent.tool != .text else { return }
            picker.setVisible(true, forFirstResponder: view.page.canvas)
            view.page.canvas.becomeFirstResponder()
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
            view.onAttachment = nil
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.page }

        func textViewDidChange(_ textView: UITextView) {
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
            let points = [start, end].enumerated().map { index, point in
                let pressure = max(0, min(1, point.pressure))
                let size = width * (0.35 + 0.65 * pressure)
                return PKStrokePoint(location: CGPoint(x: point.x, y: point.y), timeOffset: Double(index) / 60,
                                     size: CGSize(width: size, height: size), opacity: 1, force: CGFloat(pressure),
                                     azimuth: 0, altitude: .pi / 2)
            }
            let path = PKStrokePath(controlPoints: points, creationDate: Date())
            let ink = PKInk(.pen, color: selectedInk?.color ?? UIColor(noteHex: parent.colorHex))
            let stroke = PKStroke(ink: ink, path: path)
            replaceDrawing(PKDrawing(strokes: canvas.drawing.strokes + [stroke]), in: canvas, registerUndo: true)
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
            guard !isLoading else { return }
            #if DEBUG
            guard !isRunningDiagnostics else { return }
            #endif
            let displayedData = canvas.drawing.dataRepresentation()
            guard displayedData != expectedDrawingData else { return }
            let canonical = canonicalDrawing(from: canvas.drawing, theme: appliedTheme ?? parent.theme)
            let data = canonical.dataRepresentation()
            let portable = portableStrokes(from: canonical)
            expectedDrawingData = displayedData
            lastData = data
            lastStrokes = portable
            if let onInkChange = parent.onInkChange { onInkChange(portable, data) }
            else { parent.strokes = portable; parent.pencilKitData = data }
            view?.resizePage()
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

        private func portableStrokes(from drawing: PKDrawing) -> [InkStroke] {
            drawing.strokes.flatMap { stroke in
                var converted = PortableInkConverter.strokes(from: PKDrawing(strokes: [stroke]))
                if stroke.path.count == 2, stroke.mask == nil, stroke.ink.inkType == .pen, converted.count == 1 {
                    converted[0].points = [stroke.path[0], stroke.path[1]].map { point in
                        let location = point.location.applying(stroke.transform)
                        return InkPoint(x: location.x, y: location.y, pressure: Double(max(0, min(1, point.force))))
                    }
                }
                return converted
            }
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
                let portable = portableStrokes(from: canvas.drawing)
                try require(portable.count == 2 && portable.allSatisfy { $0.style == .pen && $0.points.count == 2 }, "Lines must survive as two-endpoint portable pen strokes")
                checks += try runThemeDiagnostics()
                result = ["passed": true, "checks": checks, "message": "iPad straight lines, undo/redo, light/dark paper, visible rules, and canonical ink preservation passed"]
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
final class UnifiedPageScrollView: UIScrollView {
    let page = UnifiedPencilPage()
    var onAttachment: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        minimumZoomScale = 0.25
        maximumZoomScale = 4
        alwaysBounceVertical = true
        alwaysBounceHorizontal = true
        keyboardDismissMode = .interactive
        delaysContentTouches = false
        panGestureRecognizer.allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        addSubview(page)
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
        let height = max(2200, textHeight + 80, inkBottom.isFinite ? inkBottom + 80 : 0)
        page.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        page.center = CGPoint(x: width * zoomScale / 2, y: height * zoomScale / 2)
        page.paper.frame = page.bounds
        page.canvas.frame = page.bounds
        page.canvas.contentSize = page.bounds.size
        page.textView.frame = CGRect(x: 40, y: 40, width: width - 80, height: height - 80)
        contentSize = CGSize(width: width * zoomScale, height: height * zoomScale)
    }
}

@MainActor
final class UnifiedPencilPage: UIView {
    let paper = UnifiedPaperView()
    let canvas = PKCanvasView()
    let textView = UITextView()
    var textToolSelected = false
    var onPencil: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        paper.isUserInteractionEnabled = false
        addSubview(paper)
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2.5)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        let isPencil = event?.allTouches?.contains(where: { $0.type == .pencil }) == true
        if isPencil { onPencil?() }
        if textToolSelected && !isPencil,
           let textHit = textView.hitTest(convert(point, to: textView), with: event) { return textHit }
        // Exclude text from this hit test only; it stays visible and keeps native
        // selection/keyboard behavior whenever the Text tool is used.
        let textWasInteractive = textView.isUserInteractionEnabled
        textView.isUserInteractionEnabled = false
        defer { textView.isUserInteractionEnabled = textWasInteractive }
        return super.hitTest(point, with: event)
    }
}

@MainActor
final class UnifiedPaperView: UIView {
    var style: InkPaper = .dotted { didSet { if style != oldValue { setNeedsLayout() } } }
    var theme: PageTheme = .light { didSet { if theme != oldValue { updateColors(); setNeedsLayout() } } }
    private let rules = CAShapeLayer()
    private var previousSize: CGSize = .zero
    private var previousStyle: InkPaper?

    override init(frame: CGRect) {
        super.init(frame: frame)
        rules.fillColor = UIColor.clear.cgColor
        rules.lineWidth = 1
        layer.addSublayer(rules)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func updateColors() {
        layer.backgroundColor = UIColor(noteHex: theme.paperHex).cgColor
        rules.strokeColor = UIColor(noteHex: theme.ruleHex).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize || style != previousStyle else { return }
        previousSize = bounds.size
        previousStyle = style
        let path = CGMutablePath()
        let spacing: CGFloat = 28
        if style != .blank {
            for y in stride(from: spacing, through: bounds.height, by: spacing) {
                path.move(to: CGPoint(x: style == .dotted ? spacing : 0, y: y))
                path.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            if style == .grid {
                for x in stride(from: spacing, through: bounds.width, by: spacing) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: bounds.height))
                }
            }
        }
        rules.frame = bounds
        rules.path = path
        rules.lineWidth = style == .dotted ? 3 : 1
        rules.lineDashPattern = style == .dotted ? [0.1, 27.9] : nil
        rules.lineCap = style == .dotted ? .round : .butt
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
