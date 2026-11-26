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

    func testTableDividerGeometryMatchesDrawingHitTestingAndFrameResizing() throws {
        let table = PageDiagram(kind: .table, x: 10, y: 20, width: 256, height: 128, rows: 2, columns: 4)
        let first = PageTableGeometry.movingDivider(table, index: 1, on: .column, to: 106)
        let sized = PageTableGeometry.movingDivider(first, index: 1, on: .row, to: 52)
        XCTAssertEqual(PageTableGeometry.edges(in: sized, axis: .column), [10, 106, 138, 202, 266])
        XCTAssertEqual(PageTableGeometry.edges(in: sized, axis: .row), [20, 52, 148])
        XCTAssertEqual(PageTableGeometry.cellRect(5, in: sized), CGRect(x: 106, y: 52, width: 32, height: 96))
        XCTAssertEqual(PageTableGeometry.cellIndex(at: InkPoint(x: 106, y: 52), in: sized), 5)
        XCTAssertEqual(PageTableGeometry.cellIndex(at: InkPoint(x: 265, y: 147), in: sized), 7)
        XCTAssertNil(PageTableGeometry.cellIndex(at: InkPoint(x: 0, y: 52), in: sized))
        XCTAssertEqual(PageTableGeometry.cellRect(Int.max, in: sized), .zero)
        var scaled = sized
        scaled.width *= 2
        scaled.height *= 2
        XCTAssertEqual(PageTableGeometry.cellRect(5, in: scaled), CGRect(x: 202, y: 84, width: 64, height: 192))
        let clamped = PageTableGeometry.movingDivider(sized, index: 1, on: .column, to: -500)
        XCTAssertEqual(PageTableGeometry.edges(in: clamped, axis: .column), [10, 26, 138, 202, 266])
        XCTAssertEqual(PageTableGeometry.movingDivider(first, index: 1, on: .column, to: 74), table)
        XCTAssertEqual(PageTableGeometry.movingDivider(sized, index: 0, on: .row, to: 80), sized)
        XCTAssertEqual(PageTableGeometry.movingDivider(sized, index: 1, on: .row, to: .nan), sized)
    }

    func testStyledDiagramsRequireFormatFiveAndClipboardReadersRetainOlderTypes() throws {
        let ordinary = fixture()
        var table = ordinary[1]
        table.columnFractions = [0.5, 0.25, 0.25]
        var arrow = ordinary[2]
        arrow.openArrowheads = true
        var floating = ordinary[2]
        floating.startAttachment?.followsTarget = true
        var invalid = floating
        invalid.startAttachment?.followsTarget = false
        XCTAssertThrowsError(try PageDiagramLimits.validate([ordinary[0], ordinary[1], invalid]))
        let v4 = PageClipboardPayload.pasteboardType, v5 = PageClipboardPayload.styledDiagramPasteboardType
        XCTAssertEqual(v5, "io.inotes.page-selection.v5")
        XCTAssertEqual(PageClipboardPayload.readablePasteboardTypes, [v5, v4, PageClipboardPayload.imagePasteboardType, PageClipboardPayload.legacyPasteboardType])
        XCTAssertEqual(PageClipboardPayload(diagrams: ordinary).writablePasteboardTypes, [v4])
        for styled in [[ordinary[0], table, ordinary[2]], [ordinary[0], ordinary[1], arrow],
                       [ordinary[0], ordinary[1], floating], [ordinary[0], table, arrow]] {
            var library = NoteLibrary.sample()
            var page = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
            page.diagrams = styled
            try library.update(page)
            XCTAssertEqual(library.formatVersion, 5)
            XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: library.nodes, formatVersion: 4)))
            let loaded = try LibraryArchive.decode(LibraryArchive.encode(library))
            XCTAssertEqual(loaded.node(id: page.id)?.pageContent, page.pageContent)
            let copy = try library.duplicate(id: page.id)
            XCTAssertEqual(library.node(id: copy)?.diagrams, styled)
            var imported = NoteLibrary()
            _ = try imported.merge(loaded)
            XCTAssertEqual(imported.formatVersion, 5)
            XCTAssertEqual(imported.nodes.first { $0.kind == .sheet }?.diagrams, styled)
            let clipboard = PageClipboardPayload(diagrams: styled)
            XCTAssertEqual(clipboard.writablePasteboardTypes, [v5])
            XCTAssertEqual(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(clipboard)), clipboard)
            page.diagrams = ordinary
            try library.update(page)
            try library.trash(id: copy)
            library.emptyTrash()
            XCTAssertEqual(library.formatVersion, 5)
        }
    }

    func testInvalidCustomTableSizesAndArrowStylesRejectAtomically() throws {
        let base = NoteLibrary.sample(), original = try XCTUnwrap(base.nodes.first { $0.kind == .sheet })
        let table = PageDiagram(kind: .table, rows: 2, columns: 2)
        var invalid: [PageDiagram] = []
        for sizes in [[], [0.5], [0, 1], [-0.2, 1.2], [0.2, 0.2], [.nan, 0.5], [.infinity, 0.5], [1e-300, 1]] {
            var candidate = table
            candidate.rowFractions = sizes
            invalid.append(candidate)
            candidate = table
            candidate.columnFractions = sizes
            invalid.append(candidate)
        }
        var sizedShape = PageDiagram()
        sizedShape.rowFractions = [1]
        invalid.append(sizedShape)
        invalid.append(PageDiagram(kind: .rectangle, openArrowheads: true))
        invalid.append(PageDiagram(kind: .connector, openArrowheads: false))
        for object in invalid {
            var page = original, library = base
            page.diagrams = [object]
            XCTAssertThrowsError(try library.update(page))
            XCTAssertEqual(library, base)
            XCTAssertThrowsError(try PageClipboardPayload(diagrams: [object]).validatePageContent())
        }
        var oversized = table
        oversized.columnFractions = Array(repeating: 0.01, count: 100)
        let data = try JSONEncoder().encode(oversized)
        XCTAssertThrowsError(try JSONDecoder().decode(PageDiagram.self, from: data))
        var unsafeCounts = table
        unsafeCounts.rows = Int.max
        XCTAssertEqual(PageTableGeometry.edges(in: unsafeCounts, axis: .row), [])
        XCTAssertEqual(PageTableGeometry.cellRect(2, in: unsafeCounts), .zero)
    }

    func testExternalArrowReferencesUsePageScopedKindsAndPersistAtomically() throws {
        let shared = UUID()
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="))
        let image = PageImage(id: shared, x: 100, y: 50, width: 80, height: 60, imageData: png)
        let box = PageTextBox(id: shared, x: 300, y: 100, width: 100, text: "Caption")
        let equation = NoteEquation(id: shared, x: 500, y: 200, width: 140, height: 80)
        let shape = PageDiagram(id: shared)
        let arrow = PageDiagram(kind: .connector, startAttachment: .init(targetDiagramID: shared, side: .right, targetKind: .image),
            endAttachment: .init(targetDiagramID: shared, side: .bottom, targetKind: .textBox))
        let second = PageDiagram(kind: .connector, endAttachment: .init(targetDiagramID: shared, side: .top, targetKind: .equation))
        let diagrams = [shape, arrow, second]
        let frames = PageDiagramGeometry.externalAnchorFrames(images: [image], textBoxes: [box], equations: [equation],
            textBoxHeight: { $0 == shared ? 64 : nil })
        let projected = PageDiagramGeometry.projectingExternalEndpoints(in: diagrams, frames: frames)
        XCTAssertEqual(projected[1].start, InkPoint(x: 180, y: 80))
        XCTAssertEqual(projected[1].end, InkPoint(x: 350, y: 164))
        XCTAssertEqual(projected[2].end, InkPoint(x: 570, y: 200))
        XCTAssertEqual(PageDiagramGeometry.resolvedEndpoints(for: projected[1], in: projected).start, projected[1].start)
        XCTAssertEqual(PageDiagramGeometry.projectingExternalEndpoints(in: projected, frames: [:]), projected)
        let clipboard = PageClipboardPayload(textBoxes: [box], equations: [equation], images: [image], diagrams: projected)
        XCTAssertEqual(clipboard.writablePasteboardTypes, [PageClipboardPayload.styledDiagramPasteboardType])
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(clipboard)), clipboard)
        var library = NoteLibrary.sample()
        var page = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
        page.pageContent = PageContent(textBoxes: [box], equations: [equation], images: [image], diagrams: projected)
        try library.update(page)
        let before = library
        XCTAssertEqual(library.formatVersion, 5)
        XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: library.nodes, formatVersion: 4)))
        XCTAssertEqual(try LibraryArchive.decode(LibraryArchive.encode(library)).node(id: page.id)?.pageContent, page.pageContent)
        for kind in [PageObjectAnchorKind.image, .textBox, .equation] {
            var stripped = page, badClipboard = clipboard
            switch kind {
            case .image: stripped.images = []; badClipboard.images = []
            case .textBox: stripped.textBoxes = []; badClipboard.textBoxes = []
            case .equation: stripped.equations = []; badClipboard.equations = []
            }
            XCTAssertThrowsError(try library.update(stripped))
            XCTAssertEqual(library, before)
            XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(badClipboard)))
        }
    }

    func testExternalArrowMoveDeletionAndCopyRetainOnlySelectedTypedTargets() throws {
        let shared = UUID(), shape = PageDiagram(id: shared)
        let arrow = PageDiagram(kind: .connector, start: InkPoint(x: 50, y: 60), end: InkPoint(x: 400, y: 200),
            startAttachment: .init(targetDiagramID: shared, side: .right, targetKind: .image),
            endAttachment: .init(targetDiagramID: shared, side: .left, targetKind: .equation))
        let diagrams = [shape, arrow]
        let moved = PageDiagramGeometry.translated(diagrams, selectedIDs: [], dx: 20, dy: 10,
            selectedObjectIDs: [.image: [shared]])
        XCTAssertEqual(moved[1].start, InkPoint(x: 70, y: 70))
        XCTAssertEqual(moved[1].end, arrow.end)
        XCTAssertEqual(moved[1].startAttachment, arrow.startAttachment)
        let group = PageDiagramGeometry.translated(diagrams, selectedIDs: [arrow.id, shape.id], dx: 20, dy: 10,
            selectedObjectIDs: [.image: [shared]])
        XCTAssertEqual(group[1].startAttachment, arrow.startAttachment)
        XCTAssertNil(group[1].endAttachment)
        XCTAssertEqual(group[1].end, InkPoint(x: 420, y: 210))
        let removed = PageDiagramGeometry.removing(ids: [shape.id], from: diagrams, objectIDs: [.equation: [shared]])
        XCTAssertEqual(removed[0].startAttachment, arrow.startAttachment)
        XCTAssertNil(removed[0].endAttachment)
        XCTAssertEqual(removed[0].end, arrow.end)
        let arrowCopy = UUID(), imageCopy = UUID(), equationCopy = UUID()
        let mapping = [arrow.id: arrowCopy, shape.id: UUID()]
        let both = PageDiagramGeometry.remapped(diagrams, mapping: mapping, dx: 20, dy: 10,
            objectMappings: [.image: [shared: imageCopy], .equation: [shared: equationCopy]])
        XCTAssertEqual(both[1].startAttachment, .init(targetDiagramID: imageCopy, side: .right, targetKind: .image))
        XCTAssertEqual(both[1].endAttachment, .init(targetDiagramID: equationCopy, side: .left, targetKind: .equation))
        let preview = PageDiagramGeometry.projectingExternalEndpoints(in: diagrams,
            frames: [.image: [shared: CGRect(x: 400, y: 400, width: 200, height: 100)]])
        let partial = PageDiagramGeometry.remapped([arrow], mapping: [arrow.id: arrowCopy], resolvingIn: preview,
            objectMappings: [.equation: [shared: equationCopy]])
        XCTAssertNil(partial[0].startAttachment)
        XCTAssertEqual(partial[0].start, InkPoint(x: 600, y: 450))
        XCTAssertEqual(partial[0].endAttachment?.targetDiagramID, equationCopy)
    }

    func testAutomaticConnectorFacesMovingAndResizedTargetsInEveryDirection() throws {
        let source = PageDiagram(x: 300, y: 300, width: 100, height: 100)
        var dest = PageDiagram(kind: .table, x: 600, y: 300, width: 100, height: 100)
        let arrow = PageDiagram(kind: .connector, startAttachment: .init(targetDiagramID: source.id, side: .right, followsTarget: true),
            endAttachment: .init(targetDiagramID: dest.id, side: .left, followsTarget: true), route: .elbow)
        let cases: [(Double, Double, PageDiagram.AnchorSide, PageDiagram.AnchorSide)] = [
            (600, 300, .right, .left), (0, 300, .left, .right), (300, 0, .top, .bottom), (300, 600, .bottom, .top)
        ]
        for (x, y, startSide, endSide) in cases {
            dest.x = x; dest.y = y
            let values = [source, dest, arrow]
            let routed = PageDiagramGeometry.routedConnectors(in: values, movedDiagramIDs: [dest.id])
            XCTAssertEqual(routed[2].startAttachment?.side, startSide)
            XCTAssertEqual(routed[2].endAttachment?.side, endSide)
            let start = PageDiagramGeometry.anchorPoint(on: source, side: startSide)
            let end = PageDiagramGeometry.anchorPoint(on: dest, side: endSide)
            XCTAssertEqual(PageDiagramGeometry.connectorPoints(for: arrow, in: values), [start, end])
            XCTAssertEqual(routed[2].start, start)
            XCTAssertEqual(routed[2].end, end)
            let middle = InkPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            XCTAssertTrue(PageDiagramGeometry.hitTest(arrow, at: middle, in: values))
            XCTAssertTrue(PageDiagramGeometry.bounds(of: arrow, in: values).contains(CGPoint(x: middle.x, y: middle.y)))
        }
        // Horizontal and vertical free space differ by two points. Preserve
        // the authored axis during small diagonal pointer movements.
        dest.x = 600; dest.y = 602
        var values = [source, dest, arrow]
        XCTAssertEqual(PageDiagramGeometry.routedConnectors(in: values)[2].startAttachment?.side, .right)
        values[0].width = 180
        let resized = PageDiagramGeometry.routedConnectors(in: values)
        XCTAssertEqual(resized[2].startAttachment?.side, .bottom)
        XCTAssertEqual(resized[2].start, InkPoint(x: 390, y: 400))
        var same = arrow
        same.endAttachment?.targetDiagramID = source.id
        let loop = PageDiagramGeometry.routedConnectors(in: [source, same])
        XCTAssertEqual(loop[1].startAttachment, same.startAttachment)
        XCTAssertEqual(loop[1].endAttachment, same.endAttachment)
        let path = PageDiagramGeometry.connectorPoints(for: loop[1], in: loop)
        XCTAssertTrue(path.count > 3)
        XCTAssertTrue(path.dropFirst().first!.x > path.first!.x && path.dropLast().last!.x < path.last!.x)
        XCTAssertFalse(PageDiagramGeometry.hitTest(loop[1], at: InkPoint(x: 350, y: 350), in: loop))
    }

    func testAutomaticConnectorProjectionScopesTypedTargetsPinsAndFreeEnds() throws {
        let source = PageDiagram(x: 300, y: 300, width: 100, height: 100)
        let target = UUID(), other = UUID()
        let auto = PageDiagram(kind: .connector, startAttachment: .init(targetDiagramID: source.id, side: .bottom, followsTarget: true),
            endAttachment: .init(targetDiagramID: target, side: .top, targetKind: .textBox, followsTarget: true), route: .elbow)
        var pinned = auto
        pinned.id = UUID()
        pinned.startAttachment?.side = .left
        pinned.startAttachment?.followsTarget = nil
        let unrelated = PageDiagram(kind: .connector, endAttachment: .init(targetDiagramID: other, side: .left, targetKind: .image))
        let frames: [PageObjectAnchorKind: [UUID: CGRect]] = [.textBox: [target: CGRect(x: 550, y: 320, width: 170, height: 40)],
                                                               .image: [other: CGRect(x: 110, y: 20, width: 30, height: 30)]]
        let ordered = [source, auto, pinned, unrelated]
        let routed = PageDiagramGeometry.routedConnectors(in: ordered, frames: frames, movedDiagramIDs: [], movedObjectIDs: [.textBox: [target]])
        XCTAssertEqual(routed[3], unrelated)
        XCTAssertEqual(routed[1].startAttachment?.side, .right)
        XCTAssertEqual(routed[1].endAttachment?.side, .left)
        XCTAssertEqual(routed[1].end, InkPoint(x: 550, y: 340))
        XCTAssertEqual(PageDiagramGeometry.resolvedEndpoints(for: routed[1], in: routed).start, routed[1].start)
        XCTAssertEqual(PageDiagramGeometry.routedConnectors(in: routed, frames: [:]), routed)
        XCTAssertEqual(routed[2].startAttachment, pinned.startAttachment)
        let elbow = PageDiagramGeometry.connectorPoints(for: routed[2], in: routed)
        XCTAssertLessThan(elbow[1].x, elbow[0].x)
        XCTAssertFalse(PageDiagramGeometry.hitTest(routed[2], at: InkPoint(x: 350, y: 350), in: routed))
        let removed = PageDiagramGeometry.removing(ids: [], from: ordered, objectIDs: [.textBox: [target]], frames: frames)
        XCTAssertNil(removed[1].endAttachment)
        XCTAssertEqual(removed[1].end, routed[1].end)
        XCTAssertEqual(removed[1].startAttachment?.followsTarget, true)
        XCTAssertEqual(removed[3], unrelated)
        var selected = auto
        selected.text = "Selected label"
        let copied = PageDiagramGeometry.remapped([source, selected], mapping: [source.id: UUID(), auto.id: UUID()], dx: 10,
            resolvingIn: ordered, sourceFrames: frames)
        XCTAssertEqual(copied[1].text, selected.text)
        XCTAssertNil(copied[1].endAttachment)
        XCTAssertEqual(copied[1].end, InkPoint(x: 560, y: 340))
        XCTAssertEqual(copied[1].startAttachment?.targetDiagramID, copied[0].id)
        XCTAssertEqual(copied[1].startAttachment?.followsTarget, true)
        let free = PageDiagramGeometry.translated(removed, selectedIDs: [source.id], dx: 0, dy: 500)
        XCTAssertEqual(free[1].end, removed[1].end)
        XCTAssertEqual(free[1].startAttachment?.side, .top)
    }
}
