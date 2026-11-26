#if os(macOS)
import AppKit
import NotesCore
import PDFKit

@MainActor
enum TableResizeDiagnostics {
    static func run(page: UnifiedMacPageView, controller: MacPageSelectionController, store: NotesStore, sheetID: UUID,
                    event: (NSEvent.EventType, InkPoint) throws -> NSEvent, passive: () -> Void) throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw DiagramDiagnostics.Failure(description: "Table divider: " + message) }
            checks += 1
        }
        func saved() throws -> PageContent {
            guard let content = store.library.node(id: sheetID)?.pageContent else {
                throw DiagramDiagnostics.Failure(description: "Missing disposable table page")
            }
            return content
        }
        let table = PageDiagram(kind: .table, x: 100, y: 1550, width: 300, height: 180,
                                colorHex: "#D52C4E", lineWidth: 3, rows: 2, columns: 3,
                                cells: ["A", "Beta", "C", "Row two", "E", "F"])
        var initial = try saved()
        initial.diagrams.append(table)
        try check(controller.commit(initial, action: "Prepare Table Fixture"), "prepare existing mixed-content page")
        passive()
        controller.selection = MacPageSelection(diagrams: [table.id])
        controller.history.removeAllActions()
        let overlay = page.selectionView
        let column = InkPoint(x: 200, y: 1590), wide = InkPoint(x: 235, y: 1590)
        let row = InkPoint(x: 155, y: 1640), tall = InkPoint(x: 155, y: 1667)
        try check(overlay.tableDividerCursor(at: CGPoint(x: column.x, y: column.y)) === NSCursor.resizeLeftRight &&
                  overlay.tableDividerCursor(at: CGPoint(x: row.x, y: row.y)) === NSCursor.resizeUpDown &&
                  overlay.tableDividerCursor(at: CGPoint(x: 150, y: 1570)) == nil,
                  "selected table assigns directional cursors only to actual internal boundaries")
        func drag(_ from: InkPoint, _ to: InkPoint) throws {
            overlay.mouseDown(with: try event(.leftMouseDown, from))
            overlay.mouseDragged(with: try event(.leftMouseDragged, to))
        }
        try drag(column, wide)
        let columnPreview = controller.displayedContent
        try check(columnPreview != initial && page.diagramView.diagrams == columnPreview.diagrams && (try saved()) == initial,
                  "drag previews the new column while keeping the saved page intact")
        overlay.mouseUp(with: try event(.leftMouseUp, wide)); passive()
        let columns = try saved()
        guard let widened = columns.diagrams.last else { throw DiagramDiagnostics.Failure(description: "Missing resized column") }
        let horizontal = PageTableGeometry.edges(in: widened, axis: .column)
        try check(columns == columnPreview && horizontal.count == 4 && abs(horizontal[1] - wide.x) < 0.000001 &&
                  abs(horizontal[2] - 300) < 0.000001 && controller.history.undoActionName == "Resize Table Column",
                  "column drag changes only adjacent widths and commits one named edit")
        try drag(row, tall)
        overlay.mouseUp(with: try event(.leftMouseUp, tall)); passive()
        let both = try saved()
        guard let resized = both.diagrams.last else { throw DiagramDiagnostics.Failure(description: "Missing resized row") }
        let vertical = PageTableGeometry.edges(in: resized, axis: .row)
        try check(vertical.count == 3 && abs(vertical[1] - tall.y) < 0.000001 && resized.cells == table.cells &&
                  resized.width == table.width && resized.height == table.height && resized.id == table.id &&
                  controller.history.undoActionName == "Resize Table Row",
                  "row drag preserves frame, cells and identity")
        try check(PageTableGeometry.cellIndex(at: InkPoint(x: 213, y: 1650), in: resized) == 0 &&
                  PageTableGeometry.cellIndex(at: InkPoint(x: 245, y: 1680), in: resized) == 4,
                  "cell editing follows the redistributed row and column hit areas")
        controller.history.undo(); passive()
        try check(try saved() == columns, "one undo restores the previous row layout and exact mixed page")
        controller.history.undo(); passive()
        try check(try saved() == initial && !controller.history.canUndo, "one more undo restores the legacy equal-width table")
        controller.history.redo(); passive(); controller.history.redo(); passive()
        try check(try saved() == both && page.diagramView.diagrams == both.diagrams, "redo restores both independent drags")

        try drag(wide, InkPoint(x: 210, y: 1590))
        overlay.cancelOperation(nil)
        try check(!controller.hasPreview && (try saved()) == both && page.diagramView.diagrams == both.diagrams,
                  "Escape cancels the transient resize")
        try check(store.flush(), "save the custom layout")
        let reopened = try LibraryArchive.decode(LibraryArchive.read(from: store.libraryURL))
        try check(reopened.node(id: sheetID)?.pageContent == both, "reopen the exact customized table and mixed page")

        let data = UnifiedPageExport.pdf(text: "", rtfData: nil, strokes: [], paper: .blank, diagrams: [resized])
        guard let pdf = PDFDocument(data: data), let pdfPage = pdf.page(at: 0), let nativePage = pdfPage.pageRef else {
            throw DiagramDiagnostics.Failure(description: "Missing native resized table PDF")
        }
        func isRedLine(x: CGFloat, y: CGFloat) -> Bool {
            guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
            context.translateBy(x: 2 - x, y: 2 - (nativePage.getBoxRect(.mediaBox).maxY - y))
            context.drawPDFPage(nativePage)
            return stride(from: 0, to: 64, by: 4).contains { bytes[$0] > 150 && bytes[$0 + 1] < 100 && bytes[$0 + 2] < 150 }
        }
        try check(isRedLine(x: wide.x, y: column.y) && !isRedLine(x: column.x, y: column.y) &&
                  isRedLine(x: row.x, y: tall.y) && !isRedLine(x: row.x, y: row.y),
                  "rendered PDF draws both resized separators at their current positions")
        try check(pdf.string?.contains("Beta") == true && pdf.string?.contains("Row two") == true,
                  "resized cells export searchable content")
        return checks
    }
}
#endif
