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
