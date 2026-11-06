import SwiftUI
import NotesCore
#if os(macOS)
import AppKit
#endif

@main
struct iNotesApp: App {
    @StateObject private var store: NotesStore
    @StateObject private var inputDevice = InputDeviceMonitor()
    @AppStorage("appearance") private var appearance = "system"
    #if os(macOS)
    @StateObject private var updater = AppUpdater()
    @StateObject private var toolShortcutMonitor = ToolShortcutMonitor()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    @Environment(\.scenePhase) private var phase

    init() {
        #if os(macOS)
        if CommandLine.arguments.contains("--smoke-test") {
            do {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-check-\(UUID())")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let repository = LibraryRepository(url: temporary.appendingPathComponent("Library.json"))
                var library = NoteLibrary()
                let root = try library.create(kind: .workbook, title: "Smoke test", parentID: nil)
                let chapter = try library.create(kind: .chapter, title: "Chapter", parentID: root)
                let page = try library.create(kind: .sheet, title: "Native ARM64", parentID: chapter)
                try library.rename(id: page, title: "Saved and reloaded")
                try repository.save(library)
                guard let loaded = try repository.load(), loaded.nodes.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
                let decoded = try LibraryArchive.decode(LibraryArchive.encode(loaded))
                guard decoded.nodes.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
                if CommandLine.arguments.contains("--diagram-test") {
                    print("\(try DiagramDiagnostics.run()) native diagram checks passed")
                }
                if CommandLine.arguments.contains("--workspace-test") {
                    print(try WorkspaceDiagnostics.run())
                } else if CommandLine.arguments.contains("--editor-test") {
                    print(try EditorDiagnostics.run())
                    print(try EquationDiagnostics.run())
                    print(try ToolShortcutDiagnostics.run())
                    print(try RuledTextDiagnostics.run())
                    print(try WorkspaceDiagnostics.run())
                }
                print(try StoreDiagnostics.run())
                print(try StoreDiagnostics.runSheetNumberingChecks())
                print(try StoreDiagnostics.runHierarchyChecks())
                print(try BackupDiagnostics.run())
                print("iNotes self-check passed: hierarchy, atomic save, reload, archive round-trip; \(ProcessInfo.processInfo.operatingSystemVersionString)")
                exit(0)
            } catch { fputs("iNotes self-check failed: \(error)\n", stderr); exit(1) }
        }
        #endif
        _store = StateObject(wrappedValue: NotesStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).environmentObject(inputDevice)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                #if os(macOS)
                .frame(minWidth: 880, minHeight: 580)
                .onAppear {
                    _ = toolShortcutMonitor
                    delegate.store = store
                    updater.prepareForInstallation = { [weak store = store] in
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return store?.prepareForQuit() ?? false
                    }
                }
                #endif
                .onOpenURL { url in
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do { store.importArchive(try LibraryArchive.read(from: url)) }
                    catch { store.errorMessage = error.localizedDescription }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1220, height: 800)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { NotesCommands(store: store, updater: updater) }
        #endif
        .onChange(of: phase) { _, value in
            if value == .background { _ = store.prepareForQuit() }
            else if value != .active { _ = store.flush() }
        }
    }
}

