import Foundation
#if !INOTES_STANDALONE_TESTS
import XCTest
#endif
@testable import NotesCore

final class BackupRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_620_800) // 2026-11-02 12:00 UTC.

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-retention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func archive(_ revision: Int) throws -> Data {
        var library = NoteLibrary.sample()
        var sheet = try XCTUnwrap(library.nodes.first { $0.kind == .sheet })
        sheet.body = "Recovery revision \(revision) — नमस्ते"
        sheet.strokes = [InkStroke(points: [InkPoint(x: 4, y: 7), InkPoint(x: 28, y: 31)], colorHex: "#3869B2", style: .pencil)]
        sheet.textBoxes = [PageTextBox(x: 90, y: 140, text: "Keep annotations")]
        sheet.equations = [NoteEquation(latex: "E=mc^2")]
        try library.update(sheet)
        return try LibraryArchive.encode(library)
    }

    private func managedDirectory(_ root: URL, owner: UUID) -> URL {
        root.appendingPathComponent("iNotes Backups", isDirectory: true)
            .appendingPathComponent("Automatic-\(owner.uuidString)", isDirectory: true)
    }

    private func files(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testRetentionPlannerKeepsRecentDailyAndWeeklyRecoveryPoints() {
        var entries: [BackupRetentionEntry] = []
        for index in 0..<12 {
            entries.append(BackupRetentionEntry(name: "recent-\(index)",
                date: now.addingTimeInterval(-Double(index) * 60), byteCount: 1024))
        }
        for day in 1...35 {
            let date = now.addingTimeInterval(-Double(day) * 86_400)
            entries.append(BackupRetentionEntry(name: "day-\(day)-new", date: date, byteCount: 1024))
            entries.append(BackupRetentionEntry(name: "day-\(day)-old", date: date.addingTimeInterval(-60), byteCount: 1024))
        }
        let kept = BackupRetentionPolicy().retainedNames(in: Array(entries.reversed()), now: now)
        var expected = Set((0..<5).map { "recent-\($0)" })
        expected.formUnion((1...6).map { "day-\($0)-new" })
        // The first six daily points already include the previous ISO week.
        // Sunday 25 October and Sunday 18 October are the newest available
        // snapshots in the two older weeks.
        expected.formUnion(["day-8-new", "day-15-new"])
        XCTAssertEqual(kept, expected)
        XCTAssertTrue(kept.count <= 16)
    }

    func testRetentionPlannerUsesUTCDayAndISOWeekBoundaries() {
        let at = ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")!
        func entry(_ name: String, _ stamp: String) -> BackupRetentionEntry {
            BackupRetentionEntry(name: name, date: ISO8601DateFormatter().date(from: stamp)!, byteCount: 1)
        }
        let daily = [
            entry("newest", "2026-11-02T00:00:00Z"),
            entry("recent", "2026-11-01T23:59:59Z"),
            entry("daily-edge", "2026-10-27T00:00:00Z"),
            entry("daily-expired", "2026-10-26T23:59:59Z")
        ]
        let dayPolicy = BackupRetentionPolicy(recentCount: 2, dailyDays: 7, weeklyWeeks: 0)
        XCTAssertEqual(dayPolicy.retainedNames(in: daily, now: at), Set(["newest", "recent", "daily-edge"]))
        let weekly = [
            entry("newest", "2026-11-02T00:00:00Z"),
            entry("recent", "2026-11-01T23:59:59Z"),
            entry("weekly-edge", "2026-10-12T00:00:00Z"),
            entry("weekly-expired", "2026-10-11T23:59:59Z")
        ]
        let weekPolicy = BackupRetentionPolicy(recentCount: 2, dailyDays: 0, weeklyWeeks: 4)
        XCTAssertEqual(weekPolicy.retainedNames(in: weekly, now: at), Set(["newest", "recent", "weekly-edge"]))
    }

    func testRetentionBudgetTrimsOlderPointsButPreservesTwoNewest() {
        let entries = (0..<8).map {
            BackupRetentionEntry(name: "copy-\($0)", date: now.addingTimeInterval(-Double($0) * 60),
                byteCount: 20 * 1024 * 1024)
        }
        let limited = BackupRetentionPolicy(maximumBytes: 50 * 1024 * 1024)
        XCTAssertEqual(limited.retainedNames(in: entries, now: now), Set(["copy-0", "copy-1"]))
        let impossible = BackupRetentionPolicy(maximumBytes: 1)
        XCTAssertEqual(impossible.retainedNames(in: entries, now: now), Set(["copy-0", "copy-1"]))
        let old = entries.map { BackupRetentionEntry(name: $0.name,
            date: $0.date.addingTimeInterval(-365 * 86_400), byteCount: $0.byteCount) }
        XCTAssertEqual(BackupRetentionPolicy().retainedNames(in: old, now: now), Set((0..<5).map { "copy-\($0)" }))
    }

    func testRetentionPlannerIsStableForDateTiesAndRejectsMalformedMetadata() {
        let entries = ["a", "b", "c", "d", "e", "f"].map {
            BackupRetentionEntry(name: $0, date: now, byteCount: 1)
        }
        let policy = BackupRetentionPolicy(recentCount: 2, dailyDays: 0, weeklyWeeks: 0)
        XCTAssertEqual(policy.retainedNames(in: entries, now: now), Set(["e", "f"]))
        XCTAssertEqual(policy.retainedNames(in: Array(entries.reversed()), now: now), Set(["e", "f"]))
        let malformed = [
            BackupRetentionEntry(name: "bad-date", date: Date(timeIntervalSince1970: .nan), byteCount: 1),
            BackupRetentionEntry(name: "bad-size", date: now.addingTimeInterval(1), byteCount: -1)
        ]
        XCTAssertEqual(policy.retainedNames(in: entries + malformed, now: now), Set(["e", "f"]))
    }

    func testFrequentManagedBackupsRetainFiveCompleteRecentCopies() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        var snapshots: [(URL, Data)] = []
        var removed = 0
        for index in 0..<12 {
            let data = try archive(index)
            let result = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60))
            XCTAssertTrue(result.didWrite)
            XCTAssertNil(result.cleanupWarning)
            snapshots.append((result.url, data))
            removed += result.removedCount
        }
        XCTAssertEqual(removed, 7)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 5)
        for (url, _) in snapshots.prefix(7) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        for (url, data) in snapshots.suffix(5) {
            XCTAssertEqual(try LibraryArchive.read(from: url), data)
            XCTAssertEqual(try LibraryArchive.decode(LibraryArchive.read(from: url)), try LibraryArchive.decode(data))
        }
    }

    func testIdenticalManagedBackupIsSkippedAcrossSeparateCalls() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), data = try archive(1)
        let first = try ManagedBackupWriter.write(data, to: root, ownerID: owner, date: now)
        let duplicate = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
            date: now.addingTimeInterval(3 * 86_400))
        XCTAssertTrue(first.didWrite)
        XCTAssertFalse(duplicate.didWrite)
        XCTAssertEqual(duplicate.url, first.url)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 1)
        XCTAssertEqual(try LibraryArchive.read(from: duplicate.url), data)
        let changed = try ManagedBackupWriter.write(archive(2), to: root, ownerID: owner,
            date: now.addingTimeInterval(3 * 86_400 + 60))
        XCTAssertTrue(changed.didWrite)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 2)
    }

    func testRetentionPreservesOtherOwnersLegacyExportsAndUnrecognizedFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), foreignOwner = UUID(), original = try archive(0)
        let legacy = try BackupArchiveWriter.write(original, to: root, date: now.addingTimeInterval(-90 * 86_400))
        let foreign = try ManagedBackupWriter.write(original, to: root, ownerID: foreignOwner,
            date: now.addingTimeInterval(-90 * 86_400))
        _ = try ManagedBackupWriter.write(original, to: root, ownerID: owner, date: now)
        let unknown = managedDirectory(root, owner: owner).appendingPathComponent("Keep this manual export.inotes")
        try original.write(to: unknown)
        let unexpected = managedDirectory(root, owner: owner).appendingPathComponent("readme.txt")
        try Data("User-owned document".utf8).write(to: unexpected)
        for index in 1...10 {
            _ = try ManagedBackupWriter.write(archive(index), to: root, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60))
        }
        XCTAssertEqual(try LibraryArchive.read(from: legacy), original)
        XCTAssertEqual(try LibraryArchive.read(from: foreign.url), original)
        XCTAssertEqual(try LibraryArchive.read(from: unknown), original)
        XCTAssertEqual(try Data(contentsOf: unexpected), Data("User-owned document".utf8))
        XCTAssertEqual(try files(managedDirectory(root, owner: foreignOwner)).count, 1)
    }

    func testMultibyteLookalikeFilenameIsPreservedWithoutInterruptingBackups() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), original = try archive(0)
        _ = try ManagedBackupWriter.write(original, to: root, ownerID: owner, date: now)
        // This matches a legacy filename's byte length, but has far fewer Swift
        // Characters. Parsing it as fixed-width text must not index past its end.
        let name = "iNotes-" + String(repeating: "😀", count: 14) + "A.inotes"
        XCTAssertEqual(name.utf8.count, 71)
        let unexpected = managedDirectory(root, owner: owner).appendingPathComponent(name)
        try original.write(to: unexpected)
        for index in 1...7 {
            let data = try archive(index)
            let result = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60))
            XCTAssertTrue(result.didWrite)
            XCTAssertNotNil(result.cleanupWarning)
            XCTAssertEqual(try LibraryArchive.read(from: result.url), data)
        }
        XCTAssertEqual(try LibraryArchive.read(from: unexpected), original)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 6)
    }

    func testFailedManagedWritePreservesAllExistingRecoveryCopies() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), original = try archive(0)
        var saved: [URL] = []
        for index in 0..<5 {
            let result = try ManagedBackupWriter.write(archive(index), to: root, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60))
            saved.append(result.url)
        }
        let before = try saved.map { try LibraryArchive.read(from: $0) }
        XCTAssertThrowsError(try ManagedBackupWriter.write(Data("corrupt input".utf8), to: root,
            ownerID: owner, date: now.addingTimeInterval(1000)))
        XCTAssertEqual(try saved.map { try LibraryArchive.read(from: $0) }, before)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 5)
        XCTAssertThrowsError(try ManagedBackupWriter.write(original, to: root.appendingPathComponent("Missing"), ownerID: owner))
        let ordinaryFile = root.appendingPathComponent("Not a folder")
        try original.write(to: ordinaryFile)
        XCTAssertThrowsError(try ManagedBackupWriter.write(original, to: ordinaryFile, ownerID: owner))
        XCTAssertEqual(try Data(contentsOf: ordinaryFile), original)
    }

    func testManagedNameCollisionNeverReplacesSavedContents() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), id = UUID(), data = try archive(0)
        let first = try ManagedBackupWriter.write(data, to: root, ownerID: owner, date: now, id: id)
        let changed = try archive(1)
        let second = try ManagedBackupWriter.write(changed, to: root, ownerID: owner, date: now, id: id)
        XCTAssertTrue(second.didWrite)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try LibraryArchive.read(from: first.url), data)
        XCTAssertEqual(try LibraryArchive.read(from: second.url), changed)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 2)
    }

    func testRapidAndBackwardClockWritesProtectTheActualLatestCopies() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), id = UUID()
        var snapshots: [(URL, Data)] = []
        for index in 0..<12 {
            let data = try archive(index)
            let result = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
                date: index < 8 ? now : now.addingTimeInterval(-86_400), id: id)
            snapshots.append((result.url, data))
        }
        XCTAssertEqual(Set(snapshots.map { $0.0 }).count, 12)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 5)
        for (url, _) in snapshots.prefix(7) { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        for (url, data) in snapshots.suffix(5) { XCTAssertEqual(try LibraryArchive.read(from: url), data) }
        let latest = snapshots.last!
        let duplicate = try ManagedBackupWriter.write(latest.1, to: root, ownerID: owner,
            date: now.addingTimeInterval(-86_400), id: id)
        XCTAssertFalse(duplicate.didWrite)
        XCTAssertEqual(duplicate.url, latest.0)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 5)
    }

    func testDestinationsRetainAndDeduplicateIndependently() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let google = root.appendingPathComponent("Google", isDirectory: true)
        let cloud = root.appendingPathComponent("iCloud", isDirectory: true)
        try FileManager.default.createDirectory(at: google, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let owner = UUID(), original = try archive(0)
        let initial = try ManagedBackupWriter.write(original, to: cloud, ownerID: owner, date: now)
        var latest = original
        for index in 0..<9 {
            latest = try archive(index)
            _ = try ManagedBackupWriter.write(latest, to: google, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60))
        }
        XCTAssertEqual(try files(managedDirectory(google, owner: owner)).count, 5)
        XCTAssertEqual(try files(managedDirectory(cloud, owner: owner)).count, 1)
        XCTAssertEqual(try LibraryArchive.read(from: initial.url), original)
        let caughtUp = try ManagedBackupWriter.write(latest, to: cloud, ownerID: owner, date: now.addingTimeInterval(600))
        XCTAssertTrue(caughtUp.didWrite)
        XCTAssertEqual(try LibraryArchive.read(from: caughtUp.url), latest)
        XCTAssertEqual(try files(managedDirectory(cloud, owner: owner)).count, 2)
    }

    func testUnverifiedNewBackupCannotPruneExistingHistory() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        var previous: [URL: Data] = [:]
        for index in 0..<5 {
            let data = try archive(index)
            let result = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60))
            previous[result.url] = data
        }
        XCTAssertThrowsError(try ManagedBackupWriter.write(archive(6), to: root, ownerID: owner,
            date: now.addingTimeInterval(600), id: UUID(), policy: BackupRetentionPolicy(),
            afterWriteBeforeVerification: { url in try Data("damaged during folder write".utf8).write(to: url) },
            beforeRemove: nil))
        for (url, data) in previous { XCTAssertEqual(try LibraryArchive.read(from: url), data) }
    }

    func testOwnerDirectoryReplacementDuringWritePreservesOriginalHistory() throws {
        for replacementIsLink in [false, true] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = UUID()
            var previous: [String: Data] = [:]
            for index in 0..<5 {
                let data = try archive(index)
                let result = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
                    date: now.addingTimeInterval(Double(index) * 60))
                previous[result.url.lastPathComponent] = data
            }
            let preserved = root.appendingPathComponent("Preserved originals", isDirectory: true)
            XCTAssertThrowsError(try ManagedBackupWriter.write(archive(6), to: root, ownerID: owner,
                date: now.addingTimeInterval(600), id: UUID(), policy: BackupRetentionPolicy(),
                afterWriteBeforeVerification: { newFile in
                    let originalDirectory = newFile.deletingLastPathComponent()
                    try FileManager.default.moveItem(at: originalDirectory, to: preserved)
                    if replacementIsLink {
                        try FileManager.default.createSymbolicLink(at: originalDirectory, withDestinationURL: preserved)
                    } else {
                        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
                    }
                }, beforeRemove: nil))
            for (name, data) in previous {
                XCTAssertEqual(try LibraryArchive.read(from: preserved.appendingPathComponent(name)), data)
            }
        }
    }

    func testCleanupFailureDoesNotMisreportVerifiedBackupAsFailed() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        var previous: [URL] = []
        for index in 0..<5 {
            previous.append(try ManagedBackupWriter.write(archive(index), to: root, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60)).url)
        }
        let data = try archive(6)
        let policy = BackupRetentionPolicy(recentCount: 2, dailyDays: 0, weeklyWeeks: 0)
        let result = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
            date: now.addingTimeInterval(600), id: UUID(), policy: policy,
            afterWriteBeforeVerification: nil,
            beforeRemove: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertTrue(result.didWrite)
        XCTAssertNotNil(result.cleanupWarning)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(try LibraryArchive.read(from: result.url), data)
        for url in previous { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        let retry = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
            date: now.addingTimeInterval(660), id: UUID(), policy: policy,
            afterWriteBeforeVerification: nil, beforeRemove: nil)
        XCTAssertFalse(retry.didWrite)
        XCTAssertNil(retry.cleanupWarning)
        XCTAssertEqual(try files(managedDirectory(root, owner: owner)).count, 2)
    }

    func testCorruptNewestCopyDoesNotReplaceValidRecoveryProtection() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let policy = BackupRetentionPolicy(recentCount: 2, dailyDays: 0, weeklyWeeks: 0)
        let oldData = try archive(0), laterData = try archive(1)
        let old = try ManagedBackupWriter.write(oldData, to: root, ownerID: owner, date: now)
        let corrupt = try ManagedBackupWriter.write(laterData, to: root, ownerID: owner, date: now.addingTimeInterval(60))
        let corruptData = Data("Not a valid archive".utf8)
        try corruptData.write(to: corrupt.url)
        let latestData = try archive(2)
        let latest = try ManagedBackupWriter.write(latestData, to: root, ownerID: owner,
            date: now.addingTimeInterval(120), id: UUID(), policy: policy,
            afterWriteBeforeVerification: nil, beforeRemove: nil)
        XCTAssertTrue(latest.didWrite)
        XCTAssertNotNil(latest.cleanupWarning)
        XCTAssertEqual(try LibraryArchive.read(from: latest.url), latestData)
        XCTAssertEqual(try LibraryArchive.read(from: old.url), oldData)
        XCTAssertEqual(try Data(contentsOf: corrupt.url), corruptData)
    }

    func testCorruptHistoricalRepresentativeCannotDisplaceValidDailyOrWeeklyRecovery() throws {
        // Two days exercises a daily bucket; fourteen days exercises a weekly
        // bucket outside the daily window. Both are older than the latest five.
        for ageInDays in [2, 14] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = UUID(), original = try archive(0), later = try archive(1)
            let morning = now.addingTimeInterval(-Double(ageInDays) * 86_400 - 3 * 3600)
            let valid = try ManagedBackupWriter.write(original, to: root, ownerID: owner, date: morning)
            let damaged = try ManagedBackupWriter.write(later, to: root, ownerID: owner,
                date: morning.addingTimeInterval(3600))
            let corruptData = Data("Corrupted newer historical recovery point".utf8)
            try corruptData.write(to: damaged.url)
            var latestData = original
            for index in 0..<7 {
                latestData = try archive(index + 10)
                _ = try ManagedBackupWriter.write(latestData, to: root, ownerID: owner,
                    date: now.addingTimeInterval(Double(index) * 60))
            }
            XCTAssertEqual(try LibraryArchive.read(from: valid.url), original)
            XCTAssertEqual(try Data(contentsOf: damaged.url), corruptData)
            // A later duplicate/cleanup attempt must continue using the valid
            // representative; corruption is not just handled on first detection.
            let repeated = try ManagedBackupWriter.write(latestData, to: root, ownerID: owner,
                date: now.addingTimeInterval(600))
            XCTAssertFalse(repeated.didWrite)
            XCTAssertNotNil(repeated.cleanupWarning)
            XCTAssertEqual(try LibraryArchive.read(from: valid.url), original)
            XCTAssertEqual(try Data(contentsOf: damaged.url), corruptData)
            XCTAssertEqual(try LibraryArchive.read(from: repeated.url), latestData)
        }
    }

    func testHistoricalRecoveryReplacementStopsCleanupBeforeRemovingOtherCopies() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), oldData = try archive(0), replacement = try archive(99)
        let historical = try ManagedBackupWriter.write(oldData, to: root, ownerID: owner,
            date: now.addingTimeInterval(-2 * 86_400))
        var recent: [URL: Data] = [:]
        for index in 0..<5 {
            let data = try archive(index + 1)
            let saved = try ManagedBackupWriter.write(data, to: root, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60))
            recent[saved.url] = data
        }
        var replacementTriggered = false
        let latest = try archive(6)
        let result = try ManagedBackupWriter.write(latest, to: root, ownerID: owner,
            date: now.addingTimeInterval(600), id: UUID(), policy: BackupRetentionPolicy(),
            afterWriteBeforeVerification: nil,
            beforeRemove: { _ in
                replacementTriggered = true
                try replacement.write(to: historical.url, options: .atomic)
            })
        XCTAssertTrue(replacementTriggered)
        XCTAssertTrue(result.didWrite)
        XCTAssertNotNil(result.cleanupWarning)
        XCTAssertEqual(result.removedCount, 0)
        for (url, data) in recent { XCTAssertEqual(try LibraryArchive.read(from: url), data) }
        XCTAssertEqual(try LibraryArchive.read(from: historical.url), replacement)
        XCTAssertEqual(try LibraryArchive.read(from: result.url), latest)
    }

    func testCleanupPreservesAFileReplacedAfterRetentionPlanning() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), replacement = try archive(99)
        var originals: [URL] = []
        for index in 0..<5 {
            originals.append(try ManagedBackupWriter.write(archive(index), to: root, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60)).url)
        }
        let protectedURL = originals[0]
        let result = try ManagedBackupWriter.write(archive(6), to: root, ownerID: owner,
            date: now.addingTimeInterval(600), id: UUID(),
            policy: BackupRetentionPolicy(recentCount: 2, dailyDays: 0, weeklyWeeks: 0),
            afterWriteBeforeVerification: nil,
            beforeRemove: { url in
                if url == protectedURL { try replacement.write(to: url, options: .atomic) }
            })
        XCTAssertTrue(result.didWrite)
        XCTAssertNotNil(result.cleanupWarning)
        XCTAssertEqual(try LibraryArchive.read(from: protectedURL), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originals[4].path))
        XCTAssertNotNil(try LibraryArchive.decode(LibraryArchive.read(from: result.url)).nodes.first)
    }

    func testManagedBackupRejectsSymlinkDirectoriesAndPreservesLinkedFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), data = try archive(0)
        let outside = root.appendingPathComponent("Foreign files", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let foreignFile = outside.appendingPathComponent("Preserved.inotes")
        try data.write(to: foreignFile)
        for component in ["selected", "backups", "owner"] {
            let destination = root.appendingPathComponent(component, isDirectory: true)
            if component == "selected" {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
            } else {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let backups = destination.appendingPathComponent("iNotes Backups", isDirectory: true)
                if component == "backups" {
                    try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: outside)
                } else {
                    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(at: managedDirectory(destination, owner: owner), withDestinationURL: outside)
                }
            }
            XCTAssertThrowsError(try ManagedBackupWriter.write(data, to: destination, ownerID: owner, date: now))
            // FileManager may enumerate the /private/var spelling of a /var
            // temporary URL. Compare the same canonical paths, still requiring
            // exactly the original file and no newly created backup directories.
            XCTAssertEqual(try files(outside).map { $0.resolvingSymlinksInPath() },
                [foreignFile.resolvingSymlinksInPath()])
            XCTAssertEqual(try LibraryArchive.read(from: foreignFile), data)
        }
        let safe = root.appendingPathComponent("Safe", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        _ = try ManagedBackupWriter.write(data, to: safe, ownerID: owner, date: now)
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-90 * 86_400))
            .replacingOccurrences(of: ":", with: "-")
        let link = managedDirectory(safe, owner: owner).appendingPathComponent("iNotes-\(stamp)-\(UUID().uuidString).inotes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreignFile)
        for index in 1...7 {
            _ = try ManagedBackupWriter.write(archive(index), to: safe, ownerID: owner,
                date: now.addingTimeInterval(Double(index) * 60))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), foreignFile.path)
        XCTAssertEqual(try LibraryArchive.read(from: foreignFile), data)
    }
}
