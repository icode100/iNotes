#if os(macOS)
import AppKit
import NotesCore
import PDFKit

@MainActor
enum MixedAnchorDiagnostics {
    static func run(page: UnifiedMacPageView, controller: MacPageSelectionController, store: NotesStore, sheetID: UUID,
                    event: (NSEvent.EventType, InkPoint) throws -> NSEvent, tool: (InkTool) -> Void,
                    passive: () -> Void) throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw DiagramDiagnostics.Failure(description: "Object attachment: " + message) }
            checks += 1
        }
        func saved() throws -> PageContent {
            guard let result = store.library.node(id: sheetID)?.pageContent else {
                throw DiagramDiagnostics.Failure(description: "Missing disposable attachment page")
            }
            return result
        }
        var content = try saved()
        guard let png = content.images.first?.imageData else { throw DiagramDiagnostics.Failure(description: "Missing test PNG") }
        let image = PageImage(x: 75, y: 2230, width: 64, height: 58, imageData: png)
        let box = PageTextBox(x: 320, y: 2310, width: 160, text: "Positioned text")
        let equation = NoteEquation(latex: "x^2", x: 670, y: 2510, width: 120, height: 75)
        content.images.append(image); content.textBoxes.append(box); content.equations.append(equation)
        try check(controller.commit(content, action: "Prepare anchor targets"), "mount the native image, text box and equation")
        passive()
        var first = PageDiagram(kind: .connector, colorHex: "#C32246", lineWidth: 3,
            startAttachment: .init(targetDiagramID: image.id, side: .right, targetKind: .image),
            endAttachment: .init(targetDiagramID: box.id, side: .left, targetKind: .textBox))
        var second = PageDiagram(kind: .connector, colorHex: "#C32246", lineWidth: 3,
            startAttachment: .init(targetDiagramID: box.id, side: .bottom, targetKind: .textBox),
            endAttachment: .init(targetDiagramID: equation.id, side: .top, targetKind: .equation), route: .elbow)
        let frames = page.externalAnchorFrames(in: content)
        let attached = PageDiagramGeometry.projectingExternalEndpoints(in: [first, second], frames: frames)
        first = attached[0]; second = attached[1]
        content.diagrams += attached
        try check(controller.commit(content, action: "Connect native objects"), "persist the bound arrows")
        passive(); controller.history.removeAllActions()
        func drag(_ from: InkPoint, _ to: InkPoint) throws {
            page.selectionView.mouseDown(with: try event(.leftMouseDown, from))
            page.selectionView.mouseDragged(with: try event(.leftMouseDragged, to))
        }
        func finish(_ point: InkPoint) throws {
            page.selectionView.mouseUp(with: try event(.leftMouseUp, point)); passive()
        }
        func matches(_ a: InkPoint?, _ b: InkPoint) -> Bool {
            a.map { abs($0.x - b.x) < 1e-6 && abs($0.y - b.y) < 1e-6 } ?? false
        }
        func verifyPorts(_ context: String) throws {
            let visible = page.diagramView.diagrams
            guard let left = visible.first(where: { $0.id == first.id }), let right = visible.first(where: { $0.id == second.id }),
                  let imageRect = page.imageViews[image.id]?.frame, let textRect = page.textBoxViews[box.id]?.frame,
                  let equationRect = page.equationViews[equation.id]?.frame else { throw DiagramDiagnostics.Failure(description: "Lost external target") }
            try check(matches(left.start, PageDiagramGeometry.anchorPoint(in: imageRect, side: .right)) &&
                      matches(left.end, PageDiagramGeometry.anchorPoint(in: textRect, side: .left)) &&
                      matches(right.start, PageDiagramGeometry.anchorPoint(in: textRect, side: .bottom)) &&
                      matches(right.end, PageDiagramGeometry.anchorPoint(in: equationRect, side: .top)), context)
        }
        controller.selection = MacPageSelection(diagrams: [first.id])
        let center = InkPoint(x: 100, y: 2250), moved = InkPoint(x: 143, y: 2268)
        try drag(center, moved)
        try check(controller.singleSelectedImageID == image.id && controller.hasPreview && (try saved()) == content,
                  "one press-and-drag on the image picks it up from the prior arrow selection and stays transient")
        try verifyPorts("arrow follows the image before mouse-up")
        try finish(moved)
        let afterMove = try saved()
        try check(afterMove.diagrams.first(where: { $0.id == first.id })?.start == page.diagramView.diagrams.first(where: { $0.id == first.id })?.start,
                  "moving the image commits its current fallback port")
        let movedImage = try storedImage(afterMove, id: image.id)
        let corner = InkPoint(x: movedImage.x + movedImage.width, y: movedImage.y + movedImage.height)
        let larger = InkPoint(x: corner.x + 36, y: corner.y + 32)
        try drag(corner, larger)
        try verifyPorts("image resize reprojects its attached midpoint in the native preview")
        try finish(larger)
        let afterResize = try saved()
        try check(try storedImage(afterResize, id: image.id).width > movedImage.width, "the selected image really resized")
        controller.history.undo(); passive()
        try check(try saved() == afterMove, "undo restores image size and endpoint together")
        controller.history.redo(); passive()
        try check(try saved() == afterResize, "redo restores image size and endpoint together")

        // The selected arrow retains both ends when its targets move as a group;
        // the unselected arrow follows the text box while its image end stays fixed.
        controller.selection = MacPageSelection(textBoxes: [box.id], equations: [equation.id], diagrams: [second.id])
        let dragStart = InkPoint(x: box.x + 14, y: box.y + 9), dragEnd = InkPoint(x: box.x + 50, y: box.y + 35)
        try drag(dragStart, dragEnd)
        try verifyPorts("both targets and the attached connector follow the mixed selection throughout a drag")
        try finish(dragEnd)
        let group = try saved()
        try check(group.diagrams.first(where: { $0.id == second.id })?.startAttachment == second.startAttachment &&
                  group.diagrams.first(where: { $0.id == second.id })?.endAttachment == second.endAttachment &&
                  group.equations.last!.x > equation.x && group.textBoxes.last!.x > box.x, "group move preserves both typed attachments")

        guard let initialTextFrame = page.textBoxViews[box.id]?.frame else { throw DiagramDiagnostics.Failure(description: "Missing text target") }
        // Initially there is more room below the box. Adding three text lines
        // closes that gap, leaving the horizontal route to this equation open.
        let neighbor = NoteEquation(latex: "y", x: initialTextFrame.maxX + 28, y: initialTextFrame.maxY + 55,
                                    width: 100, height: 56)
        let automatic = PageDiagram(kind: .connector, colorHex: "#C32246", lineWidth: 3,
            startAttachment: .init(targetDiagramID: box.id, side: .bottom, targetKind: .textBox, followsTarget: true),
            endAttachment: .init(targetDiagramID: neighbor.id, side: .top, targetKind: .equation, followsTarget: true))
        var neighbors = group
        neighbors.equations.append(neighbor); neighbors.diagrams.append(automatic)
        neighbors.diagrams = controller.projectedDiagrams(in: neighbors, changedDiagrams: [automatic.id])
        try check(controller.commit(neighbors, action: "Connect neighboring equation"), "save an automatic text-to-equation connection")
        passive()
        func verifyAutomatic(_ snapshot: PageContent, start: PageDiagram.AnchorSide, end: PageDiagram.AnchorSide) throws {
            guard let stored = snapshot.diagrams.first(where: { $0.id == automatic.id }),
                  let visible = page.diagramView.diagrams.first(where: { $0.id == automatic.id }),
                  let boxFrame = page.textBoxViews[box.id]?.frame, let mathFrame = page.equationViews[neighbor.id]?.frame else {
                throw DiagramDiagnostics.Failure(description: "Missing automatic text-to-equation connection")
            }
            try check(stored == visible && stored.startAttachment?.side == start && stored.endAttachment?.side == end &&
                      matches(stored.start, PageDiagramGeometry.anchorPoint(in: boxFrame, side: start)) &&
                      matches(stored.end, PageDiagramGeometry.anchorPoint(in: mathFrame, side: end)),
                      "saved and rendered automatic ports use text \(start) and equation \(end)")
        }
        try verifyAutomatic(try saved(), start: .bottom, end: .top)

        tool(.text); passive()
        guard let nativeBox = page.textBoxViews[box.id] else { throw DiagramDiagnostics.Failure(description: "Text target disappeared") }
        let oldHeight = nativeBox.frame.height
        try check(page.window?.makeFirstResponder(nativeBox.editor) == true && page.window?.firstResponder === nativeBox.editor
                  && nativeBox.editor.undoManager === controller.history, "typing uses the focused box and page undo manager")
        nativeBox.editor.setSelectedRange(NSRange(location: (nativeBox.editor.string as NSString).length, length: 0))
        nativeBox.editor.breakUndoCoalescing()
        controller.history.beginUndoGrouping()
        nativeBox.editor.insertText("\nA second line\nA third line\nA fourth line", replacementRange: nativeBox.editor.selectedRange())
        nativeBox.editor.breakUndoCoalescing()
        controller.history.endUndoGrouping()
        let synchronousHeight = nativeBox.frame.height
        passive()
        try check(nativeBox.frame.height > oldHeight, "native typing changes the text box's measured height")
        try verifyPorts("text wrapping updates side and bottom connectors without moving the box")
        let typed = try saved()
        try verifyAutomatic(typed, start: .right, end: .left)
        let savedPort = typed.diagrams.first(where: { $0.id == second.id })?.start
        let nativePort = PageDiagramGeometry.anchorPoint(in: nativeBox.frame, side: .bottom)
        let expandedHeight = nativeBox.frame.height
        try check(matches(savedPort, nativePort), "saved endpoint follows native text height (saved=\(String(describing: savedPort)), native=\(nativePort), previousHeight=\(oldHeight), editHeight=\(synchronousHeight), finalHeight=\(nativeBox.frame.height), textSaved=\(typed.textBoxes.last?.text == nativeBox.editor.string))")
        controller.history.undo(); passive()
        let undone = try saved()
        try verifyAutomatic(undone, start: .bottom, end: .top)
        guard let restoredBox = undone.textBoxes.first(where: { $0.id == box.id }) else { throw DiagramDiagnostics.Failure(description: "Missing restored text target") }
        // Undo restores real native text. The original plain-text box can now
        // have RTF, so compare exact geometry with a reopening of the saved box.
        let reopened = MacPageTextBoxView(frame: .zero)
        reopened.configure(restoredBox, theme: page.theme, paper: page.paperView.paper, editable: false, onChange: { _, _ in })
        try check(restoredBox.text == box.text && nativeBox.editor.string == box.text && nativeBox.frame.height < expandedHeight
                  && nativeBox.frame == reopened.frame, "native undo restores the original text and the exact bounds of its saved RTF")
        try verifyPorts("undoing native box text updates both arrows")
        try check(matches(undone.diagrams.first(where: { $0.id == second.id })?.start,
                          PageDiagramGeometry.anchorPoint(in: nativeBox.frame, side: .bottom)), "native undo saves the restored bottom port")
        try verifyPDF(undone, arrow: first, "PDF places the connector on the restored native text box after undo")
        try verifyPDF(undone, arrow: automatic, "PDF recreates the vertical automatic route after undo")
        controller.history.redo(); passive()
        let redone = try saved()
        try verifyAutomatic(redone, start: .right, end: .left)
        try check(redone.textBoxes.last?.text == typed.textBoxes.last?.text &&
                  redone.diagrams.first(where: { $0.id == second.id })?.start == savedPort,
                  "native redo saves the expanded text and its original bottom port")
        try verifyPorts("native text redo restores both visual attachment positions")
        tool(.select); passive()

        func verifyPDF(_ snapshot: PageContent, arrow: PageDiagram, _ context: String) throws {
            // Deliberately incorrect fallbacks force export to recreate native
            // object frames before drawing the expected connector shaft.
            var exportArrow = arrow
            exportArrow.start = .init(x: 10, y: 15); exportArrow.end = .init(x: 30, y: 35)
            if exportArrow.hasAutomaticPort {
                exportArrow.startAttachment?.side = .left; exportArrow.endAttachment?.side = .bottom
            }
            let output = UnifiedPageExport.pdf(text: "", rtfData: nil, strokes: [], paper: .blank,
                textBoxes: snapshot.textBoxes, equations: snapshot.equations, images: snapshot.images, diagrams: [exportArrow])
            guard let pdfPage = PDFDocument(data: output)?.page(at: 0)?.pageRef,
                  let visible = page.diagramView.diagrams.first(where: { $0.id == arrow.id }),
                  let surface = CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8, bytesPerRow: 24,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = surface.data?.assumingMemoryBound(to: UInt8.self) else { throw DiagramDiagnostics.Failure(description: "Missing projected PDF") }
            let x = (visible.start.x + visible.end.x) / 2, y = (visible.start.y + visible.end.y) / 2
            surface.translateBy(x: 3 - x, y: 3 - (pdfPage.getBoxRect(.mediaBox).maxY - y))
            surface.drawPDFPage(pdfPage)
            try check(stride(from: 0, to: 144, by: 4).contains { bytes[$0] > 140 && bytes[$0 + 1] < 100 && bytes[$0 + 2] < 145 }, context)
        }
        try verifyPDF(redone, arrow: first, "PDF draws the expanded connector shaft between image and text-box ports after redo")
        try verifyPDF(redone, arrow: automatic, "PDF recreates the horizontal automatic route after redo")
        controller.selection = MacPageSelection(diagrams: [automatic.id])
        let rightPort = PageDiagramGeometry.anchorPoint(in: nativeBox.frame, side: .right)
        let topPort = PageDiagramGeometry.anchorPoint(in: nativeBox.frame, side: .top)
        try drag(rightPort, topPort); try finish(topPort)
        let pinned = try saved().diagrams.first { $0.id == automatic.id }
        try check(pinned?.startAttachment?.targetDiagramID == box.id && pinned?.startAttachment?.side == .top
                  && pinned?.startAttachment?.followsTarget == nil && pinned?.start == topPort
                  && pinned?.endAttachment?.targetDiagramID == neighbor.id && pinned?.endAttachment?.followsTarget == true,
                  "manually dragging an automatic endpoint pins only that side")
        controller.history.undo(); passive()
        try verifyAutomatic(try saved(), start: .right, end: .left)
        return checks
    }

    private static func storedImage(_ content: PageContent, id: UUID) throws -> PageImage {
        guard let image = content.images.first(where: { $0.id == id }) else { throw DiagramDiagnostics.Failure(description: "Missing connected image") }
        return image
    }
}
#endif
