#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
import Foundation
@testable import NotesCore

final class InkValidationTests: XCTestCase {
    func testEmptyStrokeRejectedThroughArchiveAndClipboardBeforeEditing() throws {
        let stroke = InkStroke(points: [])
        XCTAssertThrowsError(try InkGeometryLimits.validate([stroke]))
        XCTAssertThrowsError(try LibraryArchive.decode(unvalidatedArchive(strokes: [stroke])))
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(PageClipboardPayload(strokes: [stroke]))))
        var library = NoteLibrary.sample()
        var sheet = library.nodes.first { $0.kind == .sheet }!
        let previous = library
        sheet.strokes = [stroke]
        XCTAssertThrowsError(try library.update(sheet))
        XCTAssertEqual(library, previous)
    }

    func testExtremeFiniteCoordinatesRejectedAtEveryPortableBoundary() throws {
        for point in [InkPoint(x: 0, y: 1e12), InkPoint(x: -1e12, y: 0),
                      InkPoint(x: 100_001, y: 1), InkPoint(x: 1, y: -100_001)] {
            let strokes = [InkStroke(points: [point, InkPoint(x: point.x + 1, y: point.y + 1)])]
            XCTAssertThrowsError(try LibraryArchive.decode(unvalidatedArchive(strokes: strokes)))
            XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(PageClipboardPayload(strokes: strokes))))
            var library = NoteLibrary.sample()
            var sheet = library.nodes.first { $0.kind == .sheet }!
            sheet.strokes = strokes
            let previous = library
            XCTAssertThrowsError(try library.update(sheet))
            XCTAssertEqual(library, previous)
        }
    }

    func testInvalidWidthPressureAndNonfiniteGeometryAreRejected() {
        for point in [InkPoint(x: .nan, y: 0), InkPoint(x: 0, y: .infinity),
                      InkPoint(x: 0, y: 0, pressure: .nan), InkPoint(x: 0, y: 0, pressure: -0.1),
                      InkPoint(x: 0, y: 0, pressure: 1.1)] {
            XCTAssertThrowsError(try InkGeometryLimits.validate([InkStroke(points: [point])]))
        }
        for width in [Double.nan, .infinity, -.infinity, -1, 0, 101] {
            XCTAssertThrowsError(try InkGeometryLimits.validate([InkStroke(points: [InkPoint(x: 1, y: 1)], width: width)]))
        }
    }

    func testStrokeAndAggregatePointBudgets() throws {
        let dot = InkStroke(points: [InkPoint(x: 20, y: 30)])
        try InkGeometryLimits.validate(Array(repeating: dot, count: InkGeometryLimits.maximumStrokeCount))
        XCTAssertThrowsError(try InkGeometryLimits.validate(Array(repeating: dot, count: InkGeometryLimits.maximumStrokeCount + 1)))
        let halfBudget = Array(repeating: InkPoint(x: 20, y: 30), count: InkGeometryLimits.maximumPointCount / 2)
        let halfStroke = InkStroke(points: halfBudget)
        try InkGeometryLimits.validate([halfStroke, halfStroke])
        XCTAssertThrowsError(try InkGeometryLimits.validate([halfStroke, halfStroke, dot]))
    }

    func testEmptyPageOnePointDotsAndBoundaryCoordinatesStillRoundTrip() throws {
        try InkGeometryLimits.validate([])
        let limit = InkGeometryLimits.maximumCoordinate
        let strokes = [InkStroke(points: [InkPoint(x: 0, y: 0, pressure: 0)]),
                       InkStroke(points: [InkPoint(x: -limit, y: -limit), InkPoint(x: limit, y: limit)], width: 100, linePattern: .dashed)]
        let loaded = try LibraryArchive.decode(unvalidatedArchive(strokes: strokes))
        XCTAssertEqual(loaded.nodes.first { $0.kind == .sheet }?.strokes, strokes)
        let clipboard = PageClipboardPayload(strokes: strokes)
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(clipboard)), clipboard)
    }

    func testPatternAmplificationRejectedByArchiveClipboardAndAtomicUpdate() throws {
        // Fewer than 40 KiB of valid coordinates can request nearly a million
        // tiny dots; the old point-count and coordinate limits alone allowed it.
        let points = (0..<1_000).map { InkPoint(x: $0.isMultiple(of: 2) ? 100 : 1500, y: 100) }
        let stroke = InkStroke(points: points, width: 0.5, linePattern: .dotted)
        let archive = try unvalidatedArchive(strokes: [stroke])
        let clipboard = try JSONEncoder().encode(PageClipboardPayload(strokes: [stroke]))
        XCTAssertLessThan(archive.count, 40 * 1024)
        XCTAssertLessThan(clipboard.count, PageClipboardPayload.maximumBytes)
        XCTAssertThrowsError(try LibraryArchive.decode(archive))
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(clipboard))
        var library = NoteLibrary.sample()
        var sheet = library.nodes.first { $0.kind == .sheet }!
        let previous = library
        sheet.strokes = [stroke]
        XCTAssertThrowsError(try library.update(sheet))
        XCTAssertEqual(library, previous)
        // A longer adversarial path must stop during estimation, before a
        // renderer creates its 300,000-segment native path or dash expansion.
        let manyPoints = (0..<300_000).map { InkPoint(x: $0.isMultiple(of: 2) ? 100 : 1500, y: 100) }
        var remaining = InkGeometryLimits.maximumPatternSegments
        XCTAssertFalse(InkGeometryLimits.consumePatternBudget(for: InkStroke(points: manyPoints, width: 0.5, linePattern: .dotted), remaining: &remaining))
        XCTAssertTrue(remaining >= 0)
    }

    func testPatternBudgetCountsCurveOvershootAndTheWholePage() throws {
        // Equal endpoints in the middle segment still trace a cubic loop:
        // its neighboring control points extend beyond x=100. A chord-only
        // estimate would admit this path with a budget of 140.
        let loop = InkStroke(points: [InkPoint(x: 0, y: 100), InkPoint(x: 100, y: 100),
                                      InkPoint(x: 100, y: 100), InkPoint(x: 0, y: 100)], width: 0.5, linePattern: .dotted)
        var smallBudget = 140
        XCTAssertFalse(InkGeometryLimits.consumePatternBudget(for: loop, remaining: &smallBudget))
        let safeStroke = InkStroke(points: [InkPoint(x: 10, y: 30), InkPoint(x: 1010, y: 30)], width: 0.5, linePattern: .dotted)
        try InkGeometryLimits.validate([safeStroke])
        let excessivePage = Array(repeating: safeStroke, count: 200)
        XCTAssertThrowsError(try InkGeometryLimits.validate(excessivePage))
        XCTAssertThrowsError(try LibraryArchive.decode(unvalidatedArchive(strokes: excessivePage)))
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(PageClipboardPayload(strokes: excessivePage))))
    }

    func testOrdinaryPatternedTablesRemainAccepted() throws {
        var table: [InkStroke] = []
        for row in 0..<200 {
            table.append(InkStroke(points: [InkPoint(x: 80, y: Double(row * 28)), InkPoint(x: 1080, y: Double(row * 28))],
                                   width: 2.5, linePattern: row.isMultiple(of: 2) ? .dashed : .dotted))
        }
        table.append(InkStroke(points: [InkPoint(x: 80, y: 0), InkPoint(x: 80, y: 5600)], width: 2.5, linePattern: .solid))
        table.append(InkStroke(points: [InkPoint(x: 1080, y: 0), InkPoint(x: 1080, y: 5600)], width: 2.5, linePattern: .solid))
        let decoded = try LibraryArchive.decode(unvalidatedArchive(strokes: table))
        XCTAssertEqual(decoded.nodes.first { $0.kind == .sheet }?.strokes, table)
        let clipboard = PageClipboardPayload(strokes: table)
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(clipboard)), clipboard)
        var budget = InkGeometryLimits.maximumPatternSegments
        for stroke in table { XCTAssertTrue(InkGeometryLimits.consumePatternBudget(for: stroke, remaining: &budget)) }
        XCTAssertTrue(budget > 0)
    }

    /// Deliberately bypass the encoder's validator to model an external archive.
    private func unvalidatedArchive(strokes: [InkStroke]) throws -> Data {
        let nodes = NoteLibrary.sample().nodes.map { node -> NoteNode in
            var node = node
            if node.kind == .sheet { node.strokes = strokes }
            return node
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(NoteLibrary(nodes: nodes))
    }
}
