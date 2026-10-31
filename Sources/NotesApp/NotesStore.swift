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
    @Published var dirty = false
    @Published var recoveryAvailable = false
    private let repository: LibraryRepository
    private let preferences: UserDefaults
    let libraryURL: URL
    private var saveTask: Task<Void, Never>?
    private var driveBackupTask: Task<Void, Never>?
    private var driveNeedsBackup = false
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
        #if os(macOS)
        if let data = preferences.data(forKey: "driveBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                driveFolder = url
                if stale { rememberDriveFolder(url) }
            }
        }
        #endif
    }

    var selectedSheet: NoteNode? { library.nodes.first { $0.id == sheetID } }
    var folders: [NoteNode] { library.nodes.filter { $0.kind != .sheet && !$0.isTrashed } }
    var visibleSheets: [NoteNode] {
        let hits: Set<UUID>? = search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : Set(library.search(search, includingTrash: filter == .trash).map(\.id))
        return library.nodes.filter { node in
            guard node.kind == .sheet else { return false }
            switch filter {
            case .all: guard !node.isTrashed else { return false }
            case .favorites: guard !node.isTrashed && node.isFavorite else { return false }
            case .trash: guard node.isTrashed else { return false }
            }
            if let hits { return hits.contains(node.id) }
            guard let folderID, filter == .all else { return true }
            return isDescendant(node.id, of: folderID)
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

    func create(_ kind: NoteKind, title: String, parent: UUID?) {
        var createdID: UUID?
        if mutate({ createdID = try $0.create(kind: kind, title: title, parentID: parent) }), let id = createdID {
            filter = .all; search = ""
            if kind == .sheet { folderID = parent; sheetID = id }
            else { folderID = id; sheetID = nil }
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
            let needsFullCheck = predicted > LibraryArchive.maximumBytes - 1024
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
            driveNeedsBackup = true
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
            scheduleDriveBackup()
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
                sheetID = visibleSheets.first?.id
            }
        } catch { errorMessage = "Could not import this backup. \(error.localizedDescription)" }
    }

    func backupToDrive() {
        driveBackupTask?.cancel()
        driveBackupTask = nil
        guard let folder = driveFolder else { return }
        do {
            let directory = folder.appendingPathComponent("iNotes Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let destination = directory.appendingPathComponent("iNotes-\(stamp)-\(UUID().uuidString).inotes")
            try archiveData().write(to: destination, options: .atomic)
            lastBackup = Date()
            driveNeedsBackup = false
        } catch { errorMessage = "Saved locally, but the Google Drive backup failed. \(error.localizedDescription)" }
    }

    private func scheduleDriveBackup() {
        guard driveFolder != nil, driveNeedsBackup, driveBackupTask == nil else { return }
        let delay = max(0, 60 - Date().timeIntervalSince(lastBackup ?? .distantPast))
        driveBackupTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.backupToDrive()
        }
    }

    func prepareForQuit() -> Bool {
        guard flush() else { return false }
        if driveNeedsBackup && driveFolder != nil { backupToDrive() }
        return true
    }

    func emptyTrash() { mutate { $0.emptyTrash() }; sheetID = nil }

    #if os(macOS)
    func rememberDriveFolder(_ url: URL) {
        if let old = driveFolder { old.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()
        driveFolder = url
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            preferences.set(bookmark, forKey: "driveBookmark")
            backupToDrive()
        } catch { errorMessage = "Folder connected for this session, but its permission could not be remembered. \(error.localizedDescription)" }
    }

    func disconnectDrive() {
        driveBackupTask?.cancel()
        driveBackupTask = nil
        driveFolder?.stopAccessingSecurityScopedResource()
        driveFolder = nil
        lastBackup = nil
        preferences.removeObject(forKey: "driveBookmark")
    }
    #endif

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
