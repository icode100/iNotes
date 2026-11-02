import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct BackupRetentionEntry: Equatable, Sendable {
    public let name: String
    public let date: Date
    public let byteCount: Int64

    public init(name: String, date: Date, byteCount: Int64) {
        self.name = name
        self.date = date
        self.byteCount = byteCount
    }
}

/// A union of recent, UTC-day and ISO-week recovery points, not three copies
/// of the same archive. The two newest entries always survive a byte budget.
public struct BackupRetentionPolicy: Sendable {
    public let recentCount: Int
    public let dailyDays: Int
    public let weeklyWeeks: Int
    public let maximumBytes: Int64

    public init(recentCount: Int = 5, dailyDays: Int = 7, weeklyWeeks: Int = 4,
                maximumBytes: Int64 = 500 * 1024 * 1024) {
        self.recentCount = max(2, min(2048, recentCount))
        self.dailyDays = max(0, min(366, dailyDays))
        self.weeklyWeeks = max(0, min(53, weeklyWeeks))
        self.maximumBytes = max(0, maximumBytes)
    }

    public func retainedNames(in entries: [BackupRetentionEntry], now: Date) -> Set<String> {
        guard Self.supportedDate(now) else { return [] }
        var names = Set<String>()
        let ordered = entries.filter {
            !$0.name.isEmpty && Self.supportedDate($0.date) && $0.byteCount >= 0
        }.sorted {
            $0.date == $1.date ? $0.name > $1.name : $0.date > $1.date
        }.filter { names.insert($0.name).inserted }
        let protected = Set(ordered.prefix(2).map(\.name))
        var retained = Set(ordered.prefix(recentCount).map(\.name))
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let firstDay = calendar.date(byAdding: .day, value: -(dailyDays - 1), to: today),
              let firstWeek = calendar.date(byAdding: .weekOfYear, value: -(weeklyWeeks - 1), to: thisWeek) else {
            return protected
        }
        var days = Set<Date>()
        var weeks = Set<Date>()
        for entry in ordered where entry.date <= now {
            let day = calendar.startOfDay(for: entry.date)
            if dailyDays > 0 && day >= firstDay && days.insert(day).inserted {
                retained.insert(entry.name)
            }
            if weeklyWeeks > 0, let week = calendar.dateInterval(of: .weekOfYear, for: entry.date)?.start,
               week >= firstWeek && weeks.insert(week).inserted {
                retained.insert(entry.name)
            }
        }
        var bytes = ordered.filter { retained.contains($0.name) }.reduce(Int64(0)) { total, entry in
            Self.addingBytes(total, entry.byteCount)
        }
        for entry in ordered.reversed() where bytes > maximumBytes && retained.contains(entry.name) && !protected.contains(entry.name) {
            retained.remove(entry.name)
            // Recalculate instead of subtracting from a possibly saturated sum.
            bytes = ordered.filter { retained.contains($0.name) }.reduce(Int64(0)) {
                Self.addingBytes($0, $1.byteCount)
            }
        }
        return retained
    }

    static func addingBytes(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    static func supportedDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_799
    }
}

public struct ManagedBackupResult: Sendable {
    public let url: URL
    public let didWrite: Bool
    public let removedCount: Int
    public let retainedCount: Int
    public let retainedBytes: Int64
    public let cleanupWarning: String?
}

public enum ManagedBackupError: Error, LocalizedError {
    case unsafeDirectory
    case changedFile
    case verificationFailed
    case workLimit

    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory: "The backup location must use real folders, not symbolic links."
        case .changedFile: "A backup changed while it was being checked. Its contents were kept."
        case .verificationFailed: "The newly written backup could not be verified. Earlier backups were kept."
        case .workLimit: "Backup cleanup reached its safety limit. Some older files were kept."
        }
    }
}

/// Complete, portable archives owned by one local library installation. Legacy
/// archives, exports and other owners never participate in automatic cleanup.
public enum ManagedBackupWriter {
    public static func directory(in folder: URL, ownerID: UUID) -> URL {
        folder.appendingPathComponent("iNotes Backups", isDirectory: true)
            .appendingPathComponent("Automatic-\(ownerID.uuidString)", isDirectory: true)
    }

