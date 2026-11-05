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
        try check(WorkspaceTheme(rawValue: "forest") == nil
                  && WorkspaceTheme(preferenceValue: "forest") == .nature
                  && WorkspaceTheme(preferenceValue: "unrecognized") == .classic,
                  "removed Forest preferences resolve to Nature and unknown preferences fall back to Classic")
        try check(WorkspaceTheme.photographicThemes.count == 6
                  && WorkspaceTheme.openSkyscape.title == "Open Skyscape"
                  && WorkspaceTheme.rubyHills.title == "Ruby Hills",
                  "the six scenery choices use their displayed names")
        try check(WorkspaceArtwork.url(theme: .classic, isDark: false) == nil
                  && WorkspaceArtwork.url(theme: .classic, isDark: true) == nil,
                  "Classic does not load a photographic background")
        for theme in WorkspaceTheme.photographicThemes {
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
        func waitPassively(until condition: () -> Bool, timeout: TimeInterval = 1) {
            let deadline = Date(timeIntervalSinceNow: timeout)
            repeat {
                RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.016)))
            } while !condition() && Date() < deadline
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
        let penFine = 0.45 * 72 / 25.4
        try check(abs(page.inkView.lineWidth - penFine) < 0.000001, "fresh workspace uses the 0.45 mm Fine pen nib")
        for tool in [InkTool.pen, .line, .pencil, .marker, .highlighter] {
            let widestPreset: InkNibPreset = tool == .highlighter ? .broad : .extraBroad
            preferences.set(widestPreset.width(for: tool), forKey: "inkWidth")
            preferences.set("#B14D55", forKey: "inkColor")
            settle(0.1)
            NotificationCenter.default.post(name: .noteToolShortcut, object: tool)
            let fine = InkNibPreset.defaultWidth(for: tool)
            waitPassively { page.activeTool == tool && abs(page.inkView.lineWidth - fine) < 0.000001 }
            try check(page.activeTool == tool && abs(page.inkView.lineWidth - fine) < 0.000001
                      && abs(preferences.double(forKey: "inkWidth") - fine) < 0.000001,
                      "selecting \(tool.rawValue) resets \(widestPreset.title) to that tool's Fine preset")
            let expectedColor = tool == .line ? "#30343B" : tool == .highlighter ? "#E2B84D" : "#B14D55"
            try check(page.inkView.colorHex == expectedColor && !editor.isEditable && !editor.isSelectable,
                      "selecting \(tool.rawValue) preserves its original color policy and native ink routing")
            let expectedPresets: [InkNibPreset] = tool == .highlighter
                ? [.fine, .medium, .broad, .highlighter] : [.extraFine, .fine, .medium, .broad, .extraBroad]
            try check(InkNibPreset.presets(for: tool) == expectedPresets,
                      "\(tool.rawValue) keeps the requested nib menu order and Highlighter choices")
            let expectedMillimeters: [Double] = tool == .marker
                ? [0.5, 0.7, 1, 1.5, 2] : [0.3, 0.45, 0.7, 1, tool == .pen ? 1.5 : 1.3]
            for (index, preset) in InkNibPreset.presets(for: tool).enumerated() {
                let width = preset.width(for: tool)
                preferences.set(width, forKey: "inkWidth")
                waitPassively { abs(page.inkView.lineWidth - width) < 0.000001 }
                try check(abs(page.inkView.lineWidth - width) < 0.000001 && findPage(host.view) === page,
                          "\(tool.rawValue) \(preset.label(for: tool)) reaches the same native page without clamping")
                if tool != .highlighter {
                    let style = InkStyle(rawValue: tool.rawValue) ?? .pen
                    let stroke = InkStroke(points: [InkPoint(x: 20, y: 20)], width: page.inkView.lineWidth, style: style)
                    let actualMillimeters = (InkRenderer.bounds(of: stroke)?.width ?? 0) * 25.4 / 72
                    try check(abs(actualMillimeters - expectedMillimeters[index]) < 0.000001,
                              "\(tool.rawValue) \(preset.title) renders the requested nominal millimetres after its style multiplier")
                }
            }
        }
        let customWidth = 1.2345
        preferences.set(customWidth, forKey: "inkWidth")
        NotificationCenter.default.post(name: .noteToolShortcut, object: InkTool.text)
        waitPassively { page.activeTool == .text && editor.isEditable && page.inkView.lineWidth == customWidth }
        try check(page.activeTool == .text && editor.isEditable && page.inkView.lineWidth == customWidth,
                  "returning to Text restores typing and preserves a custom nib value")
        preferences.set(penFine, forKey: "inkWidth")
        preferences.set("#30343B", forKey: "inkColor")
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

        func logHeadingGeometry(_ phase: String) {
            let detailRect = detailView.convert(detailView.bounds, to: host.view)
            let viewportRect = scroll.convert(scroll.bounds, to: host.view)
            let message = "Heading geometry [\(phase)] baselineViewport=\(normalWidth)x\(normalHeight)"
                + " window=\(NSStringFromRect(window.frame)) contentLayout=\(NSStringFromRect(window.contentLayoutRect))"
                + " hostFrame=\(NSStringFromRect(host.view.frame)) hostBounds=\(NSStringFromRect(host.view.bounds))"
                + " detailFrame=\(NSStringFromRect(detailView.frame)) detailBounds=\(NSStringFromRect(detailView.bounds)) detailInHost=\(NSStringFromRect(detailRect))"
                + " scrollFrame=\(NSStringFromRect(scroll.frame)) scrollBounds=\(NSStringFromRect(scroll.bounds)) viewport=\(NSStringFromRect(viewportRect))"
                + " clipFrame=\(NSStringFromRect(scroll.contentView.frame)) clipBounds=\(NSStringFromRect(scroll.contentView.bounds))"
                + " magnification=\(scroll.magnification) fitsPageWidth=\(String(describing: (scroll as? PageZoomScrollView)?.fitsPageWidth))"
                + " headingVisible=\(presentation.headingVisible) sidebarCollapsed=\(sidebarItem.isCollapsed) sheetsCollapsed=\(sheetsItem.isCollapsed)"
            geometryHistory.append(message)
            print(message)
            func titleFields(in view: NSView) -> [NSTextField] {
                var fields: [NSTextField] = []
                if let field = view as? NSTextField,
                   field.placeholderString == "Page title"
                    || (field.isEditable && abs((field.font?.pointSize ?? 0) - 28) < 0.1) {
                    fields.append(field)
                }
                for child in view.subviews { fields.append(contentsOf: titleFields(in: child)) }
                return fields
            }
            let fields = titleFields(in: detailView)
            let countMessage = "Heading title fields [\(phase)] count=\(fields.count)"
            geometryHistory.append(countMessage)
            print(countMessage)
            for (index, field) in fields.enumerated() {
                let fieldMessage = "Heading title field [\(phase)] index=\(index) type=\(type(of: field))"
                    + " frame=\(NSStringFromRect(field.frame)) bounds=\(NSStringFromRect(field.bounds)) inHost=\(NSStringFromRect(field.convert(field.bounds, to: host.view)))"
                    + " intrinsic=\(NSStringFromSize(field.intrinsicContentSize)) fitting=\(NSStringFromSize(field.fittingSize))"
                    + " hidden=\(field.isHiddenOrHasHiddenAncestor) editable=\(field.isEditable)"
                geometryHistory.append(fieldMessage)
                print(fieldMessage)
            }
        }

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

        logHeadingGeometry("before hide")
        presentation.toggleHeading()
        settle()
        logHeadingGeometry("after hide")
        try checkEditorSurvives("hiding the heading independently")
        try check(!presentation.headingVisible && presentation.sheetsVisible && !sheetsItem.isCollapsed
                  && sidebarItem.isCollapsed == sidebarWasCollapsed,
                  "hiding the heading does not collapse either navigation pane")
        try check(scroll.bounds.height > normalHeight + 50,
                  "hiding the heading gives its vertical space to the same native editor")
        presentation.toggleHeading()
        settle()
        // Capture the original observation before diagnostic metric reads or
        // any additional run-loop turns can change its pass/fail outcome.
        let restoredHeadingHeight = scroll.bounds.height
        let restoredHeadingMatchesBaseline = abs(restoredHeadingHeight - normalHeight) < 5
        logHeadingGeometry("restored initial")
        try checkEditorSurvives("restoring the heading independently")
        if !restoredHeadingMatchesBaseline {
            let start = ProcessInfo.processInfo.systemUptime
            let deadline = start + 1
            var previousSample = start
            var sampleCount = 0
            var maximumGap: TimeInterval = 0
            repeat {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                // Observe only normal run-loop work. Later recovery is evidence,
                // never a replacement for the failed initial observation.
                RunLoop.main.run(until: Date(timeIntervalSinceNow: min(0.016, remaining)))
                let now = ProcessInfo.processInfo.systemUptime
                let gap = now - previousSample
                maximumGap = max(maximumGap, gap)
                previousSample = now
                sampleCount += 1
                logHeadingGeometry("restored passive sample\(sampleCount) elapsed=\(now - start) gap=\(gap)")
            } while ProcessInfo.processInfo.systemUptime < deadline
            let summary = "Heading restore passive summary samples=\(sampleCount) elapsed=\(ProcessInfo.processInfo.systemUptime - start) maximumSampleGap=\(maximumGap)"
                + " initialHeight=\(restoredHeadingHeight) baselineHeight=\(normalHeight) finalHeight=\(scroll.bounds.height) initialResult=\(restoredHeadingMatchesBaseline)"
            geometryHistory.append(summary)
            print(summary)
        }
        try check(restoredHeadingMatchesBaseline,
                  "restoring the heading restores its previous layout height (initial=\(restoredHeadingHeight), baseline=\(normalHeight), delta=\(restoredHeadingHeight - normalHeight), tolerance<5)")

        presentation.toggleSheets()
        waitPassively { sheetsItem.isCollapsed && scroll.bounds.width > normalWidth + 100 }
        try checkEditorSurvives("hiding only the sheets pane")
        try check(!presentation.sheetsVisible && sheetsItem.isCollapsed && presentation.headingVisible
                  && sidebarItem.isCollapsed == sidebarWasCollapsed,
                  "the sheets toggle collapses only the native middle pane")
        try checkDetailGeometry("hiding resized sheets")
        try check(scroll.bounds.width > normalWidth + 100,
                  "collapsing sheets gives their horizontal space to the same editor")
        try checkPassiveSidebarCycle(sheetsVisible: false, tool: .text)
        presentation.toggleSheets()
        waitPassively { !sheetsItem.isCollapsed && abs(scroll.bounds.width - normalWidth) < 5 }
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
        let caretBeforePaperChanges = editor.selectedRange()
        for theme in [WorkspaceTheme.classic] + WorkspaceTheme.photographicThemes {
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
                          && abs(scroll.magnification - 1.25) < 0.001
                          && editor.undoManager === undo && undo.canUndo
                          && editor.selectedRange() == caretBeforePaperChanges,
                          "\(theme.rawValue) \(appearance) preserves the editor, notes, caret, undo, and zoom")
                let expectedPaper = PageColorScheme.system.resolved(isDark: appearance == .dark, scenery: theme.rawValue)
                try check(page.theme == expectedPaper && page.paperView.theme == expectedPaper
                          && page.inkView.theme == expectedPaper
                          && editor.appearance?.name == (expectedPaper.isDark ? .darkAqua : .aqua),
                          "\(theme.rawValue) \(appearance) matches native paper, ink, and text appearance to the scenery")
                try check(page.activeTool == .pen && !editor.isEditable && !editor.isSelectable
                          && scroll.documentCursor === activeTip && page.activePageCursor === activeTip
                          && page.inputView(at: NSPoint(x: 100, y: 100), event: nil) === page.inkView,
                          "\(theme.rawValue) \(appearance) keeps pen cursor ownership and routes input to ink")
            }
        }

        // Explicit papers must remain fixed when both the surrounding scenery
        // and system appearance change. Exercise the mounted editor so this
        // catches accidental view replacement as well as preference wiring.
        for choice in PageColorScheme.allCases where choice != .system {
            preferences.set(choice.rawValue, forKey: "pageColorScheme")
            let expectedPaper = choice.resolved(isDark: false)
            for appearance in [ColorScheme.light, .dark] {
                preferences.set(appearance == .light ? "ruby-hills" : "nature", forKey: "workspaceTheme")
                host.rootView = ContentView(presentation: presentation)
                    .environmentObject(store)
                    .environmentObject(inputDevice)
                    .defaultAppStorage(preferences)
                    .preferredColorScheme(appearance)
                settle(0.25)
                try check(page.theme == expectedPaper && page.paperView.theme == expectedPaper
                          && page.inkView.theme == expectedPaper
                          && editor.appearance?.name == (expectedPaper.isDark ? .darkAqua : .aqua),
                          "\(choice.rawValue) stays fixed with matching native text appearance through \(appearance) scenery changes")
                try check(findPage(host.view) === page && page.textView === editor
                          && store.selectedSheet?.pageContent == contentBeforeScenery
                          && editor.undoManager === undo && undo.canUndo
                          && editor.selectedRange() == caretBeforePaperChanges
                          && abs(scroll.magnification - 1.25) < 0.001,
                          "\(choice.rawValue) \(appearance) preserves editor identity, content, caret, undo, and zoom")
                let activeTip = page.inkView.tipCursor()
                try check(page.activeTool == .pen && !editor.isEditable && !editor.isSelectable
                          && scroll.documentCursor === activeTip && page.activePageCursor === activeTip
                          && page.inputView(at: NSPoint(x: 100, y: 100), event: nil) === page.inkView,
                          "\(choice.rawValue) \(appearance) retains pen cursor ownership and ink routing")
            }
        }
        preferences.set("system", forKey: "pageColorScheme")
        settle(0.25)

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

        // Start a separate two-sheet fixture after the original editor's checks.
        // A sheet's editor may change identity; window-level navigation must not.
        preferences.set("text", forKey: "inkTool")
        preferences.set("classic", forKey: "workspaceTheme")
        presentation.fullPage = false
        presentation.headingVisible = true
        presentation.toolsVisible = true
        store.create(.workbook, title: "Switch regression", parent: nil)
        let switchWorkbook = try require(store.folderID, "switch fixture workbook")
        store.create(.chapter, title: "Shared chapter", parent: switchWorkbook)
        let switchChapter = try require(store.folderID, "switch fixture chapter")
        store.create(.sheet, title: "First", parent: switchChapter)
        let firstSheet = try require(store.sheetID, "first switch fixture sheet")
        store.update(firstSheet) { $0.body = "Switch fixture A" }
        store.create(.sheet, title: "Second", parent: switchChapter)
        let secondSheet = try require(store.sheetID, "second switch fixture sheet")
        store.update(secondSheet) { $0.body = "Switch fixture B" }
        store.sheetID = firstSheet
        settle()

        func require<T>(_ value: T?, _ label: String) throws -> T {
            guard let value else { throw Failure(description: "Missing \(label)") }
            return value
        }
        func probes(in view: NSView) -> [WorkspaceNavigationProbe] {
            let own = (view as? WorkspaceNavigationProbe).map { $0.window === window ? [$0] : [] } ?? []
            return own + view.subviews.flatMap { probes(in: $0) }
        }
        func switchFrames(_ activePage: UnifiedMacPageView) -> [NSRect]? {
            guard let activeScroll = activePage.enclosingScrollView,
                  let activeDetail = navigation.splitViewItems.last?.viewController.view else { return nil }
            let detailRect = activeDetail.convert(activeDetail.bounds, to: host.view)
            let viewport = activeScroll.convert(activeScroll.bounds, to: host.view)
            // SwiftUI header/tools are virtual accessibility elements offscreen.
            // Their shared native region above the viewport must remain steady.
            let chrome = NSRect(x: viewport.minX, y: detailRect.minY, width: viewport.width,
                                height: max(0, viewport.minY - detailRect.minY))
            return [detailRect, chrome, viewport]
        }
        func typeFixture(_ suffix: String, in activePage: UnifiedMacPageView) throws {
            let activeEditor = activePage.textView
            let history = try require(activeEditor.undoManager, "switch fixture undo manager")
            try check(window.makeFirstResponder(activeEditor), "switch fixture text accepts keyboard focus")
            activeEditor.setSelectedRange(NSRange(location: (activeEditor.string as NSString).length, length: 0))
            activeEditor.breakUndoCoalescing()
            history.beginUndoGrouping()
            activeEditor.insertText(suffix, replacementRange: activeEditor.selectedRange())
            activeEditor.breakUndoCoalescing()
            history.endUndoGrouping()
            settle() // Editing is fixture setup, never part of the passive switch wait.
        }

        var didInjectSwitchStall = false
        for mode in ["sidebar hidden", "both panes hidden", "full page"] {
            presentation.fullPage = false
            presentation.sheetsVisible = true
            sidebarItem.isCollapsed = true
            store.sheetID = firstSheet
            settle()
            let expandedWidth = sheetsItem.viewController.view.convert(sheetsItem.viewController.view.bounds, to: split).width
            if mode == "both panes hidden" { presentation.sheetsVisible = false }
            if mode == "full page" { presentation.fullPage = true }
            settle()
            let firstPage = try require(findPage(host.view), "first mounted switch page")
            try typeFixture(" a", in: firstPage)
            let firstHistory = try require(firstPage.textView.undoManager, "first sheet undo")
            let expectedFirstText = firstPage.textView.string
            let baselineProbes = probes(in: host.view)
            try check(baselineProbes.count == 1, "\(mode) starts with one navigation probe")
            let stableProbe = try require(baselineProbes.first, "stable navigation probe")
            let expectedFrames = try require(switchFrames(firstPage), "switch fixture geometry")
            let expectedCollapsed = [sidebarItem.isCollapsed, sheetsItem.isCollapsed]
            let expectedPresentation = [presentation.fullPage, presentation.sheetsVisible,
                                        presentation.headingVisible, presentation.toolsVisible]

            func switchPassively(to target: UUID, text: String) throws -> UnifiedMacPageView {
                var collapseChanges: [String] = []
                let observations = [sidebarItem, sheetsItem].enumerated().map { index, item in
                    item.observe(\.isCollapsed, options: [.new]) { item, _ in
                        MainActor.assumeIsolated {
                            collapseChanges.append("pane\(index)=\(item.isCollapsed)")
                        }
                    }
                }
                defer { observations.forEach { $0.invalidate() } }
                var stableIdentity = true, maximumFrameDrift: CGFloat = 0, samples = 0
                var turns = 0, postTurnSamples = 0
                let start = ProcessInfo.processInfo.systemUptime
                let deadline = start + 5
                var previousSampleTime = start, maximumSampleGap: TimeInterval = 0
                var firstPostTurnSampleDelay: TimeInterval?
                let injectStall = !didInjectSwitchStall
                var injectedStallDuration: TimeInterval = 0
                var injectedStallTurn: Int?
                func sample(afterTurn: Bool) {
                    let now = ProcessInfo.processInfo.systemUptime
                    maximumSampleGap = max(maximumSampleGap, now - previousSampleTime)
                    previousSampleTime = now
                    let currentProbes = probes(in: host.view)
                    stableIdentity = stableIdentity && currentProbes.count == 1 && currentProbes.first === stableProbe
                    if let activePage = findPage(host.view), let frames = switchFrames(activePage) {
                        samples += 1
                        if afterTurn {
                            postTurnSamples += 1
                            if firstPostTurnSampleDelay == nil { firstPostTurnSampleDelay = now - start }
                        }
                        for (actual, expected) in zip(frames, expectedFrames) {
                            maximumFrameDrift = max(maximumFrameDrift, [abs(actual.minX - expected.minX),
                                abs(actual.minY - expected.minY), abs(actual.width - expected.width),
                                abs(actual.height - expected.height)].max() ?? 0)
                        }
                    }
                }
                store.sheetID = target
                sample(afterTurn: false)
                if injectStall {
                    didInjectSwitchStall = true
                    // Diagnostic-only slow run-loop source: reproduce a hosted
                    // stall that consumes the old 0.6-second sampling window.
                    // It does not lay out, redraw, focus or change any view.
                    RunLoop.main.perform {
                        MainActor.assumeIsolated {
                            injectedStallTurn = turns
                            let stallStart = ProcessInfo.processInfo.systemUptime
                            Thread.sleep(forTimeInterval: 0.65)
                            injectedStallDuration = ProcessInfo.processInfo.systemUptime - stallStart
                        }
                    }
                }
                while ProcessInfo.processInfo.systemUptime < deadline
                        && (ProcessInfo.processInfo.systemUptime - start < 0.6 || postTurnSamples < 12) {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: min(0.016, max(0, remaining))))
                    turns += 1
                    sample(afterTurn: true)
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                // No forced layout/display, focus changes, or page clicks above.
                // Later samples do not establish continuous geometry during a
                // stalled source; report the actual gaps without discarding any
                // observed drift or native collapse events.
                let sampleLog = "Sheet switch [\(mode)] target=\(target) samples=\(samples) postTurnSamples=\(postTurnSamples)"
                    + " turns=\(turns) elapsed=\(elapsed) firstPostTurnSampleDelay=\(firstPostTurnSampleDelay.map { String($0) } ?? "none")"
                    + " maximumSampleGap=\(maximumSampleGap) injectedStallDuration=\(injectedStallDuration)"
                    + " injectedStallTurn=\(injectedStallTurn.map { String($0) } ?? "none") probeStable=\(stableIdentity)"
                    + " frameDrift=\(maximumFrameDrift) nativeCollapseChanges=\(collapseChanges)"
                geometryHistory.append(sampleLog)
                print(sampleLog)
                try check(postTurnSamples >= 12 && elapsed >= 0.6 && elapsed < 5,
                          "\(mode) sheet switch obtains enough passive geometry samples within its timeout")
                if injectStall {
                    try check(injectedStallTurn == 0 && injectedStallDuration >= 0.6 && maximumSampleGap >= 0.6,
                              "sheet switch sampling continues after an injected first-turn run-loop stall")
                }
                try check(stableIdentity, "\(mode) sheet switch retains one window-level navigation probe throughout")
                try check(collapseChanges.isEmpty && [sidebarItem.isCollapsed, sheetsItem.isCollapsed] == expectedCollapsed,
                          "\(mode) sheet switch never transiently reopens either native pane")
                try check([presentation.fullPage, presentation.sheetsVisible, presentation.headingVisible,
                           presentation.toolsVisible] == expectedPresentation,
                          "\(mode) sheet switch preserves independent chrome preferences")
                try check(samples > 1 && maximumFrameDrift <= 2,
                          "\(mode) sheet switch keeps detail, heading/tools region, and viewport steady in every sample")
                let activePage = try require(findPage(host.view), "selected switch page")
                try check(activePage.textView.string == text && store.selectedSheet?.id == target
                          && store.selectedSheet?.body == text,
                          "\(mode) sheet switch displays and persists only the selected sheet's text")
                try check(activePage.activeTool == .text && activePage.textView.isEditable
                          && activePage.enclosingScrollView?.documentCursor === NSCursor.iBeam,
                          "\(mode) sheet switch preserves the selected text tool and cursor")
                return activePage
            }

            let secondText = try require(store.library.node(id: secondSheet)?.body, "second sheet text")
            let secondPage = try switchPassively(to: secondSheet, text: secondText)
            let secondHistory = try require(secondPage.textView.undoManager, "second sheet undo")
            try check(secondHistory !== firstHistory && !secondHistory.canUndo,
                      "\(mode) the second sheet does not inherit the first sheet's undo actions")
            try typeFixture(" b", in: secondPage)
            secondHistory.undo()
            settle()
            try check(store.library.node(id: secondSheet)?.body == secondText
                      && store.library.node(id: firstSheet)?.body == expectedFirstText,
                      "\(mode) undo changes only the edited second sheet")
            let returnedPage = try switchPassively(to: firstSheet, text: expectedFirstText)
            try check(returnedPage.textView.undoManager !== secondHistory && returnedPage.textView.undoManager?.canUndo == false,
                      "\(mode) returning to the first sheet cannot undo a second-sheet edit")
            presentation.fullPage = false
            presentation.sheetsVisible = true
            settle()
            let restoredWidth = sheetsItem.viewController.view.convert(sheetsItem.viewController.view.bounds, to: split).width
            try check(abs(restoredWidth - expandedWidth) < 5,
                      "\(mode) sheet changes preserve the retained sheets-pane width")
        }

        preferences.set("pen", forKey: "inkTool")
        presentation.fullPage = false
        presentation.sheetsVisible = true
        presentation.headingVisible = true
        presentation.toolsVisible = true
        sidebarItem.isCollapsed = true
        settle()
        let motionPage = try require(findPage(host.view), "pane-motion page")
        let motionScroll = try require(motionPage.enclosingScrollView, "pane-motion viewport")
        let motionProbe = try require(probes(in: host.view).first, "pane-motion probe")
        let motionContent = store.selectedSheet?.pageContent
        let motionUndo = motionPage.textView.undoManager
        let motionCursor = motionPage.inkView.tipCursor()
        var missingMotionInterpolation: [String] = []

        func samplePaneMotion(_ label: String, actions: [(TimeInterval, () -> Void)],
                              sidebarHidden: Bool, sheetsVisible: Bool, fullPage: Bool,
                              monotonic: Bool = false) throws {
            let start = Date(), deadline = Date(timeIntervalSinceNow: 0.8)
            var actionIndex = 0, samples = 0, stableIdentity = true, boundedViewport = true
            var presentationX: [CGFloat] = []
            func sample() {
                samples += 1
                let currentProbes = probes(in: host.view)
                stableIdentity = stableIdentity && currentProbes.count == 1 && currentProbes.first === motionProbe
                    && findPage(host.view) === motionPage
                let viewport = motionScroll.convert(motionScroll.bounds, to: host.view)
                let splitRect = split.convert(split.bounds, to: host.view)
                boundedViewport = boundedViewport && viewport.minX.isFinite && viewport.maxX.isFinite
                    && viewport.width > 100 && viewport.minX >= splitRect.minX - 2
                    && viewport.maxX <= splitRect.maxX + 2
                // Model frames may immediately take their destination while
                // AppKit animates presentation layers. Never mistake that for
                // a visible jump or require display work in an offscreen fixture.
                if let layer = motionScroll.layer?.presentation(),
                   let rootLayer = host.view.layer?.presentation() {
                    presentationX.append(layer.convert(layer.bounds, to: rootLayer).minX)
                }
            }
            sample()
            repeat {
                let elapsed = Date().timeIntervalSince(start)
                while actionIndex < actions.count, elapsed >= actions[actionIndex].0 {
                    actions[actionIndex].1()
                    actionIndex += 1
                }
                RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.016)))
                sample()
            } while Date() < deadline
            let finalViewport = motionScroll.convert(motionScroll.bounds, to: host.view)
            let detailRect = navigation.splitViewItems.last!.viewController.view.convert(
                navigation.splitViewItems.last!.viewController.view.bounds, to: host.view)
            let splitRect = split.convert(split.bounds, to: host.view)
            let navigationRight = navigation.splitViewItems.dropLast().filter { !$0.isCollapsed }
                .map { $0.viewController.view.convert($0.viewController.view.bounds, to: host.view).maxX }
                .max() ?? splitRect.minX
            var backtrack: CGFloat = 0
            var intermediatePositions: Set<CGFloat> = []
            if monotonic, let first = presentationX.first, let last = presentationX.last, abs(last - first) > 5 {
                let direction: CGFloat = last > first ? 1 : -1
                for (previous, current) in zip(presentationX, presentationX.dropFirst()) {
                    backtrack = max(backtrack, -(current - previous) * direction)
                }
                let span = abs(last - first), lower = min(first, last), upper = max(first, last)
                intermediatePositions = Set(presentationX.filter {
                    $0 > lower + span * 0.1 && $0 < upper - span * 0.1
                }.map { ($0 * 10).rounded() / 10 })
            }
            let requiresInterpolation = monotonic && presentationX.count >= 3
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            geometryHistory.append("Pane motion [\(label)] nativeSamples=\(samples) presentationSamples=\(presentationX.count) presentationBacktrack=\(backtrack) intermediatePositions=\(intermediatePositions.count) finalViewport=\(NSStringFromRect(finalViewport)) positions=\(presentationX)")
            try check(actionIndex == actions.count && samples > 2 && stableIdentity,
                      "\(label) processes every requested action without replacing chrome or editor")
            try check(boundedViewport && abs(finalViewport.minX - max(detailRect.minX, navigationRight)) < 2
                      && abs(finalViewport.maxX - detailRect.maxX) < 2,
                      "\(label) keeps sampled viewports bounded and settles without clipping or a blank gutter")
            try check(sidebarItem.isCollapsed == sidebarHidden && sheetsItem.isCollapsed == !sheetsVisible
                      && presentation.sheetsVisible == sheetsVisible && presentation.fullPage == fullPage,
                      "\(label) honors the latest pane intent after interrupted animations finish")
            try check(backtrack <= 2.5, "\(label) has no backward bounce in available presentation-layer samples")
            if requiresInterpolation && intermediatePositions.count < 2 { missingMotionInterpolation.append(label) }
            try check(store.selectedSheet?.pageContent == motionContent && motionPage.textView.undoManager === motionUndo
                      && motionPage.activeTool == .pen && !motionPage.textView.isEditable
                      && motionScroll.documentCursor === motionCursor && motionPage.activePageCursor === motionCursor,
                      "\(label) retains page content, undo isolation, and the pen cursor")
        }

        try samplePaneMotion("animated sheets hide", actions: [(0, { presentation.toggleSheets() })],
                             sidebarHidden: true, sheetsVisible: false, fullPage: false, monotonic: true)
        try samplePaneMotion("animated sheets show", actions: [(0, { presentation.toggleSheets() })],
                             sidebarHidden: true, sheetsVisible: true, fullPage: false, monotonic: true)
        try samplePaneMotion("rapid sheets reversal", actions: [
            (0, { presentation.toggleSheets() }), (0.06, { presentation.toggleSheets() }),
            (0.12, { presentation.toggleSheets() })],
            sidebarHidden: true, sheetsVisible: false, fullPage: false)
        presentation.headingVisible = false
        presentation.toolsVisible = false
        sidebarItem.isCollapsed = false
        settle() // Establish independently hidden sheets/header/tools before the rapid sequence.
        try samplePaneMotion("rapid full-page reversal", actions: [
            (0, { presentation.fullPage.toggle() }), (0.06, { presentation.fullPage.toggle() }),
            (0.12, { presentation.fullPage.toggle() }), (0.18, { presentation.fullPage.toggle() })],
            sidebarHidden: false, sheetsVisible: false, fullPage: false)
        try check(!presentation.headingVisible && !presentation.toolsVisible,
                  "rapid full-page reversal preserves independently hidden heading and tools")

        // Finish an earlier full-page session with the sidebar visible. A
        // subsequent sheets animation must not reuse that session's snapshot
        // after the user independently hides the sidebar.
        presentation.sheetsVisible = true
        presentation.fullPage = true
        settle()
        presentation.fullPage = false
        settle()
        sidebarItem.isCollapsed = true
        settle() // Setup ends here; the mixed transitions below are passive.
        try check(sidebarItem.isCollapsed && !sheetsItem.isCollapsed && !presentation.fullPage,
                  "mixed-transition fixture starts with a newly hidden sidebar after an older full-page session")
        var mixedTransitionReopenedSidebar = false
        let mixedSidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { item, _ in
            MainActor.assumeIsolated {
                if !item.isCollapsed { mixedTransitionReopenedSidebar = true }
            }
        }
        defer { mixedSidebarObservation.invalidate() }
        try samplePaneMotion("full page entered during a later sheets animation", actions: [
            (0, { presentation.toggleSheets() }),
            (0.06, { presentation.fullPage = true }),
            (0.38, { presentation.fullPage = false })],
            sidebarHidden: true, sheetsVisible: false, fullPage: false)
        mixedSidebarObservation.invalidate()
        try check(!mixedTransitionReopenedSidebar,
                  "entering and leaving full page during a later sheets animation never reopens the independently hidden sidebar")

        sidebarItem.isCollapsed = true
        presentation.fullPage = true
        settle()
        var emptySelectionCollapseChanges: [String] = []
        let emptySelectionObservers = [sidebarItem, sheetsItem].enumerated().map { index, item in
            item.observe(\.isCollapsed, options: [.new]) { item, _ in
                MainActor.assumeIsolated { emptySelectionCollapseChanges.append("pane\(index)=\(item.isCollapsed)") }
            }
        }
        store.sheetID = nil
        let emptyDeadline = Date(timeIntervalSinceNow: 0.6)
        repeat { RunLoop.main.run(until: min(emptyDeadline, Date(timeIntervalSinceNow: 0.016))) } while Date() < emptyDeadline
        emptySelectionObservers.forEach { $0.invalidate() }
        geometryHistory.append("Empty selection hidden-pane transitions=\(emptySelectionCollapseChanges)")
        try check(store.selectedSheet == nil && !presentation.fullPage && !presentation.sheetsVisible
                  && sidebarItem.isCollapsed && sheetsItem.isCollapsed && emptySelectionCollapseChanges.isEmpty,
                  "nil selection exits full page without even transiently reopening independently hidden panes")
        try check(probes(in: host.view).count == 1 && probes(in: host.view).first === motionProbe
                  && !presentation.headingVisible && !presentation.toolsVisible,
                  "nil selection preserves the navigation owner and independent header/tool preferences")

        // Detachment can happen while AppKit is still animating. Use a fresh
        // native split controller so this lifecycle check has no notebook data.
        struct NativePaneSnapshot: Equatable {
            let collapsed: Bool, canCollapse: Bool, collapseFromResize: Bool, springLoaded: Bool
            let collapseBehavior: NSSplitViewItem.CollapseBehavior
            let minimum: CGFloat, maximum: CGFloat, preferred: CGFloat, automaticMaximum: CGFloat
            let adjustsSafeArea: Bool?
            init(_ item: NSSplitViewItem) {
                collapsed = item.isCollapsed
                canCollapse = item.canCollapse
                collapseFromResize = item.canCollapseFromWindowResize
                springLoaded = item.isSpringLoaded
                collapseBehavior = item.collapseBehavior
                minimum = item.minimumThickness
                maximum = item.maximumThickness
                preferred = item.preferredThicknessFraction
                automaticMaximum = item.automaticMaximumThickness
                if #available(macOS 26.0, *) { adjustsSafeArea = item.automaticallyAdjustsSafeAreaInsets }
                else { adjustsSafeArea = nil }
            }
            func differences(from expected: NativePaneSnapshot) -> String {
                var differences: [String] = []
                func compare<T: Equatable>(_ name: String, _ old: T, _ actual: T) {
                    if old != actual { differences.append("\(name): expected=\(old), actual=\(actual)") }
                }
                compare("collapsed", expected.collapsed, collapsed)
                compare("canCollapse", expected.canCollapse, canCollapse)
                compare("collapseFromResize", expected.collapseFromResize, collapseFromResize)
                compare("springLoaded", expected.springLoaded, springLoaded)
                compare("collapseBehavior", expected.collapseBehavior, collapseBehavior)
                compare("minimum", expected.minimum, minimum)
                compare("maximum", expected.maximum, maximum)
                compare("preferred", expected.preferred, preferred)
                compare("automaticMaximum", expected.automaticMaximum, automaticMaximum)
                compare("adjustsSafeArea", expected.adjustsSafeArea, adjustsSafeArea)
                return differences.isEmpty ? "none" : differences.joined(separator: "; ")
            }
        }
        let detachedNavigation = NSSplitViewController()
        detachedNavigation.splitView.isVertical = true
        let detachedControllers = (0..<3).map { index -> NSViewController in
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: index == 2 ? 550 : 220, height: 600))
            controller.view.wantsLayer = true
            return controller
        }
        let detachedItems = [NSSplitViewItem(sidebarWithViewController: detachedControllers[0]),
                             NSSplitViewItem(contentListWithViewController: detachedControllers[1]),
                             NSSplitViewItem(viewController: detachedControllers[2])]
        detachedItems[0].minimumThickness = 140
        detachedItems[0].maximumThickness = 280
        detachedItems[1].minimumThickness = 170
        detachedItems[1].maximumThickness = 400
        detachedItems[2].minimumThickness = 300
        detachedItems.forEach { detachedNavigation.addSplitViewItem($0) }
        let detachedWindow = NSWindow(contentRect: NSRect(x: -8000, y: -6000, width: 1000, height: 600),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        detachedWindow.isReleasedWhenClosed = false
        detachedWindow.contentViewController = detachedNavigation
        detachedWindow.orderFront(nil)
        detachedWindow.setFrame(NSRect(x: -8000, y: -6000, width: 1000, height: 600), display: false)
        defer { detachedWindow.orderOut(nil); detachedWindow.close() }
        detachedNavigation.view.layoutSubtreeIfNeeded() // Fixture setup only.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let originalPaneStates = detachedItems.map(NativePaneSnapshot.init)
        let originalPaneAnimations = detachedItems.map(\.animations)
        let originalPaneFrames = detachedItems.map {
            $0.viewController.view.convert($0.viewController.view.bounds, to: detachedNavigation.splitView)
        }
        let detachedProbe = WorkspaceNavigationProbe(frame: detachedControllers[2].view.bounds)
        var detachedCallbacks = 0
        detachedProbe.onSheetsVisibilityChange = { _ in detachedCallbacks += 1 }
        detachedProbe.onLeadingInsetChange = { _ in detachedCallbacks += 1 }
        detachedControllers[2].view.addSubview(detachedProbe)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        try check(detachedItems[1].minimumThickness == 120,
                  "detachment fixture mounts the real navigation probe before starting its transition")
        detachedProbe.fullPage = true
        detachedProbe.scheduleSynchronization()
        // Queue detachment on the same main turn, after synchronization but
        // before AppKit's deferred animation transaction has necessarily begun.
        // A timer-based delay can let it start first and hide this teardown race.
        var detachedDuringTransition = false
        var collapseStarted = false
        DispatchQueue.main.async {
            collapseStarted = detachedItems.dropLast().allSatisfy(\.isCollapsed)
            detachedProbe.dismantle()
            detachedProbe.removeFromSuperview()
            detachedDuringTransition = true
        }
        let collapseStartDeadline = Date(timeIntervalSinceNow: 0.3)
        repeat {
            RunLoop.main.run(until: min(collapseStartDeadline, Date(timeIntervalSinceNow: 0.008)))
        } while !detachedDuringTransition && Date() < collapseStartDeadline
        try check(detachedDuringTransition && collapseStarted,
                  "detachment fixture removes the probe on the same turn as native full-page collapse")
        let callbacksAtDetachment = detachedCallbacks
        let immediatePaneStates = detachedItems.map(NativePaneSnapshot.init)
        var firstDivergentPaneStates: [NativePaneSnapshot]? = immediatePaneStates == originalPaneStates ? nil : immediatePaneStates
        var restoredThroughout = immediatePaneStates == originalPaneStates
        let detachedDeadline = Date(timeIntervalSinceNow: 0.6)
        repeat {
            RunLoop.main.run(until: min(detachedDeadline, Date(timeIntervalSinceNow: 0.016)))
            let current = detachedItems.map(NativePaneSnapshot.init)
            if current != originalPaneStates && firstDivergentPaneStates == nil { firstDivergentPaneStates = current }
            restoredThroughout = restoredThroughout && current == originalPaneStates
        } while Date() < detachedDeadline
        let finalPaneFrames = detachedItems.map {
            $0.viewController.view.convert($0.viewController.view.bounds, to: detachedNavigation.splitView)
        }
        let maximumDetachedFrameDrift = zip(originalPaneFrames, finalPaneFrames).map { original, final in
            max(abs(original.minX - final.minX), abs(original.width - final.width))
        }.max() ?? 0
        geometryHistory.append("Detached probe restored=\(restoredThroughout) lateCallbacks=\(detachedCallbacks - callbacksAtDetachment) frameDrift=\(maximumDetachedFrameDrift) reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
        let finalPaneStates = detachedItems.map(NativePaneSnapshot.init)
        for index in detachedItems.indices {
            geometryHistory.append("Detached pane\(index) immediate=[\(immediatePaneStates[index].differences(from: originalPaneStates[index]))] firstDivergence=[\(firstDivergentPaneStates?[index].differences(from: originalPaneStates[index]) ?? "none")] final=[\(finalPaneStates[index].differences(from: originalPaneStates[index]))] originalFrame=\(NSStringFromRect(originalPaneFrames[index])) finalFrame=\(NSStringFromRect(finalPaneFrames[index]))")
        }
        // Report both transition and detachment observations in the same run,
        // even when interpolation fails before the detached fixture executes.
        try check(missingMotionInterpolation.isEmpty,
                  "simple pane toggles render intermediate positions instead of jumping: \(missingMotionInterpolation)")
        try check(restoredThroughout,
                  "detaching during collapse restores and retains every original native pane policy and state")
        try check(detachedCallbacks == callbacksAtDetachment,
                  "a detached navigation probe publishes no delayed geometry or visibility callbacks")
        try check(zip(detachedItems, originalPaneAnimations).allSatisfy { item, animations in
            NSDictionary(dictionary: item.animations).isEqual(to: animations)
        }, "detachment restores each native item's original animation policy for future navigation owners")
        try check(maximumDetachedFrameDrift <= 2 && finalPaneFrames.allSatisfy { $0.width >= 100 },
                  "the old collapse animation cannot hide or resize restored columns after probe detachment")

        // A new SwiftUI owner may attach before the old AppKit transaction has
        // completed. Its latest intent must not become a stale native callback.
        for successorFullPage in [false, true] {
            let outgoing = WorkspaceNavigationProbe(frame: detachedControllers[2].view.bounds)
            detachedControllers[2].view.addSubview(outgoing)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let successor = WorkspaceNavigationProbe(frame: detachedControllers[2].view.bounds)
            successor.fullPage = successorFullPage
            successor.sheetsVisible = true
            var successorVisibilityChanges: [Bool] = []
            successor.onSheetsVisibilityChange = { [weak successor] visible in
                successorVisibilityChanges.append(visible)
                successor?.sheetsVisible = visible
            }
            outgoing.fullPage = true
            outgoing.scheduleSynchronization()
            var replaced = false
            DispatchQueue.main.async {
                if successorFullPage {
                    // Exercise SwiftUI's possible attach-before-dismantle order.
                    // Give the successor a main turn to attempt ownership first.
                    detachedControllers[2].view.addSubview(successor)
                    DispatchQueue.main.async {
                        outgoing.dismantle()
                        outgoing.removeFromSuperview()
                        replaced = true
                    }
                } else {
                    outgoing.dismantle()
                    outgoing.removeFromSuperview()
                    detachedControllers[2].view.addSubview(successor)
                    replaced = true
                }
            }
            let replacementDeadline = Date(timeIntervalSinceNow: 0.8)
            repeat {
                RunLoop.main.run(until: min(replacementDeadline, Date(timeIntervalSinceNow: 0.016)))
            } while Date() < replacementDeadline
            geometryHistory.append("Replacement probe fullPage=\(successorFullPage) collapsed=\(detachedItems.map(\.isCollapsed)) visibilityCallbacks=\(successorVisibilityChanges)")
            try check(replaced && successor.fullPage == successorFullPage && successor.sheetsVisible
                      && detachedItems.dropLast().allSatisfy { $0.isCollapsed == successorFullPage },
                      "the replacement navigation owner keeps its requested panes after every outgoing animation finishes")
            try check(successorVisibilityChanges.isEmpty,
                      "an outgoing collapse is never published as the replacement owner's sheets preference")
            successor.dismantle()
            successor.removeFromSuperview()
            let successorDetachDeadline = Date(timeIntervalSinceNow: 0.4)
            repeat {
                RunLoop.main.run(until: min(successorDetachDeadline, Date(timeIntervalSinceNow: 0.016)))
            } while Date() < successorDetachDeadline
            try check(detachedItems.map(NativePaneSnapshot.init) == originalPaneStates,
                      "detaching a replacement owner restores the original native pane policies and state")
        }
        return "\(checks) workspace integration checks passed (photographic resources, light/dark scenery, independent heading and sheets pane, native collapse observation, narrow-window and floating restores, full-page navigation, toolbar restoration, native editor identity, typing undo/redo, caret, zoom, pen cursor, Trash, and empty selection)."
    }
}
#endif
