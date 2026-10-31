#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NotesCore

@MainActor
enum MacFileActions {
    static func chooseDriveFolder(_ store: NotesStore) {
        let panel = NSOpenPanel()
        panel.title = "Connect a Google Drive backup folder"
        panel.message = "Choose a folder inside Google Drive in Finder. iNotes writes versioned backups; Drive for desktop handles uploading them."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect Folder"
        if panel.runModal() == .OK, let url = panel.url { store.rememberDriveFolder(url) }
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
        if let rtf = sheet.richTextRTF, NSAttributedString(rtf: rtf, documentAttributes: nil)?.string == sheet.body {
            save(rtf, title: sheet.title + ".rtf", type: .rtf, store: store)
        }
        else {
            let text = NSAttributedString(string: sheet.body, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            do {
                let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                save(data, title: sheet.title + ".rtf", type: .rtf, store: store)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }

    static func exportPagePNG(_ sheet: NoteNode, paper: InkPaper, store: NotesStore) {
        guard let data = UnifiedPageExport.png(text: sheet.body, rtfData: sheet.richTextRTF, strokes: sheet.strokes, paper: paper) else { return }
        save(data, title: sheet.title + ".png", type: .png, store: store)
    }

    static func exportPDF(_ sheet: NoteNode, store: NotesStore) {
        let data = UnifiedPageExport.pdf(text: sheet.body, rtfData: sheet.richTextRTF,
                                         strokes: sheet.strokes,
                                         paper: InkPaper(rawValue: sheet.paperStyle.rawValue) ?? .dotted)
        save(data, title: sheet.title + ".pdf", type: .pdf, store: store)
    }

}


struct NotesCommands: Commands {
    @ObservedObject var store: NotesStore
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Sheet…") { NotificationCenter.default.post(name: .newSheet, object: nil) }.keyboardShortcut("n")
            Button("New Workbook…") { NotificationCenter.default.post(name: .newWorkbook, object: nil) }.keyboardShortcut("n", modifiers: [.command, .shift])
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
    }
}
#endif