    public static func write(_ data: Data, to folder: URL, ownerID: UUID,
                             date: Date = Date(), id: UUID = UUID()) throws -> ManagedBackupResult {
        try write(data, to: folder, ownerID: ownerID, date: date, id: id,
                  policy: BackupRetentionPolicy(), afterWriteBeforeVerification: nil, beforeRemove: nil)
    }

    // Hooks exercise real filesystem failure boundaries using temporary folders.
    static func write(_ data: Data, to folder: URL, ownerID: UUID,
                      date: Date = Date(), id: UUID = UUID(), policy: BackupRetentionPolicy,
                      afterWriteBeforeVerification: ((URL) throws -> Void)?,
                      beforeRemove: ((URL) throws -> Void)?) throws -> ManagedBackupResult {
        _ = try LibraryArchive.decode(data)
        guard BackupRetentionPolicy.supportedDate(date), folder.isFileURL else {
            throw LibraryError.invalidData("The backup date or folder is invalid.")
        }
        var result: Result<ManagedBackupResult, Error>?
        let operation: (URL) -> Void = { coordinatedFolder in
            result = Result {
                let access = try BackupDirectoryAccess(folder: coordinatedFolder, ownerID: ownerID)
                let scan = try access.scan()
                var warning = scan.warning
                var records = scan.records
                let budget = BackupReadBudget()
                var verified: [String: BackupFileState] = [:]
                var invalid = Set<String>()
                var current: BackupRecord?
                var didWrite = true

                // Compare only the newest recognized file. If it is damaged,
                // write a fresh copy instead of falling back to an older match.
                if scan.complete, let newest = records.first {
                    do {
                        let existing = try access.read(newest, budget: budget)
                        if existing == data {
                            verified[newest.entry.name] = newest.state
                            current = newest
                            didWrite = false
                        } else {
                            _ = try LibraryArchive.decode(existing)
                            verified[newest.entry.name] = newest.state
                        }
                    } catch {
                        invalid.insert(newest.entry.name)
                        warning = "Some existing backup files could not be verified and were kept."
                    }
                }
                if current == nil {
                    // Keep a strict ordering for rapid manual requests and a
                    // backwards-moving clock. Ten milliseconds also survives
                    // the formatter's millisecond precision and Date rounding.
                    let stamp = max(date, records.first?.entry.date.addingTimeInterval(0.01) ?? date)
                    let name = try BackupRecord.fileName(date: stamp, id: id)
                    try access.atomicWrite(data, named: name)
                    let url = access.url.appendingPathComponent(name)
                    try afterWriteBeforeVerification?(url)
                    let written = try access.record(named: name)
                    guard let written, try access.read(written) == data else {
                        throw ManagedBackupError.verificationFailed
                    }
                    verified[name] = written.state
                    current = written
                    records.append(written)
                    records.sort(by: BackupRecord.newestFirst)
                }
                guard let current else { throw ManagedBackupError.verificationFailed }
                if !scan.complete {
                    try access.verifyDirectories()
                    return makeResult(current: current, didWrite: didWrite, removed: 0,
                                      records: records, warning: warning)
                }

                // Locate the two newest valid recovery points first. A damaged
                // file never takes the place of a usable recovery copy.
                var protected = Set<String>()
                for record in records where protected.count < 2 && !invalid.contains(record.entry.name) {
                    if verified[record.entry.name] != nil {
                        protected.insert(record.entry.name)
                        continue
                    }
                    do {
                        _ = try LibraryArchive.decode(access.read(record, budget: budget))
                        verified[record.entry.name] = record.state
                        protected.insert(record.entry.name)
                    } catch {
                        invalid.insert(record.entry.name)
                        warning = "Some existing backup files could not be verified and were kept."
                        if budget.exhausted { break }
                    }
                }
                // The file just written or matched must never be selected for
                // deletion, even if a device clock moves backwards.
                protected.insert(current.entry.name)
                var retained = Set<String>()
                while true {
                    if budget.exhausted {
                        try access.verifyDirectories()
                        return makeResult(current: current, didWrite: didWrite, removed: 0, records: records,
                                          warning: "Backup saved. Cleanup reached its verification limit, so all older copies were kept.")
                    }
                    let candidates = records.filter { !invalid.contains($0.entry.name) }
                    let selected = policy.retainedNames(in: candidates.map(\.entry), now: max(date, current.entry.date))
                        .union(protected)
                    retained = selected.union(invalid)
                    // No files would be deleted, so there is no historical
                    // alternative to protect in this transaction.
                    if !records.contains(where: { !retained.contains($0.entry.name) }) { break }
                    let unchecked = records.filter { selected.contains($0.entry.name) && verified[$0.entry.name] == nil }
                    if unchecked.isEmpty { break }
                    // Validate every selected recent/day/week representative
                    // before deleting alternatives from its recovery period.
                    // If one is damaged, keep its bytes but exclude it from the
                    // policy and select the next usable copy on the next pass.
                    for record in unchecked {
                        do {
                            _ = try LibraryArchive.decode(access.read(record, budget: budget))
                            verified[record.entry.name] = record.state
                        } catch {
                            invalid.insert(record.entry.name)
                            warning = "Some existing backup files could not be verified and were kept."
                            if budget.exhausted { break }
                        }
                    }
                }
                let verifiedKeepers = retained.subtracting(invalid)
                var removed = Set<String>()
                for record in records.reversed() where !retained.contains(record.entry.name) {
                    do {
                        let url = access.url.appendingPathComponent(record.entry.name)
                        try beforeRemove?(url)
                        // A changed recent, daily or weekly recovery point
                        // suspends cleanup before an alternative can be removed.
                        guard try verifiedKeepers.allSatisfy({ name in
                            try access.record(named: name)?.state == verified[name]
                        }) else {
                            warning = "Backup cleanup stopped because a retained recovery copy changed."
                            break
                        }
                        // Recheck the descriptor and content after any provider
                        // or test change; never remove a substituted file.
                        _ = try LibraryArchive.decode(access.read(record, budget: budget))
                        try access.remove(record)
                        removed.insert(record.entry.name)
                    } catch {
                        warning = "Backup saved, but some older files could not be safely removed."
                        if budget.exhausted { break }
                    }
                }
                records.removeAll { removed.contains($0.entry.name) }
                let bytes = records.reduce(Int64(0)) { BackupRetentionPolicy.addingBytes($0, $1.entry.byteCount) }
                if bytes > policy.maximumBytes {
                    warning = "Backup saved. Older files were kept for safety, so this history is above its storage budget."
                }
                try access.verifyDirectories()
                return makeResult(current: current, didWrite: didWrite, removed: removed.count,
                                  records: records, warning: warning)
            }
        }
        #if os(macOS) || os(iOS)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: folder, options: .forMerging,
                               error: &coordinationError, byAccessor: operation)
        if let coordinationError { throw coordinationError }
        #else
        operation(folder)
        #endif
        guard let result else { throw BackupArchiveError.folderUnavailable }
        return try result.get()
    }

    private static func makeResult(current: BackupRecord, didWrite: Bool, removed: Int,
                                   records: [BackupRecord], warning: String?) -> ManagedBackupResult {
        ManagedBackupResult(url: current.url, didWrite: didWrite, removedCount: removed,
                            retainedCount: records.count,
                            retainedBytes: records.reduce(Int64(0)) { BackupRetentionPolicy.addingBytes($0, $1.entry.byteCount) },
                            cleanupWarning: warning)
    }
}

