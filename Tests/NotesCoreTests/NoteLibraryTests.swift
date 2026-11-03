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

    func testSubtreeMembershipPreservesMovesTrashAndArrayOrder() throws {
        var (library, workbook, chapter, topic, sheet) = try hierarchy()
        let other = try library.create(kind: .chapter, title: "Other", parentID: workbook)
        let outside = try library.create(kind: .sheet, parentID: other)
        let before = library
        XCTAssertEqual(library.subtreeIDs(rootID: topic), Set([topic, sheet]))
        XCTAssertEqual(library, before)
        try library.trash(id: sheet)
        XCTAssertTrue(library.subtreeIDs(rootID: chapter).contains(sheet))
        try library.restore(id: sheet)
        try library.move(id: sheet, to: other)
        XCTAssertFalse(library.subtreeIDs(rootID: chapter).contains(sheet))
        XCTAssertEqual(library.subtreeIDs(rootID: other), Set([other, sheet, outside]))
        let reversed = NoteLibrary(nodes: Array(library.nodes.reversed()))
        XCTAssertEqual(reversed.subtreeIDs(rootID: workbook), library.subtreeIDs(rootID: workbook))
        XCTAssertEqual(library.subtreeIDs(rootID: sheet), Set([sheet]))
        let missing = UUID()
        XCTAssertEqual(library.subtreeIDs(rootID: missing), Set([missing]))
        // Defensive termination even for an invalid programmatically constructed graph.
        let a = UUID(), b = UUID()
        let cycle = NoteLibrary(nodes: [NoteNode(id: a, parentID: b, kind: .topic, title: "A"),
                                       NoteNode(id: b, parentID: a, kind: .topic, title: "B")])
        XCTAssertEqual(cycle.subtreeIDs(rootID: a), Set([a, b]))
    }

    func testNearLimitLeafFirstHierarchyHasBoundedSubtreeQuery() throws {
        let folders = (0..<127).map { _ in UUID() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sheets = (1...49_000).map { number in
            NoteNode(parentID: folders.last!, kind: .sheet, title: "", createdAt: date,
                     updatedAt: date, order: number, sheetNumber: number)
        }
        let ancestors = folders.enumerated().map { index, id in
            NoteNode(id: id, parentID: index == 0 ? nil : folders[index - 1],
                     kind: index == 0 ? .workbook : index == 1 ? .chapter : .topic,
                     title: "Folder", createdAt: date, updatedAt: date,
                     lastSheetNumber: index == 126 ? sheets.count : 0)
        }
        let library = NoteLibrary(nodes: sheets + ancestors)
        let encoded = try LibraryArchive.encode(library)
        let reopened = try LibraryArchive.decode(encoded)
        let start = ProcessInfo.processInfo.systemUptime
        let members = reopened.subtreeIDs(rootID: folders[0])
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(members, Set(reopened.nodes.map(\.id)))
        // A broad guard against reintroducing per-leaf full-array ancestry walks.
        XCTAssertLessThan(elapsed, 5.0)
        XCTAssertEqual(reopened.nodes.map(\.id), library.nodes.map(\.id))
        print("Near-limit subtree: \(members.count) nodes, \(String(format: "%.3f", elapsed))s")
    }

    func testUntitledSheetsPersistWithoutWeakeningFolderNames() throws {
        var (library, workbook, chapter, topic, sheet) = try hierarchy()
        let createdAt = try XCTUnwrap(library.node(id: sheet)?.createdAt)
        try library.rename(id: sheet, title: " \n ")
        var note = try XCTUnwrap(library.node(id: sheet))
        note.body = "The title is optional; the note is not."
        try library.update(note)
        let blank = try library.create(kind: .sheet, parentID: topic)
        XCTAssertEqual(library.node(id: blank)?.title, "")
        XCTAssertEqual(library.node(id: blank)?.displayTitle, "Sheet 2")
        let reopened = try LibraryArchive.decode(LibraryArchive.encode(library))
        XCTAssertEqual(reopened.node(id: sheet)?.title, "")
        XCTAssertEqual(reopened.node(id: sheet)?.body, note.body)
        XCTAssertEqual(try XCTUnwrap(reopened.node(id: sheet)).createdAt.timeIntervalSince1970,
                       createdAt.timeIntervalSince1970, accuracy: 0.001)
        for id in [workbook, chapter, topic] {
            let before = library
            XCTAssertThrowsError(try library.rename(id: id, title: "  "))
            var folder = try XCTUnwrap(library.node(id: id)); folder.title = ""
            XCTAssertThrowsError(try library.update(folder))
            XCTAssertEqual(library, before)
        }
        let copy = try library.duplicate(id: blank)
        XCTAssertEqual(library.node(id: copy)?.title, "")
        XCTAssertEqual(library.node(id: copy)?.sheetNumber, 3)
    }

    func testSheetNumbersFollowPageOrderAndReuseRemovedTail() throws {
        var (library, _, chapter, topic, first) = try hierarchy()
        let second = try library.create(kind: .sheet, parentID: topic)
        let otherScope = try library.create(kind: .sheet, parentID: chapter)
        XCTAssertEqual(library.node(id: first)?.sheetNumber, 1)
        XCTAssertEqual(library.node(id: second)?.sheetNumber, 2)
        XCTAssertEqual(library.node(id: otherScope)?.sheetNumber, 1)
        let creation = try XCTUnwrap(library.node(id: first)?.createdAt)
        var note = try XCTUnwrap(library.node(id: first)); note.body = "Find stable numbering"; note.isFavorite = true
        try library.update(note)
        try library.rename(id: first, title: "Renamed")
        try library.move(id: second, to: topic, at: 0)
        XCTAssertEqual(library.search("stable").first?.sheetNumber, 2)
        XCTAssertEqual(library.node(id: first)?.createdAt, creation)
        XCTAssertEqual(library.node(id: second)?.sheetNumber, 1)
        try library.trash(id: second)
        let third = try library.create(kind: .sheet, parentID: topic)
        XCTAssertEqual(library.node(id: third)?.sheetNumber, 2)
        XCTAssertEqual(library.node(id: third)?.displayTitle, "Sheet 2")
        XCTAssertEqual(library.node(id: first)?.sheetNumber, 1)
        XCTAssertEqual(library.node(id: otherScope)?.sheetNumber, 1)
        try library.restore(id: second)
        XCTAssertEqual(Set(library.children(of: topic).compactMap(\.sheetNumber)), Set([1, 2, 3]))
        try library.trash(id: third)
        try library.permanentlyDelete(id: third)
        try library.trash(id: second)
        library.emptyTrash()
        library = try LibraryArchive.decode(LibraryArchive.encode(library))
        let fourth = try library.create(kind: .sheet, parentID: topic)
        XCTAssertEqual(library.node(id: fourth)?.sheetNumber, 2)
        XCTAssertEqual(library.node(id: first)?.body, "Find stable numbering")
        try library.validate()
    }

    func testMiddleDeletionCompactsPagesAndDraggingNewSheetRenumbersInPageOrder() throws {
        var (library, _, _, topic, first) = try hierarchy()
        let second = try library.create(kind: .sheet, parentID: topic)
        let third = try library.create(kind: .sheet, title: "Third page", parentID: topic)
        let originalThird = try XCTUnwrap(library.node(id: third))
        try library.trash(id: second)
        XCTAssertEqual(library.node(id: first)?.sheetNumber, 1)
        XCTAssertEqual(library.node(id: third)?.sheetNumber, 2)
        var compactedThird = try XCTUnwrap(library.node(id: third))
        compactedThird.sheetNumber = originalThird.sheetNumber
        XCTAssertEqual(compactedThird, originalThird)
        let newSheet = try library.create(kind: .sheet, parentID: topic)
        XCTAssertEqual(library.node(id: newSheet)?.sheetNumber, 3)
        try library.move(id: newSheet, to: topic, at: 1)
        XCTAssertEqual(library.children(of: topic).map(\.id), [first, newSheet, third])
        XCTAssertEqual(library.children(of: topic).compactMap(\.sheetNumber), [1, 2, 3])
        XCTAssertEqual(library.node(id: newSheet)?.displayTitle, "Sheet 2")
        XCTAssertEqual(library.node(id: third)?.title, "Third page")
        XCTAssertEqual(library.node(id: third)?.updatedAt, originalThird.updatedAt)
        XCTAssertEqual(library.node(id: third)?.createdAt, originalThird.createdAt)
        let reopened = try LibraryArchive.decode(LibraryArchive.encode(library))
        XCTAssertEqual(reopened.children(of: topic).map(\.id), [first, newSheet, third])
        XCTAssertEqual(reopened.children(of: topic).compactMap(\.sheetNumber), [1, 2, 3])
        try reopened.validate()
    }

    func testRemovingAllSheetsRestartsAtOneWithOrWithoutRetainedTrash() throws {
        for removal in ["trash", "permanent", "empty"] {
            var (library, _, chapter, topic, first) = try hierarchy()
            let second = try library.create(kind: .sheet, parentID: topic)
            let otherScope = try library.create(kind: .sheet, parentID: chapter)
            for id in [first, second] { try library.trash(id: id) }
            if removal == "permanent" {
                for id in [first, second] { try library.permanentlyDelete(id: id) }
            } else if removal == "empty" { library.emptyTrash() }
            library = try LibraryArchive.decode(LibraryArchive.encode(library))
            let replacement = try library.create(kind: .sheet, parentID: topic)
            XCTAssertEqual(library.node(id: replacement)?.sheetNumber, 1)
            XCTAssertEqual(library.node(id: replacement)?.displayTitle, "Sheet 1")
            XCTAssertEqual(library.node(id: otherScope)?.sheetNumber, 1)
            XCTAssertEqual(library.children(of: topic).map(\.id), [replacement])
            if removal == "trash" {
                XCTAssertTrue(library.node(id: first)?.isTrashed == true)
                XCTAssertTrue(library.node(id: second)?.isTrashed == true)
            }
            try library.validate()
            _ = try LibraryArchive.decode(LibraryArchive.encode(library))
        }
    }

    func testNumberReusePreservesTrashedAnnotatedPageAndArchiveCompatibility() throws {
        var (library, _, _, topic, _) = try hierarchy()
        let deleted = try library.create(kind: .sheet, title: "Annotated page", parentID: topic)
        var page = try XCTUnwrap(library.node(id: deleted))
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="))
        page.pageContent = PageContent(text: "Keep this note — 日本語", rtfData: Data("{\\rtf1 preserved}".utf8),
            strokes: [InkStroke(points: [InkPoint(x: 30, y: 50, pressure: 0.4)])],
            pencilKitData: Data([0, 1, 127, 255]), textBoxes: [PageTextBox(text: "Caption")],
            equations: [NoteEquation(latex: "x^2")], images: [PageImage(imageData: png)])
        page.attachments = [NoteAttachment(filename: "keep.txt", data: Data([1, 2, 3]))]
        page.tags = ["keep"]; page.isFavorite = true
        try library.update(page)
        try library.trash(id: deleted)
        let archived = try XCTUnwrap(library.node(id: deleted))
        let previousOrder = library.nodes.map(\.id)
        let replacement = try library.create(kind: .sheet, parentID: topic)
        XCTAssertEqual(library.node(id: replacement)?.sheetNumber, 2)
        var displaced = try XCTUnwrap(library.node(id: deleted))
        XCTAssertNotEqual(displaced.sheetNumber, library.node(id: replacement)?.sheetNumber)
        // An archival number change must not look like a content edit or lose any payload.
        displaced.sheetNumber = archived.sheetNumber
        XCTAssertEqual(displaced, archived)
        XCTAssertEqual(Array(library.nodes.dropLast()).map(\.id), previousOrder)
        var reopened = try LibraryArchive.decode(LibraryArchive.encode(library))
        XCTAssertEqual(reopened.formatVersion, 3)
        XCTAssertEqual(reopened.node(id: deleted)?.pageContent, archived.pageContent)
        try reopened.restore(id: deleted)
        XCTAssertEqual(reopened.node(id: deleted)?.pageContent, archived.pageContent)
        XCTAssertEqual(reopened.node(id: deleted)?.attachments, archived.attachments)
        XCTAssertEqual(reopened.node(id: deleted)?.title, archived.title)
        XCTAssertEqual(try XCTUnwrap(reopened.node(id: deleted)).createdAt.timeIntervalSince1970,
                       archived.createdAt.timeIntervalSince1970, accuracy: 0.001)
        let siblings = reopened.children(of: topic, includingTrash: true).filter { $0.kind == .sheet }
        let numbers = siblings.compactMap(\.sheetNumber)
        XCTAssertEqual(Set(numbers).count, siblings.count)
        XCTAssertTrue(numbers.allSatisfy { $0 > 0 && $0 <= reopened.node(id: topic)!.lastSheetNumber })
        try reopened.validate()
    }

    func testNumberReuseRejectsInvalidMovesAndUpdatesAtomically() throws {
        var (library, workbook, chapter, _, sheet) = try hierarchy()
        let deleted = try library.create(kind: .sheet, parentID: chapter)
        try library.trash(id: deleted)
        let before = library
        var invalid = try XCTUnwrap(library.node(id: sheet))
        invalid.parentID = chapter
        invalid.strokes = [InkStroke(points: [InkPoint(x: .infinity, y: 0)])]
        // The destination's trashed number must survive a rejected allocation/content edit.
        XCTAssertThrowsError(try library.update(invalid))
        XCTAssertEqual(library, before)
        XCTAssertThrowsError(try library.move(id: sheet, to: workbook))
        XCTAssertEqual(library, before)
        var unsupported = library
        unsupported.formatVersion = 999
        let unsupportedBefore = unsupported
        XCTAssertThrowsError(try unsupported.move(id: sheet, to: chapter))
        XCTAssertEqual(unsupported, unsupportedBefore)

        _ = try library.create(kind: .sheet, parentID: chapter)
        let beforeRestore = library
        invalid = try XCTUnwrap(library.node(id: deleted))
        invalid.isTrashed = false
        invalid.strokes = [InkStroke(points: [])]
        XCTAssertThrowsError(try library.update(invalid))
        XCTAssertEqual(library, beforeRestore)
        try library.validate()
    }

    func testSheetMoveDuplicateAndImportKeepIndependentSequences() throws {
        var (library, _, chapter, topic, sheet) = try hierarchy()
        let destinationFirst = try library.create(kind: .sheet, parentID: chapter)
        try library.move(id: sheet, to: chapter)
        XCTAssertEqual(library.node(id: sheet)?.sheetNumber, 2)
        let topicNext = try library.create(kind: .sheet, parentID: topic)
        XCTAssertEqual(library.node(id: topicNext)?.sheetNumber, 1)
        let sheetCopy = try library.duplicate(id: sheet)
        XCTAssertEqual(library.node(id: sheetCopy)?.sheetNumber, 3)
        let chapterCopy = try library.duplicate(id: chapter)
        let copiedNumbers = library.children(of: chapterCopy).filter { $0.kind == .sheet }.compactMap(\.sheetNumber).sorted()
        XCTAssertEqual(copiedNumbers, [1, 2, 3])
        let copiedNext = try library.create(kind: .sheet, parentID: chapterCopy)
        XCTAssertEqual(library.node(id: copiedNext)?.sheetNumber, 4)
        let source = try LibraryArchive.decode(LibraryArchive.encode(library))
        let roots = try library.merge(source)
        let imported = roots.flatMap { library.descendants(of: $0) }
        XCTAssertEqual(imported.filter { $0.kind == .sheet }.compactMap(\.sheetNumber).sorted(),
                       source.nodes.filter { $0.kind == .sheet }.compactMap(\.sheetNumber).sorted())
        XCTAssertEqual(library.node(id: destinationFirst)?.sheetNumber, 1)
        XCTAssertEqual(library.node(id: chapter)?.lastSheetNumber, 3)
        try library.validate()
    }

    func testStructuralUpdatesAndMovesReindexSourceAndDestinationPages() throws {
        var (library, _, chapter, topic, first) = try hierarchy()
        let second = try library.create(kind: .sheet, parentID: topic)
        let third = try library.create(kind: .sheet, parentID: topic)
        let destination = try library.create(kind: .sheet, parentID: chapter)
        try library.move(id: second, to: chapter, at: 0)
        XCTAssertEqual(library.children(of: topic).map(\.id), [first, third])
        XCTAssertEqual(library.children(of: topic).compactMap(\.sheetNumber), [1, 2])
        XCTAssertEqual(library.node(id: second)?.sheetNumber, 1)
        XCTAssertEqual(library.node(id: destination)?.sheetNumber, 2)
        try library.move(id: second, to: topic, at: 1)
        XCTAssertEqual(library.children(of: topic).map(\.id), [first, second, third])
        XCTAssertEqual(library.children(of: topic).compactMap(\.sheetNumber), [1, 2, 3])
        XCTAssertEqual(library.node(id: destination)?.sheetNumber, 1)

        var changed = try XCTUnwrap(library.node(id: third))
        changed.order = -1
        try library.update(changed)
        XCTAssertEqual(library.children(of: topic).map(\.id), [third, first, second])
        XCTAssertEqual(library.children(of: topic).compactMap(\.sheetNumber), [1, 2, 3])
        changed = try XCTUnwrap(library.node(id: third)); changed.isTrashed = true
        try library.update(changed)
        XCTAssertEqual(library.children(of: topic).map(\.id), [first, second])
        XCTAssertEqual(library.children(of: topic).compactMap(\.sheetNumber), [1, 2])
        changed = try XCTUnwrap(library.node(id: third)); changed.isTrashed = false
        try library.update(changed)
        XCTAssertEqual(library.children(of: topic).map(\.id), [third, first, second])
        XCTAssertEqual(library.children(of: topic).compactMap(\.sheetNumber), [1, 2, 3])
        try library.validate()
    }

    func testRestoringSheetAncestorsAndFoldersReinstatesPageOrder() throws {
        var (library, _, chapter, topic, first) = try hierarchy()
        let second = try library.create(kind: .sheet, parentID: topic)
        let outside = try library.create(kind: .sheet, parentID: chapter)
        try library.trash(id: first)
        XCTAssertEqual(library.node(id: second)?.sheetNumber, 1)
        try library.trash(id: topic)
        try library.restore(id: second)
        XCTAssertFalse(library.node(id: topic)!.isTrashed)
        XCTAssertTrue(library.node(id: first)!.isTrashed)
        XCTAssertEqual(library.node(id: second)?.sheetNumber, 1)
        try library.restore(id: topic)
        XCTAssertEqual(library.children(of: topic).map(\.id), [first, second])
        XCTAssertEqual(library.children(of: topic).compactMap(\.sheetNumber), [1, 2])
        XCTAssertEqual(library.node(id: outside)?.sheetNumber, 1)
        try library.validate()
        _ = try LibraryArchive.decode(LibraryArchive.encode(library))
    }

    func testMovingTrashedSheetsAcrossParentsKeepsUniqueArchiveNumbersAndContent() throws {
        for useContentUpdate in [false, true] {
            var (library, _, chapter, topic, source) = try hierarchy()
            let destination = try library.create(kind: .sheet, title: "Destination recovery page", parentID: chapter)
            var sourcePage = try XCTUnwrap(library.node(id: source))
            sourcePage.body = "Retain moved recovery text"
            sourcePage.attachments = [NoteAttachment(filename: "keep.txt", data: Data([1, 2, 255]))]
            try library.update(sourcePage)
            try library.trash(id: source)
            try library.trash(id: destination)
            XCTAssertEqual(library.node(id: source)?.sheetNumber, 1)
            XCTAssertEqual(library.node(id: destination)?.sheetNumber, 1)
            let previousDestination = try XCTUnwrap(library.node(id: destination))
            let previousSource = try XCTUnwrap(library.node(id: source))
            if useContentUpdate {
                var moved = previousSource
                moved.parentID = chapter
                try library.update(moved)
            } else { try library.move(id: source, to: chapter) }
            let siblings = library.children(of: chapter, includingTrash: true).filter { $0.kind == .sheet }
            XCTAssertEqual(siblings.count, 2)
            XCTAssertTrue(siblings.allSatisfy(\.isTrashed))
            XCTAssertEqual(Set(siblings.compactMap(\.sheetNumber)).count, 2)
            XCTAssertTrue(library.children(of: topic, includingTrash: true).isEmpty)
            XCTAssertEqual(library.node(id: source)?.pageContent, previousSource.pageContent)
            XCTAssertEqual(library.node(id: source)?.attachments, previousSource.attachments)
            XCTAssertEqual(library.node(id: source)?.createdAt, previousSource.createdAt)
            var retainedDestination = try XCTUnwrap(library.node(id: destination))
            retainedDestination.sheetNumber = previousDestination.sheetNumber
            XCTAssertEqual(retainedDestination, previousDestination)
            library = try LibraryArchive.decode(LibraryArchive.encode(library))
            try library.restore(id: source)
            XCTAssertEqual(library.node(id: source)?.sheetNumber, 1)
            XCTAssertEqual(library.node(id: source)?.body, previousSource.body)
            XCTAssertTrue(library.node(id: destination)!.isTrashed)
            try library.validate()
        }
    }

    func testFolderDuplicateAndOldArchiveImportNormalizePageGaps() throws {
        var (library, _, _, topic, first) = try hierarchy()
        let second = try library.create(kind: .sheet, parentID: topic)
        let third = try library.create(kind: .sheet, parentID: topic)
        try library.trash(id: second)
        let copy = try library.duplicate(id: topic)
        XCTAssertEqual(library.children(of: copy).compactMap(\.sheetNumber), [1, 2])
        let next = try library.create(kind: .sheet, parentID: copy)
        XCTAssertEqual(library.node(id: next)?.sheetNumber, 3)

        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryArchive.encode(library)) as? [String: Any])
        var archivedNodes = try XCTUnwrap(archive["nodes"] as? [[String: Any]])
        for index in archivedNodes.indices {
            let id = archivedNodes[index]["id"] as? String
            if id == topic.uuidString { archivedNodes[index]["lastSheetNumber"] = 99 }
            if id == first.uuidString { archivedNodes[index]["sheetNumber"] = 7 }
            if id == third.uuidString { archivedNodes[index]["sheetNumber"] = 19 }
            if id == second.uuidString { archivedNodes[index]["sheetNumber"] = 55 }
        }
        archive["nodes"] = archivedNodes
        for version in [1, 2, 3] {
            archive["formatVersion"] = version
            let compatible = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: archive))
            XCTAssertEqual(compatible.formatVersion, version)
            XCTAssertEqual(compatible.children(of: topic).compactMap(\.sheetNumber), [1, 2])
        }
        let reopened = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: archive))
        XCTAssertEqual(reopened.children(of: topic).map(\.id), [first, third])
        XCTAssertEqual(reopened.children(of: topic).compactMap(\.sheetNumber), [1, 2])
        XCTAssertEqual(reopened.node(id: topic)?.lastSheetNumber, 99)
        XCTAssertEqual(reopened.nodes.map(\.id), library.nodes.map(\.id))
        XCTAssertEqual(reopened.node(id: first)?.body, library.node(id: first)?.body)
        XCTAssertEqual(try XCTUnwrap(reopened.node(id: first)).createdAt.timeIntervalSince1970,
                       try XCTUnwrap(library.node(id: first)).createdAt.timeIntervalSince1970, accuracy: 0.001)
        var destination = NoteLibrary.sample()
        let originalNodes = destination.nodes
        let roots = try destination.merge(reopened)
        XCTAssertEqual(Array(destination.nodes.prefix(originalNodes.count)), originalNodes)
        for node in roots.flatMap({ destination.descendants(of: $0) }) where node.kind == .chapter || node.kind == .topic {
            let sheets = destination.children(of: node.id).filter { $0.kind == .sheet }
            XCTAssertEqual(sheets.compactMap(\.sheetNumber), (0..<sheets.count).map { $0 + 1 })
        }
        try destination.validate()
    }

    func testLargeFolderRestoreReindexesInOneBoundedPass() throws {
        let count = 10_000
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let workbook = NoteNode(kind: .workbook, title: "Large restore", createdAt: date, updatedAt: date)
        let chapter = NoteNode(parentID: workbook.id, kind: .chapter, title: "Pages", isTrashed: true,
                               createdAt: date, updatedAt: date, lastSheetNumber: count)
        let pages = (1...count).map { number in
            NoteNode(parentID: chapter.id, kind: .sheet, title: "", body: "Page \(number)", isTrashed: true,
                     createdAt: date, updatedAt: date, order: number, sheetNumber: number)
        }
        var library = NoteLibrary(nodes: pages + [chapter, workbook])
        let storedOrder = library.nodes.map(\.id)
        let started = ProcessInfo.processInfo.systemUptime
        try library.restore(id: chapter.id)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let restored = library.children(of: chapter.id)
        XCTAssertEqual(restored.map(\.id), pages.map(\.id))
        XCTAssertEqual(restored.compactMap(\.sheetNumber), Array(1...count))
        XCTAssertEqual(restored.map(\.body), pages.map(\.body))
        XCTAssertEqual(library.nodes.map(\.id), storedOrder)
        XCTAssertLessThan(elapsed, 5.0)
        try library.validate()
        print("Large folder restore: \(count) pages, \(String(format: "%.3f", elapsed))s")
    }

    func testPageNumberOrderTiesUseCreationDateThenUUIDWithoutChangingStoredOrder() throws {
        let date = Date(timeIntervalSince1970: 100)
        let workbook = NoteNode(kind: .workbook, title: "Ties", createdAt: date, updatedAt: date)
        let chapter = NoteNode(parentID: workbook.id, kind: .chapter, title: "Pages", createdAt: date, updatedAt: date)
        let low = NoteNode(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, parentID: chapter.id,
                           kind: .sheet, title: "Low UUID", createdAt: date, updatedAt: date, order: 7)
        let high = NoteNode(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, parentID: chapter.id,
                            kind: .sheet, title: "High UUID", createdAt: date, updatedAt: date, order: 7)
        let earlier = NoteNode(parentID: chapter.id, kind: .sheet, title: "Earlier", createdAt: date.addingTimeInterval(-1),
                               updatedAt: date, order: 7)
        let stored = [high, chapter, earlier, low, workbook]
        let library = NoteLibrary(nodes: stored)
        let reversed = NoteLibrary(nodes: stored.reversed())
        for candidate in [library, reversed] {
            XCTAssertEqual(candidate.node(id: earlier.id)?.sheetNumber, 1)
            XCTAssertEqual(candidate.node(id: low.id)?.sheetNumber, 2)
            XCTAssertEqual(candidate.node(id: high.id)?.sheetNumber, 3)
            try candidate.validate()
        }
        XCTAssertEqual(library.nodes.map(\.id), stored.map(\.id))
        XCTAssertEqual(reversed.nodes.map(\.id), stored.reversed().map(\.id))
    }

    func testLegacyNumberMigrationUsesPageOrderAndPreservesAllContent() throws {
        let workbook = NoteNode(kind: .workbook, title: "Old workbook")
        let chapter = NoteNode(parentID: workbook.id, kind: .chapter, title: "Old chapter")
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = NoteNode(id: firstID, parentID: chapter.id, kind: .sheet, title: "First", body: "Keep my text",
                             strokes: [InkStroke(points: [InkPoint(x: 3, y: 5)])],
                             createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 900), order: 99)
        let second = NoteNode(id: secondID, parentID: chapter.id, kind: .sheet, title: "Second", isTrashed: true,
                              createdAt: first.createdAt, updatedAt: Date(timeIntervalSince1970: 200), order: 0)
        let third = NoteNode(parentID: chapter.id, kind: .sheet, title: "Third", createdAt: Date(timeIntervalSince1970: 300), order: 1)
        let old = NoteLibrary(nodes: [third, second, chapter, first, workbook], modifiedAt: Date(timeIntervalSince1970: 1000))
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryArchive.encode(old)) as? [String: Any])
        var archivedNodes = try XCTUnwrap(archive["nodes"] as? [[String: Any]])
        for index in archivedNodes.indices {
            archivedNodes[index].removeValue(forKey: "sheetNumber")
            archivedNodes[index].removeValue(forKey: "lastSheetNumber")
        }
        archive["nodes"] = archivedNodes
        let legacyBytes = try JSONSerialization.data(withJSONObject: archive)
        var migrated = try LibraryArchive.decode(legacyBytes)
        XCTAssertEqual(migrated.node(id: first.id)?.sheetNumber, 2)
        XCTAssertEqual(migrated.node(id: second.id)?.sheetNumber, 3)
        XCTAssertEqual(migrated.node(id: third.id)?.sheetNumber, 1)
        XCTAssertEqual(migrated.node(id: first.id)?.body, first.body)
        XCTAssertEqual(migrated.node(id: first.id)?.strokes, first.strokes)
        XCTAssertEqual(migrated.node(id: first.id)?.createdAt, first.createdAt)
        XCTAssertEqual(migrated.node(id: first.id)?.updatedAt, first.updatedAt)
        XCTAssertEqual(migrated.modifiedAt, old.modifiedAt)
        XCTAssertEqual(migrated.nodes.map(\.id), old.nodes.map(\.id))
        archive["nodes"] = archivedNodes.reversed().map { $0 }
        let reversed = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: archive))
        for node in migrated.nodes { XCTAssertEqual(reversed.node(id: node.id)?.sheetNumber, node.sheetNumber) }
        try migrated.restore(id: second.id)
        XCTAssertEqual(migrated.children(of: chapter.id).map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(migrated.children(of: chapter.id).compactMap(\.sheetNumber), [1, 2, 3])
        let fourth = try migrated.create(kind: .sheet, parentID: chapter.id)
        XCTAssertEqual(migrated.node(id: fourth)?.sheetNumber, 4)
        var destination = NoteLibrary()
        let importedRoots = try destination.merge(try LibraryArchive.decode(legacyBytes))
        XCTAssertEqual(destination.descendants(of: try XCTUnwrap(importedRoots.first)).filter { $0.kind == .sheet }.compactMap(\.sheetNumber).sorted(), [1, 2, 3])
    }

    func testNumberTamperingCannotPartiallyMutateLibrary() throws {
        var (library, _, _, topic, sheet) = try hierarchy()
        let before = library
        var note = try XCTUnwrap(library.node(id: sheet)); note.sheetNumber = 99
        XCTAssertThrowsError(try library.update(note))
        note = try XCTUnwrap(library.node(id: sheet)); note.createdAt = .distantPast
        XCTAssertThrowsError(try library.update(note))
        var folder = try XCTUnwrap(library.node(id: topic)); folder.lastSheetNumber = 0
        XCTAssertThrowsError(try library.update(folder))
        XCTAssertEqual(library, before)
        let duplicateNumber = NoteNode(parentID: topic, kind: .sheet, title: "Collision", sheetNumber: 1)
        XCTAssertThrowsError(try NoteLibrary(nodes: before.nodes + [duplicateNumber]).validate())
        let negativeNumber = NoteNode(parentID: topic, kind: .sheet, title: "Invalid", sheetNumber: -1)
        XCTAssertThrowsError(try NoteLibrary(nodes: before.nodes + [negativeNumber]).validate())
        for invalidDate in [Double.nan, .infinity, -.infinity] {
            for invalidCreation in [true, false] {
                var legacyNodes = before.nodes
                var badDate = NoteNode(parentID: topic, kind: .sheet, title: "Bad date")
                if invalidCreation { badDate.createdAt = Date(timeIntervalSince1970: invalidDate) }
                else { badDate.updatedAt = Date(timeIntervalSince1970: invalidDate) }
                legacyNodes.append(badDate)
                legacyNodes.append(NoteNode(parentID: topic, kind: .sheet, title: "Keep this note", createdAt: .distantPast))
                for index in legacyNodes.indices { legacyNodes[index].sheetNumber = nil; legacyNodes[index].lastSheetNumber = 0 }
                let invalid = NoteLibrary(nodes: legacyNodes)
                XCTAssertThrowsError(try invalid.validate())
                XCTAssertEqual(invalid.nodes.map(\.id), legacyNodes.map(\.id))
                XCTAssertTrue(invalid.nodes.allSatisfy { $0.sheetNumber == nil })
            }
        }
    }

    func testHistoricalMaximumCounterDoesNotBlockAvailableSheetNumbers() throws {
        let (original, _, chapter, topic, sheet) = try hierarchy()
        var nodes = original.nodes
        for index in nodes.indices where nodes[index].id == chapter || nodes[index].id == topic {
            nodes[index].lastSheetNumber = Int.max
        }
        var library = try LibraryArchive.decode(LibraryArchive.encode(NoteLibrary(nodes: nodes)))
        let created = try library.create(kind: .sheet, parentID: chapter)
        XCTAssertEqual(library.node(id: created)?.sheetNumber, 1)
        try library.move(id: sheet, to: chapter)
        XCTAssertEqual(library.node(id: sheet)?.sheetNumber, 2)
        let sourceReplacement = try library.create(kind: .sheet, parentID: topic)
        XCTAssertEqual(library.node(id: sourceReplacement)?.sheetNumber, 1)
        var movedByUpdate = try XCTUnwrap(library.node(id: sourceReplacement))
        movedByUpdate.parentID = chapter
        movedByUpdate.order = 99
        try library.update(movedByUpdate)
        XCTAssertEqual(library.node(id: sourceReplacement)?.sheetNumber, 3)
        let sourceNext = try library.create(kind: .sheet, parentID: topic)
        XCTAssertEqual(library.node(id: sourceNext)?.sheetNumber, 1)
        XCTAssertEqual(library.node(id: chapter)?.lastSheetNumber, Int.max)
        XCTAssertEqual(library.node(id: topic)?.lastSheetNumber, Int.max)
        try library.validate()
        _ = try LibraryArchive.decode(LibraryArchive.encode(library))
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
