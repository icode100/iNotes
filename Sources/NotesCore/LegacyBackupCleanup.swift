import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct LegacyBackupEntry: Identifiable, Sendable {
    public let id: String
    public let fileName: String
    public let date: Date
    public let byteCount: Int64
    public let canDelete: Bool
}

/// A review is tied to the exact folder and file identities that were inspected.
/// Clients can select its entry IDs, but cannot construct removal paths or fingerprints.
public struct LegacyBackupPreview: Sendable {
    public let folderURL: URL
    public let entries: [LegacyBackupEntry]
    public let warning: String?
    fileprivate let folderIdentity: LegacyFileIdentity
    fileprivate let backupDirectoryIdentity: LegacyFileIdentity?
    fileprivate let fingerprints: [String: LegacyFileFingerprint]
    fileprivate let isComplete: Bool
    fileprivate let reviewByteLimit: Int
}

public struct LegacyBackupCleanupResult: Sendable {
    public let removedCount: Int
    public let removedBytes: Int64
    public let warning: String?
}

public enum LegacyBackupCleanupError: Error, LocalizedError {
    case folderChanged
    case reviewIncomplete
    case selectionChanged
    case currentBackupUnavailable

    public var errorDescription: String? {
        switch self {
        case .folderChanged:
            "The backup folder changed after it was reviewed. Review its older backups again."
        case .reviewIncomplete:
            "The older-backup review could not finish safely. No older backups were removed."
        case .selectionChanged:
            "A selected backup changed or is now one of the two newest backups. Review the list again."
        case .currentBackupUnavailable:
            "A valid current backup could not be verified in this destination. No older backups were removed."
        }
    }
}

/// Explicit, reviewed cleanup of the files written before automatic-backup ownership
/// and retention existed. It never adopts these files into automatic retention.
public enum LegacyBackupCleanup {
    public static let maximumReviewEntries = 10_000
    public static let maximumReviewBytes = 256 * 1024 * 1024
    private static let legacyFileNameExpression = try? NSRegularExpression(
        pattern: "^iNotes-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z)-([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\\.inotes$"
    )

    public static func preview(in folder: URL) throws -> LegacyBackupPreview {
        try preview(in: folder, maximumBytes: maximumReviewBytes)
    }

    // A smaller bounded budget makes repeated-batch behavior practical to exercise
    // without constructing hundreds of megabytes of test archives.
    static func preview(in folder: URL, maximumBytes: Int) throws -> LegacyBackupPreview {
        guard maximumBytes > 0, maximumBytes <= maximumReviewBytes else {
            throw LegacyBackupCleanupError.reviewIncomplete
        }
        return try coordinate(folder: folder, writing: false) { coordinatedFolder in
            try review(folder: coordinatedFolder, displayedFolder: folder.standardizedFileURL, byteLimit: maximumBytes)
        }
    }

    /// The caller must first write its current library to a managed backup in this
    /// destination. This additionally validates that archive before removing anything.
    /// All selected files are preflighted before the first removal. A later provider
    /// failure is reported with the actual removal counts rather than losing them.
    public static func remove(_ ids: Set<String>, from preview: LegacyBackupPreview,
                              verifiedBackupURL: URL) throws -> LegacyBackupCleanupResult {
        try remove(ids, from: preview, verifiedBackupURL: verifiedBackupURL, beforeRemove: nil)
    }