private struct BackupFileState: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        size = Int64(value.st_size)
        #if canImport(Darwin)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(value.st_mtim.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtim.tv_nsec)
        changedSeconds = Int64(value.st_ctim.tv_sec)
        changedNanoseconds = Int64(value.st_ctim.tv_nsec)
        #endif
    }
}

private struct BackupRecord {
    let entry: BackupRetentionEntry
    let state: BackupFileState
    let url: URL

    static func newestFirst(_ lhs: BackupRecord, _ rhs: BackupRecord) -> Bool {
        lhs.entry.date == rhs.entry.date ? lhs.entry.name > rhs.entry.name : lhs.entry.date > rhs.entry.date
    }

    static func fileName(date: Date, id: UUID) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let name = "iNotes-\(stamp)-\(id.uuidString).inotes"
        guard self.date(in: name) != nil else { throw LibraryError.invalidData("The backup date is invalid.") }
        return name
    }

    static func date(in name: String) -> Date? {
        guard (name.utf8.count == 71 || name.utf8.count == 75),
              name.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
              name.hasPrefix("iNotes-"), name.hasSuffix(".inotes") else { return nil }
        let stem = String(name.dropFirst(7).dropLast(7))
        let stampCount = name.utf8.count == 75 ? 24 : 20
        let stamp = String(stem.prefix(stampCount))
        let idText = String(stem.suffix(36))
        guard stem[stem.index(stem.startIndex, offsetBy: stampCount)] == "-",
              let id = UUID(uuidString: idText), id.uuidString == idText else { return nil }
        // Exact round trip rejects alternate spellings and path fragments.
        let source = String(stamp.prefix(11)) + stamp.dropFirst(11).replacingOccurrences(of: "-", with: ":")
        let formatter = ISO8601DateFormatter()
        if stampCount == 24 { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        guard let date = formatter.date(from: source),
              formatter.string(from: date).replacingOccurrences(of: ":", with: "-") == stamp else { return nil }
        return date
    }
}

