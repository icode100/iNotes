import Foundation
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
@testable import NotesCore

final class NoteLibraryTests: XCTestCase {
    private func hierarchy() throws -> (NoteLibrary, UUID, UUID, UUID, UUID) {
        var library = NoteLibrary()
        let workbook = try library.create(kind: .workbook, title: "Research")
        let chapter = try library.create(kind: .chapter, title: "Ideas", parentID: workbook)
        let topic = try library.create(kind: .topic, title: "Field notes", parentID: chapter)
        let sheet = try library.create(kind: .sheet, title: "Café résumé ✨", parentID: topic)
        return (library, workbook, chapter, topic, sheet)
    }

    func testHierarchyAndOrderedChildren() throws {
        var (library, workbook, chapter, topic, sheet) = try hierarchy()
        let second = try library.create(kind: .sheet, title: "Second", parentID: topic)
        XCTAssertEqual(library.roots.map(\.id), [workbook])
        XCTAssertEqual(library.children(of: topic).map(\.id), [sheet, second])
        XCTAssertEqual(library.path(to: sheet).map(\.id), [workbook, chapter, topic, sheet])
        XCTAssertEqual(Set(library.descendants(of: workbook).map(\.id)), Set([chapter, topic, sheet, second]))
        try library.validate()
    }

    func testInvalidParentsAndTitlesLeaveLibraryUnchanged() throws {
        var (library, workbook, _, _, sheet) = try hierarchy()
        let original = library
        XCTAssertThrowsError(try library.create(kind: .sheet, title: "Orphan"))
        XCTAssertThrowsError(try library.create(kind: .topic, title: "Invalid", parentID: sheet))
        XCTAssertThrowsError(try library.create(kind: .chapter, title: "Invalid", parentID: sheet))
        XCTAssertThrowsError(try library.create(kind: .workbook, title: "Nested", parentID: workbook))
        XCTAssertThrowsError(try library.create(kind: .workbook, title: " \n "))
        XCTAssertThrowsError(try library.rename(id: sheet, title: String(repeating: "x", count: 257)))
        XCTAssertEqual(library, original)
        try library.rename(id: sheet, title: "  新しいメモ 📝  ")
        XCTAssertEqual(library.node(id: sheet)?.title, "新しいメモ 📝")
    }

    func testMoveRejectsCycleAndAllowsReordering() throws {
        var (library, _, chapter, topic, sheet) = try hierarchy()
        let nested = try library.create(kind: .topic, title: "Nested", parentID: topic)
        XCTAssertThrowsError(try library.move(id: topic, to: nested)) { XCTAssertEqual($0 as? LibraryError, .cycle) }
        XCTAssertThrowsError(try library.move(id: topic, to: topic))
        try library.move(id: sheet, to: chapter, at: 0)
        XCTAssertEqual(library.children(of: chapter).map(\.id), [sheet, topic])
        try library.move(id: sheet, to: chapter, at: 99)
        XCTAssertEqual(library.children(of: chapter).map(\.id), [topic, sheet])
        try library.validate()
    }

    func testSearchUsesAllTokensTitlesBodiesTagsAndAccentFolding() throws {
        var (library, _, _, _, sheet) = try hierarchy()
        var note = library.node(id: sheet)!
        note.body = "Apple Pencil experiments and meeting notes"
        note.tags = ["important", "université"]
        note.isFavorite = true
        try library.update(note)
        XCTAssertEqual(library.search("CAFE pencil universite").map(\.id), [sheet])
        XCTAssertEqual(library.search("resume", favoritesOnly: true).map(\.id), [sheet])
        XCTAssertTrue(library.search("pencil banana").isEmpty)
        try library.trash(id: sheet)
        XCTAssertTrue(library.search("pencil").isEmpty)
    }

    func testTrashSubtreeAndRestoreAncestors() throws {
        var (library, workbook, chapter, topic, sheet) = try hierarchy()
        try library.trash(id: chapter)
        XCTAssertFalse(library.node(id: workbook)!.isTrashed)
        XCTAssertTrue(library.node(id: chapter)!.isTrashed)
        XCTAssertTrue(library.node(id: topic)!.isTrashed)
        XCTAssertTrue(library.node(id: sheet)!.isTrashed)
        XCTAssertTrue(library.children(of: workbook).isEmpty)
        XCTAssertThrowsError(try library.create(kind: .sheet, title: "Hidden", parentID: chapter))
        try library.restore(id: sheet)
        XCTAssertFalse(library.node(id: chapter)!.isTrashed)
        XCTAssertFalse(library.node(id: topic)!.isTrashed)
        XCTAssertFalse(library.node(id: sheet)!.isTrashed)
        try library.validate()
    }

