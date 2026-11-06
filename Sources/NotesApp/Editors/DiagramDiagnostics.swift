#if os(macOS)
import AppKit
import SwiftUI
import NotesCore
import PDFKit
import ImageIO

@MainActor
private final class DiagramDiagnosticState: ObservableObject {
    @Published var tool = InkTool.diagram
    @Published var kind = PageDiagram.Kind.rectangle
    @Published var theme = PageTheme.light
    @Published var readOnly = false
    var rejectChanges = false
    var placementCount = 0
}

private struct DiagramDiagnosticEditor: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var state: DiagramDiagnosticState
    let sheetID: UUID

    var body: some View {
        UnifiedPageEditor(text: store.binding(sheetID, \.body, fallback: ""),
            rtfData: store.binding(sheetID, \.richTextRTF, fallback: nil),
            strokes: store.binding(sheetID, \.strokes, fallback: []),
            pencilKitData: store.binding(sheetID, \.pencilKitData, fallback: nil),
            textBoxes: store.binding(sheetID, \.textBoxes, fallback: []),
            equations: store.binding(sheetID, \.equations, fallback: []),
            images: store.binding(sheetID, \.images, fallback: []),
            diagrams: store.binding(sheetID, \.diagrams, fallback: []),
            tool: state.tool, colorHex: "#D52C4E", lineWidth: 3, paper: .blank, theme: state.theme,
            diagramKind: state.kind, connectorRoute: .elbow, arrowHeads: .both, tableRows: 2, tableColumns: 3,
            onTextChange: { text, rtf in store.update(sheetID) { $0.body = text; $0.richTextRTF = rtf } },
            onInkChange: { strokes, native in store.update(sheetID) { $0.strokes = strokes; $0.pencilKitData = native } },
            onPageChange: { value in store.update(sheetID) { $0.pageContent = value } },
            onPageValidate: { !state.rejectChanges && store.validatePageChange(sheetID, content: $0) },
            onObjectPlacement: { state.placementCount += 1; state.tool = .select })
            .disabled(state.readOnly)
    }
}

/// Offscreen native components and disposable notes only. Synthetic events are
/// delivered directly to this fixture, never posted to the user's event stream.
@MainActor
enum DiagramDiagnostics {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Temporary investigation only: weak references must not extend a
    /// fixture's lifetime while measuring its ordinary teardown.
    @MainActor
    private final class LifetimeProbe {
        weak var window: NSWindow?
        weak var host: NSView?
        weak var page: UnifiedMacPageView?
        weak var controller: MacPageSelectionController?

        func log(_ stage: String) {
            let fixtureWindow = window.map {
                "visible=\($0.isVisible) attachedSheet=\($0.attachedSheet != nil) firstResponder=\($0.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
            } ?? "released"
            let application = NSApp.map { app in
                let windows = app.windows
                return "count=\(windows.count) visible=\(windows.filter(\.isVisible).count) key=\(app.keyWindow != nil) modal=\(app.modalWindow != nil)"
            } ?? "not-created"
            let grouping = controller.map { String($0.history.groupingLevel) } ?? "released"
            print("Diagram lifetime [\(stage)] window={\(fixtureWindow)} hostReleased=\(host == nil) pageReleased=\(page == nil) controllerReleased=\(controller == nil) undoGrouping=\(grouping) appWindows={\(application)}")
        }
    }

    static func run() throws -> Int {
        let lifetime = LifetimeProbe()
        lifetime.log("before-pool")
        defer { lifetime.log("after-pool") }
        return try autoreleasepool { try runChecks(lifetime: lifetime) }
    }

