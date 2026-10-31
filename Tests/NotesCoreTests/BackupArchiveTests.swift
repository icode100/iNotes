import Foundation
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
@testable import NotesCore

final class BackupArchiveTests: XCTestCase {
    func testTwoDestinationsKeepIndependentCompleteArchives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-backups-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let google = root.appendingPathComponent("Google", isDirectory: true)
        let cloud = root.appendingPathComponent("iCloud", isDirectory: true)
        try FileManager.default.createDirectory(at: google, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        var library = NoteLibrary.sample()
        let sheet = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
        var written = sheet
        written.body = "नमस्ते — handwritten notes"
        written.pencilKitData = Data([1, 3, 5, 7])
        written.strokes = [InkStroke(points: [InkPoint(x: 4, y: 7), InkPoint(x: 28, y: 31)], colorHex: "#3869B2", style: .pencil)]
        written.textBoxes = [PageTextBox(x: 90, y: 140, text: "Movable text")]
        written.equations = [NoteEquation(latex: "E=mc^2")]
        try library.update(written)
        let archive = try LibraryArchive.encode(library)
        let archivedLibrary = try LibraryArchive.decode(archive)
        let first = try BackupArchiveWriter.write(archive, to: google)
        let second = try BackupArchiveWriter.write(archive, to: cloud)
        XCTAssertEqual(try Data(contentsOf: first), archive)
        XCTAssertEqual(try Data(contentsOf: second), archive)
        XCTAssertEqual(try LibraryArchive.decode(LibraryArchive.read(from: first)), archivedLibrary)
        XCTAssertEqual(try LibraryArchive.decode(LibraryArchive.read(from: second)), archivedLibrary)
        XCTAssertNotEqual(BackupDestination.googleDrive.bookmarkKey, BackupDestination.iCloudDrive.bookmarkKey)
        XCTAssertNotEqual(BackupDestination.googleDrive.lastBackupKey, BackupDestination.iCloudDrive.lastBackupKey)
    }

    func testVersionedWritesNeverReplaceAnExistingBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-versions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = try LibraryArchive.encode(NoteLibrary.sample())
        let date = Date(timeIntervalSince1970: 1000)
        let id = UUID()
        let first = try BackupArchiveWriter.write(archive, to: root, date: date, id: id)
        XCTAssertThrowsError(try BackupArchiveWriter.write(archive, to: root, date: date, id: id))
        XCTAssertEqual(try Data(contentsOf: first), archive)
        let next = try BackupArchiveWriter.write(archive, to: root, date: date)
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: first.deletingLastPathComponent(), includingPropertiesForKeys: nil).count, 2)
    }

    func testUnavailableDestinationAndInvalidArchivePreserveLocalData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-failed-backup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = try LibraryArchive.encode(NoteLibrary.sample())
        let local = root.appendingPathComponent("Library.json")
        try archive.write(to: local)
        XCTAssertThrowsError(try BackupArchiveWriter.write(archive, to: root.appendingPathComponent("Missing")))
        XCTAssertThrowsError(try BackupArchiveWriter.write(archive, to: local))
        XCTAssertThrowsError(try BackupArchiveWriter.write(Data("broken".utf8), to: root))
        XCTAssertEqual(try Data(contentsOf: local), archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("iNotes Backups").path))
    }

    func testScheduleThrottlesTargetsAndRetriesIndependently() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(BackupSchedule.delay(now: now, lastSuccess: nil, retryAfter: nil), 0)
        XCTAssertEqual(BackupSchedule.delay(now: now, lastSuccess: now.addingTimeInterval(-15), retryAfter: nil), 45)
        XCTAssertEqual(BackupSchedule.delay(now: now, lastSuccess: now.addingTimeInterval(-120), retryAfter: now.addingTimeInterval(60)), 60)
        XCTAssertEqual(BackupSchedule.delay(now: now, lastSuccess: now.addingTimeInterval(-120), retryAfter: now.addingTimeInterval(-1)), 0)
    }
}
