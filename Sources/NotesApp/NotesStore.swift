import SwiftUI
import NotesCore
#if os(macOS)
import AppKit
#endif

enum LibraryFilter: String, CaseIterable { case all = "All sheets", favorites = "Favorites", trash = "Trash" }

@MainActor
final class NotesStore: ObservableObject {
    @Published var library = NoteLibrary()
    @Published var folderID: UUID?
    @Published var sheetID: UUID?
    @Published var filter: LibraryFilter = .all
    @Published var search = ""
    @Published var errorMessage: String?
    @Published var saveStatus = "Opening library…"
    @Published var driveFolder: URL?
    @Published var lastBackup: Date?
    @Published var iCloudFolder: URL?
    @Published var lastICloudBackup: Date?
    @Published private(set) var backupStatuses: [BackupDestination: String] = [
        .googleDrive: "Not connected", .iCloudDrive: "Not connected"
    ]
    @Published var dirty = false
    @Published var recoveryAvailable = false
    private let repository: LibraryRepository
    private let preferences: UserDefaults
    let libraryURL: URL
    private var saveTask: Task<Void, Never>?
    private var backupTasks: [BackupDestination: Task<Void, Never>] = [:]
    private var backupNeedsWrite: Set<BackupDestination> = []
    private var backupRetryAfter: [BackupDestination: Date] = [:]
    private var backupAccesses: [BackupDestination: BackupFolderAccess] = [:]
    private var backupSessionOnly: Set<BackupDestination> = []
    private var backupPermissionErrors: [BackupDestination: String] = [:]
    private var canSave = true
    private var serializedBytes = 0

    init(directory: URL? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let base: URL
        if let directory {
            base = directory
        } else if let override = ProcessInfo.processInfo.environment["INOTES_DATA_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("iNotes", isDirectory: true)
        }
        libraryURL = base.appendingPathComponent("Library.json")
        repository = LibraryRepository(url: libraryURL)
        do {
            if let saved = try repository.load() {
                library = saved
                serializedBytes = try LibraryArchive.encode(saved).count
                saveStatus = "Saved on this device"
            } else {
                try makeWelcome()
                serializedBytes = try LibraryArchive.encode(library).count
                dirty = true
                _ = flush()
            }
            sheetID = library.nodes.first(where: { $0.kind == .sheet && !$0.isTrashed })?.id
        } catch {
            canSave = false
            recoveryAvailable = (try? repository.recoverBackup()) != nil
            saveStatus = "Library could not be opened"
            errorMessage = "Your original library has been left untouched. \(error.localizedDescription)\nUse File → Show Library in Finder to preserve or repair it, then restart iNotes."
        }
        restoreBackupFolders()
    }