    private static func runChecks(lifetime: LifetimeProbe) throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw Failure(description: "Diagram diagnostic failed: \(message)") }
            checks += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-diagrams-\(UUID())")
        let suite = "io.inotes.diagram-diagnostics.\(UUID())"
        guard let preferences = UserDefaults(suiteName: suite) else { throw Failure(description: "Missing diagram fixture preferences") }
        let store = NotesStore(directory: directory, preferences: preferences)
        guard let sheetID = store.selectedSheet?.id else { throw Failure(description: "Missing disposable diagram sheet") }
        guard let imageContext = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Cannot create diagram mixed-content image")
        }
        imageContext.setFillColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 1)
        imageContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = imageContext.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "Cannot encode diagram mixed-content image")
        }
        store.update(sheetID) {
            $0.body = "Diagram fixture — नमस्ते 👋"
            $0.richTextRTF = nil
            $0.strokes = [InkStroke(points: [InkPoint(x: 70, y: 250), InkPoint(x: 150, y: 260)], colorHex: "#245EEA", width: 4)]
            $0.textBoxes = [PageTextBox(x: 320, y: 80, width: 180, text: "Movable text")]
            $0.equations = [NoteEquation(latex: "x^2", x: 540, y: 80, width: 100, height: 80)]
            $0.images = [PageImage(x: 700, y: 80, width: 40, height: 40, imageData: png)]
            $0.diagrams = []
        }
        func saved() throws -> PageContent {
            guard let value = store.library.node(id: sheetID)?.pageContent else { throw Failure(description: "Diagram fixture sheet disappeared") }
            return value
        }
        let initial = try saved()
        let initialNode = store.library.node(id: sheetID)!
        let state = DiagramDiagnosticState()
        let host = NSHostingView(rootView: DiagramDiagnosticEditor(store: store, state: state, sheetID: sheetID))
        let window = NSWindow(contentRect: NSRect(x: -6500, y: -6500, width: 960, height: 640),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        lifetime.window = window
        lifetime.host = host
        window.orderFront(nil)
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.close()
            _ = store.prepareForQuit()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            lifetime.log("closed-before-pool-drain")
        }
        func passive(_ seconds: TimeInterval = 0.06) {
            let deadline = Date(timeIntervalSinceNow: seconds)
            repeat { RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.016))) } while Date() < deadline
        }
        func mountedPage(in view: NSView) -> UnifiedMacPageView? {
            if let page = view as? UnifiedMacPageView { return page }
            return view.subviews.lazy.compactMap { mountedPage(in: $0) }.first
        }
        let mountDeadline = Date(timeIntervalSinceNow: 2)
        while mountedPage(in: host) == nil && Date() < mountDeadline { passive(0.02) }
        guard let page = mountedPage(in: host), let controller = page.selectionController,
              let scroll = page.enclosingScrollView as? PageZoomScrollView else {
            throw Failure(description: "Actual unified diagram editor did not mount")
        }
        lifetime.page = page
        lifetime.controller = controller
        passive()
        let pageID = ObjectIdentifier(page), historyID = ObjectIdentifier(controller.history)
        try check(controller.content == initial && page.activeTool == .diagram,
            "Actual unified editor loads every existing payload before diagram input")
        try check(!page.textView.isEditable && !page.textView.isSelectable
            && page.inputView(at: NSPoint(x: 150, y: 400), event: nil) === page.selectionView,
            "The diagram tool owns native pointer input while text remains visible and protected")
        controller.history.removeAllActions()
        var time = ProcessInfo.processInfo.systemUptime
        var eventCoordinates: [String] = []
        // Page -> window -> NSEvent -> page crosses the native magnification
        // transform. Arithmetic on those doubles need not round-trip bitwise;
        // this tolerance is below a millionth of one unzoomed page point.
        // Stored snapshots, IDs, text and attachment semantics stay exact.
        func sameCoordinate(_ actual: Double, _ expected: Double) -> Bool {
            actual.isFinite && expected.isFinite && abs(actual - expected) <= 0.000001
        }
        func geometryContext(_ value: PageDiagram) -> String {
            "actual kind=\(value.kind.rawValue) x=\(value.x) y=\(value.y) width=\(value.width) height=\(value.height) magnification=\(scroll.magnification) events=[\(eventCoordinates.suffix(3).joined(separator: "; "))]"
        }
        func payloadContext(_ actual: PageContent, comparedTo expected: PageContent) -> String {
            func bytes(_ value: Data?) -> String { value.map { "\($0.count) bytes" } ?? "nil" }
            let actualBoxRTF = actual.textBoxes.map { "\($0.id):\(bytes($0.rtfData))" }.joined(separator: ",")
            let expectedBoxRTF = expected.textBoxes.map { "\($0.id):\(bytes($0.rtfData))" }.joined(separator: ",")
            return "equal=\(actual == expected) textEqual=\(actual.text == expected.text) textUTF8=\(actual.text.utf8.count)/\(expected.text.utf8.count) bodyRTFEqual=\(actual.rtfData == expected.rtfData) bodyRTF=\(bytes(actual.rtfData))/\(bytes(expected.rtfData)) nativeInkEqual=\(actual.pencilKitData == expected.pencilKitData) nativeInk=\(bytes(actual.pencilKitData))/\(bytes(expected.pencilKitData)) strokesEqual=\(actual.strokes == expected.strokes) strokes=\(actual.strokes.count)/\(expected.strokes.count) boxesEqual=\(actual.textBoxes == expected.textBoxes) boxRTF=[\(actualBoxRTF)]/[\(expectedBoxRTF)] equationsEqual=\(actual.equations == expected.equations) imagesEqual=\(actual.images == expected.images) diagramsEqual=\(actual.diagrams == expected.diagrams) diagramIDs=\(actual.diagrams.map(\.id))/\(expected.diagrams.map(\.id))"
        }
        func historyContext() -> String {
            "manager=\(ObjectIdentifier(controller.history)) canUndo=\(controller.history.canUndo) canRedo=\(controller.history.canRedo) grouping=\(controller.history.groupingLevel) groupsByEvent=\(controller.history.groupsByEvent) undoing=\(controller.history.isUndoing) redoing=\(controller.history.isRedoing) registering=\(controller.history.isUndoRegistrationEnabled) undoAction=\(controller.history.undoActionName.debugDescription) redoAction=\(controller.history.redoActionName.debugDescription) currentPage=\(mountedPage(in: host).map(ObjectIdentifier.init).map(String.init(describing:)) ?? "nil") storeError=\(store.errorMessage.debugDescription)"
        }
        func event(_ type: NSEvent.EventType, _ point: InkPoint) throws -> NSEvent {
            time += 0.01
            let location = page.selectionView.convert(NSPoint(x: point.x, y: point.y), to: nil)
            guard let value = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                throw Failure(description: "Cannot construct a fixture-local diagram event")
            }
            let roundTrip = page.selectionView.convert(value.locationInWindow, from: nil)
            eventCoordinates.append("\(type.rawValue) requested=(\(point.x),\(point.y)) window=\(value.locationInWindow) returned=\(roundTrip) delta=(\(Double(roundTrip.x) - point.x),\(Double(roundTrip.y) - point.y))")
            try check(sameCoordinate(Double(roundTrip.x), point.x) && sameCoordinate(Double(roundTrip.y), point.y),
                "Fixture-native event conversion preserves page coordinates within 1e-6 point: \(eventCoordinates.last!)")
            return value
        }
        let start = InkPoint(x: 100, y: 360), end = InkPoint(x: 320, y: 480)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, start))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, end))
        try check(try saved() == initial && page.diagramView.diagrams.count == 1 && !controller.history.canUndo,
            "Dragging previews a vector object without saving or consuming undo")
        page.selectionView.mouseUp(with: try event(.leftMouseUp, end))
        passive()
        let inserted = try saved()
        guard let shape = inserted.diagrams.first else { throw Failure(description: "Native diagram drag did not insert a shape") }
        let creationGeometry = geometryContext(shape)
        print("Diagram creation geometry: \(creationGeometry)")
        try check(inserted.diagrams.count == 1 && shape.kind == .rectangle
            && sameCoordinate(shape.x, start.x) && sameCoordinate(shape.y, start.y)
            && sameCoordinate(shape.width, 220) && sameCoordinate(shape.height, 120),
            "Native drag creates the requested editable rectangle in page coordinates (\(creationGeometry))")
        try check(inserted.text == initial.text && inserted.strokes == initial.strokes && inserted.images == initial.images,
            "Diagram insertion preserves shared text, ink and image content")
        try check(state.tool == .select && page.activeTool == .select && state.placementCount == 1
            && controller.selection.diagrams == [shape.id] && window.firstResponder === page.selectionView
            && scroll.documentCursor === NSCursor.arrow,
            "Successful placement synchronizes the toolbar to Select and immediately focuses native object manipulation")
        let blank = InkPoint(x: 1400, y: 1800)
        let creationUndoAction = controller.history.undoActionName
        page.selectionView.mouseDown(with: try event(.leftMouseDown, blank))
        page.selectionView.mouseUp(with: try event(.leftMouseUp, blank))
        try check(try saved() == inserted && controller.selection.isEmpty && state.placementCount == 1
            && page.activeTool == .select && controller.history.undoActionName == creationUndoAction,
            "The next blank click deselects without creating another shape or an undo action")
        let beforeCreationUndo = historyContext()
        controller.history.undo()
        let immediateUndoContent = try saved()
        let immediateCreationUndo = "\(historyContext()) store=[\(payloadContext(immediateUndoContent, comparedTo: initial))] controller=[\(payloadContext(controller.content, comparedTo: initial))]"
        passive()
        let afterCreationUndo = try saved()
        let creationUndoContext = "before={\(beforeCreationUndo)} immediate={\(immediateCreationUndo)} after={\(historyContext()) store=[\(payloadContext(afterCreationUndo, comparedTo: initial))] controller=[\(payloadContext(controller.content, comparedTo: initial))]}"
        print("Diagram creation undo: \(creationUndoContext)")
        try check(afterCreationUndo == initial,
            "One native creation undo restores every exact page payload (\(creationUndoContext))")
        try check(!controller.history.canUndo && controller.history.canRedo,
            "One native creation gesture has exactly one reversible page transaction (\(creationUndoContext))")
        controller.history.redo(); passive()
        try check(try saved() == inserted && mountedPage(in: host).map(ObjectIdentifier.init) == pageID,
            "Redo restores the same object ID without replacing the native page")
        state.tool = .diagram; passive()
        controller.selection = MacPageSelection(diagrams: [shape.id])
        let rejectedUndoAction = controller.history.undoActionName
        state.rejectChanges = true
        try check(!controller.insertDiagram(from: InkPoint(x: 1000, y: 900), to: InkPoint(x: 1150, y: 1000))
            && (try saved()) == inserted && state.tool == .diagram && page.activeTool == .diagram
            && controller.selection.diagrams == [shape.id] && state.placementCount == 1
            && controller.history.undoActionName == rejectedUndoAction && !controller.history.canRedo,
            "A rejected placement retains the armed tool, selection, exact page and native undo action")
        state.rejectChanges = false
        state.kind = .table; state.tool = .diagram; passive()
        try check(controller.insertDiagram(from: InkPoint(x: 550, y: 360), to: InkPoint(x: 850, y: 540)),
            "The actual diagram insertion action creates a table")
        passive()
        guard let table = try saved().diagrams.first(where: { $0.kind == .table }) else { throw Failure(description: "Missing table") }
        try check(table.rows == 2 && table.columns == 3 && table.cells.count == 6,
            "Table creation retains requested dimensions and bounded editable cells")
        try check(state.tool == .select && page.activeTool == .select && state.placementCount == 2,
            "Explicitly re-arming Shapes inserts the next object and returns the toolbar to Select again")
        state.kind = .connector; state.tool = .diagram; passive()
        try check(controller.insertDiagram(from: PageDiagramGeometry.anchorPoint(on: shape, side: .right),
            to: PageDiagramGeometry.anchorPoint(on: table, side: .left)), "The actual connector action inserts an arrow")
        passive()
        guard let connector = try saved().diagrams.first(where: { $0.kind == .connector }) else { throw Failure(description: "Missing connector") }
        try check(connector.startAttachment?.targetDiagramID == shape.id && connector.endAttachment?.targetDiagramID == table.id
            && connector.route == .elbow && connector.arrowHeads == .both
            && state.tool == .select && page.activeTool == .select && state.placementCount == 3,
            "A routed arrow attaches to both native shape/table anchors")
        state.tool = .select; passive()
        controller.selection = MacPageSelection(diagrams: [shape.id])
        let beforeMove = try saved()
        let center = InkPoint(x: shape.x + shape.width / 2, y: shape.y + shape.height / 2)
        let movedCenter = InkPoint(x: center.x + 40, y: center.y + 30)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, center))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, movedCenter))
        try check(try saved() == beforeMove, "A native shape move remains a transient preview until mouse-up")
        page.selectionView.mouseUp(with: try event(.leftMouseUp, movedCenter)); passive()
        let moved = try saved()
        guard let movedShape = moved.diagrams.first(where: { $0.id == shape.id }),
              let movedArrow = moved.diagrams.first(where: { $0.id == connector.id }) else { throw Failure(description: "Move lost diagrams") }
        let oldEnds = PageDiagramGeometry.resolvedEndpoints(for: connector, in: beforeMove.diagrams)
        let movedEnds = PageDiagramGeometry.resolvedEndpoints(for: movedArrow, in: moved.diagrams)
        try check(sameCoordinate(movedShape.x, shape.x + 40) && sameCoordinate(movedShape.y, shape.y + 30)
            && sameCoordinate(movedEnds.start.x, oldEnds.start.x + 40) && sameCoordinate(movedEnds.start.y, oldEnds.start.y + 30)
            && movedEnds.end == oldEnds.end,
            "Moving one target carries its attached arrow endpoint while the other endpoint stays anchored (\(geometryContext(movedShape)); old=\(oldEnds), moved=\(movedEnds))")
        controller.history.undo(); passive()
        try check(try saved() == beforeMove, "Shape movement and its attached-arrow projection undo together")
        controller.history.redo(); passive()
        controller.selection = MacPageSelection(diagrams: [shape.id])
        let resizeStart = InkPoint(x: movedShape.x + movedShape.width, y: movedShape.y + movedShape.height)
        let resizeEnd = InkPoint(x: resizeStart.x + 40, y: resizeStart.y + 40)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, resizeStart))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, resizeEnd))
        try check(try saved() == moved, "The native lower-right resize handle does not save intermediate geometry")
        page.selectionView.mouseUp(with: try event(.leftMouseUp, resizeEnd)); passive()
        let resized = try saved()
        guard let resizedShape = resized.diagrams.first(where: { $0.id == shape.id }),
              let resizedArrow = resized.diagrams.first(where: { $0.id == connector.id }) else { throw Failure(description: "Resize lost diagrams") }
        try check(sameCoordinate(resizedShape.width, movedShape.width + 40) && sameCoordinate(resizedShape.height, movedShape.height + 40)
            && PageDiagramGeometry.resolvedEndpoints(for: resizedArrow, in: resized.diagrams).start
                == PageDiagramGeometry.anchorPoint(on: resizedShape, side: .right),
            "Actual resize handles update shape dimensions and attached endpoints (\(geometryContext(resizedShape)); expected width=\(movedShape.width + 40) height=\(movedShape.height + 40))")
        controller.history.undo(); passive()
        try check(try saved() == moved, "Native resize has one exact undo snapshot")
        controller.history.redo(); passive()
        controller.selection = MacPageSelection(diagrams: [connector.id])
        let connectorEnd = PageDiagramGeometry.resolvedEndpoints(for: resizedArrow, in: resized.diagrams).end
        let newEnd = PageDiagramGeometry.anchorPoint(on: table, side: .bottom)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, connectorEnd))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, newEnd))
        page.selectionView.mouseUp(with: try event(.leftMouseUp, newEnd)); passive()
        let reconnected = try saved()
        try check(reconnected.diagrams.first(where: { $0.id == connector.id })?.endAttachment?.side == .bottom,
            "Dragging an actual arrow endpoint reconnects it to the selected target side")
        controller.history.undo(); passive()
        try check(try saved() == resized, "Arrow reconnection restores the original attachment through undo")
        controller.history.redo(); passive()
        try check(controller.editDiagramText(id: shape.id, text: "Start — 日本語"), "Native label Save action updates a shape label")
        passive()
        let beforeCell = try saved()
        try check(controller.editDiagramText(id: table.id, cell: 4, text: "Cell नमस्ते 👋\nSecond line"),
            "The table editor's Save action accepts multiline Unicode cell text")
        passive()
        let edited = try saved()
        try check(edited.diagrams.first(where: { $0.id == table.id })?.cells[4] == "Cell नमस्ते 👋\nSecond line",
            "The cell edit reaches the actual persisted page model")
        controller.history.undo(); passive()
        try check(try saved() == beforeCell, "A table cell edit undoes atomically with unrelated objects intact")
        controller.history.redo(); passive()
        try check(try saved() == edited, "Cell redo restores exact Unicode and line breaks")
        try check(!controller.editDiagramText(id: table.id, cell: 4, text: String(repeating: "x", count: PageDiagramLimits.maximumCellBytes + 1)),
            "Oversized native table edits are rejected before a transaction")
        try check(try saved() == edited && controller.history.undoActionName == "Edit Table Cell",
            "Rejected text preserves the accepted page and its undo action")
        state.rejectChanges = true
        try check(!controller.editDiagramText(id: table.id, cell: 4, text: "Rejected store write"),
            "A store rejection is reported by the actual table Save action")
        controller.history.undo(); passive()
        try check(try saved() == edited && controller.history.canUndo,
            "Rejected diagram undo preserves the snapshot and leaves its native action retryable")
        state.rejectChanges = false
        controller.history.undo(); passive()
        try check(try saved() == beforeCell, "The same undo succeeds after the store accepts changes again")
        controller.history.redo(); passive()

        let themedContent = try saved()
        scroll.magnification = 1.25
        page.textView.setSelectedRange(NSRange(location: 3, length: 2))
        let caret = page.textView.selectedRange(), canUndo = controller.history.canUndo
        for theme in [PageTheme.rubyDark, .pitchWhite, .pastelLavender, .pitchBlack] {
            state.theme = theme; passive()
            try check(try saved() == themedContent && page.diagramView.diagrams == themedContent.diagrams,
                "Paper \(theme.rawValue) resolves display colors without rewriting diagram style or payload")
            try check(mountedPage(in: host).map(ObjectIdentifier.init) == pageID
                && mountedPage(in: host)?.selectionController.map { ObjectIdentifier($0.history) } == historyID
                && controller.history.canUndo == canUndo && abs(scroll.magnification - 1.25) < 0.000001 && !scroll.fitsPageWidth
                && page.textView.selectedRange() == caret,
                "Diagram theme changes preserve page identity, native undo, caret and explicit zoom")
        }
        state.tool = .pen; passive()
        try check(page.selectAllPageContent(), "Page Select All remains available while Pen is selected")
        try check(controller.selection.diagrams == Set(themedContent.diagrams.map(\.id))
            && controller.selection.strokes == Set(themedContent.strokes.map(\.id))
            && controller.selection.images == Set(themedContent.images.map(\.id))
            && controller.selection.equations == Set(themedContent.equations.map(\.id))
            && controller.selection.textBoxes == Set(themedContent.textBoxes.map(\.id)) && !controller.selection.textRanges.isEmpty,
            "One Select All spans diagrams, body text, ink, images, equations and text boxes")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try check(controller.copySelection(to: board), "The real copy writer accepts a mixed diagram selection")
        guard let data = board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.pasteboardType)) else {
            throw Failure(description: "Actual copy writer omitted the v4 page payload")
        }
        let copied = try PageClipboardPayload.decodeValidated(data)
        try check(Set(copied.diagrams.map(\.id)) == Set(themedContent.diagrams.map(\.id))
            && copied.diagrams.filter { $0.kind != .connector } == themedContent.diagrams.filter { $0.kind != .connector }
            && copied.images == themedContent.images && (try saved()) == themedContent,
            "Clipboard validation retains diagram styles, text and image bytes without changing the source")
        try check(board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.imagePasteboardType)) == nil
            && board.data(forType: NSPasteboard.PasteboardType(PageClipboardPayload.legacyPasteboardType)) == nil
            && board.string(forType: .string)?.contains("Cell नमस्ते") == true,
            "Diagram copies omit unsafe older page types while including readable label/table text")
        let selectedBeforeInvalidPaste = controller.selection.diagrams
        let undoBeforeInvalidPaste = controller.history.undoActionName
        var invalidPasteReported = false
        controller.onPasteError = { _ in invalidPasteReported = true }
        controller.paste(PageClipboardPayload(diagrams: [shape, shape]), offset: 20, action: "Rejected Diagram Paste")
        try check(invalidPasteReported && (try saved()) == themedContent
            && controller.selection.diagrams == selectedBeforeInvalidPaste && controller.history.undoActionName == undoBeforeInvalidPaste,
            "Direct malformed diagram paste rejects duplicate IDs atomically before geometry or undo changes")
        controller.paste(copied, offset: 20, action: "Paste Diagram Fixture"); passive()
        let pasted = try saved()
        let copiedIDs = Set(controller.selection.diagrams)
        try check(pasted.diagrams.count == themedContent.diagrams.count * 2
            && copiedIDs.count == themedContent.diagrams.count && copiedIDs.isDisjoint(with: Set(themedContent.diagrams.map(\.id))),
            "Mixed paste assigns fresh object identities without overwriting originals")
        guard let copiedArrow = pasted.diagrams.first(where: { copiedIDs.contains($0.id) && $0.kind == .connector }) else {
            throw Failure(description: "Mixed paste lost its arrow")
        }
        try check(copiedArrow.startAttachment.map { copiedIDs.contains($0.targetDiagramID) } == true
            && copiedArrow.endAttachment.map { copiedIDs.contains($0.targetDiagramID) } == true,
            "Pasted arrows reference their copied targets rather than the source objects")
        controller.perform(.delete); passive()
        try check(try saved() == themedContent, "Deleting the pasted mixed selection restores every original payload")
        controller.history.undo(); passive()
        try check(try saved() == pasted, "Undo restores all copied diagram identities and their mixed selection payload")
        controller.history.redo(); passive()
        _ = page.selectAllPageContent()
        controller.perform(.delete); passive()
        let emptied = try saved()
        try check(emptied.text.isEmpty && emptied.strokes.isEmpty && emptied.images.isEmpty && emptied.diagrams.isEmpty
            && emptied.textBoxes.isEmpty && emptied.equations.isEmpty, "Whole-page deletion includes diagrams and every older page object")
        controller.history.undo(); passive()
        try check(try saved() == themedContent, "Whole-page undo restores exact diagram/table and legacy payloads")
        state.readOnly = true; passive()
        try check(!page.inkView.isInputEnabled && !controller.editDiagramText(id: table.id, cell: 4, text: "Forbidden"),
            "A read-only native page rejects table editing")
        state.readOnly = false; passive()
        try check(store.library.node(id: sheetID)?.createdAt == initialNode.createdAt
            && store.library.node(id: sheetID)?.sheetNumber == initialNode.sheetNumber && store.library.node(id: sheetID)?.id == initialNode.id,
            "Diagram authoring retains sheet identity, creation metadata and numbering")
        try check(store.prepareForQuit(), "The temporary diagram library saves successfully")
        let reopened = try LibraryArchive.decode(LibraryArchive.read(from: store.libraryURL))
        try check(reopened.node(id: sheetID)?.pageContent == themedContent && reopened.formatVersion == 4,
            "A saved format-4 library reloads exact canonical diagram and mixed page content")
        checks += try exportChecks(themedContent)
        // The unchanged-text observer guard must still publish genuine native
        // font/paragraph undo. Exercise the real toolbar and AppKit actions on
        // both page text roles, sharing the same page undo manager as diagrams.
        state.tool = .text; passive()
        // An inactive command-line app need not have NSApp.keyWindow. The
        // production toolbar already supports that state through the native
        // responder-maintained activeEditor; do not activate the desktop app
        // or substitute a fake key window to make the fixture pass.
        try check(NSApp.keyWindow == nil || NSApp.keyWindow === window,
            "Native formatting is routed through this fixture or the existing no-key-window fallback")
        func value(_ content: PageContent, boxID: UUID?) throws -> (text: String, rtf: Data?) {
            if let boxID {
                guard let box = content.textBoxes.first(where: { $0.id == boxID }) else { throw Failure(description: "Native formatting lost its text box") }
                return (box.text, box.rtfData)
            }
            return (content.text, content.rtfData)
        }
        func formatted(_ content: PageContent, boxID: UUID?) throws -> NSAttributedString {
            let value = try value(content, boxID: boxID)
            guard let data = value.rtf else { throw Failure(description: "A real native text/formatting edit failed to persist RTF") }
            let attributed = try NSAttributedString(data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            guard attributed.string == value.text, attributed.length > 0 else { throw Failure(description: "Native formatting serialized inconsistent text") }
            return attributed
        }
        func bold(_ content: PageContent, boxID: UUID?) throws -> Bool {
            let attributed = try formatted(content, boxID: boxID)
            guard let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { throw Failure(description: "Native formatting omitted its font") }
            return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }
        func alignment(_ content: PageContent, boxID: UUID?) throws -> NSTextAlignment {
            let attributed = try formatted(content, boxID: boxID)
            return (attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment ?? .natural
        }
        func unrelatedPayloadsEqual(_ actual: PageContent, _ expected: PageContent, boxID: UUID?) -> Bool {
            var adjusted = actual
            if let boxID {
                guard let actualIndex = adjusted.textBoxes.firstIndex(where: { $0.id == boxID }),
                      let old = expected.textBoxes.first(where: { $0.id == boxID }) else { return false }
                adjusted.textBoxes[actualIndex].text = old.text
                adjusted.textBoxes[actualIndex].rtfData = old.rtfData
            } else {
                adjusted.text = expected.text
                adjusted.rtfData = expected.rtfData
            }
            return adjusted == expected
        }
        func nativeAction(_ editor: NotesTextView, _ action: () -> Void) {
            editor.breakUndoCoalescing()
            controller.history.beginUndoGrouping()
            action()
            editor.breakUndoCoalescing()
            controller.history.endUndoGrouping()
            passive()
        }
        func formattingUndoChecks(_ editor: NotesTextView, boxID: UUID?, role: String) throws {
            try check(editor.isEditable && editor.undoManager === controller.history && window.makeFirstResponder(editor),
                "Actual \(role) text editing uses the diagram page's native undo manager")
            try check(window.firstResponder === editor && NotesTextView.activeEditor === editor,
                "Native \(role) responder focus establishes the actual toolbar fallback target")
            let beforeTyping = try saved()
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            nativeAction(editor) { editor.insertText(" Δ", replacementRange: editor.selectedRange()) }
            let typed = try saved()
            try check(try value(typed, boxID: boxID).text == value(beforeTyping, boxID: boxID).text + " Δ"
                && unrelatedPayloadsEqual(typed, beforeTyping, boxID: boxID),
                "Genuine native \(role) typing publishes only its intended text payload")
            controller.history.undo(); passive()
            let typingUndone = try saved()
            try check(try value(typingUndone, boxID: boxID).text == value(beforeTyping, boxID: boxID).text
                && editor.string == value(beforeTyping, boxID: boxID).text && unrelatedPayloadsEqual(typingUndone, beforeTyping, boxID: boxID),
                "Direct manager undo still publishes genuine native \(role) text changes")
            controller.history.redo(); passive()
            try check(try value(saved(), boxID: boxID).text == value(typed, boxID: boxID).text,
                "Direct manager redo restores genuine native \(role) text changes")
            editor.setSelectedRange(NSRange(location: 0, length: 7))
            nativeAction(editor) { editor.alignLeft(nil) }
            let beforeBold = try saved()
            try check(try !bold(beforeBold, boxID: boxID) && alignment(beforeBold, boxID: boxID) == .left,
                "Native \(role) formatting starts with a persisted regular font and left paragraph")
            try check(window.firstResponder === editor && NotesTextView.activeEditor === editor
                && (NSApp.keyWindow == nil || NSApp.keyWindow === window),
                "The real Bold toolbar action targets the focused native \(role) editor")
            nativeAction(editor) { RichTextEditor.perform(.bold) }
            let madeBold = try saved()
            try check(try bold(madeBold, boxID: boxID) && unrelatedPayloadsEqual(madeBold, beforeBold, boxID: boxID),
                "The actual Bold toolbar action persists a genuine native \(role) font change")
            controller.history.undo(); passive()
            let fontUndone = try saved()
            let nativeUndoFont = editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            try check(try !bold(fontUndone, boxID: boxID)
                && nativeUndoFont.map { !NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
                && unrelatedPayloadsEqual(fontUndone, beforeBold, boxID: boxID),
                "Direct native \(role) font undo updates both stored RTF and the actual text view")
            controller.history.redo(); passive()
            try check(try bold(saved(), boxID: boxID), "Direct native \(role) font redo remains publishable")
            let beforeParagraph = try saved()
            nativeAction(editor) { editor.alignCenter(nil) }
            try check(try alignment(saved(), boxID: boxID) == .center,
                "A genuine native \(role) paragraph action reaches stored RTF")
            controller.history.undo(); passive()
            let paragraphUndone = try saved()
            try check(try alignment(paragraphUndone, boxID: boxID) == .left && bold(paragraphUndone, boxID: boxID)
                && unrelatedPayloadsEqual(paragraphUndone, beforeParagraph, boxID: boxID),
                "Native \(role) paragraph undo preserves the font and all unrelated diagram-page payloads")
            controller.history.redo(); passive()
            try check(try alignment(saved(), boxID: boxID) == .center && bold(saved(), boxID: boxID),
                "Native \(role) paragraph redo is not skipped by unchanged-text normalization")
        }
        try formattingUndoChecks(page.textView, boxID: nil, role: "body")
        guard let box = initial.textBoxes.first, let boxView = page.textBoxViews[box.id] else { throw Failure(description: "Actual movable text editor disappeared") }
        try formattingUndoChecks(boxView.editor, boxID: box.id, role: "text-box")
        state.tool = .select; passive()
        let beforeLabel = try saved()
        let labelled = PageDiagram(kind: .connector, colorHex: "#D52C4E", lineWidth: 2, text: "Arrow label",
            start: InkPoint(x: 900, y: 650), end: InkPoint(x: 1200, y: 650))
        var labelPage = beforeLabel
        labelPage.diagrams.append(labelled)
        try check(controller.commit(labelPage, action: "Insert Labelled Connector"), "The actual page accepts a labelled connector fixture")
        passive()
        guard let labelBounds = page.diagramView.labelBounds(of: labelled) else { throw Failure(description: "Visible connector label has no native bounds") }
        let labelPoint = InkPoint(x: labelBounds.midX, y: labelBounds.midY)
        try check(!PageDiagramGeometry.hitTest(labelled, at: labelPoint, in: labelPage.diagrams)
            && page.diagramView.hitTestDiagram(labelled, at: labelPoint),
            "The native label/double-click predicate includes visible label text away from the connector stem")
        controller.select(at: labelPoint)
        try check(controller.selection.diagrams == [labelled.id], "Clicking the connector's actual label bounds selects its object")
        controller.select(polygon: PageSelectionGeometry.rectangle(
            from: InkPoint(x: labelPoint.x - 2, y: labelPoint.y - 2), to: InkPoint(x: labelPoint.x + 2, y: labelPoint.y + 2)))
        try check(controller.selection.diagrams == [labelled.id] && controller.selectionBounds()?.contains(labelBounds) == true,
            "A small label lasso selects the connector and its native selection bounds cover the label")
        var unlabelled = labelled
        unlabelled.text = ""
        try check(page.diagramView.labelBounds(of: unlabelled) == nil && !page.diagramView.hitTestDiagram(unlabelled, at: labelPoint),
            "Unlabelled arrows have no invisible off-stem label hit region")
        controller.history.undo(); passive()
        try check(try saved() == beforeLabel,
            "Diagram-only undo preserves exact rich text after genuine body/text-box formatting changes")
        // Use a real raster with a center outside its resize handle, and a
        // named board so the actual native Paste hook never reads user data.
        guard let pasteContext = CGContext(data: nil, width: 240, height: 120, bitsPerComponent: 8, bytesPerRow: 240 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Cannot create an immediately movable image fixture")
        }
        pasteContext.draw(image, in: CGRect(x: 0, y: 0, width: 240, height: 120))
        guard let pasteImage = pasteContext.makeImage(),
              let pastePNG = NSBitmapImageRep(cgImage: pasteImage).representation(using: .png, properties: [:]) else {
            throw Failure(description: "Cannot encode the native image-paste fixture")
        }
        let imageBoard = NSPasteboard.withUniqueName()
        defer { imageBoard.releaseGlobally() }
        imageBoard.setData(pastePNG, forType: .png)
        state.tool = .text; passive()
        guard window.makeFirstResponder(page.textView) else { throw Failure(description: "Native Text paste could not focus its actual body editor") }
        let beforeImagePaste = try saved(), placementsBeforeImage = state.placementCount
        let previousPasteHook = page.textView.onPagePaste
        page.textView.onPagePaste = { controller.pasteImage(from: imageBoard) }
        defer { page.textView.onPagePaste = previousPasteHook }
        page.textView.paste(nil); passive()
        let afterImagePaste = try saved()
        guard let pastedImage = afterImagePaste.images.first(where: { candidate in
            !beforeImagePaste.images.contains(where: { $0.id == candidate.id })
        }) else { throw Failure(description: "Native Text paste did not insert an image") }
        try check(afterImagePaste.images.count == beforeImagePaste.images.count + 1
            && afterImagePaste.text == beforeImagePaste.text && afterImagePaste.rtfData == beforeImagePaste.rtfData
            && state.tool == .select && page.activeTool == .select && state.placementCount == placementsBeforeImage + 1
            && controller.singleSelectedImageID == pastedImage.id && window.firstResponder === page.selectionView
            && scroll.documentCursor === NSCursor.arrow,
            "Real native image Paste from Text immediately selects the new image, updates the toolbar and preserves text")
        let imageCenter = InkPoint(x: pastedImage.x + pastedImage.width / 2, y: pastedImage.y + pastedImage.height / 2)
        let movedImageCenter = InkPoint(x: imageCenter.x + 30, y: imageCenter.y + 20)
        page.selectionView.mouseDown(with: try event(.leftMouseDown, imageCenter))
        page.selectionView.mouseDragged(with: try event(.leftMouseDragged, movedImageCenter))
        page.selectionView.mouseUp(with: try event(.leftMouseUp, movedImageCenter)); passive()
        let afterImageMove = try saved()
        guard let movedImage = afterImageMove.images.first(where: { $0.id == pastedImage.id }) else { throw Failure(description: "The first image drag lost its pasted object") }
        try check(sameCoordinate(movedImage.x, pastedImage.x + 30) && sameCoordinate(movedImage.y, pastedImage.y + 20)
            && movedImage.width == pastedImage.width && movedImage.height == pastedImage.height
            && state.tool == .select && state.placementCount == placementsBeforeImage + 1,
            "The very first native gesture after image Paste drags it without a manual tool change")
        page.selectionView.mouseDown(with: try event(.leftMouseDown, blank))
        page.selectionView.mouseUp(with: try event(.leftMouseUp, blank))
        try check(try saved() == afterImageMove && controller.selection.isEmpty && page.activeTool == .select,
            "A blank click immediately deselects a pasted image without creating or editing page content")
        state.tool = .pen; passive()
        controller.selection = MacPageSelection(diagrams: [shape.id])
        let imageRejectionUndo = controller.history.undoActionName
        state.rejectChanges = true
        try check(controller.pasteImage(from: imageBoard) && (try saved()) == afterImageMove
            && state.tool == .pen && page.activeTool == .pen && controller.selection.diagrams == [shape.id]
            && state.placementCount == placementsBeforeImage + 1 && controller.history.undoActionName == imageRejectionUndo,
            "Rejected image Paste preserves the chosen tool, existing selection, exact content and undo action")
        state.rejectChanges = false
        print("Diagram native checks passed: \(checks) (offscreen creation, attached arrows, native resize/reconnect, table Save/undo, mixed clipboard and persistence; no physical input claim)")
        return checks
    }

    private static func exportChecks(_ content: PageContent) throws -> Int {
        func fail(_ message: String) -> Failure { Failure(description: "Diagram export diagnostic failed: \(message)") }
        func containsDiagramColor(_ image: CGImage) throws -> Bool {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw fail("Cannot inspect rendered pixels") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // This fixture's canonical diagram red is absent from its text,
            // blue ink and yellow image; rendered presence proves object export.
            for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
                if bytes[offset] > 155 && bytes[offset + 1] < 100 && (35...145).contains(bytes[offset + 2]) { return true }
            }
            return false
        }
        var checks = 0
        for theme in [PageTheme.light, .rubyDark, .pitchBlack] {
            guard let png = UnifiedPageExport.png(text: content.text, rtfData: content.rtfData, strokes: content.strokes,
                paper: .blank, theme: theme, textBoxes: content.textBoxes, equations: content.equations,
                images: content.images, diagrams: content.diagrams),
                  let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), try containsDiagramColor(image) else {
                throw fail("PNG omits diagram geometry on \(theme.rawValue)")
            }
            checks += 1
        }
        let pdf = UnifiedPageExport.pdf(text: content.text, rtfData: content.rtfData, strokes: content.strokes,
            paper: .blank, theme: .light, textBoxes: content.textBoxes, equations: content.equations,
            images: content.images, diagrams: content.diagrams)
        guard let document = PDFDocument(data: pdf), let page = document.page(at: 0),
              let rendered = page.thumbnail(of: NSSize(width: 800, height: 1100), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil),
              try containsDiagramColor(rendered) else { throw fail("PDF omits rendered diagram geometry") }
        checks += 1
        guard document.string?.contains("Cell") == true && document.string?.contains("Start") == true else {
            throw fail("PDF omits searchable table/shape labels")
        }
        checks += 1
        return checks
    }
}
#endif
