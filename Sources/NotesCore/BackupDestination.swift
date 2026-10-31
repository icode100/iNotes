import Foundation

public enum BackupDestination: String, CaseIterable, Codable, Sendable, Identifiable {
    case googleDrive
    case iCloudDrive

    public var id: String { rawValue }
    public var title: String { self == .googleDrive ? "Google Drive" : "iCloud Drive" }
    public var symbol: String { self == .googleDrive ? "externaldrive" : "icloud" }
    public var bookmarkKey: String { self == .googleDrive ? "driveBookmark" : "iCloudDriveBookmark" }
    public var lastBackupKey: String { "backup.lastSuccess.\(rawValue)" }
}

public enum BackupArchiveError: Error, LocalizedError {
    case folderUnavailable
    case alreadyExists

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable: "The selected backup folder is unavailable. Reconnect it from Backups."
        case .alreadyExists: "A backup with this name already exists. Its contents were kept."
        }
    }
}

/// Writes independent, complete archives. Success confirms a local folder write;
/// the selected Files/Finder provider controls any later cloud upload.
public enum BackupArchiveWriter {
    @discardableResult
    public static func write(_ data: Data, to folder: URL, date: Date = Date(), id: UUID = UUID()) throws -> URL {
        _ = try LibraryArchive.decode(data)
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw BackupArchiveError.folderUnavailable
        }
        var result: Result<URL, Error>?
        let write: (URL) -> Void = { coordinatedFolder in
            result = Result {
                let directory = coordinatedFolder.appendingPathComponent("iNotes Backups", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
                let destination = directory.appendingPathComponent("iNotes-\(stamp)-\(id.uuidString).inotes")
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw BackupArchiveError.alreadyExists }
                try data.write(to: destination, options: .atomic)
                return destination
            }
        }
        #if os(macOS) || os(iOS)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError, byAccessor: write)
        if let coordinationError { throw coordinationError }
        #else
        write(folder)
        #endif
        guard let result else { throw BackupArchiveError.folderUnavailable }
        return try result.get()
    }
}

public enum BackupSchedule {
    public static let minimumInterval: TimeInterval = 60

    public static func delay(now: Date, lastSuccess: Date?, retryAfter: Date?) -> TimeInterval {
        let nextSuccess = (lastSuccess ?? .distantPast).addingTimeInterval(minimumInterval)
        return max(0, max(nextSuccess, retryAfter ?? .distantPast).timeIntervalSince(now))
    }
}
