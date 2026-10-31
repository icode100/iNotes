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
                if CommandLine.arguments.contains("--editor-test") {
                    print(try EditorDiagnostics.run())
                    print(try EquationDiagnostics.run())
                    print(try ToolShortcutDiagnostics.run())
                    print(try RuledTextDiagnostics.run())
                }
                print(try StoreDiagnostics.run())
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
        let backups = drive.appendingPathComponent("iNotes Backups")
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