    // The hook exercises changes to a protected file during the real cleanup loop
    // using disposable folders, including accurate partial-removal reporting.
    static func remove(_ ids: Set<String>, from preview: LegacyBackupPreview,
                       verifiedBackupURL: URL, beforeRemove: ((URL) throws -> Void)?) throws -> LegacyBackupCleanupResult {
        guard !ids.isEmpty else {
            return LegacyBackupCleanupResult(removedCount: 0, removedBytes: 0, warning: nil)
        }
        guard preview.isComplete else { throw LegacyBackupCleanupError.reviewIncomplete }
        let allowed = Set(preview.entries.filter(\.canDelete).map(\.id))
        guard ids.isSubset(of: allowed), preview.backupDirectoryIdentity != nil else {
            throw LegacyBackupCleanupError.selectionChanged
        }

        return try coordinate(folder: preview.folderURL, writing: true) { coordinatedFolder in
            let folder = try LegacyDirectory(url: coordinatedFolder)
            guard folder.identity == preview.folderIdentity else { throw LegacyBackupCleanupError.folderChanged }
            let directory = try LegacyDirectory(parent: folder, name: "iNotes Backups")
            guard directory.identity == preview.backupDirectoryIdentity else {
                throw LegacyBackupCleanupError.folderChanged
            }

            // The fresh archive must be in a managed subfolder, never one of the
            // legacy root files being reviewed. Every path component rejects links.
            let currentBackup = try verifiedCurrentBackup(verifiedBackupURL, preview: preview, directory: directory)
            let refreshed = try review(folder: coordinatedFolder, displayedFolder: preview.folderURL,
                                       byteLimit: preview.reviewByteLimit, prioritizing: ids)
            guard refreshed.isComplete else { throw LegacyBackupCleanupError.reviewIncomplete }
            guard refreshed.folderIdentity == folder.identity,
                  refreshed.backupDirectoryIdentity == directory.identity else {
                throw LegacyBackupCleanupError.folderChanged
            }
            let stillAllowed = Set(refreshed.entries.filter(\.canDelete).map(\.id))
            let protectedLegacyIDs = Set(refreshed.entries.filter { !$0.canDelete }.map(\.id))
            guard ids.isSubset(of: stillAllowed) else { throw LegacyBackupCleanupError.selectionChanged }
            for id in ids {
                guard let original = preview.fingerprints[id],
                      refreshed.fingerprints[id] == original else {
                    throw LegacyBackupCleanupError.selectionChanged
                }
            }
            try verifyDirectories(folder: folder, directory: directory, at: coordinatedFolder)
            guard try currentBackupStillMatches(currentBackup, under: directory) else {
                throw LegacyBackupCleanupError.currentBackupUnavailable
            }

            // Review has re-read and hashed all selections before any deletion.
            // A last metadata check also catches changes during that preflight.
            for id in ids {
                guard try metadata(of: id, in: directory) == preview.fingerprints[id]?.metadata else {
                    throw LegacyBackupCleanupError.selectionChanged
                }
            }

            var removedCount = 0
            var removedBytes: Int64 = 0
            for id in ids.sorted() {
                do {
                    try beforeRemove?(coordinatedFolder.appendingPathComponent("iNotes Backups", isDirectory: true).appendingPathComponent(id))
                    try verifyDirectories(folder: folder, directory: directory, at: coordinatedFolder)
                    guard try protectedLegacyIDs.allSatisfy({ name in
                        try metadata(of: name, in: directory) == refreshed.fingerprints[name]?.metadata
                    }) else { throw LegacyBackupCleanupError.selectionChanged }
                    guard try metadata(of: id, in: directory) == preview.fingerprints[id]?.metadata,
                          try currentBackupStillMatches(currentBackup, under: directory) else {
                        throw LegacyBackupCleanupError.selectionChanged
                    }
                    // unlinkat is pinned to the reviewed directory. It cannot follow
                    // a replacement symlink into another location or remove a directory.
                    guard unlinkat(directory.descriptor, id, 0) == 0 else { throw posixError() }
                    removedCount += 1
                    removedBytes += preview.fingerprints[id]!.metadata.byteCount
                } catch {
                    return LegacyBackupCleanupResult(
                        removedCount: removedCount, removedBytes: removedBytes,
                        warning: "Cleanup stopped after removing \(removedCount) older backup(s). The remaining files were kept. Review the folder again. \(error.localizedDescription)"
                    )
                }
            }
            return LegacyBackupCleanupResult(removedCount: removedCount, removedBytes: removedBytes, warning: nil)
        }
    }

