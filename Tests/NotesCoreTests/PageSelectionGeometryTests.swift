import Foundation
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
import CoreGraphics
@testable import NotesCore

final class PageSelectionGeometryTests: XCTestCase {
    let square = PageSelectionGeometry.rectangle(from: InkPoint(x: 20, y: 20), to: InkPoint(x: 80, y: 80))

    func testCrossingStrokeSelectsEvenWhenBothEndpointsOutside() {
        let stroke = InkStroke(points: [InkPoint(x: 0, y: 50), InkPoint(x: 100, y: 50)])
        XCTAssertTrue(PageSelectionGeometry.intersects(stroke: stroke, polygon: square))
        XCTAssertFalse(PageSelectionGeometry.intersects(stroke: stroke, polygon: square.map { InkPoint(x: $0.x, y: $0.y + 100) }))
    }

    func testBoundaryAndThickInkAndDotsAreSelectable() {
        XCTAssertTrue(PageSelectionGeometry.contains(InkPoint(x: 20, y: 50), polygon: square))
        XCTAssertTrue(PageSelectionGeometry.intersects(stroke: InkStroke(points: [InkPoint(x: 16, y: 50)], width: 10), polygon: square))
        XCTAssertTrue(PageSelectionGeometry.hits(stroke: InkStroke(points: [InkPoint(x: 10, y: 10)], width: 3), at: InkPoint(x: 13, y: 10)))
    }

    func testTextRectangleCanEncloseLassoAndLassoCanEncloseText() {
        XCTAssertTrue(PageSelectionGeometry.intersects(rect: CGRect(x: 0, y: 0, width: 100, height: 100), polygon: square))
        XCTAssertTrue(PageSelectionGeometry.intersects(rect: CGRect(x: 30, y: 30, width: 10, height: 10), polygon: square))
        XCTAssertFalse(PageSelectionGeometry.intersects(rect: CGRect(x: 90, y: 90, width: 10, height: 10), polygon: square))
    }

    func testConcaveAndInvalidPolygons() {
        let concave = [InkPoint(x: 0, y: 0),InkPoint(x: 100, y: 0),InkPoint(x: 100, y: 20),InkPoint(x: 20, y: 20),InkPoint(x: 20, y: 100),InkPoint(x: 0, y: 100)]
        XCTAssertTrue(PageSelectionGeometry.contains(InkPoint(x: 10, y: 70), polygon: concave))
        XCTAssertFalse(PageSelectionGeometry.contains(InkPoint(x: 70, y: 70), polygon: concave))
        XCTAssertFalse(PageSelectionGeometry.contains(InkPoint(x: 10, y: 10), polygon: [InkPoint(x: .infinity, y: 0),InkPoint(x: 0, y: 0),InkPoint(x: 50, y: 50)]))
        XCTAssertFalse(PageSelectionGeometry.intersects(stroke: InkStroke(points: []), polygon: square))
    }

    func testTranslationPreservesIdentityStylePressureAndCanonicalColor() {
        let stroke = InkStroke(points: [InkPoint(x: 5, y: 7, pressure: 0.42)], colorHex: "#102040", width: 4, style: .pencil)
        let moved = PageSelectionGeometry.translated(stroke, dx: 30, dy: -2)
        XCTAssertEqual(moved.id,stroke.id); XCTAssertEqual(moved.colorHex,stroke.colorHex)
        XCTAssertEqual(moved.width,stroke.width); XCTAssertEqual(moved.style,stroke.style)
        XCTAssertEqual(moved.points,[InkPoint(x:35,y:5,pressure:0.42)])
        XCTAssertEqual(PageSelectionGeometry.translated(stroke,dx:.infinity,dy:0),stroke)
    }
}