    func testPermanentDeleteRequiresTrashAndDeletesSubtree() throws {
        var (library, workbook, chapter, _, _) = try hierarchy()
        XCTAssertThrowsError(try library.permanentlyDelete(id: chapter))
        try library.trash(id: chapter)
        try library.permanentlyDelete(id: chapter)
        XCTAssertEqual(library.nodes.map(\.id), [workbook])
        try library.validate()
    }

    func testDuplicateRemapsTreeAndKeepsContent() throws {
        var (library, _, chapter, _, sheet) = try hierarchy()
        var note = library.node(id: sheet)!
        note.body = "Preserve every byte"
        note.attachments = [NoteAttachment(filename: "photo.png", mediaType: "image/png", data: Data([0, 1, 2, 255]))]
        try library.update(note)
        let duplicated = try library.duplicate(id: chapter)
        XCTAssertEqual(library.node(id: duplicated)?.title, "Ideas (copy)")
        let copiedSheet = try XCTUnwrap(library.descendants(of: duplicated).first { $0.kind == .sheet })
        XCTAssertNotEqual(copiedSheet.id, sheet)
        XCTAssertEqual(copiedSheet.body, note.body)
        XCTAssertEqual(copiedSheet.attachments, note.attachments)
        try library.validate()
    }

    func testMergeRemapsEveryIDAndDoesNotOverwrite() throws {
        var (library, workbook, _, _, sheet) = try hierarchy()
        let originalCount = library.nodes.count
        let roots = try library.merge(library)
        XCTAssertEqual(roots.count, 1)
        XCTAssertNotEqual(roots.first, workbook)
        XCTAssertEqual(library.nodes.count, originalCount * 2)
        XCTAssertEqual(library.node(id: sheet)?.title, "Café résumé ✨")
        XCTAssertEqual(Set(library.nodes.map(\.id)).count, library.nodes.count)
        try library.validate()
    }

