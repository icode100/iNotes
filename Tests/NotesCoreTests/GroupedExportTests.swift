import Foundation
import NotesCore
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif

final class GroupedExportTests: XCTestCase {
    func testWorkbookPDFOrdersSectionsAndPlacesEachTopicHeadingOnce() throws {
        var book = NoteLibrary()
        let root = try book.create(kind: .workbook, title: "Compiler Design")
        let syntax = try book.create(kind: .chapter, title: "Syntax", parentID: root)
        let empty = try book.create(kind: .chapter, title: "Appendix", parentID: root)
        let discarded = try book.create(kind: .chapter, title: "Old chapter", parentID: root)
        _ = try book.create(kind: .sheet, title: "Old notes", parentID: discarded)
        try book.trash(id: discarded)
        try book.move(id: empty, to: root, at: 0)
        let parsing = try book.create(kind: .topic, title: "Parsing", parentID: syntax)
        _ = try book.create(kind: .topic, title: "Empty topic", parentID: parsing)
        let trees = try book.create(kind: .topic, title: "Trees", parentID: parsing)
        let first = try book.create(kind: .sheet, title: "First", parentID: trees)
        let second = try book.create(kind: .sheet, title: "Second", parentID: trees)
        let sibling = try book.create(kind: .topic, title: "Tables", parentID: parsing)
        let third = try book.create(kind: .sheet, title: "Third", parentID: sibling)
        let intro = try book.create(kind: .sheet, title: "Introduction", parentID: syntax)
        let snapshot = book
        let plan = try GroupedExportPlan.make(library: book, rootID: root, format: .pdf)
        let document = try XCTUnwrap(plan.documents.first)
        XCTAssertEqual(plan.documents.count, 1)
        XCTAssertEqual(plan.suggestedFilename, "Compiler Design.pdf")
        XCTAssertEqual(document.pages, [
            .cover(title: "Compiler Design"), .chapter(number: 1, title: "Appendix"), .chapter(number: 2, title: "Syntax"),
            .sheet(id: intro, topicHeadings: []), .sheet(id: first, topicHeadings: ["Parsing", "Trees"]),
            .sheet(id: second, topicHeadings: []), .sheet(id: third, topicHeadings: ["Tables"])
        ])
        XCTAssertEqual(plan.sheetCount, 4)
        XCTAssertEqual(plan.outputPageCount, 7)
        let cover = try XCTUnwrap(document.bookmarks.first)
        XCTAssertEqual(cover.pageIndex, 0)
        XCTAssertEqual(cover.children.map(\.pageIndex), [1, 2])
        let chapter = try XCTUnwrap(cover.children.last)
        XCTAssertEqual(chapter.children.map(\.pageIndex), [3, 4])
        let topic = try XCTUnwrap(chapter.children.last)
        XCTAssertEqual(topic.children.map(\.title), ["Trees", "Tables"])
        XCTAssertEqual(topic.children.map(\.pageIndex), [4, 6])
        XCTAssertEqual(topic.children.first?.children.map(\.pageIndex), [4, 5])
        XCTAssertEqual(book, snapshot)
    }

    func testEmptyWorkbookPDFHasCoverWhileEmptyTopicAndBundleRemainUnavailable() throws {
        var book = NoteLibrary()
        let root = try book.create(kind: .workbook, title: "Workbook")
        let cover = try GroupedExportPlan.make(library: book, rootID: root, format: .pdf)
        XCTAssertEqual(cover.documents.first?.pages, [.cover(title: "Workbook")])
        XCTAssertEqual(cover.sheetCount, 0)
        let chapter = try book.create(kind: .chapter, title: "Chapter", parentID: root)
        let topic = try book.create(kind: .topic, title: "Topic", parentID: chapter)
        let plan = try GroupedExportPlan.make(library: book, rootID: root, format: .pdf)
        XCTAssertEqual(plan.outputPageCount, 2)
        XCTAssertEqual(plan.documents.first?.bookmarks.first?.children.first?.children.count, 0)
        XCTAssertThrowsError(try GroupedExportPlan.make(library: book, rootID: topic, format: .pdf))
        XCTAssertThrowsError(try GroupedExportPlan.make(library: book, rootID: root, format: .zip))
    }

