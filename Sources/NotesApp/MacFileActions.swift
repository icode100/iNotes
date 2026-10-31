#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NotesCore

@MainActor
enum MacFileActions {
    static func chooseDriveFolder(_ store: NotesStore) {
        chooseBackupFolder(store, destination: .googleDrive)
    }

    static func chooseBackupFolder(_ store: NotesStore, destination: BackupDestination) {
        let panel = NSOpenPanel()
        panel.title = "Auto-save to \(destination.title)"
        panel.message = "Choose a folder inside \(destination.title) in Finder. Automatic versioned backups start after connecting; the provider uploads them. Import a backup to transfer edits to another device."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect Folder"
        if panel.runModal() == .OK, let url = panel.url { store.rememberBackupFolder(url, for: destination) }
    }

    static func save(_ data: Data, title: String, type: UTType, store: NotesStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url, options: .atomic) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    static func exportLibrary(_ store: NotesStore) {
        do { save(try store.archiveData(), title: "iNotes Backup.inotes", type: .iNotesArchive, store: store) }
        catch { store.errorMessage = error.localizedDescription }
    }

    static func importLibrary(_ store: NotesStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.iNotesArchive, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Import adds a separate copy of the backup. Your existing notes are kept."
        if panel.runModal() == .OK, let url = panel.url {
            do { store.importArchive(try LibraryArchive.read(from: url)) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    static func exportRichText(_ sheet: NoteNode, store: NotesStore) {
        do { save(try richTextData(sheet), title: sheet.title + ".rtf", type: .rtf, store: store) }
        catch { store.errorMessage = error.localizedDescription }
    }

    static func richTextData(_ sheet: NoteNode) throws -> Data {
        let result = NSMutableAttributedString(string: "")
        func append(_ text: String, rtf: Data? = nil, equation: Bool = false) {
            guard !text.isEmpty else { return }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            if let rtf, let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil), attributed.string == text {
                result.append(attributed)
            } else {
                result.append(NSAttributedString(string: text, attributes: [
                    .font: equation ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 14)
                ]))
            }
        }
        append(sheet.body, rtf: sheet.richTextRTF)
        for box in sheet.textBoxes.sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) { append(box.text, rtf: box.rtfData) }
        for equation in sheet.equations.sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            append("$$\n\(equation.latex)\n$$", equation: true)
        }
        return try result.data(from: NSRange(location: 0, length: result.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func exportPagePNG(_ sheet: NoteNode, paper: InkPaper, theme: PageTheme = .light, store: NotesStore) {
        guard let data = UnifiedPageExport.png(text: sheet.body, rtfData: sheet.richTextRTF, strokes: sheet.strokes, paper: paper, theme: theme,
                                              textBoxes: sheet.textBoxes, equations: sheet.equations) else {
            store.errorMessage = "This page is too large for PNG export. Export PDF instead."
            return
        }
        save(data, title: sheet.title + ".png", type: .png, store: store)
    }

    static func exportPDF(_ sheet: NoteNode, theme: PageTheme = .light, store: NotesStore) {
        let data = UnifiedPageExport.pdf(text: sheet.body, rtfData: sheet.richTextRTF,
                                         strokes: sheet.strokes,
                                         paper: InkPaper(rawValue: sheet.paperStyle.rawValue) ?? .dotted, theme: theme,
                                         textBoxes: sheet.textBoxes, equations: sheet.equations)
        save(data, title: sheet.title + ".pdf", type: .pdf, store: store)
    }

}


struct NotesCommands: Commands {
    @ObservedObject var store: NotesStore
    @ObservedObject var updater: AppUpdater
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { NativeUndoActions.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(NativeUndoActions.manager?.canUndo != true)
            Button("Redo") { NativeUndoActions.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(NativeUndoActions.manager?.canRedo != true)
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(updater.isConfigured && !updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Sheet…") { NotificationCenter.default.post(name: .newSheet, object: nil) }.keyboardShortcut("n")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Save Now") { _ = store.flush() }.keyboardShortcut("s")
            Button("Export Library Backup…") { MacFileActions.exportLibrary(store) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Import Library Backup…") { MacFileActions.importLibrary(store) }
            Divider()
            Button("Show Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.libraryURL]) }
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Search All Notes") { NotificationCenter.default.post(name: .focusSearch, object: nil) }.keyboardShortcut("f")
        }
        CommandMenu("Format") {
            Button("Bold") { RichTextEditor.perform(.bold) }.keyboardShortcut("b")
            Button("Italic") { RichTextEditor.perform(.italic) }.keyboardShortcut("i")
            Button("Underline") { RichTextEditor.perform(.underline) }.keyboardShortcut("u")
            Divider()
            Button("Heading") { RichTextEditor.perform(.heading) }
            Button("Body Text") { RichTextEditor.perform(.body) }
            Button("Bullet List") { RichTextEditor.perform(.bullet) }
            Button("Checklist") { RichTextEditor.perform(.checklist) }
        }
        CommandMenu("Tools") {
            ForEach(ToolShortcuts.all) { shortcut in
                Button(shortcut.title) { ToolShortcuts.activate(shortcut.tool) }
                    .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
            }
        }
    }
}

/// SwiftUI's default scene manager is separate from the native page's shared
/// text/ink history. Edit commands must follow the actual first responder.
@MainActor
enum NativeUndoActions {
    static var manager: UndoManager? {
        NSApp.keyWindow?.firstResponder?.undoManager ?? NSApp.keyWindow?.undoManager
    }
    static func undo() { if let manager, manager.canUndo { manager.undo() } }
    static func redo() { if let manager, manager.canRedo { manager.redo() } }
}
#endif