#if os(macOS)
@MainActor
enum StoreDiagnostics {
    /// Exercise numbering and native-list move offsets without creating a UI window.
    static func runSheetNumberingChecks() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-numbering-check-\(UUID())")
        let suite = "io.inotes.numbering-diagnostics.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suite)
        }
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
            guard condition() else {
                throw NSError(domain: "iNotes.NumberingDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            checks += 1
        }
        let store = NotesStore(directory: directory, preferences: preferences)
        guard let workbook = store.library.roots.first?.id else { throw LibraryError.nodeNotFound }
        func createSheet(in parent: UUID) throws -> UUID {
            store.create(.sheet, parent: parent)
            guard store.errorMessage == nil, let id = store.sheetID,
                  store.library.node(id: id)?.parentID == parent else { throw LibraryError.nodeNotFound }
            return id
        }
        func checkSequence(_ ids: [UUID], in parent: UUID) throws {
            let sheets = store.library.children(of: parent).filter { $0.kind == .sheet }
            try require(sheets.map(\.id) == ids, "Sheet order follows the requested page positions")
            try require(sheets.compactMap(\.sheetNumber) == Array(1...ids.count), "Active page numbers remain contiguous")
        }
        func rejectMove(_ offsets: IndexSet, to destination: Int, _ reason: String) throws {
            let before = store.library
            let selection = store.sheetID, folder = store.folderID
            try require(!store.reorderSheets(fromOffsets: offsets, toOffset: destination), reason)
            try require(store.library == before && store.sheetID == selection && store.folderID == folder,
                        "Rejected reordering preserves notes and navigation")
        }

        store.create(.chapter, title: "Page numbering", parent: workbook)
        guard let chapter = store.folderID else { throw LibraryError.nodeNotFound }
        let first = try createSheet(in: chapter)
        let second = try createSheet(in: chapter)
        let third = try createSheet(in: chapter)
        try require([first, second, third].allSatisfy { store.library.node(id: $0)?.title == "" },
                    "New sheets store empty titles without substituting their page-number labels")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        store.update(first) {
            $0.pageContent = PageContent(text: "Keep these notes — नमस्ते",
                strokes: [InkStroke(points: [InkPoint(x: 30, y: 40), InkPoint(x: 80, y: 60)])],
                textBoxes: [PageTextBox(x: 50, y: 70, text: "Caption")],
                equations: [NoteEquation(latex: "x^2")],
                images: [PageImage(x: 40, y: 50, width: 100, height: 100, imageData: png)])
        }
        store.rename(third, to: "A named page")
        guard let original = store.library.node(id: first) else { throw LibraryError.nodeNotFound }
        store.sheetID = first
        let titleEditOrder = store.library.nodes.map(\.id)
        let titleEditNumbers = store.library.children(of: chapter).compactMap(\.sheetNumber)
        for title in ["Physics", "Physics notes — café 日本語 नमस्ते", ""] {
            store.rename(first, to: title)
            guard let renamed = store.library.node(id: first) else { throw LibraryError.nodeNotFound }
            try require(store.errorMessage == nil && renamed.title == title,
                        "Consecutive title edits and clearing update the stored sheet name")
            try require(renamed.id == original.id && renamed.createdAt == original.createdAt
                        && renamed.pageContent == original.pageContent && renamed.order == original.order
                        && renamed.sheetNumber == original.sheetNumber && renamed.parentID == original.parentID
                        && store.library.nodes.map(\.id) == titleEditOrder
                        && store.library.children(of: chapter).compactMap(\.sheetNumber) == titleEditNumbers
                        && store.sheetID == first && store.folderID == chapter,
                        "Live title edits preserve page identity, creation metadata, complete content, numbering, order and selection")
            try require(store.flush() && store.errorMessage == nil, "Each live title edit saves successfully")
            let titleReload = NotesStore(directory: directory, preferences: preferences)
            guard let savedTitle = titleReload.library.node(id: first) else { throw LibraryError.nodeNotFound }
            try require(titleReload.errorMessage == nil && savedTitle.title == title
                        && savedTitle.id == original.id
                        && abs(savedTitle.createdAt.timeIntervalSince1970 - original.createdAt.timeIntervalSince1970) < 0.001
                        && savedTitle.pageContent == original.pageContent && savedTitle.order == original.order
                        && savedTitle.sheetNumber == original.sheetNumber && savedTitle.parentID == original.parentID
                        && titleReload.library.nodes.map(\.id) == titleEditOrder
                        && titleReload.library.children(of: chapter).compactMap(\.sheetNumber) == titleEditNumbers,
                        "Saved Unicode titles and blank titles reopen with page content, identity, metadata and numbering intact")
        }
        store.trash(second)
        try checkSequence([first, third], in: chapter)
        try require(store.library.node(id: second)?.isTrashed == true, "Deleted page remains recoverable in Trash")
        let appended = try createSheet(in: chapter)
        try checkSequence([first, third, appended], in: chapter)
        store.sheetID = first
        try require(store.reorderSheets(fromOffsets: IndexSet(integer: 2), toOffset: 1), "Page 3 can move between pages 1 and 2")
        try checkSequence([first, appended, third], in: chapter)
        try require(store.reorderSheets(fromOffsets: IndexSet(integer: 1), toOffset: 3), "A page can move downward to the end")
        try checkSequence([first, third, appended], in: chapter)
        try require(store.reorderSheets(fromOffsets: IndexSet(integer: 0), toOffset: 3), "The first page can move to the end")
        try checkSequence([third, appended, first], in: chapter)
        try require(store.reorderSheets(fromOffsets: IndexSet(integer: 2), toOffset: 0), "The final page can move to the start")
        try checkSequence([first, third, appended], in: chapter)
        try require(store.sheetID == first && store.folderID == chapter, "Reordering retains the selected editor identity")
        try require(store.library.node(id: first)?.pageContent == original.pageContent
                    && store.library.node(id: first)?.createdAt == original.createdAt
                    && store.library.node(id: third)?.title == "A named page",
                    "Reordering preserves text, ink, objects, image bytes, creation dates and titles")
        for id in [first, third, appended] { store.trash(id) }
        let restarted = try createSheet(in: chapter)
        try checkSequence([restarted], in: chapter)
        try require(store.library.node(id: first)?.pageContent == original.pageContent, "Restarting at Sheet 1 keeps deleted page content")

        store.create(.chapter, title: "Mixed siblings", parent: workbook)
        guard let mixed = store.folderID else { throw LibraryError.nodeNotFound }
        let mixedFirst = try createSheet(in: mixed)
        store.create(.topic, title: "Nested topic", parent: mixed)
        guard let topic = store.folderID else { throw LibraryError.nodeNotFound }
        let retained = try createSheet(in: mixed)
        let mixedSecond = try createSheet(in: mixed)
        let mixedThird = try createSheet(in: mixed)
        store.trash(retained)
        store.chooseFolder(mixed)
        store.sheetID = mixedSecond
        try require(store.reorderSheets(fromOffsets: IndexSet(integer: 2), toOffset: 1), "Visible offsets account for hidden folder and Trash siblings")
        try checkSequence([mixedFirst, mixedThird, mixedSecond], in: mixed)
        try require(store.library.children(of: mixed, includingTrash: true).map(\.id)
                    == [mixedFirst, topic, retained, mixedThird, mixedSecond], "Full sibling insertion keeps the folder and Trash positions")
        try require(store.reorderSheets(fromOffsets: IndexSet(integer: 0), toOffset: 3), "End insertion accounts for full sibling positions")
        try checkSequence([mixedThird, mixedSecond, mixedFirst], in: mixed)
        try require(store.sheetID == mixedSecond, "Mixed-sibling moves preserve selection")
        try rejectMove(IndexSet([0, 1]), to: 3, "Multiple-sheet drag is rejected")
        try rejectMove(IndexSet(integer: 99), to: 0, "Invalid source offset is rejected")
        try rejectMove(IndexSet(integer: 0), to: -1, "Negative destination is rejected")
        try rejectMove(IndexSet(integer: 0), to: 99, "Invalid destination offset is rejected")
        store.search = "Caption"
        try rejectMove(IndexSet(integer: 0), to: 1, "Search results cannot reorder a visible subset")
        store.search = ""
        store.filter = .favorites
        try rejectMove(IndexSet(integer: 0), to: 1, "Favorites cannot reorder a visible subset")
        store.filter = .trash
        try rejectMove(IndexSet(integer: 0), to: 1, "Trash cannot reorder active pages")
        store.filter = .all
        let nested = try createSheet(in: topic)
        store.chooseFolder(mixed)
        store.sheetID = mixedSecond
        let displayed = store.visibleSheets
        guard let source = displayed.firstIndex(where: { $0.id == mixedFirst }),
              let destination = displayed.firstIndex(where: { $0.id == nested }) else { throw LibraryError.nodeNotFound }
        try rejectMove(IndexSet(integer: source), to: destination, "Cross-parent drag in a descendant-inclusive list is rejected")
        let archive = try store.archiveData()
        try require(store.flush() && store.errorMessage == nil, "Numbering and reordering save successfully")
        let saved = try LibraryArchive.read(from: store.libraryURL)
        try require(saved == archive, "Persistence writes the exact validated archive bytes")
        let reopened = NotesStore(directory: directory, preferences: preferences)
        try require(reopened.errorMessage == nil
                    && reopened.library.children(of: mixed).filter { $0.kind == .sheet }.map(\.id) == [mixedThird, mixedSecond, mixedFirst]
                    && reopened.library.node(id: mixedFirst)?.sheetNumber == 3
                    && reopened.library.node(id: first)?.pageContent == original.pageContent,
                    "Reopening preserves page positions, numbering and retained image-bearing notes")
        return "Sheet numbering/store checks passed: \(checks), including blank/Unicode live titles, delete/reset, native move offsets, mixed siblings, rejection, selection/content preservation and exact save/reopen"
    }

    /// Exercise the real import-to-navigation path using a disposable library.
    static func runHierarchyChecks() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-hierarchy-check-\(UUID())")
        let suite = "io.inotes.hierarchy-diagnostics.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suite)
        }
        func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
            if !condition() { throw NSError(domain: "iNotes.HierarchyDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
        }
        let store = NotesStore(directory: directory, preferences: preferences)
        guard let original = store.selectedSheet, let originalParent = original.parentID else { throw LibraryError.nodeNotFound }
        store.update(original.id) { $0.body = "outside-needle" }
        try require(store.flush(), "Initial legitimate note saves")
        let priorNodes = store.library.nodes
        let folders = (0..<127).map { _ in UUID() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var sheets = (1...49_000).map { number in
            NoteNode(parentID: folders.last!, kind: .sheet, title: "", createdAt: date,
                     updatedAt: date, order: number, sheetNumber: number)
        }
        sheets[0].body = "inside-needle"
        sheets[0].isFavorite = true
        sheets[0].strokes = [InkStroke(points: [InkPoint(x: 10, y: 20)], width: 0.8)]
        let ancestors = folders.enumerated().map { index, id in
            NoteNode(id: id, parentID: index == 0 ? nil : folders[index - 1],
                     kind: index == 0 ? .workbook : index == 1 ? .chapter : .topic,
                     title: "Folder", createdAt: date, updatedAt: date,
                     lastSheetNumber: index == 126 ? sheets.count : 0)
        }
        let archive = try LibraryArchive.encode(NoteLibrary(nodes: sheets + ancestors))
        let start = ProcessInfo.processInfo.systemUptime
        store.importArchive(archive)
        let importedIn = ProcessInfo.processInfo.systemUptime - start
        try require(store.errorMessage == nil, "Near-limit archive imports successfully")
        guard let root = store.folderID, let selected = store.selectedSheet else { throw LibraryError.nodeNotFound }
        let queryStart = ProcessInfo.processInfo.systemUptime
        let visible = store.visibleSheets
        let queryIn = ProcessInfo.processInfo.systemUptime - queryStart
        try require(queryIn < 5, "Near-limit folder selection remains bounded")
        try require(visible.count == sheets.count && visible.first?.sheetNumber == 1 && visible.last?.sheetNumber == 49_000, "Untitled sheets keep their sequence and ordering")
        try require(selected.title.isEmpty && selected.body == sheets[0].body && selected.strokes == sheets[0].strokes, "Import preserves title, text and ink")
        let previousIDs = Set(priorNodes.map(\.id))
        try require(store.library.nodes.filter { previousIDs.contains($0.id) } == priorNodes, "Import leaves previous notes unchanged")
        store.search = "outside-needle"
        try require(store.visibleSheets.map(\.id) == [original.id], "Search still spans folders")
        store.search = ""; store.filter = .favorites; store.folderID = originalParent
        try require(store.visibleSheets.map(\.id) == [selected.id], "Favorites still ignores the folder filter")
        store.trash(selected.id); store.filter = .trash
        try require(store.visibleSheets.map(\.id) == [selected.id], "Trash still ignores the folder filter")
        store.restore(selected.id)
        store.move(selected.id, to: originalParent)
        store.chooseFolder(root)
        try require(store.visibleSheets.count == sheets.count - 1, "Moving a sheet updates subtree membership immediately")
        try require(store.flush(), "Near-limit imported library saves")
        return "Hierarchy security checks passed: 49,127-node leaf-first import \(String(format: "%.3f", importedIn))s; folder query \(String(format: "%.3f", queryIn))s; original notes, untitled numbering, text/ink, search, Favorites, Trash and moves preserved"
    }

    static func run() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-store-check-\(UUID())")
        let suite = "io.inotes.diagnostics.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suite)
        }
        func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
            if !condition() { throw NSError(domain: "iNotes.StoreDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
        }
        let updateSettings: [String: Any] = [
            "SUFeedURL": "https://github.com/icode100/iNotes/releases/latest/download/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0
        ]
        try require(AppUpdater.configuration(in: updateSettings).valid, "Signed HTTPS release configuration is accepted")
        for rejectedFeed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:secret@example.com/feed", "https://example.com/feed#fragment", "https://example.com:bad/feed", "https://example.com:65536/feed", "https://example.com:0/feed"] {
            var invalid = updateSettings
            invalid["SUFeedURL"] = rejectedFeed
            try require(!AppUpdater.configuration(in: invalid).valid, "Unsafe update feed is rejected")
        }
        var unsignedUpdates = updateSettings
        unsignedUpdates["SUVerifyUpdateBeforeExtraction"] = false
        try require(!AppUpdater.configuration(in: unsignedUpdates).valid, "Unsigned archive updates are rejected")
        unsignedUpdates = updateSettings
        unsignedUpdates["SURequireSignedFeed"] = false
        try require(!AppUpdater.configuration(in: unsignedUpdates).valid, "Unsigned update feeds are rejected")
        for expiry in [nil, 20 * 24 * 60 * 60, -1, "invalid"] as [Any?] {
            var invalid = updateSettings
            invalid["SUSignedFeedFailureExpirationInterval"] = expiry
            try require(!AppUpdater.configuration(in: invalid).valid, "Unsigned-feed fallback must stay disabled")
        }
        var invalidKey = updateSettings
        invalidKey["SUPublicEDKey"] = Data(repeating: 7, count: 31).base64EncodedString()
        try require(!AppUpdater.configuration(in: invalidKey).valid, "Invalid public-key length is rejected")
        try require(!AppUpdater.configuration(in: [:]).valid, "An unconfigured updater remains dormant")
        let store = NotesStore(directory: directory, preferences: preferences)
        try require(store.errorMessage == nil && !store.dirty, "New library must save successfully")
        guard let sheet = store.selectedSheet else { throw CocoaError(.fileReadCorruptFile) }
        store.update(sheet.id) {
            $0.body = "Integration test: नमस्ते 👋 café"; $0.tags = ["integration"]; $0.isFavorite = true
            $0.paperStyle = .grid
            $0.strokes = [InkStroke(points: [InkPoint(x: 40, y: 90, pressure: 0.7), InkPoint(x: 100, y: 120, pressure: 0.4)], style: .pencil)]
        }
        try require(store.dirty, "Editing marks library dirty")
        try require(store.flush(), "Store flush saves the working copy")
        let reopened = NotesStore(directory: directory, preferences: preferences)
        try require(reopened.library.node(id: sheet.id)?.body == "Integration test: नमस्ते 👋 café", "Reopen preserves Unicode notes")
        try require(reopened.library.node(id: sheet.id)?.paperStyle == .grid && reopened.library.node(id: sheet.id)?.strokes.first?.style == .pencil, "Paper and handwriting style persist on the same typed sheet")
        let previousBody = store.library.node(id: sheet.id)?.body
        store.update(sheet.id) { $0.body = String(repeating: "x", count: LibraryArchive.maximumBytes) }
        try require(store.library.node(id: sheet.id)?.body == previousBody && store.errorMessage != nil, "Oversized edits are rejected without losing saved or exportable content")
        store.errorMessage = nil
        let workbook = store.library.roots.first!.id
        store.create(.chapter, title: "Empty chapter", parent: workbook)
        try require(store.folderID != nil && store.sheetID == nil, "New empty chapter clears the unrelated editor selection")
        let before = store.library.nodes.count
        store.importArchive(try store.archiveData())
        try require(store.library.nodes.count == before * 2, "Import adds independent notebooks")
        try require(store.flush(), "Imported notebooks save")
        let drive = directory.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        store.driveFolder = drive
        store.backupToDrive()
        try require(store.errorMessage == nil && store.lastBackup != nil, "Versioned backup writes successfully: \(store.errorMessage ?? "")")
        guard let backups = store.managedBackupDirectory(for: .googleDrive) else { throw LibraryError.nodeNotFound }
        let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        try require(files.count == 1, "First backup produces one file")
        let backup = try LibraryArchive.decode(LibraryArchive.read(from: files[0]))
        try require(backup.nodes.count == store.library.nodes.count, "Drive backup contains complete notebook data")
        store.update(sheet.id) { $0.body += "\nLast edit before quit" }
        try require(store.prepareForQuit(), "Normal quit flushes changes")
        let finalFiles = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        try require(finalFiles.count == 2, "Normal quit creates a final versioned backup")
        store.disconnectDrive()
        let savedLibrary = directory.appendingPathComponent("SavedLibrary.json")
        try FileManager.default.moveItem(at: store.libraryURL, to: savedLibrary)
        try FileManager.default.createDirectory(at: store.libraryURL, withIntermediateDirectories: false)
        store.update(sheet.id) { $0.body += "\nKeep this edit when update restart is postponed" }
        try require(!store.prepareForQuit() && store.dirty, "A failed local save postpones quit/update without discarding edits")
        try FileManager.default.removeItem(at: store.libraryURL)
        try FileManager.default.moveItem(at: savedLibrary, to: store.libraryURL)
        try require(store.prepareForQuit() && !store.dirty, "A postponed quit/update can retry after storage is repaired")
        let retried = NotesStore(directory: directory, preferences: preferences)
        try require(retried.library.node(id: sheet.id)?.body.hasSuffix("Keep this edit when update restart is postponed") == true, "Retry preserves the latest edit on disk")
        return "Store and updater checks passed: autosave, reopen, import, Drive-folder backup, quit flush, failed-save restart protection/retry, and 16 signed-update configuration checks"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: NotesStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.prepareForQuit() { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Your latest changes could not be saved"
        alert.informativeText = "Keep iNotes open and export a backup from the File menu before quitting."
        alert.addButton(withTitle: "Keep iNotes Open")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
#endif