    func testTopicPDFIncludesOrderedPagesAndNestedBookmarks() throws {
        var book = NoteLibrary()
        let root = try book.create(kind: .workbook, title: "Notes")
        let chapter = try book.create(kind: .chapter, title: "Theory", parentID: root)
        let topic = try book.create(kind: .topic, title: "Compiler", parentID: chapter)
        let child = try book.create(kind: .topic, title: "Parsing", parentID: topic)
        let nestedPage = try book.create(kind: .sheet, title: "Tokens", parentID: child)
        let first = try book.create(kind: .sheet, parentID: topic)
        let second = try book.create(kind: .sheet, title: "Introduction", parentID: topic)
        try book.move(id: second, to: topic, at: 0)
        let trash = try book.create(kind: .sheet, parentID: topic)
        try book.trash(id: trash)
        _ = try book.create(kind: .sheet, title: "Elsewhere", parentID: chapter)
        let plan = try GroupedExportPlan.make(library: book, rootID: topic, format: .pdf)
        XCTAssertEqual(plan.suggestedFilename, "Compiler.pdf")
        XCTAssertEqual(plan.documents.count, 1)
        XCTAssertEqual(plan.documents.first?.sheetIDs, [second, first, nestedPage])
        XCTAssertEqual(plan.documents.first?.pages, [second, first, nestedPage].map { .sheet(id: $0, topicHeadings: []) })
        XCTAssertEqual(plan.sheetCount, 3)
        func flatten(_ items: [GroupedExportPlan.Bookmark]) -> [GroupedExportPlan.Bookmark] {
            items.flatMap { [$0] + flatten($0.children) }
        }
        let bookmarks = flatten(try XCTUnwrap(plan.documents.first).bookmarks)
        XCTAssertEqual(bookmarks.first { $0.pageIndex == 1 }?.title, "Page 2")
        let nested = try XCTUnwrap(bookmarks.first { $0.title == "Parsing" })
        XCTAssertEqual(nested.pageIndex, 2)
        XCTAssertEqual(nested.children.map(\.title), ["Tokens"])
    }

    func testBundleKeepsDuplicateAndUnsafeFolderTitlesDistinct() throws {
        var book = NoteLibrary()
        let root = try book.create(kind: .workbook, title: "Labs")
        let chapter = try book.create(kind: .chapter, title: "Experiments", parentID: root)
        var sheets = [try book.create(kind: .sheet, parentID: chapter)]
        for name in ["../Notes", "../notes", "Experiments.pdf", "…"] {
            let topic = try book.create(kind: .topic, title: name, parentID: chapter)
            sheets.append(try book.create(kind: .sheet, parentID: topic))
        }
        let trashed = try book.create(kind: .topic, title: "Discarded", parentID: chapter)
        _ = try book.create(kind: .sheet, parentID: trashed)
        try book.trash(id: trashed)
        let plan = try GroupedExportPlan.make(library: book, rootID: root, format: .zip)
        XCTAssertEqual(plan.format, .zip)
        XCTAssertEqual(plan.sheetCount, 5)
        XCTAssertEqual(plan.outputPageCount, 5)
        XCTAssertEqual(Set(plan.documents.flatMap(\.sheetIDs)), Set(sheets))
        let paths = plan.documents.map(\.relativePath)
        XCTAssertEqual(Set(paths.map { $0.joined(separator: "/").lowercased() }).count, 5)
        for path in paths {
            XCTAssertTrue(path.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
            XCTAssertTrue(path.last?.hasSuffix(".pdf") == true)
        }
        XCTAssertThrowsError(try GroupedExportPlan.make(library: book, rootID: trashed, format: .zip))
        XCTAssertThrowsError(try GroupedExportPlan.make(library: book, rootID: sheets[0], format: .pdf))
    }
}
