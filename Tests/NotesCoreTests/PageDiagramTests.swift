#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
import Foundation
@testable import NotesCore

final class PageDiagramTests: XCTestCase {
    private func fixture() -> [PageDiagram] {
        let shape = PageDiagram(kind: .roundedRectangle, x: 100, y: 120, width: 200, height: 100,
                                colorHex: "#3869B2", fill: true, text: "A process — नमस्ते")
        let table = PageDiagram(kind: .table, x: 500, y: 200, width: 300, height: 120,
                                rows: 2, columns: 3, cells: ["First", "日本語", "Third", "4", "5", "6"])
        let arrow = PageDiagram(kind: .connector, linePattern: .dashed, text: "next",
            start: InkPoint(x: 20, y: 30), end: InkPoint(x: 40, y: 50),
            startAttachment: PageDiagramAttachment(targetDiagramID: shape.id, side: .right),
            endAttachment: PageDiagramAttachment(targetDiagramID: table.id, side: .left),
            route: .elbow, arrowHeads: .both)
        return [shape, table, arrow]
    }

    func testDiagramArchivePersistenceDuplicateImportSearchAndSnapshots() throws {
        var library = NoteLibrary.sample()
        var sheet = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
        let id = sheet.id, created = sheet.createdAt, number = sheet.sheetNumber
        sheet.diagrams = fixture()
        sheet.textBoxes = [PageTextBox(text: "Existing text")]
        sheet.equations = [NoteEquation(latex: "x^2")]
        sheet.strokes = [InkStroke(points: [InkPoint(x: 5, y: 10)])]
        try library.update(sheet)
        XCTAssertEqual(library.formatVersion, 4)
        let saved = try LibraryArchive.decode(LibraryArchive.encode(library))
        XCTAssertEqual(saved.node(id: id)?.pageContent, sheet.pageContent)
        XCTAssertEqual(saved.node(id: id)?.sheetNumber, number)
        XCTAssertEqual(try XCTUnwrap(saved.node(id: id)).createdAt.timeIntervalSince1970,
                       created.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(saved.search("नमस्ते").first?.id, id)
        XCTAssertEqual(saved.search("日本語").first?.id, id)
        XCTAssertTrue(sheet.plainTextExport.contains("First\t日本語\tThird"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-diagrams-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LibraryRepository(url: directory.appendingPathComponent("Library.json"))
        try repository.save(library)
        XCTAssertEqual(try repository.load()?.node(id: id)?.pageContent, sheet.pageContent)
        let copy = try library.duplicate(id: id)
        XCTAssertEqual(library.node(id: copy)?.diagrams, sheet.diagrams)
        var destination = NoteLibrary.sample()
        let previous = destination.nodes
        _ = try destination.merge(saved)
        XCTAssertEqual(Array(destination.nodes.prefix(previous.count)), previous)
        XCTAssertEqual(destination.formatVersion, 4)
        let imported = try XCTUnwrap(destination.nodes.last)
        XCTAssertNotEqual(imported.id, sheet.id)
        XCTAssertEqual(imported.pageContent, sheet.pageContent)
        var restored = NoteNode(kind: .sheet, title: "Snapshot")
        restored.pageContent = sheet.pageContent
        XCTAssertEqual(restored.diagrams, sheet.diagrams)
        XCTAssertEqual(try JSONDecoder().decode(PageContent.self, from: JSONEncoder().encode(sheet.pageContent)), sheet.pageContent)
        let everyKind = PageDiagram.Kind.allCases.map { PageDiagram(kind: $0) }
        try PageDiagramLimits.validate(everyKind)
        XCTAssertEqual(try JSONDecoder().decode([PageDiagram].self, from: JSONEncoder().encode(everyKind)), everyKind)
    }

    func testLegacyDiagramDefaultsAndStickyFormatFourPromotion() throws {
        for version in [1, 2, 3] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryArchive.encode(NoteLibrary.sample())) as? [String: Any])
            json["formatVersion"] = version
            var nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
            for index in nodes.indices { nodes[index].removeValue(forKey: "diagrams") }
            json["nodes"] = nodes
            var library = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(library.formatVersion, version)
            XCTAssertTrue(library.nodes.allSatisfy { $0.diagrams.isEmpty })
            var sheet = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
            sheet.diagrams = fixture()
            try library.update(sheet)
            XCTAssertEqual(library.formatVersion, 4)
            for oldVersion in [1, 2, 3] {
                XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: library.nodes, formatVersion: oldVersion)))
            }
            sheet = try XCTUnwrap(library.node(id: sheet.id)); sheet.diagrams = []
            try library.update(sheet)
            XCTAssertEqual(library.formatVersion, 4)
        }
        XCTAssertEqual(NoteLibrary().formatVersion, 2)
        let legacy = Data("{\"text\":\"Old\",\"strokes\":[]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(PageContent.self, from: legacy).diagrams, [])
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(legacy).diagrams, [])
        XCTAssertEqual(PageClipboardPayload.imagePasteboardType, "io.inotes.page-selection.v3")
        XCTAssertEqual(PageClipboardPayload.pasteboardType, "io.inotes.page-selection.v4")
    }

    func testInvalidDiagramGeometryStyleAndAttachmentRejectAtomically() throws {
        let base = NoteLibrary.sample(), diagrams = fixture()
        let original = try XCTUnwrap(base.nodes.first { $0.kind == .sheet })
        var invalid: [[PageDiagram]] = [[diagrams[0], diagrams[0]]]
        for coordinate in [-1.0, 100_001, .infinity, .nan] {
            var value = diagrams[0]; value.x = coordinate; invalid.append([value])
            value = diagrams[0]; value.y = coordinate; invalid.append([value])
        }
        for extent in [0.0, 10_001, .infinity, .nan] {
            var value = diagrams[0]; value.width = extent; invalid.append([value])
            value = diagrams[0]; value.height = extent; invalid.append([value])
        }
        for width in [0.0, 100.1, .infinity, .nan] {
            var value = diagrams[0]; value.lineWidth = width; invalid.append([value])
        }
        for color in ["red", "#123", "#12345678", "#GG0000"] {
            var value = diagrams[0]; value.colorHex = color; invalid.append([value])
        }
        var arrow = diagrams[2]; arrow.startAttachment?.targetDiagramID = UUID(); invalid.append([diagrams[0], diagrams[1], arrow])
        arrow = diagrams[2]; arrow.startAttachment?.targetDiagramID = arrow.id; invalid.append([diagrams[0], diagrams[1], arrow])
        arrow = diagrams[2]; arrow.end.x = 110_001; invalid.append([diagrams[0], diagrams[1], arrow])
        arrow = diagrams[2]; arrow.start.pressure = .nan; invalid.append([diagrams[0], diagrams[1], arrow])
        var shape = diagrams[0]; shape.startAttachment = PageDiagramAttachment(targetDiagramID: diagrams[1].id, side: .left)
        invalid.append([shape, diagrams[1]])
        for values in invalid {
            var library = base, candidate = original
            candidate.diagrams = values
            XCTAssertThrowsError(try library.update(candidate))
            XCTAssertEqual(library, base)
            let nodes = base.nodes.map { $0.id == candidate.id ? candidate : $0 }
            XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: nodes, formatVersion: 4)))
            XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(PageClipboardPayload(diagrams: values))))
        }
    }

    func testTableAndDiagramTextObjectAndPatternBudgets() throws {
        let table = PageDiagram(kind: .table, rows: 20, columns: 12)
        try PageDiagramLimits.validate([table])
        var invalid = table; invalid.rows = 21
        XCTAssertThrowsError(try PageDiagramLimits.validate([invalid]))
        invalid = table; invalid.columns = 13
        XCTAssertThrowsError(try PageDiagramLimits.validate([invalid]))
        invalid = table; invalid.cells.removeLast()
        XCTAssertThrowsError(try PageDiagramLimits.validate([invalid]))
        invalid = table; invalid.cells[0] = String(repeating: "é", count: 513)
        XCTAssertThrowsError(try PageDiagramLimits.validate([invalid]))
        var boundary = table; boundary.cells[0] = String(repeating: "é", count: 512)
        try PageDiagramLimits.validate([boundary])
        var label = PageDiagram(text: String(repeating: "x", count: PageDiagramLimits.maximumLabelBytes))
        try PageDiagramLimits.validate([label]); label.text.append("x")
        XCTAssertThrowsError(try PageDiagramLimits.validate([label]))
        let exactCells = [table, PageDiagram(kind: .table, rows: 20, columns: 12), PageDiagram(kind: .table, rows: 4, columns: 8)]
        try PageDiagramLimits.validate(exactCells)
        XCTAssertThrowsError(try PageDiagramLimits.validate(exactCells + [PageDiagram(kind: .table, rows: 1, columns: 1)]))
        let maximumObjects = (0..<PageDiagramLimits.maximumObjects).map { _ in PageDiagram() }
        try PageDiagramLimits.validate(maximumObjects)
        XCTAssertThrowsError(try PageDiagramLimits.validate(maximumObjects + [PageDiagram()]))
        let manyLabels = (0..<257).map { _ in PageDiagram(text: String(repeating: "x", count: 4_096)) }
        XCTAssertThrowsError(try PageDiagramLimits.validate(manyLabels))
        let longDashes = (0..<20).map { _ in PageDiagram(kind: .connector, lineWidth: 0.5, linePattern: .dotted,
            start: InkPoint(x: 0, y: 0), end: InkPoint(x: 100_000, y: 100_000)) }
        XCTAssertThrowsError(try PageDiagramLimits.validate(longDashes))
        try PageDiagramLimits.validate([PageDiagram(kind: .table, linePattern: .dotted, rows: 4, columns: 6)])
    }

    func testConnectorAnchorsRoutingHitTestingAndBoundaryDetachment() throws {
        let diagrams = fixture(), arrow = diagrams[2]
        let points = PageDiagramGeometry.connectorPoints(for: arrow, in: diagrams)
        XCTAssertEqual(points, [InkPoint(x: 300, y: 170), InkPoint(x: 400, y: 170),
                                InkPoint(x: 400, y: 260), InkPoint(x: 500, y: 260)])
        XCTAssertTrue(PageDiagramGeometry.hitTest(arrow, at: InkPoint(x: 400, y: 210), in: diagrams))
        XCTAssertFalse(PageDiagramGeometry.hitTest(arrow, at: InkPoint(x: 300, y: 260), in: diagrams))
        let triangle = PageDiagram(kind: .triangle, x: 100, y: 200, width: 200, height: 100)
        XCTAssertEqual(PageDiagramGeometry.anchorPoint(on: triangle, side: .left), InkPoint(x: 150, y: 250))
        XCTAssertEqual(PageDiagramGeometry.anchorPoint(on: triangle, side: .right), InkPoint(x: 250, y: 250))
        XCTAssertEqual(PageDiagramGeometry.anchorPoint(on: triangle, side: .top), InkPoint(x: 200, y: 200))
        XCTAssertEqual(PageDiagramGeometry.anchorPoint(on: triangle, side: .bottom), InkPoint(x: 200, y: 300))
        XCTAssertTrue(PageDiagramGeometry.hitTest(triangle, at: InkPoint(x: 200, y: 240), in: [triangle]))
        XCTAssertFalse(PageDiagramGeometry.hitTest(triangle, at: InkPoint(x: 100, y: 200), in: [triangle]))
        let ellipse = PageDiagram(kind: .ellipse, x: 0, y: 0, width: 100, height: 50)
        XCTAssertFalse(PageDiagramGeometry.hitTest(ellipse, at: InkPoint(x: 0, y: 0), in: [ellipse], tolerance: 0))
        XCTAssertTrue(PageDiagramGeometry.hitTest(ellipse, at: InkPoint(x: 50, y: 25), in: [ellipse]))
        let edge = PageDiagram(x: 100_000, y: 100_000, width: 10_000, height: 10_000)
        let attached = PageDiagram(kind: .connector, endAttachment: PageDiagramAttachment(targetDiagramID: edge.id, side: .right))
        let detached = PageDiagramGeometry.removing(ids: [edge.id], from: [edge, attached])
        XCTAssertEqual(detached[0].end, InkPoint(x: 110_000, y: 105_000))
        XCTAssertNil(detached[0].endAttachment)
        try PageDiagramLimits.validate(detached)
    }

    func testDiagramMoveDeleteAndCopyRemapPreserveConnectorGraph() throws {
        let diagrams = fixture(), shape = diagrams[0], table = diagrams[1], arrow = diagrams[2]
        let movedShape = PageDiagramGeometry.translated(diagrams, selectedIDs: [shape.id], dx: 70, dy: 30)
        XCTAssertEqual(PageDiagramGeometry.resolvedEndpoints(for: movedShape[2], in: movedShape).start, InkPoint(x: 370, y: 200))
        XCTAssertEqual(movedShape[2].startAttachment, arrow.startAttachment)
        let movedArrow = PageDiagramGeometry.translated(diagrams, selectedIDs: [arrow.id], dx: 10, dy: 20)
        XCTAssertNil(movedArrow[2].startAttachment); XCTAssertNil(movedArrow[2].endAttachment)
        XCTAssertEqual(movedArrow[2].start, InkPoint(x: 310, y: 190))
        let movedTogether = PageDiagramGeometry.translated(diagrams, selectedIDs: Set(diagrams.map(\.id)), dx: 10, dy: 20)
        XCTAssertEqual(movedTogether[2].startAttachment, arrow.startAttachment)
        XCTAssertEqual(PageDiagramGeometry.resolvedEndpoints(for: movedTogether[2], in: movedTogether).end, InkPoint(x: 510, y: 280))
        let removed = PageDiagramGeometry.removing(ids: [shape.id], from: diagrams)
        XCTAssertEqual(removed.map(\.id), [table.id, arrow.id])
        XCTAssertNil(removed[1].startAttachment)
        XCTAssertEqual(removed[1].start, InkPoint(x: 300, y: 170))
        XCTAssertEqual(removed[1].endAttachment, arrow.endAttachment)
        try PageDiagramLimits.validate(removed)
        let mapping = Dictionary(uniqueKeysWithValues: diagrams.map { ($0.id, UUID()) })
        let copied = PageDiagramGeometry.remapped(diagrams, mapping: mapping, dx: 20, dy: 20)
        XCTAssertEqual(copied[2].startAttachment?.targetDiagramID, mapping[shape.id])
        XCTAssertEqual(copied[2].endAttachment?.targetDiagramID, mapping[table.id])
        XCTAssertEqual(PageDiagramGeometry.resolvedEndpoints(for: copied[2], in: copied).start, InkPoint(x: 320, y: 190))
        try PageDiagramLimits.validate(copied)
        let arrowOnly = PageDiagramGeometry.remapped([arrow], mapping: [arrow.id: UUID()], dx: 20, dy: 20, resolvingIn: diagrams)
        XCTAssertNil(arrowOnly[0].startAttachment); XCTAssertNil(arrowOnly[0].endAttachment)
        XCTAssertEqual(arrowOnly[0].start, InkPoint(x: 320, y: 190))
        try PageDiagramLimits.validate(arrowOnly)
        // Unused connector fallback coordinates must not invalidate shape moves.
        let farShape = PageDiagram(x: 1_000, y: 1_000)
        let nearShape = PageDiagramGeometry.translated(farShape, dx: -900, dy: -900)
        XCTAssertEqual(nearShape.x, 100)
        XCTAssertEqual(nearShape.start, farShape.start)
        try PageDiagramLimits.validate([nearShape])
        let fartherTarget = PageDiagramGeometry.translated(diagrams, selectedIDs: [shape.id], dx: 1_000, dy: 0)
        let arrowBack = PageDiagramGeometry.translated(fartherTarget, selectedIDs: [arrow.id], dx: -400, dy: 0)
        XCTAssertEqual(arrowBack[2].start, InkPoint(x: 900, y: 170))
        XCTAssertEqual(arrowBack[2].end, InkPoint(x: 100, y: 260))
        XCTAssertEqual(arrowBack[2].x, arrow.x)
        XCTAssertEqual(arrowBack[2].width, arrow.width)
        try PageDiagramLimits.validate(arrowBack)
    }

    func testDiagramMixedClipboardRoundTripAndValidation() throws {
        let diagrams = fixture()
        let payload = PageClipboardPayload(text: "Body", strokes: [InkStroke(points: [InkPoint(x: 10, y: 20)])],
            textBoxes: [PageTextBox(text: "Movable")], equations: [NoteEquation(latex: "x^2")], diagrams: diagrams)
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(payload)), payload)
        var missingTarget = payload; missingTarget.diagrams.removeFirst()
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(missingTarget)))
        var oversizedCell = payload
        oversizedCell.diagrams[1].cells[0] = String(repeating: "x", count: PageDiagramLimits.maximumCellBytes + 1)
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(oversizedCell)))
        var restored = NoteNode(kind: .sheet, title: "Restored")
        restored.pageContent = PageContent(text: payload.text, strokes: payload.strokes,
            textBoxes: payload.textBoxes, equations: payload.equations, diagrams: payload.diagrams)
        XCTAssertEqual(restored.diagrams, diagrams)
    }
}
