#if os(macOS)
import AppKit
import SwiftUI
import NotesCore

/// Exercises the real workspace hierarchy with isolated storage and an
/// offscreen window. No user preferences, global events, or pointer moves.
@MainActor
enum WorkspaceDiagnostics {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws -> String {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(description: "Workspace diagnostic failed: \(message)") }
            checks += 1
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iNotes-workspace-check-\(UUID())")
        let suite = "io.inotes.workspace-diagnostics.\(UUID())"
        guard let preferences = UserDefaults(suiteName: suite) else {
            throw Failure(description: "Cannot create isolated workspace preferences")
        }
        preferences.set("text", forKey: "inkTool")
        preferences.set("classic", forKey: "workspaceTheme")
        preferences.set("system", forKey: "pageColorScheme")
        let store = NotesStore(directory: directory, preferences: preferences)
        let presentation = EditorPresentation()
        let inputDevice = InputDeviceMonitor()
        defer {
            _ = store.prepareForQuit()
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suite)
        }
        try check(store.errorMessage == nil, "temporary library opens without recovery or permission errors")
        guard let sheetID = store.selectedSheet?.id else {
            throw Failure(description: "Temporary workspace has no selected sheet")
        }
        let originalText = "Workspace typing — café 日本語"
        store.update(sheetID) {
            $0.body = originalText
            $0.richTextRTF = nil
            $0.strokes = []
            $0.pencilKitData = nil
            $0.textBoxes = []
            $0.equations = []
        }

        _ = NSApplication.shared
        let host = NSHostingController(rootView: ContentView(presentation: presentation)
            .environmentObject(store)
            .environmentObject(inputDevice)
            .defaultAppStorage(preferences)
            .preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1280, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }

        // NavigationSplitView mounts its detail asynchronously. Give AppKit and
        // SwiftUI complete layout turns before inspecting or changing state.
        func settle(_ duration: TimeInterval = 0.4) {
            let deadline = Date(timeIntervalSinceNow: duration)
            repeat {
                host.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            } while Date() < deadline
            host.view.layoutSubtreeIfNeeded()
        }
        func findPage(_ view: NSView) -> UnifiedMacPageView? {
            if let page = view as? UnifiedMacPageView, page.window === window,
               !page.isHiddenOrHasHiddenAncestor, page.bounds.width > 100 { return page }
            return view.subviews.lazy.compactMap(findPage).first
        }
        let mountDeadline = Date(timeIntervalSinceNow: 3)
        repeat { settle(0.1) } while findPage(host.view) == nil && Date() < mountDeadline
        guard let page = findPage(host.view), let scroll = page.enclosingScrollView,
              let undo = page.textView.undoManager else {
            throw Failure(description: "Full ContentView did not mount a visible native page and undo manager")
        }
        let editor = page.textView
        try check(page.activeTool == .text && editor.isEditable, "isolated workspace preferences reach the mounted editor")
        try check(window.makeFirstResponder(editor), "workspace native text accepts keyboard focus")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.breakUndoCoalescing()
        undo.removeAllActions()
        undo.beginUndoGrouping()
        editor.insertText(" · retained 📝", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        settle()
        let typedText = editor.string
        try check(typedText != originalText && store.selectedSheet?.body == typedText && undo.canUndo,
                  "real workspace typing persists and creates native undo history")
        let caret = NSRange(location: 3, length: 6)
        editor.setSelectedRange(caret)
        scroll.magnification = 1.25
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        let normalWidth = scroll.bounds.width

        func checkEditorSurvives(_ transition: String) throws {
            try check(findPage(host.view) === page && scroll.documentView === page && page.textView === editor,
                      "\(transition) retains the native page, scroll document, and text view")
            try check(editor.undoManager === undo && undo.canUndo,
                      "\(transition) retains the native typing undo history")
            try check(editor.selectedRange() == caret && editor.string == typedText && store.selectedSheet?.body == typedText,
                      "\(transition) retains the caret and persisted Unicode content")
            try check(abs(scroll.magnification - 1.25) < 0.001 && scroll.documentCursor === NSCursor.iBeam,
                      "\(transition) retains zoom and native text cursor ownership")
        }

        presentation.fullPage = true
        settle()
        try checkEditorSurvives("entering full page")
        try check(scroll.bounds.width > normalWidth + 250,
                  "full page frees both navigation columns for the editor")
        let toolsHeight = scroll.bounds.height
        presentation.toolsVisible = false
        settle()
        try checkEditorSurvives("hiding drawing tools")
        try check(scroll.bounds.height > toolsHeight + 30,
                  "hiding tools gives their vertical space to the native editor")
        presentation.fullPage = false
        settle()
        try checkEditorSurvives("restoring navigation with tools hidden")
        presentation.toolsVisible = true
        settle()
        try checkEditorSurvives("restoring drawing tools")
        try check(abs(scroll.bounds.width - normalWidth) < 5,
                  "leaving full page restores the previous navigation layout")
        try check(window.makeFirstResponder(editor), "typing undo can regain its original responder")
        undo.undo()
        settle()
        try check(editor.string == originalText && store.selectedSheet?.body == originalText && undo.canRedo,
                  "typing undo still restores native text and storage after all chrome transitions")
        undo.redo()
        settle()
        try check(editor.string == typedText && store.selectedSheet?.body == typedText,
                  "typing redo still restores Unicode content after all chrome transitions")

        preferences.set("pen", forKey: "inkTool")
        settle()
        try check(page.activeTool == .pen, "workspace tool preference selects the mounted native pen")
        let tipCursor = page.inkView.tipCursor()
        for fullPage in [true, false] {
            presentation.fullPage = fullPage
            presentation.toolsVisible = !fullPage
            settle()
            try check(findPage(host.view) === page && scroll.documentCursor === tipCursor
                      && page.activePageCursor === tipCursor,
                      "pen cursor ownership and native page survive full page \(fullPage)")
            try check(page.inputView(at: NSPoint(x: 100, y: 100), event: nil) === page.inkView,
                      "pen input still reaches ink over the text layer after full page \(fullPage)")
        }

        // An offscreen NSHostingView need not publish SwiftUI's virtual AX
        // children until an external accessibility client engages the app.
        // Dispatch each button's real key equivalent through this window
        // instead. Disabled or absent controls reject it, so this still catches
        // the Trash regression without bypassing the button action or posting
        // global keyboard input.
        func press(_ label: String, key: String, keyCode: UInt16, expecting expected: () -> Bool) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                              modifierFlags: [.command, .shift], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: key.uppercased(), charactersIgnoringModifiers: key,
                                              isARepeat: false, keyCode: keyCode) else {
                throw Failure(description: "Cannot create the local '\(label)' key equivalent")
            }
            try check(window.performKeyEquivalent(with: event), "\(label) has an enabled control accepting its real key equivalent")
            settle()
            try check(expected(), "\(label) changes the workspace presentation")
        }

        presentation.toolsVisible = false
        store.trash(sheetID)
        store.filter = .trash
        store.folderID = nil
        store.sheetID = sheetID
        settle()
        try check(store.selectedSheet?.isTrashed == true && findPage(host.view) != nil,
                  "trashed sheet mounts as a real read-only detail")
        try press("Full page", key: "f", keyCode: 3, expecting: { presentation.fullPage })
        try press("Show drawing toolbar", key: "t", keyCode: 17, expecting: { presentation.toolsVisible })
        try press("Exit full page", key: "f", keyCode: 3, expecting: { !presentation.fullPage })
        try press("Hide drawing toolbar", key: "t", keyCode: 17, expecting: { !presentation.toolsVisible })
        try press("Show drawing toolbar", key: "t", keyCode: 17, expecting: { presentation.toolsVisible })

        try press("Full page", key: "f", keyCode: 3, expecting: { presentation.fullPage })
        store.sheetID = nil
        settle()
        try check(store.selectedSheet == nil && !presentation.fullPage,
                  "losing sheet selection exits full page instead of stranding the empty workspace")
        try check(findPage(host.view) == nil, "empty selection removes the old sheet detail")
        return "\(checks) workspace integration checks passed (full-page navigation, toolbar restoration, native editor identity, typing undo/redo, caret, zoom, pen cursor, Trash, and empty selection)."
    }
}
#endif