    private static func review(folder url: URL, displayedFolder: URL,
                               byteLimit: Int,
                               prioritizing selectedIDs: Set<String> = []) throws -> LegacyBackupPreview {
        let folder = try LegacyDirectory(url: url)
        let directory: LegacyDirectory
        do {
            directory = try LegacyDirectory(parent: folder, name: "iNotes Backups")
        } catch let error as POSIXError where error.code == .ENOENT {
            return LegacyBackupPreview(folderURL: displayedFolder, entries: [], warning: nil,
                                       folderIdentity: folder.identity, backupDirectoryIdentity: nil,
                                       fingerprints: [:], isComplete: true, reviewByteLimit: byteLimit)
        }

        var candidates: [LegacyBackupCandidate] = []
        var examinedCount = 0
        var complete = true
        var skippedInvalid = false
        var warning: String?
        let dateFormatter = legacyDateFormatter()
        let duplicated = dup(directory.descriptor)
        guard duplicated >= 0 else { throw posixError() }
        guard let stream = fdopendir(duplicated) else {
            close(duplicated)
            throw posixError()
        }
        defer { closedir(stream) }

        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    complete = false
                    warning = "The folder could not be fully read. No files in this review can be removed."
                }
                break
            }
            let nameCapacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            examinedCount += 1
            guard examinedCount <= maximumReviewEntries else {
                complete = false
                warning = "This folder has more than \(maximumReviewEntries) entries. The review is incomplete, so no files can be removed here."
                break
            }
            guard let date = legacyDate(in: name, formatter: dateFormatter) else { continue }
            do {
                let attributes = try metadata(of: name, in: directory)
                guard attributes.byteCount >= 0, attributes.byteCount <= Int64(LibraryArchive.maximumBytes) else {
                    skippedInvalid = true
                    continue
                }
                candidates.append(LegacyBackupCandidate(name: name, date: date, metadata: attributes))
            } catch let error as POSIXError where error.code == .ELOOP || error.code == .EISDIR {
                // Links, directories and other special files are never candidates.
                skippedInvalid = true
            } catch {
                complete = false
                warning = "An older backup could not be read safely. No files in this incomplete review can be removed."
                break
            }
        }

        // Determine protection from a complete, sorted name/metadata inventory,
        // independent of readdir order. Unread files are never cleanup candidates.
        candidates.sort { $0.date == $1.date ? $0.name > $1.name : $0.date > $1.date }
        var records: [(name: String, date: Date, fingerprint: LegacyFileFingerprint)] = []
        var examinedIDs: Set<String> = []
        var protectedIDs: Set<String> = []
        var remainingBytes = byteLimit
        var limitedBatch = false
        if complete {
            for candidate in candidates {
                guard protectedIDs.count < 2 else { break }
                do {
                    if let fingerprint = try reviewCandidate(candidate, in: directory, remainingBytes: &remainingBytes) {
                        records.append((candidate.name, candidate.date, fingerprint))
                        protectedIDs.insert(candidate.name)
                    } else { skippedInvalid = true }
                    examinedIDs.insert(candidate.name)
                } catch LegacyReviewBudgetError.exhausted {
                    complete = false
                    warning = "The 256 MiB review limit was reached before the two newest valid backups could be identified. No files can be removed from this review."
                    break
                } catch {
                    complete = false
                    warning = "The newest backups could not be checked safely. No files in this incomplete review can be removed."
                    break
                }
            }
        }
        if complete {
            // Show useful oldest-first batches for large existing folders. During
            // removal, verify the user's selections first so unrelated additions
            // do not consume the batch budget before the selected files are checked.
            let older = candidates.filter { !examinedIDs.contains($0.name) }.sorted {
                let lhsSelected = selectedIDs.contains($0.name)
                let rhsSelected = selectedIDs.contains($1.name)
                if lhsSelected != rhsSelected { return lhsSelected }
                return $0.date == $1.date ? $0.name < $1.name : $0.date < $1.date
            }
            for candidate in older {
                do {
                    if let fingerprint = try reviewCandidate(candidate, in: directory, remainingBytes: &remainingBytes) {
                        records.append((candidate.name, candidate.date, fingerprint))
                    } else { skippedInvalid = true }
                } catch LegacyReviewBudgetError.exhausted {
                    limitedBatch = true
                    // A smaller later file may still fit in this bounded batch.
                    continue
                } catch {
                    complete = false
                    warning = "An older backup changed or could not be read safely. No files in this incomplete review can be removed."
                    break
                }
            }
        }
        try verifyDirectories(folder: folder, directory: directory, at: url)
        records.sort { $0.date == $1.date ? $0.name > $1.name : $0.date > $1.date }
        let entries = records.map { record in
            LegacyBackupEntry(id: record.name, fileName: record.name, date: record.date,
                              byteCount: record.fingerprint.metadata.byteCount,
                              canDelete: complete && !protectedIDs.contains(record.name))
        }
        if warning == nil {
            var notices: [String] = []
            if limitedBatch { notices.append("Showing a limited batch within the 256 MiB review limit. Review again after cleanup to see more older backups.") }
            if skippedInvalid { notices.append("Files that are not valid regular iNotes archives are excluded and will be kept.") }
            if !notices.isEmpty { warning = notices.joined(separator: " ") }
        }
        return LegacyBackupPreview(folderURL: displayedFolder, entries: entries, warning: warning,
                                   folderIdentity: folder.identity, backupDirectoryIdentity: directory.identity,
                                   fingerprints: Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.fingerprint) }),
                                   isComplete: complete, reviewByteLimit: byteLimit)
    }

    private static func reviewCandidate(_ candidate: LegacyBackupCandidate, in directory: LegacyDirectory,
                                         remainingBytes: inout Int) throws -> LegacyFileFingerprint? {
        guard remainingBytes > 0, candidate.metadata.byteCount < Int64(remainingBytes) else {
            throw LegacyReviewBudgetError.exhausted
        }
        let read = try readFile(candidate.name, in: directory,
                                maximumBytes: min(LibraryArchive.maximumBytes, remainingBytes - 1))
        remainingBytes -= read.data.count + 1
        guard read.fingerprint.metadata == candidate.metadata else { throw LegacyBackupCleanupError.selectionChanged }
        do { _ = try LibraryArchive.decode(read.data) }
        catch { return nil }
        return read.fingerprint
    }

    private static func legacyDate(in name: String, formatter: DateFormatter) -> Date? {
        // This is exactly the old writer's UTC, whole-second timestamp and canonical
        // UUID. Similar names, manual exports and nested folders are not adopted.
        guard let expression = legacyFileNameExpression,
              let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let stampRange = Range(match.range(at: 1), in: name),
              let idRange = Range(match.range(at: 2), in: name),
              let id = UUID(uuidString: String(name[idRange])), id.uuidString == name[idRange] else { return nil }
        let stamp = String(name[stampRange])
        guard let date = formatter.date(from: stamp), formatter.string(from: date) == stamp else { return nil }
        return date
    }

    private static func legacyDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        formatter.isLenient = false
        return formatter
    }

    private static func verifiedCurrentBackup(_ url: URL, preview: LegacyBackupPreview,
                                              directory: LegacyDirectory) throws -> LegacyCurrentBackup {
        do {
            guard url.isFileURL else { throw LegacyBackupCleanupError.currentBackupUnavailable }
            let base = preview.folderURL.appendingPathComponent("iNotes Backups", isDirectory: true).standardizedFileURL.pathComponents
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: base), components.count >= base.count + 2,
                  components.count <= base.count + 16, url.pathExtension == "inotes" else {
                throw LegacyBackupCleanupError.currentBackupUnavailable
            }
            let relative = Array(components.dropFirst(base.count))
            var parent = directory
            var parentIdentities: [LegacyFileIdentity] = []
            for component in relative.dropLast() {
                parent = try LegacyDirectory(parent: parent, name: component)
                parentIdentities.append(parent.identity)
            }
            let name = relative.last!
            let read = try readFile(name, in: parent, maximumBytes: LibraryArchive.maximumBytes)
            _ = try LibraryArchive.decode(read.data)
            return LegacyCurrentBackup(components: relative, parentIdentities: parentIdentities, fingerprint: read.fingerprint)
        } catch {
            throw LegacyBackupCleanupError.currentBackupUnavailable
        }
    }

    private static func currentBackupStillMatches(_ backup: LegacyCurrentBackup, under directory: LegacyDirectory) throws -> Bool {
        var parent = directory
        for (index, component) in backup.components.dropLast().enumerated() {
            parent = try LegacyDirectory(parent: parent, name: component)
            guard parent.identity == backup.parentIdentities[index] else { return false }
        }
        return try metadata(of: backup.components.last!, in: parent) == backup.fingerprint.metadata
    }

    private static func verifyDirectories(folder: LegacyDirectory, directory: LegacyDirectory, at url: URL) throws {
        let currentFolder = try LegacyDirectory(url: url)
        let currentDirectory = try LegacyDirectory(parent: currentFolder, name: "iNotes Backups")
        guard currentFolder.identity == folder.identity, currentDirectory.identity == directory.identity else {
            throw LegacyBackupCleanupError.folderChanged
        }
    }

    private static func metadata(of name: String, in directory: LegacyDirectory) throws -> LegacyFileMetadata {
        var status = stat()
        guard fstatat(directory.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw POSIXError(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) ? .ELOOP : .EISDIR)
        }
        return LegacyFileMetadata(status)
    }

    private static func readFile(_ name: String, in directory: LegacyDirectory,
                                 maximumBytes: Int) throws -> (data: Data, fingerprint: LegacyFileFingerprint) {
        // Pin the exact non-link file before checking its size/type. Nonblocking open
        // prevents a substituted FIFO from hanging, and every read is bounded.
        let descriptor = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw posixError() }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw POSIXError(.EISDIR) }
        guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else { throw LibraryError.tooLarge }
        var data = Data()
        while true {
            let remaining = maximumBytes - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining + 1)), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw LibraryError.tooLarge }
            data.append(chunk)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw posixError() }
        let original = LegacyFileMetadata(before)
        guard original == LegacyFileMetadata(after), original.byteCount == Int64(data.count),
              try metadata(of: name, in: directory) == original else { throw LegacyBackupCleanupError.selectionChanged }
        return (data, LegacyFileFingerprint(metadata: original, digest: Array(SHA256.hash(data: data))))
    }

    private static func coordinate<T>(folder: URL, writing: Bool, work: @escaping (URL) throws -> T) throws -> T {
        guard folder.isFileURL else { throw LegacyBackupCleanupError.folderChanged }
        #if os(macOS) || os(iOS)
        var result: Result<T, Error>?
        var error: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let access: (URL) -> Void = { url in result = Result { try work(url) } }
        if writing {
            coordinator.coordinate(writingItemAt: folder, options: .forMerging, error: &error, byAccessor: access)
        } else {
            coordinator.coordinate(readingItemAt: folder, options: [], error: &error, byAccessor: access)
        }
        if let error { throw error }
        guard let result else { throw LegacyBackupCleanupError.folderChanged }
        return try result.get()
        #else
        return try work(folder)
        #endif
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

fileprivate struct LegacyFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ status: stat) {
        device = UInt64(truncatingIfNeeded: status.st_dev)
        inode = UInt64(status.st_ino)
    }
}