    var selectedSheet: NoteNode? { library.nodes.first { $0.id == sheetID } }
    func sheetNumber(_ id: UUID) -> Int? { library.node(id: id)?.sheetNumber }
    func sheetHeading(_ id: UUID) -> String {
        guard let sheet = library.node(id: id), sheet.kind == .sheet,
              let parentID = sheet.parentID, let parent = library.node(id: parentID) else { return "Sheets" }
        return parent.title
    }
    var folders: [NoteNode] { library.nodes.filter { $0.kind != .sheet && !$0.isTrashed } }
    var visibleSheets: [NoteNode] {
        let hits: Set<UUID>? = search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : Set(library.search(search, includingTrash: filter == .trash).map(\.id))
        let scopedIDs = hits == nil && filter == .all
            ? folderID.map { library.subtreeIDs(rootID: $0) } : nil
        return library.nodes.filter { node in
            guard node.kind == .sheet else { return false }
            switch filter {
            case .all: guard !node.isTrashed else { return false }
            case .favorites: guard !node.isTrashed && node.isFavorite else { return false }
            case .trash: guard node.isTrashed else { return false }
            }
            if let hits { return hits.contains(node.id) }
            return scopedIDs?.contains(node.id) ?? true
        }.sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order }
    }

    func children(_ parent: UUID?) -> [NoteNode] {
        folders.filter { $0.parentID == parent }.sorted { $0.order < $1.order }
    }

    func breadcrumb(_ id: UUID?) -> String {
        var pieces: [String] = []
        var next = id
        var seen = Set<UUID>()
        while let current = next, seen.insert(current).inserted,
              let node = library.nodes.first(where: { $0.id == current }) {
            pieces.insert(node.title, at: 0)
            next = node.parentID
        }
        return pieces.joined(separator: " / ")
    }

    func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var next: UUID? = id
        var seen = Set<UUID>()
        while let current = next, seen.insert(current).inserted {
            if current == ancestor { return true }
            next = library.nodes.first(where: { $0.id == current })?.parentID
        }
        return false
    }

    func chooseFolder(_ id: UUID?) {
        folderID = id
        filter = .all
        search = ""
        sheetID = visibleSheets.first?.id
    }

    func create(_ kind: NoteKind, title: String = "", parent: UUID?) {
        var createdID: UUID?
        if mutate({ createdID = try $0.create(kind: kind, title: title, parentID: parent) }), let id = createdID {
            filter = .all; search = ""
            if kind == .sheet { folderID = parent; sheetID = id }
            else { folderID = id; sheetID = nil }
        }
    }

    /// Validate page transactions before the editor records undo or changes its view.
    func validatePageChange(_ id: UUID, content: PageContent) -> Bool {
        guard var node = library.node(id: id), !node.isTrashed else { return false }
        node.pageContent = content
        do {
            var candidate = library
            try candidate.update(node)
            _ = try LibraryArchive.encode(candidate)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func update(_ id: UUID, _ change: (inout NoteNode) -> Void) {
        guard let index = library.nodes.firstIndex(where: { $0.id == id }), !library.nodes[index].isTrashed else { return }
        var node = library.nodes[index]
        change(&node)
        node.updatedAt = Date()
        do {
            var updatedLibrary = library
            try updatedLibrary.update(node)
            guard let committedNode = updatedLibrary.node(id: id) else { return }
            let delta = try LibraryArchive.encodedNodeSize(committedNode) - LibraryArchive.encodedNodeSize(library.nodes[index])
            let predicted = serializedBytes + delta
            // The small reserve covers envelope timestamp changes. Check the entire archive near the limit.
            let needsFullCheck = committedNode.parentID != library.nodes[index].parentID
                || predicted > LibraryArchive.maximumBytes - 1024
            if mutate({ $0 = updatedLibrary }, checkSize: needsFullCheck) {
                if !needsFullCheck { serializedBytes = predicted }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func binding<T>(_ id: UUID, _ keyPath: WritableKeyPath<NoteNode, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.library.nodes.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
                set: { value in self.update(id) { $0[keyPath: keyPath] = value } })
    }

    func rename(_ id: UUID, to title: String) { update(id) { $0.title = title } }
    func trash(_ id: UUID) {
        mutate { try $0.trash(id: id) }
        if let folderID, isDescendant(folderID, of: id) { self.folderID = nil }
        if let sheetID, isDescendant(sheetID, of: id) { self.sheetID = visibleSheets.first?.id }
    }
    func restore(_ id: UUID) {
        if mutate({ try $0.restore(id: id) }), filter == .trash { sheetID = visibleSheets.first?.id }
    }
    func duplicate(_ id: UUID) {
        var newID: UUID?
        if mutate({ newID = try $0.duplicate(id: id) }) { sheetID = newID }
    }
    func move(_ id: UUID, to parent: UUID) {
        if mutate({ try $0.move(id: id, to: parent) }) {
            chooseFolder(parent)
            if library.node(id: id)?.kind == .sheet { sheetID = id }
        }
    }

    @discardableResult private func mutate(_ work: (inout NoteLibrary) throws -> Void, checkSize: Bool = true) -> Bool {
        guard canSave else { errorMessage = "The library is in recovery mode. Restart after repairing the original library."; return false }
        do {
            var candidate = library
            try work(&candidate)
            if checkSize { serializedBytes = try LibraryArchive.encode(candidate).count }
            library = candidate
            dirty = true
            backupNeedsWrite.formUnion(BackupDestination.allCases)
            for destination in BackupDestination.allCases where backupFolder(for: destination) != nil && backupRetryAfter[destination] == nil {
                backupStatuses[destination] = "Automatic backup pending. Your latest edits are saving on this device."
            }
            saveStatus = "Saving…"
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                _ = self?.flush()
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult func flush() -> Bool {
        saveTask?.cancel()
        guard canSave else { return false }
        guard dirty else { return true }
        do {
            try repository.save(library)
            dirty = false
            saveStatus = "Saved on this device"
            scheduleBackups()
            return true
        } catch {
            saveStatus = "Not saved — retry with ⌘S"
            errorMessage = "Could not save your changes. Keep iNotes open and export a backup. \(error.localizedDescription)"
            return false
        }
    }

    func archiveData() throws -> Data {
        guard canSave else { throw RepositoryError.recoveryRequired }
        return try LibraryArchive.encode(library)
    }

    func recoverPreviousVersion() {
        do {
            library = try repository.restoreFromBackup()
            serializedBytes = try LibraryArchive.encode(library).count
            canSave = true
            recoveryAvailable = false
            dirty = false
            saveStatus = "Previous version restored"
            errorMessage = nil
            sheetID = library.nodes.first { $0.kind == .sheet && !$0.isTrashed }?.id
        } catch { errorMessage = error.localizedDescription }
    }

    func importArchive(_ data: Data) {
        do {
            let incoming = try LibraryArchive.decode(data)
            var roots: [UUID] = []
            if mutate({ roots = try $0.merge(incoming) }) {
                chooseFolder(roots.first)
            }
        } catch { errorMessage = "Could not import this backup. \(error.localizedDescription)" }
    }

    func backupFolder(for destination: BackupDestination) -> URL? {
        destination == .googleDrive ? driveFolder : iCloudFolder
    }

    func lastBackup(for destination: BackupDestination) -> Date? {
        destination == .googleDrive ? lastBackup : lastICloudBackup
    }

    func backupStatus(for destination: BackupDestination) -> String {
        backupStatuses[destination] ?? "Not connected"
    }

    func backupPermissionDiagnostic(for destination: BackupDestination) -> String {
        backupPermissionErrors[destination] ?? "none"
    }

    func backupToDrive() { backupNow(to: .googleDrive) }

    func backupNow(to destination: BackupDestination) {
        backupTasks.removeValue(forKey: destination)?.cancel()
        performBackup(to: destination, reportFailure: true)
    }

    private func performBackup(to destination: BackupDestination, reportFailure: Bool) {
        guard let folder = backupFolder(for: destination) else { return }
        do {
            try BackupArchiveWriter.write(archiveData(), to: folder)
            let now = Date()
            if destination == .googleDrive { lastBackup = now } else { lastICloudBackup = now }
            preferences.set(now, forKey: destination.lastBackupKey)
            backupNeedsWrite.remove(destination)
            backupRetryAfter.removeValue(forKey: destination)
            backupStatuses[destination] = "Backup saved to folder. \(destination.title) handles uploading."
                + (backupSessionOnly.contains(destination) ? " Reconnect after restarting iNotes." : "")
        } catch {
            backupNeedsWrite.insert(destination)
            backupRetryAfter[destination] = Date().addingTimeInterval(BackupSchedule.minimumInterval)
            backupStatuses[destination] = "Backup failed; retrying in 1 minute. Your notes remain on this device."
            if reportFailure { errorMessage = "The \(destination.title) folder backup failed. Your notes remain in iNotes. \(error.localizedDescription)" }
            scheduleBackups()
        }
    }

    private func scheduleBackups() {
        for destination in BackupDestination.allCases {
            guard backupFolder(for: destination) != nil, backupNeedsWrite.contains(destination), backupTasks[destination] == nil else { continue }
            let delay = BackupSchedule.delay(now: Date(), lastSuccess: lastBackup(for: destination), retryAfter: backupRetryAfter[destination])
            backupTasks[destination] = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                self?.backupTasks.removeValue(forKey: destination)
                self?.performBackup(to: destination, reportFailure: false)
            }
        }
    }

    func prepareForQuit() -> Bool {
        guard flush() else { return false }
        for destination in BackupDestination.allCases where backupNeedsWrite.contains(destination) && backupFolder(for: destination) != nil {
            backupTasks.removeValue(forKey: destination)?.cancel()
            performBackup(to: destination, reportFailure: false)
        }
        return true
    }

    func emptyTrash() { mutate { $0.emptyTrash() }; sheetID = nil }

    func rememberDriveFolder(_ url: URL) { rememberBackupFolder(url, for: .googleDrive) }

    func rememberBackupFolder(_ url: URL, for destination: BackupDestination) {
        let access = BackupFolderAccess(url: url)
        backupTasks.removeValue(forKey: destination)?.cancel()
        backupAccesses[destination] = access
        if destination == .googleDrive { driveFolder = url; lastBackup = nil }
        else { iCloudFolder = url; lastICloudBackup = nil }
        preferences.removeObject(forKey: destination.lastBackupKey)
        backupSessionOnly.remove(destination)
        backupRetryAfter.removeValue(forKey: destination)
        do {
            preferences.set(try access.bookmark(), forKey: destination.bookmarkKey)
            backupPermissionErrors.removeValue(forKey: destination)
        } catch {
            preferences.removeObject(forKey: destination.bookmarkKey)
            backupSessionOnly.insert(destination)
            backupPermissionErrors[destination] = BackupFolderAccess.diagnostic(error)
            errorMessage = "The \(destination.title) folder is connected for this session. Reconnect it after restarting iNotes. \(error.localizedDescription)"
        }
        backupNow(to: destination)
    }

    func disconnectDrive() { disconnectBackup(.googleDrive) }

    func disconnectBackup(_ destination: BackupDestination) {
        backupTasks.removeValue(forKey: destination)?.cancel()
        backupNeedsWrite.remove(destination)
        backupRetryAfter.removeValue(forKey: destination)
        backupSessionOnly.remove(destination)
        backupPermissionErrors.removeValue(forKey: destination)
        backupAccesses.removeValue(forKey: destination)
        if destination == .googleDrive { driveFolder = nil; lastBackup = nil }
        else { iCloudFolder = nil; lastICloudBackup = nil }
        backupStatuses[destination] = "Not connected"
        preferences.removeObject(forKey: destination.bookmarkKey)
        preferences.removeObject(forKey: destination.lastBackupKey)
    }

    private func restoreBackupFolders() {
        for destination in BackupDestination.allCases {
            guard let bookmark = preferences.data(forKey: destination.bookmarkKey) else { continue }
            do {
                let restored = try BackupFolderAccess.restore(bookmark)
                backupAccesses[destination] = restored.access
                let last = preferences.object(forKey: destination.lastBackupKey) as? Date
                if destination == .googleDrive { driveFolder = restored.access.url; lastBackup = last }
                else { iCloudFolder = restored.access.url; lastICloudBackup = last }
                backupStatuses[destination] = "Folder connected. Cloud upload is managed by \(destination.title)."
                if restored.stale {
                    do { preferences.set(try restored.access.bookmark(), forKey: destination.bookmarkKey) }
                    catch {
                        backupSessionOnly.insert(destination)
                        backupPermissionErrors[destination] = BackupFolderAccess.diagnostic(error)
                    }
                }
                if last.map({ library.modifiedAt > $0 }) ?? true {
                    backupNeedsWrite.insert(destination)
                    backupStatuses[destination] = "Automatic backup pending. The provider handles cloud uploading."
                }
            } catch {
                backupPermissionErrors[destination] = BackupFolderAccess.diagnostic(error)
                backupStatuses[destination] = "Folder permission needs attention. Reconnect the folder."
            }
        }
        if canSave { scheduleBackups() }
    }

    private func makeWelcome() throws {
        let workbook = try library.create(kind: .workbook, title: "My Notebook", parentID: nil)
        let chapter = try library.create(kind: .chapter, title: "Getting started", parentID: workbook)
        let id = try library.create(kind: .sheet, title: "A little space for big ideas", parentID: chapter)
        if var page = library.nodes.first(where: { $0.id == id }) {
            page.strokes = [InkStroke(points: [InkPoint(x: 385, y: 58, pressure: 0.5), InkPoint(x: 397, y: 72, pressure: 0.8), InkPoint(x: 426, y: 39, pressure: 0.6)], colorHex: "#3869B2", width: 3)]
            page.body = "Welcome to iNotes\n\nA quiet, native home for your notes.\n\n• Organize workbooks into chapters, nested topics, and sheets.\n• Type rich text and write over or alongside it with your pen.\n• Use pen, pencil, marker, highlighter, and Text on the same page.\n• Choose dotted, grid, ruled, or blank paper; your choice saves with the sheet.\n• Find anything with search, or keep a sheet in Favorites.\n• Your changes save automatically on this device.\n\nGoogle Drive\nChoose a folder in Google Drive for desktop from the cloud menu. iNotes saves versioned backups there. Import a backup on another device to bring notes across.\n\nKeyboard\n⌘N — New sheet\n⌘S — Save now\n⌘B / ⌘I — Bold / Italic\n⌘F — Search\n\nMake yourself at home."
            try library.update(page)
        }
    }
}

#if os(macOS)
@MainActor
enum BackupDiagnostics {
    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-backup-check-\(UUID())")
        let suite = "io.inotes.backup-diagnostics.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func require(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
            if try !value() { throw NSError(domain: "iNotes.BackupDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
        }
        let google = root.appendingPathComponent("Google", isDirectory: true)
        let cloud = root.appendingPathComponent("iCloud", isDirectory: true)
        for folder in [google, cloud] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = NotesStore(directory: root.appendingPathComponent("Library"), preferences: preferences)
        store.rememberBackupFolder(google, for: .googleDrive)
        store.rememberBackupFolder(cloud, for: .iCloudDrive)
        try require(store.lastBackup != nil && store.lastICloudBackup != nil, "Both destinations back up immediately after connection")
        try require(preferences.data(forKey: BackupDestination.googleDrive.bookmarkKey) != nil && preferences.data(forKey: BackupDestination.iCloudDrive.bookmarkKey) != nil, "Both folder permissions persist independently: Google \(store.backupPermissionDiagnostic(for: .googleDrive)); iCloud \(store.backupPermissionDiagnostic(for: .iCloudDrive)); \(store.errorMessage ?? "no bookmark error")")
        if BackupFolderAccess.isKnownNonSandboxed {
            let fallback = try BackupFolderAccess(url: google).bookmark(scopedCreator: { _ in throw CocoaError(.fileReadNoPermission) })
            try require(BackupFolderAccess.isOrdinaryBookmark(fallback), "A forced scoped failure uses an explicit ordinary bookmark only outside the sandbox")
            let restoredFallback = try BackupFolderAccess.restore(fallback)
            let proof = restoredFallback.access.url.appendingPathComponent("ordinary-bookmark-proof.txt")
            try Data("fallback access proof".utf8).write(to: proof, options: .atomic)
            try require(try String(contentsOf: proof, encoding: .utf8) == "fallback access proof", "The forced ordinary fallback restores real writable folder access")
        }
        let restored = NotesStore(directory: root.appendingPathComponent("Library"), preferences: preferences)
        try require(restored.driveFolder?.resolvingSymlinksInPath() == google.resolvingSymlinksInPath() && restored.iCloudFolder?.resolvingSymlinksInPath() == cloud.resolvingSymlinksInPath(), "Both folder bookmarks reopen after restarting")
        guard let sheet = store.selectedSheet else { throw LibraryError.nodeNotFound }
        store.iCloudFolder = root.appendingPathComponent("Unavailable")
        store.update(sheet.id) { $0.body += "\nAutomatic Google backup survives an unavailable iCloud folder." }
        try require(store.prepareForQuit(), "An unavailable backup destination does not prevent a successful local quit save")
        let googleFiles = try FileManager.default.contentsOfDirectory(at: google.appendingPathComponent("iNotes Backups"), includingPropertiesForKeys: nil)
        let cloudFiles = try FileManager.default.contentsOfDirectory(at: cloud.appendingPathComponent("iNotes Backups"), includingPropertiesForKeys: nil)
        try require(googleFiles.count == 2 && cloudFiles.count == 1, "Google receives the changed backup independently of iCloud failure")
        try require(store.backupStatus(for: .iCloudDrive).contains("retrying"), "A failed target advertises its automatic retry")
        // Filenames may share a timestamp; find the completed archive by content.
        let contents = try googleFiles.map { try LibraryArchive.decode(LibraryArchive.read(from: $0)) }
        try require(contents.contains(where: { $0.node(id: sheet.id)?.body == store.library.node(id: sheet.id)?.body }), "The automatic Google archive includes the latest edits")
        store.iCloudFolder = cloud
        store.backupNow(to: .iCloudDrive)
        try require(store.backupStatus(for: .iCloudDrive).contains("saved to folder"), "A repaired destination can retry without discarding notes")
        store.disconnectDrive()
        try require(store.driveFolder == nil && store.iCloudFolder == cloud && preferences.data(forKey: BackupDestination.iCloudDrive.bookmarkKey) != nil, "Disconnecting Google preserves iCloud connection and permission")
        store.disconnectBackup(.iCloudDrive)
        restored.disconnectDrive()
        restored.disconnectBackup(.iCloudDrive)
        return "Backup integration checks passed: independent destinations, bookmarks/relaunch, auto-backup on quit, Google fallback, failed-target retry, complete latest archive, independent disconnect"
    }
}
#endif
