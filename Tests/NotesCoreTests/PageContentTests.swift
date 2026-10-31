#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
import Foundation
@testable import NotesCore

final class PageContentTests: XCTestCase {
    func testMixedPageArchiveRoundTripAndSearch() throws {
        var library = NoteLibrary.sample()
        var sheet = library.nodes.first { $0.kind == .sheet }!
        sheet.textBoxes = [PageTextBox(x: 180, y: 340, text: "Moved Unicode text नमस्ते")]
        sheet.equations = [NoteEquation(latex: "\\frac{a}{b}+\\alpha", x: 250, y: 500)]
        let originalInk = sheet.strokes
        try library.update(sheet)
        let decoded = try LibraryArchive.decode(LibraryArchive.encode(library))
        let restored = decoded.node(id: sheet.id)!
        XCTAssertEqual(restored.textBoxes, sheet.textBoxes)
        XCTAssertEqual(restored.equations, sheet.equations)
        XCTAssertEqual(restored.strokes, originalInk)
        XCTAssertEqual(decoded.search("नमस्ते").first?.id, sheet.id)
        XCTAssertEqual(decoded.search("alpha").first?.id, sheet.id)
    }

    func testLegacyArchiveDefaultsAndPromotesBeforeAddingObjects() throws {
        let library = NoteLibrary.sample()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryArchive.encode(library)) as? [String: Any])
        object["formatVersion"] = 1
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        for index in nodes.indices {
            nodes[index].removeValue(forKey: "textBoxes")
            nodes[index].removeValue(forKey: "equations")
        }
        object["nodes"] = nodes
        var legacy = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.formatVersion, 1)
        XCTAssertTrue(legacy.nodes.allSatisfy { $0.textBoxes.isEmpty && $0.equations.isEmpty })
        var sheet = legacy.nodes.first { $0.kind == .sheet }!
        sheet.textBoxes = [PageTextBox(text: "A positioned note")]
        try legacy.update(sheet)
        XCTAssertEqual(legacy.formatVersion, 2)
        XCTAssertEqual(try LibraryArchive.decode(LibraryArchive.encode(legacy)).node(id: sheet.id)?.textBoxes, sheet.textBoxes)
    }

    func testInvalidPageObjectsRejectWithoutChangingSavedNote() throws {
        var library = NoteLibrary.sample()
        let original = library.nodes.first { $0.kind == .sheet }!
        var invalid = original
        invalid.textBoxes = [PageTextBox(x: .nan, text: "Invalid")]
        XCTAssertThrowsError(try library.update(invalid))
        invalid = original
        invalid.equations = [NoteEquation(latex: String(repeating: "x", count: 16_385))]
        XCTAssertThrowsError(try library.update(invalid))
        invalid.equations = [NoteEquation(latex: "x", fontSize: .infinity)]
        XCTAssertThrowsError(try library.update(invalid))
        XCTAssertEqual(library.node(id: original.id), original)
    }

    func testMixedSnapshotAndCopyPreserveAllContent() throws {
        var source = NoteNode(kind: .sheet, title: "Source")
        source.pageContent = PageContent(text: "Typed", rtfData: Data([1, 2]),
            strokes: [InkStroke(points: [InkPoint(x: 4, y: 8)], colorHex: "#3869B2")],
            pencilKitData: Data([3, 4]), textBoxes: [PageTextBox(text: "Movable")],
            equations: [NoteEquation(latex: "x^2")])
        var restored = NoteNode(kind: .sheet, title: "Restored")
        restored.pageContent = source.pageContent
        XCTAssertEqual(restored.pageContent, source.pageContent)
        XCTAssertEqual(try JSONDecoder().decode(PageContent.self, from: JSONEncoder().encode(source.pageContent)), source.pageContent)
    }

    func testVersionOneCannotSilentlyExportNewObjects() throws {
        let nodes = NoteLibrary.sample().nodes.map { node -> NoteNode in
            var node = node
            if node.kind == .sheet { node.equations = [NoteEquation()] }
            return node
        }
        let library = NoteLibrary(nodes: nodes, formatVersion: 1)
        XCTAssertThrowsError(try LibraryArchive.encode(library))
    }

    func testClipboardRejectsOversizedAndInvalidObjects() throws {
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(Data(repeating: 0, count: PageClipboardPayload.maximumBytes + 1)))
        let invalid = PageClipboardPayload(textBoxes: [PageTextBox(width: -1, text: "Unsafe")])
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(invalid)))
        let hugeInk = PageClipboardPayload(strokes: [InkStroke(points: [InkPoint(x: 1e200, y: 20)])])
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(hugeInk)))
        let valid = PageClipboardPayload(textBoxes: [PageTextBox(text: "नमस्ते")], equations: [NoteEquation(latex: "x^2")])
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(valid)), valid)
    }

    func testImportedPagePreservesPositionedContentAndProtectsVersion() throws {
        var incoming = NoteLibrary.sample()
        var sheet = incoming.nodes.first { $0.kind == .sheet }!
        sheet.textBoxes = [PageTextBox(text: "A floating note")]
        sheet.equations = [NoteEquation(latex: "\\sqrt{x}")]
        try incoming.update(sheet)
        var destination = NoteLibrary(formatVersion: 1)
        _ = try destination.merge(incoming)
        XCTAssertEqual(destination.formatVersion, 2)
        let imported = destination.nodes.first { $0.kind == .sheet }!
        XCTAssertTrue(imported.id != sheet.id)
        XCTAssertEqual(imported.pageContent, sheet.pageContent)
        XCTAssertTrue(imported.plainTextExport.contains("A floating note"))
        XCTAssertTrue(imported.plainTextExport.contains("\\sqrt{x}"))
    }
}
