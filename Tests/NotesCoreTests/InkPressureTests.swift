#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
import Foundation
@testable import NotesCore

final class InkPressureTests: XCTestCase {
    func testDeviceForceNormalizesAcrossItsActualRange() {
        XCTAssertEqual(InkPressure.normalized(force: 0), 0)
        XCTAssertEqual(InkPressure.normalized(force: 0.25), 0.25)
        XCTAssertEqual(InkPressure.normalized(force: 1), 1)
        XCTAssertEqual(InkPressure.normalized(force: 1, maximum: 4), 0.25)
        XCTAssertEqual(InkPressure.normalized(force: 4, maximum: 4), 1)
        XCTAssertEqual(InkPressure.normalized(force: -1, maximum: 4), 0)
        XCTAssertEqual(InkPressure.normalized(force: 12, maximum: 4), 1)
        XCTAssertEqual(InkPressure.normalized(force: Double.greatestFiniteMagnitude,
                                               maximum: Double.leastNonzeroMagnitude), 1)
    }

    func testMouseAndUnavailableForceRemainAtTheSelectedBase() {
        for force in [0.0, 0.25, 1, 16_384, -1, .nan, .infinity, -.infinity] {
            let pressure = InkPressure.normalized(force: force, isStylus: false)
            XCTAssertEqual(pressure, 0)
            XCTAssertEqual(InkPressure.widthMultiplier(pressure, response: .baseWidth), 1)
        }
        for force in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(InkPressure.normalized(force: force), 0)
            XCTAssertEqual(InkPressure.widthMultiplier(force, response: .baseWidth), 1)
        }
        for maximum in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertEqual(InkPressure.normalized(force: 0.5, maximum: maximum), 0)
        }
        XCTAssertEqual(InkPressure.widthMultiplier(-1, response: .baseWidth), 1)
        XCTAssertEqual(InkPressure.widthMultiplier(2, response: .baseWidth), 2)
    }

    func testNearbyPressureValuesRemainContinuousWithoutHardwareLevelQuantization() {
        let step = 1.0 / 16_384
        let values = [0.0, step, 0.5, 0.5 + step / 4, 0.5 + step, 1.0]
        var previousPressure = -1.0
        var previousWidth = 0.0
        for value in values {
            let pressure = InkPressure.normalized(force: value)
            let width = InkPressure.widthMultiplier(pressure, response: .baseWidth)
            XCTAssertEqual(pressure, value)
            XCTAssertEqual(width, 1 + value)
            XCTAssertLessThan(previousPressure, pressure)
            XCTAssertLessThan(previousWidth, width)
            previousPressure = pressure
            previousWidth = width
        }
        // A device reporting a different maximum must retain fractional samples,
        // too: the advertised count of pressure levels is not a rounding rule.
        XCTAssertEqual(InkPressure.normalized(force: 8_192.25, maximum: 16_384), 0.5 + step / 4)
    }

    func testEveryNewNibUsesChosenWidthAsAMinimumAndPressureOnlyThickens() {
        for style in InkStyle.allCases {
            for chosenWidth in [0.5, 1.5, 3, 6, 30, 100] {
                let points = [0.0, 1.0 / 16_384, 0.25, 0.5, 1].map {
                    InkPoint(x: $0 * 100, y: 30, pressure: $0)
                }
                let stroke = InkStroke(points: points, width: chosenWidth, style: style, pressureResponse: .baseWidth)
                XCTAssertTrue(stroke.baseRenderedWidth >= chosenWidth)
                XCTAssertEqual(stroke.renderedWidth(at: points[0]), stroke.baseRenderedWidth)
                var previous = stroke.baseRenderedWidth
                for point in points {
                    let width = stroke.renderedWidth(at: point)
                    XCTAssertTrue(width >= chosenWidth)
                    XCTAssertTrue(width >= previous)
                    XCTAssertTrue(width <= stroke.baseRenderedWidth * 2)
                    previous = width
                }
                XCTAssertEqual(stroke.renderedWidth(at: points.last!), stroke.baseRenderedWidth * 2)
                XCTAssertEqual(stroke.maximumRenderedWidth, stroke.baseRenderedWidth * 2)
            }
        }
    }

    func testLegacyJSONWithoutPressureFieldsKeepsItsOriginalAppearance() throws {
        let data = Data("""
        {"id":"EAE32E4A-4B8C-4DBB-AD37-51E9C228EE60","points":[
          {"x":10,"y":20,"pressure":0},{"x":50,"y":20,"pressure":0.5},
          {"x":90,"y":20,"pressure":1}],"colorHex":"#202020","width":5,"style":"pencil"}
        """.utf8)
        let stroke = try JSONDecoder().decode(InkStroke.self, from: data)
        XCTAssertEqual(stroke.pressureResponse, .legacy)
        XCTAssertEqual(stroke.linePattern, .solid)
        XCTAssertTrue(stroke.points.allSatisfy { $0.renderedWidth == nil })
        XCTAssertEqual(stroke.baseRenderedWidth, 4)
        XCTAssertEqual(stroke.renderedWidth(at: stroke.points[0]), 1.4, accuracy: 0.0000001)
        XCTAssertEqual(stroke.renderedWidth(at: stroke.points[1]), 2.7, accuracy: 0.0000001)
        XCTAssertEqual(stroke.renderedWidth(at: stroke.points[2]), 4)
        XCTAssertEqual(InkStroke(points: [InkPoint(x: 0, y: 0)]).pressureResponse, .legacy)
    }

    func testLegacyArchiveMissingNewFieldsPreservesEveryToolWidth() throws {
        var library = NoteLibrary.sample()
        var sheet = library.nodes.first { $0.kind == .sheet }!
        sheet.strokes = InkStyle.allCases.map { style in
            InkStroke(points: [InkPoint(x: 10, y: 20, pressure: 0.25), InkPoint(x: 90, y: 20, pressure: 1)],
                      width: 6, style: style)
        }
        try library.update(sheet)
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryArchive.encode(library)) as? [String: Any])
        var nodes = try XCTUnwrap(archive["nodes"] as? [[String: Any]])
        for nodeIndex in nodes.indices {
            var strokes = try XCTUnwrap(nodes[nodeIndex]["strokes"] as? [[String: Any]])
            for index in strokes.indices {
                strokes[index].removeValue(forKey: "pressureResponse")
                var points = try XCTUnwrap(strokes[index]["points"] as? [[String: Any]])
                for pointIndex in points.indices { points[pointIndex].removeValue(forKey: "renderedWidth") }
                strokes[index]["points"] = points
            }
            nodes[nodeIndex]["strokes"] = strokes
        }
        archive["nodes"] = nodes
        for version in [1, 2] {
            archive["formatVersion"] = version
            let reopened = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: archive))
            let restored = try XCTUnwrap(reopened.node(id: sheet.id))
            XCTAssertEqual(restored.strokes, sheet.strokes)
            for stroke in restored.strokes {
                XCTAssertEqual(stroke.renderedWidth(at: stroke.points[0]),
                               6 * stroke.style.widthMultiplier * (0.35 + 0.65 * 0.25), accuracy: 0.0000001)
                XCTAssertEqual(stroke.renderedWidth(at: stroke.points[1]), 6 * stroke.style.widthMultiplier)
            }
        }
    }

    func testNewPressureAndNativeRenderedWidthsRoundTripThroughArchiveAndClipboard() throws {
        let strokes = [
            InkStroke(points: [InkPoint(x: 10, y: 30, pressure: 0), InkPoint(x: 40, y: 30, pressure: 0.25),
                               InkPoint(x: 90, y: 30, pressure: 1)], width: 4, pressureResponse: .baseWidth),
            InkStroke(points: [InkPoint(x: 10, y: 60, pressure: 0, renderedWidth: 2.3),
                               InkPoint(x: 90, y: 60, pressure: 0, renderedWidth: 7.1)], width: 5, style: .pencil)
        ]
        var library = NoteLibrary.sample()
        var sheet = library.nodes.first { $0.kind == .sheet }!
        sheet.strokes = strokes
        try library.update(sheet)
        let restored = try XCTUnwrap(LibraryArchive.decode(LibraryArchive.encode(library)).node(id: sheet.id))
        XCTAssertEqual(restored.strokes, strokes)
        XCTAssertEqual(restored.strokes[0].renderedWidth(at: restored.strokes[0].points[1]), 5)
        XCTAssertEqual(restored.strokes[1].renderedWidth(at: restored.strokes[1].points[0]), 2.3)
        XCTAssertEqual(restored.strokes[1].maximumRenderedWidth, 7.1)
        let payload = PageClipboardPayload(strokes: strokes)
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(payload)), payload)
    }

    func testValidNativeRenderedWidthBoundariesArePreserved() throws {
        for width in [0.001, 0.5, 400, 1_000] {
            let point = InkPoint(x: 20, y: 40, pressure: 0.5, renderedWidth: width)
            let stroke = InkStroke(points: [point], width: 3)
            try InkGeometryLimits.validate([stroke])
            XCTAssertEqual(stroke.renderedWidth(at: point), width)
            XCTAssertEqual(try JSONDecoder().decode(InkStroke.self, from: JSONEncoder().encode(stroke)), stroke)
        }
    }

    func testInvalidNativeRenderedWidthsRejectBeforeMutationOrImport() throws {
        for width in [Double.nan, .infinity, -.infinity, 0, -1, 1_001] {
            let stroke = InkStroke(points: [InkPoint(x: 10, y: 20, renderedWidth: width)])
            XCTAssertThrowsError(try InkGeometryLimits.validate([stroke]))
            var library = NoteLibrary.sample()
            var sheet = library.nodes.first { $0.kind == .sheet }!
            let previous = library
            sheet.strokes = [stroke]
            XCTAssertThrowsError(try library.update(sheet))
            XCTAssertEqual(library, previous)
            // Nonfinite JSON numbers are rejected by JSONEncoder itself. The
            // finite cases also exercise the actual archive/clipboard validators.
            if width.isFinite {
                let unvalidated = NoteLibrary(nodes: library.nodes.map { $0.id == sheet.id ? sheet : $0 })
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                XCTAssertThrowsError(try LibraryArchive.decode(encoder.encode(unvalidated)))
                XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(PageClipboardPayload(strokes: [stroke]))))
            }
        }
    }

    func testSelectionTranslationPreservesPressureResponseAndNativeWidths() {
        let stroke = InkStroke(points: [InkPoint(x: 10, y: 20, pressure: 0.125, renderedWidth: 3.5),
                                         InkPoint(x: 30, y: 50, pressure: 0.875, renderedWidth: 8.5)],
                               colorHex: "#123456", width: 5, style: .pencil, linePattern: .dashed, pressureResponse: .baseWidth)
        let translated = PageSelectionGeometry.translated(stroke, dx: 40, dy: -10)
        var expected = stroke
        expected.points[0].x = 50; expected.points[0].y = 10
        expected.points[1].x = 70; expected.points[1].y = 40
        XCTAssertEqual(translated, expected)
        XCTAssertEqual(translated.renderedWidth(at: translated.points[0]), 3.5)
        XCTAssertEqual(translated.renderedWidth(at: translated.points[1]), 8.5)
    }

    func testSelectionHitsVisiblePressureAndNativeWidthEdges() {
        let pressureStroke = InkStroke(points: [InkPoint(x: 20, y: 20, pressure: 1), InkPoint(x: 80, y: 20, pressure: 1)],
                                       width: 10, pressureResponse: .baseWidth)
        let nativeStroke = InkStroke(points: [InkPoint(x: 20, y: 50, renderedWidth: 30),
                                              InkPoint(x: 80, y: 50, renderedWidth: 30)], width: 2)
        for (stroke, edgeY, outsideY) in [(pressureStroke, 29.0, 31.0), (nativeStroke, 64.0, 66.0)] {
            XCTAssertTrue(PageSelectionGeometry.hits(stroke: stroke, at: InkPoint(x: 50, y: edgeY), tolerance: 0))
            XCTAssertFalse(PageSelectionGeometry.hits(stroke: stroke, at: InkPoint(x: 50, y: outsideY), tolerance: 0))
            let lasso = PageSelectionGeometry.rectangle(from: InkPoint(x: 45, y: edgeY), to: InkPoint(x: 55, y: edgeY + 0.5))
            XCTAssertTrue(PageSelectionGeometry.intersects(stroke: stroke, polygon: lasso))
        }
    }
}
