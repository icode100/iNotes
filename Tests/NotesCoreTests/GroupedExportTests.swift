import Foundation
import NotesCore
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif

final class GroupedExportTests: XCTestCase {
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