    func testArchiveRoundTripAllMediaAndUnicode() throws {
        var (library, _, _, _, sheet) = try hierarchy()
        var note = library.node(id: sheet)!
        note.body = "नमस्ते 世界\n☑ Checklist\nhttps://example.org"
        note.richTextRTF = Data("{\\rtf1 hello}".utf8)
        note.pencilKitData = Data([1, 2, 3, 4])
        note.strokes = [InkStroke(points: [InkPoint(x: 12, y: 34, pressure: 0.25), InkPoint(x: 14, y: 38, pressure: 0.9)], colorHex: "#AB12CD", width: 3)]
        note.attachments = [NoteAttachment(filename: "資料.pdf", mediaType: "application/pdf", data: Data([0, 127, 255]))]
        try library.update(note)
        let encoded = try LibraryArchive.encode(library)
        let decoded = try LibraryArchive.decode(encoded)
        let roundtrip = try XCTUnwrap(decoded.node(id: sheet))
        XCTAssertEqual(roundtrip.body, note.body)
        XCTAssertEqual(roundtrip.richTextRTF, note.richTextRTF)
        XCTAssertEqual(roundtrip.pencilKitData, note.pencilKitData)
        XCTAssertEqual(roundtrip.strokes, note.strokes)
        XCTAssertEqual(roundtrip.attachments, note.attachments)
        XCTAssertEqual(roundtrip.createdAt.timeIntervalSince1970, note.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMalformedAndFutureArchivesRejected() throws {
        XCTAssertThrowsError(try LibraryArchive.decode(Data("not json".utf8)))
        var future = NoteLibrary()
        future.formatVersion = 999
        XCTAssertThrowsError(try LibraryArchive.encode(future)) { XCTAssertEqual($0 as? LibraryError, .unsupportedVersion(999)) }
        let node = NoteNode(kind: .workbook, title: "One")
        XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: [node, node])))
        let orphan = NoteNode(parentID: UUID(), kind: .sheet, title: "Orphan")
        XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: [orphan])))
    }

    func testContentUpdateCannotCreateCycleOrInvalidDrawing() throws {
        var (library, _, _, topic, sheet) = try hierarchy()
        var invalid = library.node(id: topic)!
        invalid.parentID = topic
        let original = library
        XCTAssertThrowsError(try library.update(invalid))
        XCTAssertEqual(library, original)
        invalid = library.node(id: sheet)!
        invalid.strokes = [InkStroke(points: [InkPoint(x: .infinity, y: 0)])]
        XCTAssertThrowsError(try library.update(invalid))
        invalid.strokes = [InkStroke(points: [InkPoint(x: 0, y: 0, pressure: 1.1)])]
        XCTAssertThrowsError(try library.update(invalid))
        XCTAssertEqual(library, original)
    }

    func testAttachmentTraversalNameRejected() throws {
        var (library, _, _, _, sheet) = try hierarchy()
        var note = library.node(id: sheet)!
        note.attachments = [NoteAttachment(filename: "../escape.txt", data: Data())]
        XCTAssertThrowsError(try library.update(note))
    }

    func testEmptyTrashRetainsActiveNotes() throws {
        var (library, workbook, chapter, _, _) = try hierarchy()
        try library.trash(id: chapter)
        library.emptyTrash()
        XCTAssertEqual(library.nodes.map(\.id), [workbook])
        try library.validate()
    }

    func testSampleLibraryValidAndHasSheet() throws {
        let sample = NoteLibrary.sample()
        try sample.validate()
        XCTAssertEqual(sample.roots.count, 1)
        XCTAssertTrue(sample.nodes.contains { $0.kind == .sheet && !$0.body.isEmpty })
    }

    func testDepthLimitCannotBeBypassedByParentFirstOrder() throws {
        var library = NoteLibrary()
        let workbook = try library.create(kind: .workbook, title: "Root")
        var parent = try library.create(kind: .chapter, title: "Chapter", parentID: workbook)
        for level in 3...128 { parent = try library.create(kind: .topic, title: "Level \(level)", parentID: parent) }
        XCTAssertThrowsError(try library.create(kind: .topic, title: "Too deep", parentID: parent))
        try library.validate()
        var malicious = library.nodes
        malicious.append(NoteNode(parentID: parent, kind: .sheet, title: "Too deep"))
        XCTAssertThrowsError(try NoteLibrary(nodes: malicious).validate())
        XCTAssertThrowsError(try NoteLibrary(nodes: malicious.reversed()).validate())
    }

    func testThousandSheetLibraryRemainsCompactAndSearchable() throws {
        var library = NoteLibrary()
        let workbook = try library.create(kind: .workbook, title: "Course")
        let chapter = try library.create(kind: .chapter, title: "Lectures", parentID: workbook)
        for number in 1...1000 {
            _ = try library.create(kind: .sheet, title: "Lecture \(number)", parentID: chapter)
        }
        let bytes = try LibraryArchive.encode(library)
        XCTAssertLessThan(bytes.count, 600_000)
        XCTAssertEqual(library.search("Lecture 1000").count, 1)
        let decoded = try LibraryArchive.decode(bytes)
        XCTAssertEqual(decoded.children(of: chapter).count, 1000)
    }

    func testOversizedMergeAndDuplicateDoNotCommitPartialChanges() throws {
        let node = NoteNode(kind: .workbook, title: "Large", body: String(repeating: "x", count: LibraryArchive.maximumBytes / 2))
        var library = NoteLibrary(nodes: [node])
        _ = try LibraryArchive.encode(library)
        XCTAssertThrowsError(try library.merge(library)) { XCTAssertEqual($0 as? LibraryError, .tooLarge) }
        XCTAssertEqual(library.nodes.count, 1)
        XCTAssertThrowsError(try library.duplicate(id: node.id)) { XCTAssertEqual($0 as? LibraryError, .tooLarge) }
        XCTAssertEqual(library.nodes.count, 1)
    }

    func testUntrustedOrderingCannotOverflow() throws {
        let root = NoteNode(kind: .workbook, title: "Untrusted position", order: Int.max)
        var library = NoteLibrary(nodes: [root])
        XCTAssertThrowsError(try library.create(kind: .workbook, title: "Second"))
        XCTAssertThrowsError(try library.duplicate(id: root.id))
        XCTAssertThrowsError(try library.merge(NoteLibrary.sample()))
        XCTAssertEqual(library.nodes.count, 1)
    }

    func testTrashSearchIsExplicitAndNodeByteBudgetMatchesArchive() throws {
        var (library, _, _, _, sheet) = try hierarchy()
        try library.trash(id: sheet)
        XCTAssertTrue(library.search("cafe").isEmpty)
        XCTAssertEqual(library.search("cafe", includingTrash: true).map(\.id), [sheet])
        let before = try LibraryArchive.encode(library).count
        let node = library.node(id: sheet)!
        let oldNodeSize = try LibraryArchive.encodedNodeSize(node)
        var changed = node
        changed.body = "Escaped quote: \" and slash: / and newline:\nUnicode: नमस्ते"
        changed.richTextRTF = Data([0, 255, 127, 64])
        try library.update(changed)
        let saved = library.node(id: sheet)!
        let nodeDelta = try LibraryArchive.encodedNodeSize(saved) - oldNodeSize
        let archiveDelta = try LibraryArchive.encode(library).count - before
        // Only the independently updated library modifiedAt timestamp may change header length.
        XCTAssertLessThan(abs(nodeDelta - archiveDelta), 32)
    }

    func testPayloadOptimizationCannotBypassStructuralAndDateChecks() throws {
        var (library, workbook, _, topic, sheet) = try hierarchy()
        let original = library
        var node = library.node(id: sheet)!
        node.parentID = workbook
        XCTAssertThrowsError(try library.update(node))
        node = library.node(id: topic)!
        node.isTrashed = true
        XCTAssertThrowsError(try library.update(node))
        node = library.node(id: sheet)!
        node.kind = .workbook
        XCTAssertThrowsError(try library.update(node))
        node = library.node(id: sheet)!
        node.createdAt = Date(timeIntervalSince1970: .nan)
        XCTAssertThrowsError(try library.update(node))
        XCTAssertEqual(library, original)
        library.formatVersion = 999
        XCTAssertThrowsError(try library.update(original.node(id: sheet)!))
    }

    func testEveryInkAndPaperStylePersists() throws {
        var (library, _, _, _, sheet) = try hierarchy()
        var node = library.node(id: sheet)!
        node.strokes = InkStyle.allCases.map { style in
            InkStroke(points: [InkPoint(x: 12, y: 34, pressure: 0.75)], colorHex: "#FFCC00", width: 4, style: style)
        }
        for paper in PaperStyle.allCases {
            node.paperStyle = paper
            try library.update(node)
            let reopened = try LibraryArchive.decode(LibraryArchive.encode(library))
            let saved = try XCTUnwrap(reopened.node(id: sheet))
            XCTAssertEqual(saved.paperStyle, paper)
            XCTAssertEqual(saved.strokes.map(\.style), InkStyle.allCases)
            XCTAssertEqual(saved.strokes.map(\.width), [4, 4, 4, 4])
        }
    }

    func testLegacyVersionOneDefaultsToPenAndDottedPaper() throws {
        var (library, _, _, _, sheet) = try hierarchy()
        var node = library.node(id: sheet)!
        node.strokes = [InkStroke(points: [InkPoint(x: 1, y: 2)], style: .marker)]
        node.paperStyle = .grid
        try library.update(node)
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryArchive.encode(library)) as? [String: Any])
        archive["formatVersion"] = 1
        var nodes = try XCTUnwrap(archive["nodes"] as? [[String: Any]])
        for index in nodes.indices {
            nodes[index].removeValue(forKey: "paperStyle")
            var strokes = try XCTUnwrap(nodes[index]["strokes"] as? [[String: Any]])
            for strokeIndex in strokes.indices { strokes[strokeIndex].removeValue(forKey: "style") }
            nodes[index]["strokes"] = strokes
        }
        archive["nodes"] = nodes
        let legacy = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: archive))
        XCTAssertEqual(legacy.formatVersion, 1)
        XCTAssertTrue(legacy.nodes.allSatisfy { $0.paperStyle == .dotted })
        XCTAssertEqual(legacy.node(id: sheet)?.strokes.first?.style, .pen)
        XCTAssertEqual(legacy.node(id: sheet)?.strokes.first?.points, node.strokes.first?.points)
    }
}