fileprivate struct LegacyFileMetadata: Equatable, Sendable {
    let identity: LegacyFileIdentity
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ status: stat) {
        identity = LegacyFileIdentity(status)
        byteCount = Int64(status.st_size)
        #if canImport(Darwin)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(status.st_mtim.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtim.tv_nsec)
        changedSeconds = Int64(status.st_ctim.tv_sec)
        changedNanoseconds = Int64(status.st_ctim.tv_nsec)
        #endif
    }
}

fileprivate struct LegacyFileFingerprint: Equatable, Sendable {
    let metadata: LegacyFileMetadata
    let digest: [UInt8]
}

private struct LegacyCurrentBackup {
    let components: [String]
    let parentIdentities: [LegacyFileIdentity]
    let fingerprint: LegacyFileFingerprint
}

private struct LegacyBackupCandidate {
    let name: String
    let date: Date
    let metadata: LegacyFileMetadata
}

private enum LegacyReviewBudgetError: Error {
    case exhausted
}

private final class LegacyDirectory {
    let descriptor: Int32
    let identity: LegacyFileIdentity

    convenience init(url: URL) throws {
        try self.init(opened: open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    convenience init(parent: LegacyDirectory, name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw LegacyBackupCleanupError.folderChanged
        }
        try self.init(opened: openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    private init(opened descriptor: Int32) throws {
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTDIR)
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        identity = LegacyFileIdentity(status)
    }

    deinit { close(descriptor) }
}
