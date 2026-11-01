import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads a regular file using one handle, consuming at most the limit plus one byte.
/// The extra byte detects growth beyond the limit without loading the rest of the file.
public enum BoundedFileReader {
    public static func read(from url: URL, maximumBytes: Int) throws -> Data {
        try read(from: url, maximumBytes: maximumBytes) { handle, count in
            try handle.read(upToCount: count)
        }
    }

    // The chunk operation is injectable so tests can change a real file after its
    // metadata check, without a timing-dependent race against the filesystem.
    static func read(from url: URL, maximumBytes: Int,
                     readChunk: (FileHandle, Int) throws -> Data?) throws -> Data {
        guard maximumBytes >= 0 else { throw LibraryError.invalidData("The file size limit must not be negative.") }
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        #if canImport(Darwin) || canImport(Glibc)
        // Nonblocking open lets us inspect and reject a FIFO without waiting for a
        // writer. fstat checks the opened file, not a path that can be replaced.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw LibraryError.invalidData("Choose a regular file.")
        }
        guard status.st_size <= Int64(maximumBytes) else { throw LibraryError.tooLarge }
        #else
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw LibraryError.invalidData("Choose a regular file.") }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw LibraryError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #endif

        var data = Data()
        while true {
            let remaining = maximumBytes - data.count
            let count = remaining >= 64 * 1024 ? 64 * 1024 : remaining + 1
            guard let chunk = try readChunk(handle, count), !chunk.isEmpty else { return data }
            guard chunk.count <= remaining else { throw LibraryError.tooLarge }
            data.append(chunk)
        }
    }
}

public enum LibraryArchive {
    public static let maximumBytes = 64 * 1024 * 1024

    public static func encode(_ library: NoteLibrary) throws -> Data {
        try library.validate()
        let data = try encoder().encode(library)
        guard data.count <= maximumBytes else { throw LibraryError.tooLarge }
        return data
    }

    /// Matches an individual node's exact JSON byte contribution to the archive.
    /// Callers may cache totals to budget frequent text edits without serializing other notes.
    public static func encodedNodeSize(_ node: NoteNode) throws -> Int {
        try encoder().encode(node).count
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decode(_ data: Data) throws -> NoteLibrary {
        guard data.count <= maximumBytes else { throw LibraryError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let library = try decoder.decode(NoteLibrary.self, from: data)
        try library.validate()
        return library
    }

    public static func read(from url: URL) throws -> Data {
        try BoundedFileReader.read(from: url, maximumBytes: maximumBytes)
    }
}

public enum RepositoryError: Error, LocalizedError {
    case externalModification
    case corruptLibrary(backupURL: URL, detail: String)
    case recoveryRequired
    case missingBackup

    public var errorDescription: String? {
        switch self {
        case .externalModification: "The library changed outside this app. Reopen it before saving; your current notes have not overwritten the other copy."
        case .corruptLibrary(_, let detail): "The library could not be read. Its original bytes are preserved. You can restore the previous backup. \(detail)"
        case .recoveryRequired: "Saving is paused until you recover or reopen the damaged library."
        case .missingBackup: "No previous library backup is available."
        }
    }
}

/// Own one instance per opened library. Synchronous operations belong on the caller's serial queue.
/// Data writes are atomic, protected by a process-shared advisory lock, and compare
/// the last read bytes before replacement. No file-provider daemon is needed.
public final class LibraryRepository {
    public let url: URL
    public let backupURL: URL
    private enum State { case unopened, missing, loaded(Data), damaged }
    private var state: State = .unopened

    public init(url: URL) {
        self.url = url
        self.backupURL = url.deletingPathExtension().appendingPathExtension("previous.json")
    }

    public func load() throws -> NoteLibrary? {
        guard FileManager.default.fileExists(atPath: url.path) else { state = .missing; return nil }
        do {
            let data = try LibraryArchive.read(from: url)
            let library = try LibraryArchive.decode(data)
            state = .loaded(data)
            return library
        } catch {
            state = .damaged
            throw RepositoryError.corruptLibrary(backupURL: backupURL, detail: error.localizedDescription)
        }
    }

    public func save(_ library: NoteLibrary) throws {
        if case .damaged = state { throw RepositoryError.recoveryRequired }
        let data = try LibraryArchive.encode(library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinateWrite { coordinatedURL in
            let exists = FileManager.default.fileExists(atPath: coordinatedURL.path)
            let previous: Data?
            switch state {
            case .loaded(let expected):
                guard exists else { throw RepositoryError.externalModification }
                let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= LibraryArchive.maximumBytes else { throw RepositoryError.externalModification }
                let actual = try LibraryArchive.read(from: coordinatedURL)
                guard expected == actual else { throw RepositoryError.externalModification }
                previous = actual
            case .unopened, .missing:
                guard !exists else { throw RepositoryError.externalModification }
                previous = nil
            case .damaged: throw RepositoryError.recoveryRequired
            }
            if let previous, previous != data {
                // Commit the known-good previous version first. A failed backup never replaces primary data.
                try previous.write(to: backupURL, options: .atomic)
            }
            if previous != data { try data.write(to: coordinatedURL, options: .atomic) }
            state = .loaded(data)
        }
    }

    /// Inspects the backup without replacing the damaged primary file or unlocking saves.
    public func recoverBackup() throws -> NoteLibrary {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { throw RepositoryError.missingBackup }
        return try LibraryArchive.decode(LibraryArchive.read(from: backupURL))
    }

    /// Explicit recovery keeps a uniquely named copy of the damaged primary before restoring.
    @discardableResult
    public func restoreFromBackup() throws -> NoteLibrary {
        let library = try recoverBackup()
        let data = try LibraryArchive.encode(library)
        try coordinateWrite { coordinatedURL in
            if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                let preserved = coordinatedURL.deletingLastPathComponent().appendingPathComponent("Library-damaged-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: coordinatedURL, to: preserved)
            }
            try data.write(to: coordinatedURL, options: .atomic)
            state = .loaded(data)
        }
        return library
    }

    private func coordinateWrite(_ operation: (URL) throws -> Void) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        try operation(url)
        #else
        try operation(url)
        #endif
    }
}