private final class BackupReadBudget {
    private var remainingBytes = 512 * 1024 * 1024
    private var remainingFiles = 128
    private(set) var exhausted = false

    func reserve(_ bytes: Int64) throws {
        guard bytes >= 0, bytes <= Int64(remainingBytes), remainingFiles > 0 else {
            exhausted = true
            throw ManagedBackupError.workLimit
        }
        remainingBytes -= Int(bytes)
        remainingFiles -= 1
    }
}

/// Hold the actual directories open throughout the coordinated transaction.
/// Relative no-follow operations cannot traverse a substituted owner directory.
private final class BackupDirectoryAccess {
    let url: URL
    private let descriptor: Int32
    private let folder: URL
    private let ownerName: String
    private let rootIdentity: Identity
    private let backupsIdentity: Identity
    private let ownerIdentity: Identity

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    init(folder: URL, ownerID: UUID) throws {
        let root = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ManagedBackupError.unsafeDirectory }
        defer { close(root) }
        self.folder = folder
        rootIdentity = try Self.identity(of: root)
        let backups = try Self.openDirectory("iNotes Backups", under: root)
        defer { close(backups) }
        backupsIdentity = try Self.identity(of: backups)
        ownerName = "Automatic-\(ownerID.uuidString)"
        let owner = try Self.openDirectory(ownerName, under: backups)
        do { ownerIdentity = try Self.identity(of: owner) }
        catch { close(owner); throw error }
        descriptor = owner
        url = ManagedBackupWriter.directory(in: folder, ownerID: ownerID)
    }

    deinit { close(descriptor) }

    private static func openDirectory(_ name: String, under parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, mode_t(0o700)) != 0 && errno != EEXIST { throw failure() }
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw ManagedBackupError.unsafeDirectory }
        return child
    }

    private static func identity(of file: Int32) throws -> Identity {
        var value = stat()
        guard fstat(file, &value) == 0 else { throw failure() }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ManagedBackupError.unsafeDirectory }
        return Identity(device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino))
    }

    func verifyDirectories() throws {
        let root = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ManagedBackupError.unsafeDirectory }
        defer { close(root) }
        guard try Self.identity(of: root) == rootIdentity else { throw ManagedBackupError.changedFile }
        let backups = openat(root, "iNotes Backups", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard backups >= 0 else { throw ManagedBackupError.unsafeDirectory }
        defer { close(backups) }
        guard try Self.identity(of: backups) == backupsIdentity else { throw ManagedBackupError.changedFile }
        let owner = openat(backups, ownerName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard owner >= 0 else { throw ManagedBackupError.unsafeDirectory }
        defer { close(owner) }
        guard try Self.identity(of: owner) == ownerIdentity else { throw ManagedBackupError.changedFile }
    }

    func scan() throws -> (records: [BackupRecord], complete: Bool, warning: String?) {
        try verifyDirectories()
        let copy = dup(descriptor)
        guard copy >= 0 else { throw Self.failure() }
        guard let stream = fdopendir(copy) else { close(copy); throw Self.failure() }
        defer { closedir(stream) }
        var records: [BackupRecord] = []
        var count = 0
        var warning: String?
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw Self.failure() }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            guard name != "." && name != ".." else { continue }
            count += 1
            guard count <= 2048 else {
                try verifyDirectories()
                return (records.sorted(by: BackupRecord.newestFirst), false,
                        "Backup saved. This folder has too many files to clean up automatically.")
            }
            do {
                if let record = try record(named: name) { records.append(record) }
                else { warning = "Unrecognized files were kept outside the automatic backup policy." }
            } catch { warning = "Some existing backup files could not be inspected and were kept." }
        }
        try verifyDirectories()
        return (records.sorted(by: BackupRecord.newestFirst), true, warning)
    }

    func record(named name: String) throws -> BackupRecord? {
        guard let date = BackupRecord.date(in: name) else { return nil }
        var value = stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.failure() }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_size >= 0 else { return nil }
        return BackupRecord(entry: BackupRetentionEntry(name: name, date: date, byteCount: Int64(value.st_size)),
                            state: BackupFileState(value), url: url.appendingPathComponent(name))
    }

    func read(_ record: BackupRecord, budget: BackupReadBudget? = nil) throws -> Data {
        try verifyDirectories()
        let file = openat(descriptor, record.entry.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(file, &before) == 0 else { throw Self.failure() }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              BackupFileState(before) == record.state else { throw ManagedBackupError.changedFile }
        guard before.st_size <= Int64(LibraryArchive.maximumBytes) else { throw LibraryError.tooLarge }
        try budget?.reserve(Int64(before.st_size))
        let maximumBytes = Int(before.st_size)
        var data = Data()
        while true {
            let remaining = maximumBytes - data.count
            let requested = remaining >= 64 * 1024 ? 64 * 1024 : remaining + 1
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw ManagedBackupError.changedFile }
            data.append(chunk)
        }
        var after = stat()
        guard fstat(file, &after) == 0 else { throw Self.failure() }
        guard BackupFileState(after) == record.state, Int64(data.count) == record.entry.byteCount,
              try self.record(named: record.entry.name)?.state == record.state else {
            throw ManagedBackupError.changedFile
        }
        try verifyDirectories()
        return data
    }

    func atomicWrite(_ data: Data, named name: String) throws {
        let temporary = ".writing-\(UUID().uuidString)"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw Self.failure() }
        defer { unlinkat(descriptor, temporary, 0) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try verifyDirectories()
        #if canImport(Darwin)
        guard renameatx_np(descriptor, temporary, descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw BackupArchiveError.alreadyExists }
            throw Self.failure()
        }
        #else
        // POSIX link publishes a complete file without replacing an existing name.
        guard linkat(descriptor, temporary, descriptor, name, 0) == 0 else {
            if errno == EEXIST { throw BackupArchiveError.alreadyExists }
            throw Self.failure()
        }
        #endif
    }

    func remove(_ record: BackupRecord) throws {
        try verifyDirectories()
        guard try self.record(named: record.entry.name)?.state == record.state else {
            throw ManagedBackupError.changedFile
        }
        guard unlinkat(descriptor, record.entry.name, 0) == 0 else { throw Self.failure() }
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
