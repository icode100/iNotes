import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
@testable import NotesCore

final class LibraryRepositoryTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("Library.json") }
    private let attachmentMaximumBytes = 10 * 1024 * 1024

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

    func testAttachmentBoundedReaderAcceptsEmptyAndExactLimitFiles() throws {
        for bytes in [Data(), Data([0, 1, 127, 255]), Data(repeating: 0xA5, count: attachmentMaximumBytes)] {
            try bytes.write(to: url)
            XCTAssertEqual(try BoundedFileReader.read(from: url, maximumBytes: attachmentMaximumBytes), bytes)
        }
        try Data().write(to: url)
        XCTAssertEqual(try BoundedFileReader.read(from: url, maximumBytes: 0), Data())
    }

    func testAttachmentBoundedReaderRejectsDenseAndSparseOversizeBeforeReading() throws {
        try Data(repeating: 0xA5, count: attachmentMaximumBytes + 1).write(to: url)
        for sparse in [false, true] {
            if sparse {
                let writer = try FileHandle(forWritingTo: url)
                try writer.truncate(atOffset: UInt64(attachmentMaximumBytes) * 100)
                try writer.close()
            }
            var reads = 0
            XCTAssertThrowsError(try BoundedFileReader.read(from: url, maximumBytes: attachmentMaximumBytes) { handle, count in
                reads += 1
                return try handle.read(upToCount: count)
            }) { XCTAssertEqual($0 as? LibraryError, .tooLarge) }
            XCTAssertEqual(reads, 0)
        }
    }

    func testAttachmentBoundedReaderStopsAtLimitPlusOneAfterAppend() throws {
        try Data([0, 1, 2]).write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        var bytesRead = 0
        var requests: [Int] = []
        XCTAssertThrowsError(try BoundedFileReader.read(from: url, maximumBytes: attachmentMaximumBytes) { handle, count in
            requests.append(count)
            let chunk = try handle.read(upToCount: count)
            bytesRead += chunk?.count ?? 0
            if requests.count == 1 {
                try writer.seekToEnd()
                try writer.write(contentsOf: Data(repeating: 0xA5, count: self.attachmentMaximumBytes))
            }
            return chunk
        }) { XCTAssertEqual($0 as? LibraryError, .tooLarge) }
        XCTAssertEqual(bytesRead, attachmentMaximumBytes + 1)
        XCTAssertTrue(requests.allSatisfy { $0 > 0 && $0 <= 64 * 1024 })
    }

    func testAttachmentBoundedReaderStopsAtLimitPlusOneAfterSparseGrowth() throws {
        try Data([0, 1, 2]).write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        var bytesRead = 0
        var reads = 0
        XCTAssertThrowsError(try BoundedFileReader.read(from: url, maximumBytes: attachmentMaximumBytes) { handle, count in
            reads += 1
            let chunk = try handle.read(upToCount: count)
            bytesRead += chunk?.count ?? 0
            if reads == 1 {
                try writer.truncate(atOffset: UInt64(self.attachmentMaximumBytes) * 100)
            }
            return chunk
        }) { XCTAssertEqual($0 as? LibraryError, .tooLarge) }
        XCTAssertEqual(bytesRead, attachmentMaximumBytes + 1)
    }

    func testBoundedReaderContinuesAfterShortReadsAndDetectsGrowth() throws {
        let bytes = Data(0..<31)
        try bytes.write(to: url)
        XCTAssertEqual(try BoundedFileReader.read(from: url, maximumBytes: bytes.count) { handle, count in
            try handle.read(upToCount: min(count, 3))
        }, bytes)

        try Data([0, 1]).write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        var bytesRead = 0
        var reads = 0
        XCTAssertThrowsError(try BoundedFileReader.read(from: url, maximumBytes: bytes.count) { handle, count in
            reads += 1
            let chunk = try handle.read(upToCount: min(count, 3))
            bytesRead += chunk?.count ?? 0
            if reads == 1 {
                try writer.seekToEnd()
                try writer.write(contentsOf: bytes)
            }
            return chunk
        }) { XCTAssertEqual($0 as? LibraryError, .tooLarge) }
        XCTAssertEqual(bytesRead, bytes.count + 1)
    }

    func testBoundedReaderKeepsOpenedFileWhenPathIsReplaced() throws {
        let bytes = Data(repeating: 0xA5, count: 128 * 1024)
        try bytes.write(to: url)
        var reads = 0
        let actual = try BoundedFileReader.read(from: url, maximumBytes: attachmentMaximumBytes) { handle, count in
            reads += 1
            let chunk = try handle.read(upToCount: count)
            if reads == 1 {
                try FileManager.default.removeItem(at: self.url)
                try Data().write(to: self.url)
                let replacement = try FileHandle(forWritingTo: self.url)
                try replacement.truncate(atOffset: UInt64(self.attachmentMaximumBytes + 1))
                try replacement.close()
            }
            return chunk
        }
        XCTAssertEqual(actual, bytes)
        XCTAssertThrowsError(try BoundedFileReader.read(from: url, maximumBytes: attachmentMaximumBytes)) {
            XCTAssertEqual($0 as? LibraryError, .tooLarge)
        }
    }

    func testBoundedReaderRejectsNonregularFilesAndAcceptsRegularSymlinks() throws {
        XCTAssertThrowsError(try BoundedFileReader.read(from: directory, maximumBytes: attachmentMaximumBytes)) {
            XCTAssertEqual($0 as? LibraryError, .invalidData("Choose a regular file."))
        }
        #if canImport(Darwin) || canImport(Glibc)
        let fifo = directory.appendingPathComponent("input.pipe")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try BoundedFileReader.read(from: fifo, maximumBytes: attachmentMaximumBytes)) {
            XCTAssertEqual($0 as? LibraryError, .invalidData("Choose a regular file."))
        }
        #endif
        let bytes = Data([0, 1, 127, 255])
        try bytes.write(to: url)
        let link = directory.appendingPathComponent("attachment-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertEqual(try BoundedFileReader.read(from: link, maximumBytes: attachmentMaximumBytes), bytes)
    }

    func testArchiveReadPreservesAttachmentsLargerThanPickerLimit() throws {
        var library = NoteLibrary.sample()
        var sheet = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
        let attachment = NoteAttachment(filename: "large.bin", mediaType: "application/octet-stream",
                                        data: Data(repeating: 0xA5, count: attachmentMaximumBytes + 1))
        sheet.attachments.append(attachment)
        try library.update(sheet)
        try LibraryArchive.encode(library).write(to: url)
        let imported = try LibraryArchive.decode(LibraryArchive.read(from: url))
        XCTAssertEqual(imported.node(id: sheet.id)?.attachments, [attachment])
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
