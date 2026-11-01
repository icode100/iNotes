#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
import Foundation
@testable import NotesCore

final class PagePresentationTests: XCTestCase {
    func testLegacyArchivesDefaultToSolidLinesWithoutTemplates() throws {
        var library = NoteLibrary.sample()
        var sheet = library.nodes.first { $0.kind == .sheet }!
        sheet.strokes = [InkStroke(points: [InkPoint(x: 10, y: 20), InkPoint(x: 50, y: 20)])]
        try library.update(sheet)
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryArchive.encode(library)) as? [String: Any])
        var nodes = try XCTUnwrap(archive["nodes"] as? [[String: Any]])
        for index in nodes.indices {
            nodes[index].removeValue(forKey: "pageTemplate")
            nodes[index].removeValue(forKey: "templateLinePattern")
            var strokes = try XCTUnwrap(nodes[index]["strokes"] as? [[String: Any]])
            for strokeIndex in strokes.indices { strokes[strokeIndex].removeValue(forKey: "linePattern") }
            nodes[index]["strokes"] = strokes
        }
        archive["nodes"] = nodes
        for version in [1, 2] {
            archive["formatVersion"] = version
            let reopened = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: archive))
            XCTAssertEqual(reopened.formatVersion, version)
            XCTAssertTrue(reopened.nodes.allSatisfy { $0.pageTemplate == .none && $0.templateLinePattern == .solid })
            XCTAssertEqual(reopened.node(id: sheet.id)?.strokes.first?.linePattern, .solid)
            XCTAssertEqual(reopened.node(id: sheet.id)?.strokes.first?.points, sheet.strokes.first?.points)
        }
    }

    func testLineAndTemplateChoicesSurviveSaveImportAndDuplicate() throws {
        var library = NoteLibrary.sample()
        var sheet = library.nodes.first { $0.kind == .sheet }!
        sheet.strokes = LinePattern.allCases.map {
            InkStroke(points: [InkPoint(x: 12, y: 32), InkPoint(x: 180, y: 32)], width: 4, linePattern: $0)
        }
        for paper in PaperStyle.allCases {
            for template in PageTemplate.allCases {
                for pattern in LinePattern.allCases {
                    sheet.paperStyle = paper; sheet.pageTemplate = template; sheet.templateLinePattern = pattern
                    try library.update(sheet)
                    let restored = try LibraryArchive.decode(LibraryArchive.encode(library)).node(id: sheet.id)!
                    XCTAssertEqual(restored.paperStyle, paper)
                    XCTAssertEqual(restored.pageTemplate, template)
                    XCTAssertEqual(restored.templateLinePattern, pattern)
                    XCTAssertEqual(restored.strokes, sheet.strokes)
                }
            }
        }
        let copyID = try library.duplicate(id: sheet.id)
        let copied = library.node(id: copyID)!
        XCTAssertEqual(copied.pageTemplate, sheet.pageTemplate)
        XCTAssertEqual(copied.templateLinePattern, sheet.templateLinePattern)
        XCTAssertEqual(copied.strokes, sheet.strokes)
        var destination = NoteLibrary()
        _ = try destination.merge(library)
        let imported = destination.nodes.first { $0.title == sheet.title && $0.kind == .sheet }!
        XCTAssertNotEqual(imported.id, sheet.id)
        XCTAssertEqual(imported.pageTemplate, sheet.pageTemplate)
        XCTAssertEqual(imported.templateLinePattern, sheet.templateLinePattern)
        XCTAssertEqual(imported.strokes, sheet.strokes)
    }

    func testPatternSurvivesClipboardAndSelectionTranslation() throws {
        for pattern in LinePattern.allCases {
            let stroke = InkStroke(points: [InkPoint(x: 4, y: 8), InkPoint(x: 80, y: 8)], linePattern: pattern)
            let payload = PageClipboardPayload(strokes: [stroke])
            let copied = try PageClipboardPayload.decodeValidated(JSONEncoder().encode(payload))
            XCTAssertEqual(copied.strokes, [stroke])
            let moved = PageSelectionGeometry.translated(copied.strokes[0], dx: 20, dy: 30)
            XCTAssertEqual(moved.linePattern, pattern)
            XCTAssertEqual(moved.points.map(\.x), [24, 100])
            XCTAssertEqual(moved.points.map(\.y), [38, 38])
        }
    }

    func testTemplateCompatibilityAndDashLengthsAreBounded() {
        for paper in PaperStyle.allCases {
            XCTAssertTrue(PageTemplate.none.isSupported(on: paper))
            XCTAssertTrue(PageTemplate.centerDivider.isSupported(on: paper))
            XCTAssertEqual(PageTemplate.centerDivider.effective(on: paper), .centerDivider)
            let allowsMargin = paper == .blank || paper == .ruled
            XCTAssertEqual(PageTemplate.leftMargin.isSupported(on: paper), allowsMargin)
            XCTAssertEqual(PageTemplate.leftMargin.effective(on: paper), allowsMargin ? .leftMargin : .none)
        }
        XCTAssertEqual(LinePattern.solid.dashLengths(width: 3), [])
        XCTAssertEqual(LinePattern.dashed.dashLengths(width: 2), [12, 6])
        XCTAssertTrue(LinePattern.dotted.dashLengths(width: 4)[1] > LinePattern.dotted.dashLengths(width: 2)[1])
        for pattern in LinePattern.allCases {
            for width in [Double.nan, .infinity, -.infinity, -1, 0, 100_000] {
                XCTAssertTrue(pattern.dashLengths(width: width).allSatisfy { $0.isFinite && $0 > 0 && $0 <= 600 })
            }
        }
    }
}
