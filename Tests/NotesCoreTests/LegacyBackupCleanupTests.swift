import Foundation
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
@testable import NotesCore

final class LegacyBackupCleanupTests: XCTestCase {
    private func fixture() throws -> (URL, Data, [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-legacy-cleanup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try LibraryArchive.encode(NoteLibrary.sample())
        let files = try (0..<5).map { index in
            try BackupArchiveWriter.write(data, to: root, date: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 60))
        }
        return (root, data, files)
    }

    func testLegacyPreviewProtectsNewestAndIgnoresUnrecognizedFiles() throws {
        let (root, data, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = files[0].deletingLastPathComponent()
        let export = directory.appendingPathComponent("My permanent export.inotes")
        try data.write(to: export)
        let bad = directory.appendingPathComponent("iNotes-2026-01-01T01-01-01Z-\(UUID().uuidString).inotes")
        try Data("damaged archive".utf8).write(to: bad)
        let link = directory.appendingPathComponent("iNotes-2025-01-01T01-01-01Z-\(UUID().uuidString).inotes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: export)
        let preview = try LegacyBackupCleanup.preview(in: root)
        XCTAssertEqual(preview.entries.count, 5)
        XCTAssertEqual(Set(preview.entries.filter { !$0.canDelete }.map(\.fileName)), Set(files.suffix(2).map(\.lastPathComponent)))
        XCTAssertEqual(preview.entries.filter(\.canDelete).count, 3)
        XCTAssertNotNil(preview.warning)
        XCTAssertEqual(try LibraryArchive.read(from: export), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testExplicitLegacyCleanupPreservesNewestManualExportsAndManagedHistory() throws {
        let (root, data, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = files[0].deletingLastPathComponent().appendingPathComponent("Permanent.inotes")
        try data.write(to: export)
        let current = try ManagedBackupWriter.write(data, to: root, ownerID: UUID())
        let preview = try LegacyBackupCleanup.preview(in: root)
        let ids = Set(preview.entries.filter(\.canDelete).map(\.id))
        let result = try LegacyBackupCleanup.remove(ids, from: preview, verifiedBackupURL: current.url)
        XCTAssertEqual(result.removedCount, 3)
        XCTAssertEqual(result.removedBytes, Int64(data.count * 3))
        XCTAssertNil(result.warning)
        XCTAssertEqual(try LegacyBackupCleanup.preview(in: root).entries.count, 2)
        XCTAssertEqual(try LibraryArchive.read(from: current.url), data)
        XCTAssertEqual(try LibraryArchive.read(from: export), data)
        for file in files.suffix(2) { XCTAssertEqual(try LibraryArchive.read(from: file), data) }
    }

    func testChangedLegacySelectionRejectsBeforeDeletingAnyFile() throws {
        let (root, data, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try ManagedBackupWriter.write(data, to: root, ownerID: UUID())
        let preview = try LegacyBackupCleanup.preview(in: root)
        let ids = Set(preview.entries.filter(\.canDelete).map(\.id))
        let changed = try LibraryArchive.encode(NoteLibrary())
        try changed.write(to: files[1], options: .atomic)
        XCTAssertThrowsError(try LegacyBackupCleanup.remove(ids, from: preview, verifiedBackupURL: current.url))
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertEqual(try LibraryArchive.read(from: files[1]), changed)
    }

    func testLegacyCleanupRequiresVerifiedCurrentBackupAndRejectsProtectedOrForgedIDs() throws {
        let (root, data, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try LegacyBackupCleanup.preview(in: root)
        let ids = Set(preview.entries.filter(\.canDelete).map(\.id))
        let missing = root.appendingPathComponent("iNotes Backups/missing.inotes")
        XCTAssertThrowsError(try LegacyBackupCleanup.remove(ids, from: preview, verifiedBackupURL: missing))
        let current = try ManagedBackupWriter.write(data, to: root, ownerID: UUID())
        XCTAssertThrowsError(try LegacyBackupCleanup.remove([files.last!.lastPathComponent], from: preview, verifiedBackupURL: current.url))
        XCTAssertThrowsError(try LegacyBackupCleanup.remove(["../Library.json"], from: preview, verifiedBackupURL: current.url))
        try Data("corrupt current backup".utf8).write(to: current.url)
        XCTAssertThrowsError(try LegacyBackupCleanup.remove(ids, from: preview, verifiedBackupURL: current.url))
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }

    func testLegacyCleanupRejectsFolderReplacementAndSymlinkedBackupFolder() throws {
        let (root, data, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try ManagedBackupWriter.write(data, to: root, ownerID: UUID())
        let preview = try LegacyBackupCleanup.preview(in: root)
        let ids = Set(preview.entries.filter(\.canDelete).map(\.id))
        let directory = files[0].deletingLastPathComponent()
        let moved = root.appendingPathComponent("Unrelated originals", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        XCTAssertThrowsError(try LegacyBackupCleanup.preview(in: root))
        XCTAssertThrowsError(try LegacyBackupCleanup.remove(ids, from: preview, verifiedBackupURL: current.url))
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(file.lastPathComponent).path)) }
    }

    func testBoundedLegacyReviewBatchesMakeProgressWithoutDroppingNewestProtection() throws {
        let (root, data, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try ManagedBackupWriter.write(data, to: root, ownerID: UUID())
        // Identical small archives exercise the production byte-budget boundary
        // without allocating hundreds of megabytes: two protected + one old copy.
        let budget = (data.count + 1) * 3
        for index in 0..<3 {
            let preview = try LegacyBackupCleanup.preview(in: root, maximumBytes: budget)
            let deletable = preview.entries.filter(\.canDelete)
            XCTAssertEqual(deletable.map(\.fileName), [files[index].lastPathComponent])
            XCTAssertEqual(Set(preview.entries.filter { !$0.canDelete }.map(\.fileName)),
                Set(files.suffix(2).map(\.lastPathComponent)))
            if index < 2 { XCTAssertNotNil(preview.warning) }
            let result = try LegacyBackupCleanup.remove(Set(deletable.map(\.id)), from: preview,
                verifiedBackupURL: current.url)
            XCTAssertEqual(result.removedCount, 1)
            XCTAssertEqual(result.removedBytes, Int64(data.count))
            XCTAssertNil(result.warning)
            for url in files.suffix(2) { XCTAssertEqual(try LibraryArchive.read(from: url), data) }
        }
        let final = try LegacyBackupCleanup.preview(in: root, maximumBytes: budget)
        XCTAssertEqual(final.entries.count, 2)
        XCTAssertTrue(final.entries.allSatisfy { !$0.canDelete })
        XCTAssertEqual(try LibraryArchive.read(from: current.url), data)
    }

    func testProtectedLegacyReplacementStopsCleanupAndReportsActualPartialCount() throws {
        let (root, data, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try ManagedBackupWriter.write(data, to: root, ownerID: UUID())
        let preview = try LegacyBackupCleanup.preview(in: root)
        let ids = Set(preview.entries.filter(\.canDelete).map(\.id))
        let replacement = try LibraryArchive.encode(NoteLibrary())
        var removalAttempts = 0
        let result = try LegacyBackupCleanup.remove(ids, from: preview, verifiedBackupURL: current.url,
            beforeRemove: { _ in
                removalAttempts += 1
                if removalAttempts == 2 {
                    try replacement.write(to: files[4], options: .atomic)
                }
            })
        XCTAssertEqual(removalAttempts, 2)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.removedBytes, Int64(data.count))
        XCTAssertNotNil(result.warning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        for url in files[1...3] { XCTAssertEqual(try LibraryArchive.read(from: url), data) }
        XCTAssertEqual(try LibraryArchive.read(from: files[4]), replacement)
        XCTAssertEqual(try LibraryArchive.read(from: current.url), data)
    }
}
