#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
import Foundation
@testable import NotesCore

final class PageImageTests: XCTestCase {
    private var png: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    }

    private func fixture() throws -> (NoteLibrary, UUID) {
        var library = NoteLibrary.sample()
        var sheet = library.nodes.first { $0.kind == .sheet }!
        sheet.pageContent = PageContent(text: "An annotated image — 日本語",
            strokes: [InkStroke(points: [InkPoint(x: 50, y: 60), InkPoint(x: 90, y: 80)])],
            textBoxes: [PageTextBox(x: 60, y: 70, text: "Caption")],
            equations: [NoteEquation(latex: "x^2")],
            images: [PageImage(x: 40, y: 50, width: 200, height: 100, imageData: png)])
        try library.update(sheet)
        return (library, sheet.id)
    }

    func testImageArchiveSaveDuplicateAndImportPreserveAnnotatedPage() throws {
        var (library, id) = try fixture()
        let original = try XCTUnwrap(library.node(id: id))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-images-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LibraryRepository(url: directory.appendingPathComponent("Library.json"))
        try repository.save(library)
        let saved = try XCTUnwrap(repository.load())
        XCTAssertEqual(saved.formatVersion, 3)
        XCTAssertEqual(saved.node(id: id)?.pageContent, original.pageContent)
        XCTAssertEqual(try XCTUnwrap(saved.node(id: id)).createdAt.timeIntervalSince1970,
                       original.createdAt.timeIntervalSince1970, accuracy: 0.000_001)
        let duplicateID = try library.duplicate(id: id)
        XCTAssertNotEqual(duplicateID, id)
        XCTAssertEqual(library.node(id: duplicateID)?.pageContent, original.pageContent)
        var destination = NoteLibrary.sample()
        let previous = destination.nodes
        let roots = try destination.merge(saved)
        XCTAssertEqual(destination.formatVersion, 3)
        XCTAssertTrue(roots.allSatisfy { !saved.nodes.map(\.id).contains($0) })
        XCTAssertEqual(Array(destination.nodes.prefix(previous.count)), previous)
        XCTAssertEqual(destination.nodes.last?.pageContent, original.pageContent)
    }

    func testLegacyArchivesSnapshotsAndClipboardDefaultImagesAndPromoteOnlyWhenNeeded() throws {
        for version in [1, 2] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryArchive.encode(NoteLibrary.sample())) as? [String: Any])
            object["formatVersion"] = version
            var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
            for index in nodes.indices { nodes[index].removeValue(forKey: "images") }
            object["nodes"] = nodes
            var legacy = try LibraryArchive.decode(JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(legacy.formatVersion, version)
            XCTAssertTrue(legacy.nodes.allSatisfy { $0.images.isEmpty })
            var sheet = try XCTUnwrap(legacy.nodes.first { $0.kind == .sheet })
            let created = sheet.createdAt, number = sheet.sheetNumber
            sheet.textBoxes = [PageTextBox(text: "Positioned")]
            try legacy.update(sheet)
            XCTAssertEqual(legacy.formatVersion, 2)
            sheet = try XCTUnwrap(legacy.node(id: sheet.id))
            sheet.images = [PageImage(imageData: png)]
            try legacy.update(sheet)
            XCTAssertEqual(legacy.formatVersion, 3)
            XCTAssertEqual(legacy.node(id: sheet.id)?.createdAt, created)
            XCTAssertEqual(legacy.node(id: sheet.id)?.sheetNumber, number)
            sheet.images = []
            try legacy.update(sheet)
            XCTAssertEqual(legacy.formatVersion, 3)
        }
        let oldSnapshot = Data("{\"text\":\"Legacy\",\"strokes\":[],\"textBoxes\":[],\"equations\":[]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(PageContent.self, from: oldSnapshot).images, [])
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(oldSnapshot).images, [])
    }

    func testImageGeometryAndIDsRejectAtomicallyAcrossArchiveAndClipboard() throws {
        let base = NoteLibrary.sample()
        let original = try XCTUnwrap(base.nodes.first { $0.kind == .sheet })
        let valid = PageImage(imageData: png)
        var invalidImages: [[PageImage]] = [[valid, valid]]
        for value in [-1.0, 100_001, .infinity, .nan] {
            var image = valid; image.x = value; invalidImages.append([image])
            image = valid; image.y = value; invalidImages.append([image])
        }
        for value in [0.0, -1, 10_001, .infinity, .nan] {
            var image = valid; image.width = value; invalidImages.append([image])
            image = valid; image.height = value; invalidImages.append([image])
        }
        invalidImages.append((0...PageImageLimits.maximumImagesPerPage).map { _ in PageImage(imageData: png) })
        for images in invalidImages {
            var library = base, invalid = original
            invalid.images = images
            XCTAssertThrowsError(try library.update(invalid))
            XCTAssertEqual(library, base)
            // Encoder rejects nonfinite geometry before archive decode; both paths
            // must refuse the candidate and never replace the valid library.
            let nodes = base.nodes.map { $0.id == invalid.id ? invalid : $0 }
            XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: nodes, formatVersion: 3)))
            XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(PageClipboardPayload(images: images))))
        }
    }

    func testImageBytePixelAndContainerLimitsRejectBeforeRendering() throws {
        var invalidData = [Data(), Data("not a PNG".utf8), Data(png.dropLast()),
                           Data(repeating: 0, count: PageImageLimits.maximumBytes + 1)]
        for (width, height) in [(0, 1), (8_193, 1), (1, 8_193), (4_001, 4_000), (Int(UInt32.max), 1)] {
            invalidData.append(declaredPNG(width: width, height: height))
        }
        var extra = png; extra.append(0); invalidData.append(extra)
        var invalidChunk = png; invalidChunk.replaceSubrange(33..<37, with: [255, 255, 255, 255]); invalidData.append(invalidChunk)
        var animation = png; animation.replaceSubrange(37..<41, with: Array("acTL".utf8)); invalidData.append(animation)
        for data in invalidData {
            XCTAssertThrowsError(try PageImageLimits.pngDimensions(data))
            XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(PageClipboardPayload(images: [PageImage(imageData: data)]))))
        }
        let size = try PageImageLimits.pngDimensions(png)
        XCTAssertEqual(size.width, 1)
        XCTAssertEqual(size.height, 1)
        let large = declaredPNG(width: 4_000, height: 4_000)
        try PageImageLimits.validate((0..<4).map { _ in PageImage(imageData: large) })
        XCTAssertThrowsError(try PageImageLimits.validate((0..<5).map { _ in PageImage(imageData: large) }))
        try PageImageLimits.validate([PageImage(x: 100_000, y: 100_000, width: 1, height: 10_000, imageData: png)])
    }

    func testImagesRequireVersionThreeAndMixedClipboardRetainsBytes() throws {
        let (library, id) = try fixture()
        let content = try XCTUnwrap(library.node(id: id)).pageContent
        for version in [1, 2] {
            XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: library.nodes, formatVersion: version)))
        }
        XCTAssertThrowsError(try LibraryArchive.encode(NoteLibrary(nodes: library.nodes, formatVersion: 4)))
        XCTAssertEqual(try JSONDecoder().decode(PageContent.self, from: JSONEncoder().encode(content)), content)
        let payload = PageClipboardPayload(text: content.text, rtfData: content.rtfData, strokes: content.strokes,
            pencilKitData: content.pencilKitData, textBoxes: content.textBoxes, equations: content.equations, images: content.images)
        XCTAssertEqual(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(payload)), payload)
        XCTAssertNotEqual(PageClipboardPayload.pasteboardType, PageClipboardPayload.legacyPasteboardType)
        var note = NoteNode(kind: .sheet, title: "Snapshot restore")
        note.pageContent = content
        XCTAssertEqual(note.images, content.images)
        XCTAssertEqual(note.pageContent, content)
    }

    func testImageAggregateArchiveLimitRejectsDuplicateAndImportAtomically() throws {
        // Bounded ancillary bytes keep this fixture's decoded image at one pixel,
        // while exercising the real JSON/base64 archive budget rather than an estimate.
        var padded = png
        let length = 7 * 1_024 * 1_024
        var chunk = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
                          UInt8((length >> 8) & 255), UInt8(length & 255)])
        chunk.append(contentsOf: Array("tEXt".utf8))
        chunk.append(Data(repeating: 0, count: length + 4))
        padded.insert(contentsOf: chunk, at: padded.count - 12)
        var library = NoteLibrary.sample()
        var sheet = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
        sheet.images = (0..<4).map { _ in PageImage(imageData: padded) }
        try library.update(sheet)
        XCTAssertLessThan(try LibraryArchive.encode(library).count, LibraryArchive.maximumBytes)
        let page = PageClipboardPayload(images: sheet.images)
        try page.validatePageContent()
        XCTAssertThrowsError(try PageClipboardPayload.decodeValidated(JSONEncoder().encode(page)))
        let oversizedPage = PageClipboardPayload(images: (0..<8).map { _ in PageImage(imageData: padded) })
        XCTAssertThrowsError(try oversizedPage.validatePageContent())
        let previous = library
        XCTAssertThrowsError(try library.duplicate(id: sheet.id))
        XCTAssertEqual(library, previous)
        XCTAssertThrowsError(try library.merge(previous))
        XCTAssertEqual(library, previous)
        var invalid = sheet
        invalid.images[0].imageData = Data("bad PNG".utf8)
        let invalidNodes = previous.nodes.map { $0.id == sheet.id ? invalid : $0 }
        XCTAssertThrowsError(try library.merge(NoteLibrary(nodes: invalidNodes, formatVersion: 3)))
        XCTAssertEqual(library, previous)
    }

    // A PNG container with synthetic IHDR dimensions. This tests portable bounds;
    // native decoder tests separately verify the compressed pixels themselves.
    private func declaredPNG(width: Int, height: Int) -> Data {
        var data = png
        for (offset, number) in [(16, width), (20, height)] {
            data.replaceSubrange(offset..<(offset + 4), with: [
                UInt8((number >> 24) & 255), UInt8((number >> 16) & 255),
                UInt8((number >> 8) & 255), UInt8(number & 255)
            ])
        }
        return data
    }
}
