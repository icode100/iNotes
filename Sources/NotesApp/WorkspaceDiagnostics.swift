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
        var geometryHistory: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                geometryHistory.forEach { print($0) }
                throw Failure(description: "Workspace diagnostic failed: \(message)")
            }
            checks += 1
        }

        // Exercise the installed resource lookup, not a source-tree path. This
        // catches missing SwiftPM bundles and Xcode resource-phase omissions.
        try check(WorkspaceArtwork.url(theme: .classic, isDark: false) == nil
                  && WorkspaceArtwork.url(theme: .classic, isDark: true) == nil,
                  "Classic does not load a photographic background")
        for theme in [WorkspaceTheme.coast, .forest, .alpine] {
            var variants: [Data] = []
            for dark in [false, true] {
                guard let url = WorkspaceArtwork.url(theme: theme, isDark: dark) else {
                    throw Failure(description: "Missing bundled \(theme.rawValue) \(dark ? "dark" : "light") artwork")
                }
                let bytes = try Data(contentsOf: url)
                let bitmap = NSBitmapImageRep(data: bytes)
                try check(bitmap?.pixelsWide == 1672 && bitmap?.pixelsHigh == 941,
                          "\(theme.rawValue) \(dark ? "dark" : "light") artwork decodes at its original resolution")
                try check(WorkspaceArtwork.image(theme: theme, isDark: dark) != nil,
                          "the workspace can load the bundled \(theme.rawValue) appearance")
                variants.append(bytes)
            }
            try check(variants[0] != variants[1], "\(theme.rawValue) has distinct light and dark photographs")
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
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1226, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        window.setFrame(NSRect(x: -6000, y: -6000, width: 1226, height: 800), display: false)
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

        func navigationController() -> NSSplitViewController? {
            var ancestor: NSView? = page
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical,
                   let controller = split.delegate as? NSSplitViewController,
                   controller.splitViewItems.count >= 3,
                   let detail = controller.splitViewItems.last,
                   page.isDescendant(of: detail.viewController.view) { return controller }
                ancestor = view.superview
            }
            return nil
        }
        guard let navigation = navigationController(),
              let sidebarItem = navigation.splitViewItems.first else {
            throw Failure(description: "Workspace has no native three-column navigation controller")
        }
        let sheetsItem = navigation.splitViewItems[navigation.splitViewItems.count - 2]
        let sidebarWasCollapsed = sidebarItem.isCollapsed
        // Match the resized-pane geometry that exposed left-side clipping in
        // live QA. This uses native divider APIs in a fresh isolated window,
        // never accessibility frame overrides or user-app interaction.
        let split = navigation.splitView
        window.setFrame(NSRect(x: -6000, y: -6000, width: 1226, height: 800), display: false)
        settle()
        split.setPosition(189.5, ofDividerAt: 0)
        split.setPosition(sidebarItem.viewController.view.frame.maxX + split.dividerThickness + 451.5, ofDividerAt: 1)
        split.adjustSubviews()
        settle()
        geometryHistory.append("Workspace requested visible sheets width451.5; native hosting width=\(sheetsItem.viewController.view.bounds.width)")
        for (index, item) in navigation.splitViewItems.enumerated() {
            geometryHistory.append("Workspace native item\(index): frame=\(NSStringFromRect(item.viewController.view.frame)) minimum=\(item.minimumThickness) maximum=\(item.maximumThickness) preferred=\(item.preferredThicknessFraction) fitting=\(item.viewController.view.fittingSize)")
        }
        for (index, view) in split.subviews.enumerated() {
            geometryHistory.append("Workspace split child\(index) \(type(of: view)) frame=\(NSStringFromRect(view.frame)) bounds=\(NSStringFromRect(view.bounds)) hidden=\(view.isHidden)")
        }
        let normalWidth = scroll.bounds.width
        let normalHeight = scroll.bounds.height
        let detailView = navigation.splitViewItems[navigation.splitViewItems.count - 1].viewController.view
        let initialDetailRect = detailView.convert(detailView.bounds, to: host.view)
        let initialViewportRect = scroll.convert(scroll.bounds, to: host.view)
        let initialNavigationRight = navigation.splitViewItems.dropLast().filter { !$0.isCollapsed }
            .map { $0.viewController.view.convert($0.viewController.view.bounds, to: host.view).maxX }.max()
            ?? initialDetailRect.minX
        let expectedLeadingInset = initialViewportRect.minX - max(initialDetailRect.minX, initialNavigationRight)
        let expectedTrailingInset = initialDetailRect.maxX - initialViewportRect.maxX

        func checkDetailGeometry(_ transition: String) throws {
            let detailRect = detailView.convert(detailView.bounds, to: host.view)
            let viewportRect = scroll.convert(scroll.bounds, to: host.view)
            let visibleViewport = scroll.convert(scroll.visibleRect, to: host.view)
            let splitRect = split.convert(split.bounds, to: host.view)
            let visibleNavigationRight = navigation.splitViewItems.dropLast().filter { !$0.isCollapsed }
                .map { $0.viewController.view.convert($0.viewController.view.bounds, to: host.view).maxX }
                .max() ?? splitRect.minX
            let tolerance: CGFloat = 2
            let contained = viewportRect.minX >= detailRect.minX - tolerance
                && viewportRect.maxX <= detailRect.maxX + tolerance
            let unclipped = visibleViewport.minX <= viewportRect.minX + tolerance
                && visibleViewport.maxX >= viewportRect.maxX - tolerance
            let stableInsets = abs(viewportRect.minX - max(detailRect.minX, visibleNavigationRight) - expectedLeadingInset) < tolerance
                && abs(detailRect.maxX - viewportRect.maxX - expectedTrailingInset) < tolerance
            let besideNavigation = viewportRect.minX >= visibleNavigationRight - tolerance
                && viewportRect.maxX <= splitRect.maxX + tolerance
            var automaticSafeArea = "unavailable"
            if #available(macOS 26.0, *) {
                automaticSafeArea = String(navigation.splitViewItems.last!.automaticallyAdjustsSafeAreaInsets)
            }
            geometryHistory.append("Workspace geometry [\(transition)] window=\(NSStringFromRect(window.frame)) host=\(NSStringFromRect(host.view.bounds)) split=\(NSStringFromRect(splitRect)) sidebar=\(NSStringFromRect(sidebarItem.viewController.view.convert(sidebarItem.viewController.view.bounds, to: host.view))) sheets=\(NSStringFromRect(sheetsItem.viewController.view.convert(sheetsItem.viewController.view.bounds, to: host.view))) detail=\(NSStringFromRect(detailRect)) viewport=\(NSStringFromRect(viewportRect)) visible=\(NSStringFromRect(visibleViewport)) safeArea=\(detailView.safeAreaInsets) autoSafeArea=\(automaticSafeArea)")
            if !besideNavigation || !contained || !unclipped || !stableInsets {
                var ancestor: NSView? = scroll
                var depth = 0
                while let view = ancestor, depth < 16 {
                    geometryHistory.append("Workspace geometry ancestor\(depth) \(type(of: view)) frame=\(NSStringFromRect(view.frame)) bounds=\(NSStringFromRect(view.bounds)) inHost=\(NSStringFromRect(view.convert(view.bounds, to: host.view))) attached=\(view.window === window)")
                    if view === detailView { break }
                    ancestor = view.superview
                    depth += 1
                }
            }
            try check(besideNavigation,
                      "\(transition) keeps actual editor content beside visible navigation, not underneath it")
            try check(contained, "\(transition) keeps the editor viewport inside the native detail frame")
            try check(unclipped, "\(transition) keeps both editor viewport edges visible without parent clipping")
            try check(stableInsets, "\(transition) aligns editor content with the measured unobscured detail edges")
        }

        func checkPassiveSidebarCycle(sheetsVisible: Bool, tool: InkTool) throws {
            let initialCollapsed = sidebarItem.isCollapsed
            let savedCaret = editor.selectedRange()
            let savedContent = store.selectedSheet?.pageContent
            let savedText = editor.string
            let savedZoom = scroll.magnification
            let savedCursor = scroll.documentCursor
            for collapsed in [!initialCollapsed, initialCollapsed] {
                let transition = "passive native sidebar \(collapsed ? "hide" : "show") with sheets \(sheetsVisible ? "visible" : "hidden") in \(tool.rawValue)"
                // Use the same animated AppKit action as the standard sidebar
                // control. No model change or page click may repair its layout.
                navigation.toggleSidebar(nil)
                let deadline = Date(timeIntervalSinceNow: 0.8)
                repeat {
                    RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.02)))
                } while Date() < deadline
                // Deliberately do NOT call settle(), layoutSubtreeIfNeeded(),
                // adjustSubviews(), display(), or updateWindows() here. The old
                // forced-layout fixture masked a stale leading inset until the
                // user clicked the page after hiding the native sidebar.
                try check(sidebarItem.isCollapsed == collapsed
                          && presentation.sheetsVisible == sheetsVisible
                          && sheetsItem.isCollapsed == !sheetsVisible,
                          "\(transition) changes only the requested native sidebar state")
                try checkDetailGeometry(transition)
                try check(findPage(host.view) === page && scroll.documentView === page
                          && page.textView === editor && editor.undoManager === undo && undo.canUndo,
                          "\(transition) retains the native editor and typing undo history without a click")
                try check(editor.selectedRange() == savedCaret && editor.string == savedText
                          && store.selectedSheet?.pageContent == savedContent
                          && abs(scroll.magnification - savedZoom) < 0.001,
                          "\(transition) retains caret, exact page content, and zoom without a click")
                if tool == .text {
                    try check(page.activeTool == .text && editor.isEditable && editor.isSelectable
                              && scroll.documentCursor === NSCursor.iBeam,
                              "\(transition) retains native text editing and cursor ownership")
                } else {
                    try check(page.activeTool == tool && !editor.isEditable && !editor.isSelectable
                              && scroll.documentCursor === savedCursor && page.activePageCursor === savedCursor
                              && page.inputView(at: NSPoint(x: 100, y: 100), event: nil) === page.inkView,
                              "\(transition) retains the pen cursor and ink routing without a click")
                }
            }
        }
        try checkDetailGeometry("expanded451-point sheets")
        try check(presentation.headingVisible && presentation.sheetsVisible && !sheetsItem.isCollapsed,
                  "heading and native sheets pane begin independently visible")
        try checkPassiveSidebarCycle(sheetsVisible: true, tool: .text)

        presentation.toggleHeading()
        settle()
        try checkEditorSurvives("hiding the heading independently")
        try check(!presentation.headingVisible && presentation.sheetsVisible && !sheetsItem.isCollapsed
                  && sidebarItem.isCollapsed == sidebarWasCollapsed,
                  "hiding the heading does not collapse either navigation pane")
        try check(scroll.bounds.height > normalHeight + 50,
                  "hiding the heading gives its vertical space to the same native editor")
        presentation.toggleHeading()
        settle()
        try checkEditorSurvives("restoring the heading independently")
        try check(abs(scroll.bounds.height - normalHeight) < 5,
                  "restoring the heading restores its previous layout height")

        presentation.toggleSheets()
        settle()
        try checkEditorSurvives("hiding only the sheets pane")
        try check(!presentation.sheetsVisible && sheetsItem.isCollapsed && presentation.headingVisible
                  && sidebarItem.isCollapsed == sidebarWasCollapsed,
                  "the sheets toggle collapses only the native middle pane")
        try checkDetailGeometry("hiding resized sheets")
        try check(scroll.bounds.width > normalWidth + 100,
                  "collapsing sheets gives their horizontal space to the same editor")
        try checkPassiveSidebarCycle(sheetsVisible: false, tool: .text)
        presentation.toggleSheets()
        settle()
        try checkEditorSurvives("restoring only the sheets pane")
        try checkDetailGeometry("restoring resized sheets")
        geometryHistory.append("Workspace restored viewport width=\(scroll.bounds.width) expected=\(normalWidth)")
        try check(presentation.sheetsVisible && !sheetsItem.isCollapsed
                  && abs(scroll.bounds.width - normalWidth) < 5,
                  "restoring sheets restores their native pane and previous width")

        // A user collapsing the native divider must update the model, otherwise
        // the next SwiftUI update would immediately reopen the pane.
        sheetsItem.isCollapsed = true
        settle()
        try checkEditorSurvives("native sheets-divider collapse")
        try check(!presentation.sheetsVisible && sheetsItem.isCollapsed && presentation.headingVisible,
                  "native collapse observation updates sheets visibility without hiding the heading")
        try checkDetailGeometry("native sheets collapse")
        sheetsItem.isCollapsed = false
        settle()
        try checkEditorSurvives("native sheets-divider expansion")
        try check(presentation.sheetsVisible && !sheetsItem.isCollapsed,
                  "native expansion observation updates sheets visibility")
        try checkDetailGeometry("native sheets expansion")
        try check(abs(scroll.bounds.width - normalWidth) < 5,
                  "native sheets expansion restores the previous user-resized width")

        presentation.headingVisible = false
        presentation.sheetsVisible = false
        settle()
        presentation.fullPage = true
        settle()
        try checkEditorSurvives("full page with independently hidden heading and sheets")
        try check(navigation.splitViewItems.dropLast().allSatisfy(\.isCollapsed),
                  "full page still collapses every native navigation pane")
        presentation.fullPage = false
        settle()
        try checkEditorSurvives("leaving full page with independently hidden chrome")
        try check(!presentation.headingVisible && !presentation.sheetsVisible && sheetsItem.isCollapsed
                  && sidebarItem.isCollapsed == sidebarWasCollapsed,
                  "full-page exit preserves the separately hidden heading and sheets")
        presentation.fullPage = true
        settle()
        presentation.toggleHeading()
        settle()
        try checkEditorSurvives("restoring only heading from full page")
        try check(!presentation.fullPage && presentation.headingVisible
                  && !presentation.sheetsVisible && sheetsItem.isCollapsed,
                  "heading restore exits full page without reopening hidden sheets")
        presentation.headingVisible = false
        presentation.fullPage = true
        settle()
        presentation.toggleSheets()
        settle()
        try checkEditorSurvives("restoring only sheets from full page")
        try check(!presentation.fullPage && presentation.sheetsVisible && !sheetsItem.isCollapsed
                  && !presentation.headingVisible,
                  "sheets restore exits full page without reopening the hidden heading")
        presentation.headingVisible = true
        settle()

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

        for visible in [true, false] {
            presentation.sheetsVisible = visible
            settle() // Establish the fixture before the independent sidebar action.
            try checkPassiveSidebarCycle(sheetsVisible: visible, tool: .pen)
        }
        presentation.sheetsVisible = true
        settle()

        let contentBeforeScenery = store.selectedSheet?.pageContent
        for theme in [WorkspaceTheme.coast, .forest, .alpine] {
            preferences.set(theme.rawValue, forKey: "workspaceTheme")
            for appearance in [ColorScheme.light, .dark] {
                host.rootView = ContentView(presentation: presentation)
                    .environmentObject(store)
                    .environmentObject(inputDevice)
                    .defaultAppStorage(preferences)
                    .preferredColorScheme(appearance)
                settle(0.25)
                let activeTip = page.inkView.tipCursor()
                try check(findPage(host.view) === page && page.textView === editor
                          && store.selectedSheet?.pageContent == contentBeforeScenery
                          && abs(scroll.magnification - 1.25) < 0.001,
                          "\(theme.rawValue) \(appearance) preserves the editor, notes, and zoom")
                try check(page.activeTool == .pen && !editor.isEditable && !editor.isSelectable
                          && scroll.documentCursor === activeTip && page.activePageCursor === activeTip
                          && page.inputView(at: NSPoint(x: 100, y: 100), event: nil) === page.inkView,
                          "\(theme.rawValue) \(appearance) keeps pen cursor ownership and routes input to ink")
            }
        }

        func checkSheetBadgePassesThrough(_ transition: String, topOffset: CGFloat) throws {
            let local = NSPoint(x: scroll.bounds.maxX - 40,
                                y: scroll.isFlipped ? scroll.bounds.minY + topOffset : scroll.bounds.maxY - topOffset)
            // NSView.hitTest receives a point in its superview coordinates.
            // Exercise the complete SwiftUI overlay hierarchy, rather than
            // directly asking the native page which input view it would use.
            let point = scroll.convert(local, to: host.view.superview)
            let hit = host.view.hitTest(point)
            let reachesInk = hit === page.inkView || (hit?.isDescendant(of: page.inkView) ?? false)
            try check(reachesInk, "\(transition) sheet badge passes pen hit testing through to native ink (hit=\(String(describing: hit.map { String(describing: type(of: $0)) })))")
            try check(findPage(host.view) === page && scroll.documentCursor === page.inkView.tipCursor(),
                      "\(transition) sheet badge retains the native page and pen cursor")
        }
        try checkSheetBadgePassesThrough("visible-toolbar", topOffset: 15)
        presentation.toolsVisible = false
        settle()
        try checkSheetBadgePassesThrough("hidden-toolbar below floating controls", topOffset: 82)
        presentation.toolsVisible = true
        settle()

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
                                              characters: key == "2" ? "@" : key.uppercased(), charactersIgnoringModifiers: key,
                                              isARepeat: false, keyCode: keyCode) else {
                throw Failure(description: "Cannot create the local '\(label)' key equivalent")
            }
            try check(window.performKeyEquivalent(with: event), "\(label) has an enabled control accepting its real key equivalent")
            settle()
            try check(expected(), "\(label) changes the workspace presentation")
        }

        let wideSize = window.contentLayoutRect.size
        let narrowCaret = editor.selectedRange()
        let narrowCursor = scroll.documentCursor
        window.setContentSize(NSSize(width: 880, height: 720))
        settle()
        try check(findPage(host.view) === page && page.textView === editor && editor.undoManager === undo
                  && undo.canUndo && editor.selectedRange() == narrowCaret,
                  "narrow-window layout preserves the editor, caret, and undo history")
        try press("Hide heading at narrow width", key: "h", keyCode: 4, expecting: { !presentation.headingVisible })
        try press("Restore heading at narrow width", key: "h", keyCode: 4, expecting: { presentation.headingVisible })
        try press("Hide sheets at narrow width", key: "2", keyCode: 19, expecting: { !presentation.sheetsVisible })
        try press("Restore sheets at narrow width", key: "2", keyCode: 19, expecting: { presentation.sheetsVisible })
        presentation.toolsVisible = false
        settle()
        try press("Floating hide-heading control", key: "h", keyCode: 4, expecting: { !presentation.headingVisible })
        try press("Floating hide-sheets control", key: "2", keyCode: 19, expecting: { !presentation.sheetsVisible })
        try press("Floating restore-heading control", key: "h", keyCode: 4, expecting: { presentation.headingVisible })
        try press("Floating restore-sheets control", key: "2", keyCode: 19, expecting: { presentation.sheetsVisible })
        try check(findPage(host.view) === page && editor.selectedRange() == narrowCaret
                  && editor.undoManager === undo && undo.canUndo && scroll.documentCursor === narrowCursor
                  && abs(scroll.magnification - 1.25) < 0.001,
                  "narrow floating restores retain editor identity, caret, undo, zoom, and pen cursor")
        presentation.toolsVisible = true
        window.setContentSize(wideSize)
        settle()

        presentation.toolsVisible = false
        store.trash(sheetID)
        store.filter = .trash
        store.folderID = nil
        store.sheetID = sheetID
        settle()
        try check(store.selectedSheet?.isTrashed == true && findPage(host.view) != nil,
                  "trashed sheet mounts as a real read-only detail")
        let trashedContent = store.selectedSheet?.pageContent
        try press("Hide heading in Trash with tools hidden", key: "h", keyCode: 4, expecting: { !presentation.headingVisible })
        try press("Hide sheets in Trash with tools hidden", key: "2", keyCode: 19, expecting: { !presentation.sheetsVisible })
        try press("Full page with hidden Trash chrome", key: "f", keyCode: 3, expecting: { presentation.fullPage })
        try press("Restore heading from full-page Trash", key: "h", keyCode: 4,
                  expecting: { !presentation.fullPage && presentation.headingVisible && !presentation.sheetsVisible })
        try press("Hide heading again in Trash", key: "h", keyCode: 4, expecting: { !presentation.headingVisible })
        try press("Full page before restoring Trash sheets", key: "f", keyCode: 3, expecting: { presentation.fullPage })
        try press("Restore sheets from full-page Trash", key: "2", keyCode: 19,
                  expecting: { !presentation.fullPage && presentation.sheetsVisible && !presentation.headingVisible })
        try press("Restore heading in Trash", key: "h", keyCode: 4, expecting: { presentation.headingVisible })
        try check(store.selectedSheet?.pageContent == trashedContent && findPage(host.view) === page,
                  "all independent Trash chrome controls remain enabled without editing read-only note content")
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
        return "\(checks) workspace integration checks passed (photographic resources, light/dark scenery, independent heading and sheets pane, native collapse observation, narrow-window and floating restores, full-page navigation, toolbar restoration, native editor identity, typing undo/redo, caret, zoom, pen cursor, Trash, and empty selection)."
    }
}
#endif
