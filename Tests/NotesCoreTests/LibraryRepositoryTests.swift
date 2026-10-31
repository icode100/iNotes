import Foundation
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
@testable import NotesCore

final class LibraryRepositoryTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("Library.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testNewRepositorySaveReopenAndBackupKeepsPreviousVersion() throws {
        let repository = LibraryRepository(url: url)
        XCTAssertNil(try repository.load())
        var library = NoteLibrary.sample()
        try repository.save(library)
        let initialBytes = try Data(contentsOf: url)
        let first = library.roots[0].id
        try library.rename(id: first, title: "Edited workbook")
        try repository.save(library)
        XCTAssertEqual(try Data(contentsOf: repository.backupURL), initialBytes)
        let reopened = try XCTUnwrap(LibraryRepository(url: url).load())
        XCTAssertEqual(reopened.node(id: first)?.title, "Edited workbook")
        // Saving unchanged content must not replace the recovery copy with identical current bytes.
        try repository.save(library)
        XCTAssertEqual(try Data(contentsOf: repository.backupURL), initialBytes)
    }

    func testExternalModificationRefusesOverwriteAndPreservesBothVersions() throws {
        let first = LibraryRepository(url: url)
        var library = NoteLibrary.sample()
        try first.save(library)
        let second = LibraryRepository(url: url)
        var external = try XCTUnwrap(second.load())
        try external.rename(id: external.roots[0].id, title: "Other window")
        try second.save(external)
        let externalBytes = try Data(contentsOf: url)
        try library.rename(id: library.roots[0].id, title: "My pending edit")
        XCTAssertThrowsError(try first.save(library)) { error in
            guard case RepositoryError.externalModification = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), externalBytes)
        XCTAssertEqual(library.roots[0].title, "My pending edit")
    }

    func testExternalDeletionAndUnexpectedExistingFileRefuseOverwrite() throws {
        let repository = LibraryRepository(url: url)
        let library = NoteLibrary.sample()
        try repository.save(library)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try repository.save(library))
        try Data("other data".utf8).write(to: url)
        XCTAssertThrowsError(try LibraryRepository(url: url).save(library))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "other data")
    }

    func testCorruptLibraryIsPreservedAndSavesAreBlockedUntilExplicitRecovery() throws {
        let originalRepository = LibraryRepository(url: url)
        var library = NoteLibrary.sample()
        try originalRepository.save(library)
        try library.rename(id: library.roots[0].id, title: "Second version")
        try originalRepository.save(library)
        let badBytes = Data("{broken json — preserve me}".utf8)
        try badBytes.write(to: url)
        let repository = LibraryRepository(url: url)
        XCTAssertThrowsError(try repository.load())
        XCTAssertThrowsError(try repository.save(NoteLibrary()))
        XCTAssertEqual(try Data(contentsOf: url), badBytes)
        let preview = try repository.recoverBackup()
        XCTAssertEqual(preview.roots[0].title, "My Notebook")
        XCTAssertEqual(try Data(contentsOf: url), badBytes)
        let recovered = try repository.restoreFromBackup()
        XCTAssertEqual(recovered.roots[0].title, "My Notebook")
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Library-damaged-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), badBytes)
        try repository.save(recovered)
        XCTAssertNotNil(try LibraryRepository(url: url).load())
    }

    func testRecoveryWithoutBackupDoesNotModifyPrimary() throws {
        let bytes = Data("bad".utf8)
        try bytes.write(to: url)
        let repository = LibraryRepository(url: url)
        XCTAssertThrowsError(try repository.load())
        XCTAssertThrowsError(try repository.restoreFromBackup())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testBoundedReaderRejectsOversizedSparseFileBeforeLoading() throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(LibraryArchive.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try LibraryArchive.read(from: url)) { XCTAssertEqual($0 as? LibraryError, .tooLarge) }
        XCTAssertThrowsError(try LibraryRepository(url: url).load())
    }

    func testArchiveImportAndExportIntegration() throws {
        let origin = NoteLibrary.sample()
        let exported = directory.appendingPathComponent("backup.inotes")
        try LibraryArchive.encode(origin).write(to: exported, options: .atomic)
        let incoming = try LibraryArchive.decode(LibraryArchive.read(from: exported))
        var destination = NoteLibrary.sample()
        try destination.merge(incoming)
        let repository = LibraryRepository(url: url)
        try repository.save(destination)
        let reloaded = try XCTUnwrap(LibraryRepository(url: url).load())
        XCTAssertEqual(reloaded.roots.count, 2)
        XCTAssertEqual(reloaded.nodes.filter { $0.kind == .sheet }.count, 2)
        XCTAssertEqual(Set(reloaded.nodes.map(\.id)).count, reloaded.nodes.count)
    }
}
