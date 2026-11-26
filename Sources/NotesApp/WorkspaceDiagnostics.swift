#if os(macOS)
import AppKit
import SwiftUI
import NotesCore

/// Optional fixture instrumentation. The shipped environment is nil, so normal
/// windows create no probe views or retained diagnostic action closures.
@MainActor
final class WorkspaceDiagnosticControls {
    @MainActor
    final class Control {
        fileprivate weak var view: NSView?
        fileprivate var action: (() -> Void)?
        fileprivate(set) var isEnabled: Bool
        fileprivate(set) var value: String?
        fileprivate let mountOrder: Int

        fileprivate init(view: NSView, enabled: Bool, value: String?, action: (() -> Void)?, mountOrder: Int) {
            self.view = view; self.isEnabled = enabled; self.value = value; self.action = action
            self.mountOrder = mountOrder
        }

        func frame(in root: NSView) -> NSRect? {
            guard let view, view.window != nil, view.window === root.window,
                  !view.isHiddenOrHasHiddenAncestor else { return nil }
            return view.convert(view.bounds, to: root)
        }

        @discardableResult
        func perform() -> Bool {
            guard isEnabled, let view, view.window != nil, view.superview != nil,
                  !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0,
                  let action else { return false }
            action()
            return true
        }
    }

    private var mounted: [String: [ObjectIdentifier: Control]] = [:]
    private var nextMountOrder = 0

    func removeAll() {
        for entries in mounted.values { for control in entries.values { control.action = nil } }
        mounted.removeAll()
    }

    func control(_ identifier: String) -> Control? {
        mounted[identifier]?.values.filter { control in
            guard let view = control.view else { return false }
            return view.window != nil && view.superview != nil && !view.isHiddenOrHasHiddenAncestor
        }.max { $0.mountOrder < $1.mountOrder }
    }

    fileprivate func register(_ identifier: String, view: NSView, enabled: Bool, value: String?, action: (() -> Void)?) {
        let ownerID = ObjectIdentifier(view)
        if let control = mounted[identifier]?[ownerID] {
            control.isEnabled = enabled; control.value = value; control.action = action
        } else {
            nextMountOrder += 1
            mounted[identifier, default: [:]][ownerID] = Control(view: view, enabled: enabled,
                value: value, action: action, mountOrder: nextMountOrder)
        }
    }

    fileprivate func remove(_ identifier: String, owner: NSView) {
        // Updates and dismantles from two sheet-ID subtrees can interleave.
        // Retain each actual view independently so an outgoing late update and
        // removal cannot displace or erase its already mounted successor.
        mounted[identifier]?.removeValue(forKey: ObjectIdentifier(owner))?.action = nil
        if mounted[identifier]?.isEmpty == true { mounted.removeValue(forKey: identifier) }
    }
}

private struct WorkspaceDiagnosticControlsKey: EnvironmentKey {
    static let defaultValue: WorkspaceDiagnosticControls? = nil
}

extension EnvironmentValues {
    var workspaceDiagnosticControls: WorkspaceDiagnosticControls? {
        get { self[WorkspaceDiagnosticControlsKey.self] }
        set { self[WorkspaceDiagnosticControlsKey.self] = newValue }
    }
}

/// A noninteractive background on the real SwiftUI control records its actual
/// native allocation and the very same action/enablement supplied to Button.
/// It neither changes layout nor simulates mouse/AX delivery by the OS.
struct WorkspaceDiagnosticControlProbe: NSViewRepresentable {
    let controls: WorkspaceDiagnosticControls
    let identifier: String
    var enabled = true
    var value: String? = nil
    var action: (() -> Void)? = nil

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) { configure(view) }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.detach() }

    private func configure(_ view: ProbeView) {
        if view.controls !== controls || view.registeredID != identifier { view.detach() }
        view.controls = controls; view.registeredID = identifier
        controls.register(identifier, view: view, enabled: enabled, value: value, action: action)
    }

    @MainActor
    final class ProbeView: NSView {
        weak var controls: WorkspaceDiagnosticControls?
        var registeredID: String?
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
            setAccessibilityHidden(true)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        func detach() {
            if let registeredID { controls?.remove(registeredID, owner: self) }
            controls = nil; registeredID = nil
        }
    }
}

/// Exercises the real workspace hierarchy with isolated storage and an
/// offscreen window. No user preferences, global events, or pointer moves.
@MainActor
enum WorkspaceDiagnostics {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Observe callback state after real run-loop turns. Geometry is deliberately
    /// absent from readiness: the caller must assess the first completed state.
    private static func observeCallbackCompletion<Snapshot>(
        start: TimeInterval, timeout: TimeInterval = 5,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        advanceTurn: ((TimeInterval) -> Void)? = nil,
        snapshot: () -> Snapshot, isReady: (Snapshot) -> Bool,
        observe: (Snapshot, TimeInterval, TimeInterval, Bool) -> Void
    ) -> (snapshot: Snapshot, elapsed: TimeInterval, completed: Bool) {
        let deadline = start + timeout
        var previous = start
        var value = snapshot()
        let initialTime = clock()
        observe(value, initialTime - start, initialTime - previous, false)
        previous = initialTime
        while clock() < deadline {
            let remaining = deadline - clock()
            if let advanceTurn { advanceTurn(remaining) }
            else { RunLoop.main.run(until: Date(timeIntervalSinceNow: min(0.016, max(0, remaining)))) }
            let now = clock()
            value = snapshot()
            observe(value, now - start, now - previous, true)
            previous = now
            if now < deadline && isReady(value) { return (value, now - start, true) }
        }
        return (value, clock() - start, false)
    }

    static func run() throws -> String {
        var checks = try autoreleasepool { try FloatingToolbarDiagnostics.run() }
        var geometryHistory: [String] = []
        var failureContext: (() -> String)?
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                // The failed condition is already captured. Context queries
                // cannot repair it or turn this check into a later pass.
                if let failureContext { print(failureContext()) }
                geometryHistory.forEach { print($0) }
                throw Failure(description: "Workspace diagnostic failed: \(message)")
            }
            checks += 1
        }
        WorkspaceNavigationProbe.beginDiagnosticCapture()
        defer { WorkspaceNavigationProbe.endDiagnosticCapture() }

        // Deterministically exercise callback readiness later than the former
        // 0.4-second wait, then reject incorrect geometry at that first boundary.
        var policyClock: TimeInterval = 0
        var delayedCallbackReady = false
        var observedPendingOriginalWindow = false
        let delayed = observeCallbackCompletion(start: 0, clock: { policyClock }, advanceTurn: { _ in
            policyClock += 0.1
            delayedCallbackReady = policyClock >= 0.55
        }, snapshot: { (ready: delayedCallbackReady, width: CGFloat(policyClock >= 0.8 ? 582 : 813)) }, isReady: { $0.ready }) { state, elapsed, _, afterTurn in
                if afterTurn && elapsed >= 0.4 && !state.ready { observedPendingOriginalWindow = true }
            }
        try check(delayed.completed && delayed.elapsed >= 0.55 && observedPendingOriginalWindow,
                  "passive completion policy never treats the old 0.4-second window as a callback completion")
        struct WrongCompletedGeometry: Error {}
        var rejectedWrongCompletedGeometry = false
        do {
            // The fixture would recover at 0.8 seconds. Its first completed
            // observation at 0.6 remains wrong and cannot be replaced by recovery.
            guard abs(delayed.snapshot.width - CGFloat(582)) < 5 else { throw WrongCompletedGeometry() }
        } catch is WrongCompletedGeometry { rejectedWrongCompletedGeometry = true }
        try check(rejectedWrongCompletedGeometry && delayed.elapsed < 0.8,
                  "incorrect geometry remains a failure at the first callback-completed observation")
        var stalledClock: TimeInterval = 0
        let stalled = observeCallbackCompletion(start: 0, clock: { stalledClock }, advanceTurn: { _ in
            stalledClock = 5.1
        }, snapshot: { stalledClock > 5 }, isReady: { $0 }, observe: { _, _, _, _ in })
        try check(!stalled.completed && stalled.elapsed > 5,
                  "callback readiness after a first-turn stall cannot pass the absolute five-second timeout")
        var neverReadyClock: TimeInterval = 0
        let neverReady = observeCallbackCompletion(start: 0, clock: { neverReadyClock }, advanceTurn: { remaining in
            neverReadyClock += min(0.1, remaining)
        }, snapshot: { false }, isReady: { $0 }, observe: { _, _, _, _ in })
        try check(!neverReady.completed && neverReady.elapsed >= 5,
                  "permanently pending callbacks fail within the absolute observation deadline")
        geometryHistory.append("Completion policy deterministic virtual-clock callback elapsed=\(delayed.elapsed) originalWindowPending=\(observedPendingOriginalWindow) wrongCompletedGeometryRejected=\(rejectedWrongCompletedGeometry)")

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
        // These retained geometry fixtures measure the space reserved by the pinned carousel.
        preferences.set("pinned", forKey: "pageNavigationMode")
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
        let diagnosticControls = WorkspaceDiagnosticControls()
        let host = NSHostingController(rootView: ContentView(presentation: presentation)
            .environmentObject(store)
            .environmentObject(inputDevice)
            .defaultAppStorage(preferences)
            .environment(\.workspaceDiagnosticControls, diagnosticControls)
            .preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1226, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        window.setFrame(NSRect(x: -6000, y: -6000, width: 1226, height: 800), display: false)
        defer {
            diagnosticControls.removeAll()
            window.orderOut(nil); window.close()
        }

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
        var defaults = NotebookDefaults()
        defaults.widths[InkTool.pen.rawValue] = InkNibPreset.storedWidth(millimeters: 0.93, tool: .pen)
        defaults.colors[InkTool.pen.rawValue] = "#3869B2"
        defaults.paper = .ruled; defaults.template = .leftMargin; defaults.guideStyle = .dashed
        let oldPage = store.selectedSheet
        store.saveNotebookDefaults(defaults)
        NotificationCenter.default.post(name: .noteToolShortcut, object: InkTool.pen)
        waitPassively { page.activeTool == .pen && abs(page.inkView.lineWidth - defaults.width(for: .pen)) < 0.000001 }
        try check(page.inkView.colorHex == "#3869B2" && abs(InkNibPreset.millimeters(width: page.inkView.lineWidth, tool: .pen) - 0.93) < 0.000001,
                  "A custom pen width and ink color reach the active native tool")
        try check(store.selectedSheet == oldPage && findPage(host.view) === page,
                  "Saving notebook defaults preserves the current page and native editor")
        do {
            let defaultsDirectory = directory.appendingPathComponent("defaults-relaunch")
            let reopened = NotesStore(directory: defaultsDirectory, preferences: preferences)
            try check(reopened.notebookDefaults == defaults, "Tool and paper defaults survive a new store instance")
            reopened.create(.sheet, parent: reopened.selectedSheet?.parentID)
            try check(reopened.selectedSheet?.paperStyle == .ruled && reopened.selectedSheet?.pageTemplate == .leftMargin
                      && reopened.selectedSheet?.templateLinePattern == .dashed && reopened.selectedSheet?.title.isEmpty == true,
                      "Adding a blank page applies the chosen paper, template, and guide style")
            var invalid = defaults
            invalid.widths["pen"] = -1
            reopened.saveNotebookDefaults(invalid)
            try check(reopened.notebookDefaults == defaults, "Invalid nib widths cannot replace valid settings")
            _ = reopened.prepareForQuit()
        }
        store.saveNotebookDefaults(NotebookDefaults())
        waitPassively { abs(page.inkView.lineWidth - penFine) < 0.000001 }
        try check(abs(page.inkView.lineWidth - penFine) < 0.000001, "Restoring built-in defaults restores the Fine pen")
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
                   controller.splitViewItems.count == 2,
                   let detail = controller.splitViewItems.last,
                   page.isDescendant(of: detail.viewController.view) { return controller }
                ancestor = view.superview
            }
            return nil
        }
        guard let navigation = navigationController(),
              let sidebarItem = navigation.splitViewItems.first else {
            throw Failure(description: "Workspace has no native sidebar/detail navigation controller")
        }
        try check(navigation.splitViewItems.count == 2,
                  "workspace contains exactly sidebar and detail columns, with no hidden sheets column")
        let sidebarWasCollapsed = sidebarItem.isCollapsed
        // Exercise a user-resized sidebar in a fresh isolated window,
        // never accessibility frame overrides or user-app interaction.
        let split = navigation.splitView
        window.setFrame(NSRect(x: -6000, y: -6000, width: 1226, height: 800), display: false)
        settle()
        split.setPosition(189.5, ofDividerAt: 0)
        split.adjustSubviews()
        settle()
        geometryHistory.append("Workspace requested sidebar width189.5; native hosting width=\(sidebarItem.viewController.view.bounds.width) columnCount=\(navigation.splitViewItems.count)")
        for (index, item) in navigation.splitViewItems.enumerated() {
            geometryHistory.append("Workspace native item\(index): frame=\(NSStringFromRect(item.viewController.view.frame)) minimum=\(item.minimumThickness) maximum=\(item.maximumThickness) preferred=\(item.preferredThicknessFraction) fitting=\(item.viewController.view.fittingSize)")
        }
        for (index, view) in split.subviews.enumerated() {
            geometryHistory.append("Workspace split child\(index) \(type(of: view)) frame=\(NSStringFromRect(view.frame)) bounds=\(NSStringFromRect(view.bounds)) hidden=\(view.isHidden)")
        }
        let normalWidth = scroll.bounds.width
        let normalHeight = scroll.bounds.height
        let expectedTagHeight = MacTagFieldMetrics.current.height
        let expectedTitleHeight = MacSheetTitleFieldMetrics.current.height
        let detailView = navigation.splitViewItems[navigation.splitViewItems.count - 1].viewController.view
        let initialDetailRect = detailView.convert(detailView.bounds, to: host.view)
        let initialViewportRect = scroll.convert(scroll.bounds, to: host.view)
        let initialNavigationRight = navigation.splitViewItems.dropLast().filter { !$0.isCollapsed }
            .map { $0.viewController.view.convert($0.viewController.view.bounds, to: host.view).maxX }.max()
            ?? initialDetailRect.minX
        let expectedLeadingInset = initialViewportRect.minX - max(initialDetailRect.minX, initialNavigationRight)
        let expectedTrailingInset = initialDetailRect.maxX - initialViewportRect.maxX
        let normalSidebarWidth = max(0, initialNavigationRight - split.convert(split.bounds, to: host.view).minX)

        func headingNativeFields(in view: NSView) -> [NSTextField] {
            let own = (view as? NSTextField).map { [$0] } ?? []
            return own + view.subviews.flatMap { headingNativeFields(in: $0) }
        }

        failureContext = {
            var context = ["Workspace captured failure context: checksCompleted=\(checks) baselineViewport=\(normalWidth)x\(normalHeight) originalSidebarCollapsed=\(sidebarWasCollapsed)"]
            context.append("Failure asserted references controller=\(ObjectIdentifier(navigation)) sidebarItem=\(ObjectIdentifier(sidebarItem)) sidebarCollapsed=\(sidebarItem.isCollapsed) columnCount=\(navigation.splitViewItems.count) currentSidebarMatches=\(navigation.splitViewItems.first === sidebarItem)")
            context.append("Failure presentation fullPage=\(presentation.fullPage) headingVisible=\(presentation.headingVisible) sheetsVisible=\(presentation.sheetsVisible) toolsVisible=\(presentation.toolsVisible) selectedSheet=\(String(describing: store.sheetID))")
            context.append("Failure window frame=\(NSStringFromRect(window.frame)) contentLayout=\(NSStringFromRect(window.contentLayoutRect)) contentMin=\(NSStringFromSize(window.contentMinSize)) contentMax=\(NSStringFromSize(window.contentMaxSize)) hostFrame=\(NSStringFromRect(host.view.frame)) hostBounds=\(NSStringFromRect(host.view.bounds)) hostingSizingOptions=\(host.sizingOptions.rawValue)")
            for (index, item) in navigation.splitViewItems.enumerated() {
                let view = item.viewController.view
                var policy = "Failure native pane\(index) id=\(ObjectIdentifier(item)) collapsed=\(item.isCollapsed) canCollapse=\(item.canCollapse) canCollapseFromWindowResize=\(item.canCollapseFromWindowResize) collapseBehavior=\(item.collapseBehavior) springLoaded=\(item.isSpringLoaded) minimum=\(item.minimumThickness) maximum=\(item.maximumThickness) preferred=\(item.preferredThicknessFraction) automaticMaximum=\(item.automaticMaximumThickness)"
                    + " frame=\(NSStringFromRect(view.frame)) bounds=\(NSStringFromRect(view.bounds)) inHost=\(NSStringFromRect(view.convert(view.bounds, to: host.view))) attached=\(view.window === window)"
                if #available(macOS 26.0, *) { policy += " automaticallyAdjustsSafeArea=\(item.automaticallyAdjustsSafeAreaInsets)" }
                context.append(policy)
            }
            if let activePage = findPage(host.view), let activeScroll = activePage.enclosingScrollView,
               let activeDetail = navigation.splitViewItems.last?.viewController.view {
                let detailRect = activeDetail.convert(activeDetail.bounds, to: host.view)
                let viewport = activeScroll.convert(activeScroll.bounds, to: host.view)
                let chrome = NSRect(x: viewport.minX, y: detailRect.minY, width: viewport.width,
                                    height: max(0, viewport.minY - detailRect.minY))
                context.append("Failure active page id=\(ObjectIdentifier(activePage)) frame=\(NSStringFromRect(activePage.frame)) bounds=\(NSStringFromRect(activePage.bounds)) detail=\(NSStringFromRect(detailRect)) chrome=\(NSStringFromRect(chrome)) viewport=\(NSStringFromRect(viewport))")
                context.append("Failure active scroll frame=\(NSStringFromRect(activeScroll.frame)) bounds=\(NSStringFromRect(activeScroll.bounds)) clipFrame=\(NSStringFromRect(activeScroll.contentView.frame)) clipBounds=\(NSStringFromRect(activeScroll.contentView.bounds)) magnification=\(activeScroll.magnification) fitsPageWidth=\(String(describing: (activeScroll as? PageZoomScrollView)?.fitsPageWidth))")
            } else { context.append("Failure active page unavailable") }
            func currentProbes(in view: NSView) -> [WorkspaceNavigationProbe] {
                let own = (view as? WorkspaceNavigationProbe).map { [$0] } ?? []
                return own + view.subviews.flatMap { currentProbes(in: $0) }
            }
            for (index, probe) in currentProbes(in: host.view).enumerated() {
                context.append("Failure navigation probe\(index) uptime=\(probe.diagnosticsSnapshot().uptime) id=\(ObjectIdentifier(probe)) \(probe.diagnosticsState())")
            }
            let retainedOwners = WorkspaceNavigationProbe.diagnosticsRestorationOwners()
            context.append("Failure retained restoration owners count=\(retainedOwners.count)")
            context.append(contentsOf: retainedOwners)
            let navigationEvents = WorkspaceNavigationProbe.diagnosticsEventTrace()
            context.append("Failure navigation event trace count=\(navigationEvents.count) limit=512")
            context.append(contentsOf: navigationEvents)
            let fields = headingNativeFields(in: host.view)
            context.append("Failure native fields count=\(fields.count)")
            // Preserve every native frame before asking any field for a font,
            // intrinsic size, fitting size or cell measurement.
            for (index, field) in fields.enumerated() {
                context.append("Failure native field\(index) id=\(ObjectIdentifier(field)) placeholder=\(field.placeholderString ?? "nil") frame=\(NSStringFromRect(field.frame)) bounds=\(NSStringFromRect(field.bounds)) inHost=\(NSStringFromRect(field.convert(field.bounds, to: host.view)))")
            }
            // Emit the immutable frame/state snapshot before any metric query
            // can alter native sizing caches or fail on a damaged fixture.
            print(context.joined(separator: "\n"))
            context = ["Failure native metrics below are queried only after the complete initial snapshot"]
            for (index, field) in fields.enumerated() {
                let fontName = field.font?.fontName ?? "nil"
                let pointSize = field.font?.pointSize ?? 0
                let intrinsic = field.intrinsicContentSize
                let fitting = field.fittingSize
                let cellSize = field.cell?.cellSize
                context.append("Failure native field metrics\(index) id=\(ObjectIdentifier(field)) placeholder=\(field.placeholderString ?? "nil") font=\(fontName) pointSize=\(pointSize) intrinsic=\(NSStringFromSize(intrinsic)) fitting=\(NSStringFromSize(fitting)) cellSize=\(String(describing: cellSize)) frameAfterMetrics=\(NSStringFromRect(field.frame))")
            }
            return context.joined(separator: "\n")
        }

        func currentNavigationProbes(in view: NSView) -> [WorkspaceNavigationProbe] {
            let own = (view as? WorkspaceNavigationProbe).map { [$0] } ?? []
            return own + view.subviews.flatMap { currentNavigationProbes(in: $0) }
        }

        func navigatePassively(_ label: String, expectedSheets: Bool? = nil, preservesSidebar: Bool = false,
                               action: () throws -> Void) throws {
            let initialProbes = currentNavigationProbes(in: host.view)
            guard initialProbes.count == 1, let probe = initialProbes.first else {
                throw Failure(description: "Missing unique navigation probe before \(label)")
            }
            let initial = probe.diagnosticsSnapshot()
            let initialPage = findPage(host.view)
            var start = ProcessInfo.processInfo.systemUptime
            var collapseChanges: [String] = []
            let observations = [sidebarItem].enumerated().map { index, item in
                item.observe(\.isCollapsed, options: [.new]) { item, _ in
                    MainActor.assumeIsolated {
                        collapseChanges.append("elapsed=\(ProcessInfo.processInfo.systemUptime - start) pane\(index) id=\(ObjectIdentifier(item)) collapsed=\(item.isCollapsed)")
                    }
                }
            }
            defer { observations.forEach { $0.invalidate() } }
            start = ProcessInfo.processInfo.systemUptime
            try action()
            let requestedFullPage = presentation.fullPage
            let requestedSheets = expectedSheets ?? presentation.sheetsVisible
            var trace: [String] = []
            var originalObservation: String?
            var stableIdentity = true
            let result = observeCallbackCompletion(start: start, snapshot: { probe.diagnosticsSnapshot() },
                isReady: { state in
                    state.isQuiescent(expectedFullPage: requestedFullPage, expectedSheetsVisible: requestedSheets)
                }) { state, elapsed, gap, afterTurn in
                    let current = currentNavigationProbes(in: host.view)
                    stableIdentity = stableIdentity && current.count == 1 && current.first === probe
                        && state.probeID == initial.probeID && state.controllerID == initial.controllerID
                        && findPage(host.view) === initialPage
                    let detail = detailView.convert(detailView.bounds, to: host.view)
                    let viewport = findPage(host.view)?.enclosingScrollView.map { $0.convert($0.bounds, to: host.view) }
                    let entry = "Navigation passive [\(label)] uptime=\(start + elapsed) elapsed=\(elapsed) gap=\(gap) postTurn=\(afterTurn) generation=\(state.generation) idle=\(state.isQuiescent(expectedFullPage: requestedFullPage, expectedSheetsVisible: requestedSheets)) identity=\(stableIdentity) sidebarCollapsed=\(sidebarItem.isCollapsed) pageNavigationVisible=\(presentation.sheetsVisible) detail=\(NSStringFromRect(detail)) viewport=\(viewport.map(NSStringFromRect) ?? "none") state={\(probe.diagnosticsState())}"
                    trace.append(entry)
                    if afterTurn && elapsed >= 0.4 && originalObservation == nil { originalObservation = entry }
                }
            geometryHistory.append(contentsOf: trace)
            let completionLog = "Navigation completion [\(label)] elapsed=\(result.elapsed) completed=\(result.completed) original0.4=\(originalObservation ?? "completed before original observation window") nativeCollapseChanges=\(collapseChanges) firstCompleted={\(trace.last ?? "none")}"
            geometryHistory.append(completionLog)
            print(completionLog)
            try check(result.completed && result.elapsed < 5 && stableIdentity,
                      "\(label) reaches callback quiescence on the same native owner within five seconds")
            if preservesSidebar {
                try check(collapseChanges.isEmpty && result.snapshot.generation == initial.generation,
                          "\(label) never collapses a native column or starts a sidebar animation")
            }
            // Return at the first callback-idle observation, even if its geometry
            // is wrong. Existing callers assert the unchanged geometry thresholds.
        }

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
                + " headingVisible=\(presentation.headingVisible) sidebarCollapsed=\(sidebarItem.isCollapsed) pageNavigationVisible=\(presentation.sheetsVisible)"
            geometryHistory.append(message)
            print(message)
            // Include Tags as well as Title: they use different font sizes,
            // and a stale native field height can shift the whole heading.
            // Avoid font and sizing getters here: even a nominally read-only
            // native font lookup could perturb a cached layout measurement.
            let fields = headingNativeFields(in: detailView)
            let countMessage = "Heading native fields [\(phase)] count=\(fields.count)"
            geometryHistory.append(countMessage)
            print(countMessage)
            for (index, field) in fields.enumerated() {
                let fieldMessage = "Heading native field [\(phase)] index=\(index) id=\(ObjectIdentifier(field))"
                    + " placeholder=\(field.placeholderString ?? "nil")"
                    + " frame=\(NSStringFromRect(field.frame)) bounds=\(NSStringFromRect(field.bounds)) inHost=\(NSStringFromRect(field.convert(field.bounds, to: host.view)))"
                geometryHistory.append(fieldMessage)
                print(fieldMessage)
            }
        }

        func checkHeadingFieldAllocations(_ phase: String) throws {
            for (placeholder, expected) in [("Page title", expectedTitleHeight), ("Add tags, separated by commas", expectedTagHeight)] {
                let fields = headingNativeFields(in: detailView).filter {
                    $0.placeholderString == placeholder && !$0.isHiddenOrHasHiddenAncestor
                }
                let heights = fields.map { $0.frame.height }
                try check(fields.count == 1 && heights.allSatisfy { $0.isFinite && abs($0 - expected) < 0.5 },
                          "\(phase) allocates one \(placeholder) field at its native font height (actual=\(heights), expected=\(expected))")
            }
        }

        func recordFailedHeadingRestore(_ phase: String, initialHeight: CGFloat, initialResult: Bool) {
            guard !initialResult else { return }
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
                logHeadingGeometry("\(phase) passive sample\(sampleCount) elapsed=\(now - start) gap=\(gap)")
            } while ProcessInfo.processInfo.systemUptime < deadline
            let summary = "Heading restore passive summary [\(phase)] samples=\(sampleCount) elapsed=\(ProcessInfo.processInfo.systemUptime - start) maximumSampleGap=\(maximumGap)"
                + " initialHeight=\(initialHeight) baselineHeight=\(normalHeight) finalHeight=\(scroll.bounds.height) initialResult=\(initialResult)"
            geometryHistory.append(summary)
            print(summary)
            // Only after preserving a failed result and all passive evidence
            // may the diagnostic ask for metrics that can initiate layout.
            for (index, field) in headingNativeFields(in: detailView).enumerated() {
                let observedFrame = field.frame
                let intrinsic = field.intrinsicContentSize
                let fitting = field.fittingSize
                let cellSize = field.cell?.cellSize
                let metrics = "Heading failed native metrics [\(phase)] index=\(index) id=\(ObjectIdentifier(field))"
                    + " placeholder=\(field.placeholderString ?? "nil") font=\(field.font?.fontName ?? "nil") pointSize=\(field.font?.pointSize ?? 0)"
                    + " observedFrame=\(NSStringFromRect(observedFrame)) intrinsic=\(NSStringFromSize(intrinsic)) fitting=\(NSStringFromSize(fitting)) cellSize=\(String(describing: cellSize)) frameAfterMetrics=\(NSStringFromRect(field.frame))"
                geometryHistory.append(metrics)
                print(metrics)
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
            geometryHistory.append("Workspace geometry [\(transition)] window=\(NSStringFromRect(window.frame)) host=\(NSStringFromRect(host.view.bounds)) split=\(NSStringFromRect(splitRect)) sidebar=\(NSStringFromRect(sidebarItem.viewController.view.convert(sidebarItem.viewController.view.bounds, to: host.view))) columnCount=\(navigation.splitViewItems.count) detail=\(NSStringFromRect(detailRect)) viewport=\(NSStringFromRect(viewportRect)) visible=\(NSStringFromRect(visibleViewport)) safeArea=\(detailView.safeAreaInsets) autoSafeArea=\(automaticSafeArea)")
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
                let transition = "passive native sidebar \(collapsed ? "hide" : "show") with page navigation \(sheetsVisible ? "visible" : "hidden") in \(tool.rawValue)"
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
                          && navigation.splitViewItems.count == 2,
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
        try checkDetailGeometry("resized sidebar and bottom page navigation")
        try check(presentation.headingVisible && presentation.sheetsVisible,
                  "heading and bottom page navigation begin independently visible")
        try checkPassiveSidebarCycle(sheetsVisible: true, tool: .text)
        try checkHeadingFieldAllocations("initial heading")

        logHeadingGeometry("before hide")
        presentation.toggleHeading()
        settle()
        logHeadingGeometry("after hide")
        try checkEditorSurvives("hiding the heading independently")
        try check(!presentation.headingVisible && presentation.sheetsVisible
                  && sidebarItem.isCollapsed == sidebarWasCollapsed,
                  "hiding the heading preserves sidebar and bottom page navigation")
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
        recordFailedHeadingRestore("restored initial", initialHeight: restoredHeadingHeight, initialResult: restoredHeadingMatchesBaseline)
        try check(restoredHeadingMatchesBaseline,
                  "restoring the heading restores its previous layout height (initial=\(restoredHeadingHeight), baseline=\(normalHeight), delta=\(restoredHeadingHeight - normalHeight), tolerance<5)")
        try checkHeadingFieldAllocations("restored heading")

        // Repeat real heading transitions without forced layout, preference
        // changes, or page clicks. Every restore uses the original baseline;
        // a later successful cycle cannot erase an earlier mismatch.
        func waitForPassiveHeadingTurn() {
            let deadline = Date(timeIntervalSinceNow: 0.4)
            repeat {
                RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.016)))
            } while Date() < deadline
        }
        for cycle in 1...100 {
            let phase = "repeated cycle\(cycle)"
            logHeadingGeometry("\(phase) before hide")
            presentation.toggleHeading()
            waitForPassiveHeadingTurn()
            let hiddenHeight = scroll.bounds.height
            logHeadingGeometry("\(phase) after hide")
            try checkEditorSurvives("\(phase) hiding heading passively")
            try check(!presentation.headingVisible && presentation.sheetsVisible
                      && sidebarItem.isCollapsed == sidebarWasCollapsed,
                      "\(phase) hiding heading preserves sidebar and page navigation")
            try check(hiddenHeight > normalHeight + 50,
                      "\(phase) hiding heading gives its vertical space to the editor (height=\(hiddenHeight), baseline=\(normalHeight))")
            presentation.toggleHeading()
            waitForPassiveHeadingTurn()
            let restoredHeight = scroll.bounds.height
            let matchesBaseline = abs(restoredHeight - normalHeight) < 5
            logHeadingGeometry("\(phase) restored initial")
            try checkEditorSurvives("\(phase) restoring heading passively")
            try check(presentation.headingVisible && presentation.sheetsVisible
                      && sidebarItem.isCollapsed == sidebarWasCollapsed,
                      "\(phase) restoring heading preserves sidebar and page navigation")
            recordFailedHeadingRestore("\(phase) restored initial", initialHeight: restoredHeight, initialResult: matchesBaseline)
            try check(matchesBaseline,
                      "\(phase) restored heading matches the original viewport height (initial=\(restoredHeight), baseline=\(normalHeight), delta=\(restoredHeight - normalHeight), tolerance<5)")
            try checkHeadingFieldAllocations(phase)
        }

        try navigatePassively("hide bottom page navigation", preservesSidebar: true) { presentation.toggleSheets() }
        try checkEditorSurvives("hiding only bottom page navigation")
        try check(!presentation.sheetsVisible && presentation.headingVisible
                  && sidebarItem.isCollapsed == sidebarWasCollapsed,
                  "the page-navigation toggle leaves the native sidebar and heading unchanged")
        try checkDetailGeometry("hiding bottom page navigation")
        try check(abs(scroll.bounds.width - normalWidth) < 5 && scroll.bounds.height > normalHeight + 30,
                  "hiding the bottom carousel frees vertical space without changing editor width")
        try checkPassiveSidebarCycle(sheetsVisible: false, tool: .text)
        try navigatePassively("restore bottom page navigation", preservesSidebar: true) { presentation.toggleSheets() }
        try checkEditorSurvives("restoring only bottom page navigation")
        try checkDetailGeometry("restoring bottom page navigation")
        try check(presentation.sheetsVisible && abs(scroll.bounds.width - normalWidth) < 5
                  && abs(scroll.bounds.height - normalHeight) < 5,
                  "restoring bottom navigation restores its original viewport height without a native middle pane")

        try navigatePassively("hide heading and sheets before full page") {
            presentation.headingVisible = false
            presentation.sheetsVisible = false
        }
        try navigatePassively("enter full page with hidden heading and sheets") { presentation.fullPage = true }
        try checkEditorSurvives("full page with independently hidden heading and sheets")
        try check(navigation.splitViewItems.dropLast().allSatisfy(\.isCollapsed),
                  "full page still collapses every native navigation pane")
        try navigatePassively("exit full page with hidden heading and sheets") { presentation.fullPage = false }
        try checkEditorSurvives("leaving full page with independently hidden chrome")
        try check(!presentation.headingVisible && !presentation.sheetsVisible
                  && sidebarItem.isCollapsed == sidebarWasCollapsed,
                  "full-page exit preserves the separately hidden heading and bottom navigation")
        try navigatePassively("re-enter full page before heading restore") { presentation.fullPage = true }
        try navigatePassively("restore only heading from full page") { presentation.toggleHeading() }
        try checkEditorSurvives("restoring only heading from full page")
        try check(!presentation.fullPage && presentation.headingVisible
                  && !presentation.sheetsVisible,
                  "heading restore exits full page without reopening hidden bottom navigation")
        try navigatePassively("enter full page before sheets restore") {
            presentation.headingVisible = false
            presentation.fullPage = true
        }
        try navigatePassively("restore only sheets from full page", preservesSidebar: true) { presentation.toggleSheets() }
        try checkEditorSurvives("restoring only sheets from full page")
        try check(presentation.fullPage && presentation.sheetsVisible && sidebarItem.isCollapsed
                  && !presentation.headingVisible && diagnosticControls.control("page-carousel") != nil,
                  "pinned page navigation appears in full page with sidebar and heading still hidden")
        try navigatePassively("leave full page with restored page navigation") { presentation.fullPage = false }
        presentation.headingVisible = true
        settle()

        try navigatePassively("enter full page with visible sheets") { presentation.fullPage = true }
        try checkEditorSurvives("entering full page")
        try check(abs(scroll.bounds.width - (normalWidth + normalSidebarWidth)) < 5,
                  "full page gives the measured visible sidebar width to the same editor")
        let toolsHeight = scroll.bounds.height
        presentation.toolsVisible = false
        settle()
        try checkEditorSurvives("hiding drawing tools")
        try check(scroll.bounds.height > toolsHeight + 30,
                  "hiding tools gives their vertical space to the native editor")
        try navigatePassively("exit full page with tools hidden") { presentation.fullPage = false }
        try checkEditorSurvives("restoring navigation with tools hidden")
        try check(abs(scroll.bounds.width - normalWidth) < 5,
                  "full-page exit restores the previous width at its first callback-idle boundary before tools change")
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
            try navigatePassively("pen full page \(fullPage)") {
                presentation.fullPage = fullPage
                presentation.toolsVisible = !fullPage
            }
            try check(findPage(host.view) === page && scroll.documentCursor === tipCursor
                      && page.activePageCursor === tipCursor,
                      "pen cursor ownership and native page survive full page \(fullPage)")
            try check(page.inputView(at: NSPoint(x: 100, y: 100), event: nil) === page.inkView,
                      "pen input still reaches ink over the text layer after full page \(fullPage)")
        }

        for visible in [true, false] {
            try navigatePassively("establish pen sheets visibility \(visible)") { presentation.sheetsVisible = visible }
            try checkPassiveSidebarCycle(sheetsVisible: visible, tool: .pen)
        }
        try navigatePassively("restore pen sheets fixture") { presentation.sheetsVisible = true }

        let contentBeforeScenery = store.selectedSheet?.pageContent
        let caretBeforePaperChanges = editor.selectedRange()
        for theme in [WorkspaceTheme.classic] + WorkspaceTheme.photographicThemes {
            preferences.set(theme.rawValue, forKey: "workspaceTheme")
            for appearance in [ColorScheme.light, .dark] {
                host.rootView = ContentView(presentation: presentation)
                    .environmentObject(store)
                    .environmentObject(inputDevice)
                    .defaultAppStorage(preferences)
                    .environment(\.workspaceDiagnosticControls, diagnosticControls)
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
                    .environment(\.workspaceDiagnosticControls, diagnosticControls)
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
            let priorIntent = (presentation.fullPage, presentation.sheetsVisible)
            try navigatePassively(label) {
                try check(window.performKeyEquivalent(with: event), "\(label) has an enabled control accepting its real key equivalent")
            }
            if priorIntent == (presentation.fullPage, presentation.sheetsVisible) { settle() }
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
                  expecting: { presentation.fullPage && presentation.sheetsVisible && !presentation.headingVisible })
        try press("Restore heading in Trash", key: "h", keyCode: 4,
                  expecting: { !presentation.fullPage && presentation.sheetsVisible && presentation.headingVisible })
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

        // SwiftUI does not vend virtual AX nodes in this inactive offscreen
        // process. Injected, inert backgrounds capture the real mounted Button
        // closures/state/frames instead. They are absent from ordinary windows.
        func requireControl(_ identifier: String) throws -> WorkspaceDiagnosticControls.Control {
            guard let control = diagnosticControls.control(identifier) else {
                throw Failure(description: "Mounted workspace control is unavailable: \(identifier)")
            }
            return control
        }
        func pressControl(_ identifier: String) throws {
            let control = try requireControl(identifier)
            try check(control.isEnabled && control.perform(),
                      "actual mounted workspace control \(identifier) executes its enabled production action")
        }

        // Start a separate two-sheet fixture after the original editor's checks.
        // A sheet's editor may change identity; window-level navigation must not.
        preferences.set("text", forKey: "inkTool")
        preferences.set("classic", forKey: "workspaceTheme")
        presentation.fullPage = false
        presentation.headingVisible = true
        presentation.toolsVisible = true
        presentation.sheetsVisible = true
        store.create(.workbook, title: "Switch regression", parent: nil)
        let switchWorkbook = try require(store.folderID, "switch fixture workbook")
        store.create(.chapter, title: "Shared chapter", parent: switchWorkbook)
        let switchChapter = try require(store.folderID, "switch fixture chapter")
        store.create(.topic, title: "Nested topic", parent: switchChapter)
        let nestedTopic = try require(store.folderID, "nested empty-parent fixture topic")
        store.create(.sheet, title: "Nested", parent: nestedTopic)
        let nestedSheet = try require(store.sheetID, "nested fixture page")
        store.update(nestedSheet) { $0.body = "Explicit nested browser selection" }
        presentation.sheetsVisible = false
        store.chooseFolder(switchChapter, directPagesOnly: true)
        settle()
        try check(store.sheetID == nil && findPage(host.view) == nil && !presentation.sheetsVisible,
                  "an empty direct chapter stays blank despite nested pages and preserves the hidden-navigation preference")
        let emptyCarousel = diagnosticControls.control("page-carousel")
        let emptyAdd = diagnosticControls.control("page-carousel-add")
        try check(emptyCarousel != nil, "the forced empty-folder carousel mounts its actual native background")
        try check(emptyAdd != nil, "an empty direct chapter keeps its actual Add button reachable when navigation was hidden")
        // The browser's List selection uses this same binding while retaining
        // the viewed ancestor; it must not be reset to the empty direct folder.
        store.sheetID = nestedSheet
        waitPassively(until: { findPage(host.view)?.textView.string == "Explicit nested browser selection" }, timeout: 3)
        try check(store.folderID == switchChapter && store.sheetID == nestedSheet
                  && findPage(host.view)?.textView.string == "Explicit nested browser selection",
                  "an explicitly selected nested browser result remains selected under its viewed ancestor")
        store.chooseFolder(switchChapter, directPagesOnly: true)
        settle() // Mount the empty chapter's real carousel before its Add action.
        try pressControl("page-carousel-add")
        waitPassively(until: { store.sheetID != nil && findPage(host.view) != nil }, timeout: 3)
        let firstSheet = try require(store.sheetID, "first switch fixture sheet")
        try check(store.selectedSheet?.title == "" && store.selectedSheet?.sheetNumber == 1
                  && store.selectedSheet?.parentID == switchChapter,
                  "carousel Add creates and selects a blank first page without a naming dialog")
        let firstBlankUndo = try requireControl("page.history.undo")
        let firstBlankRedo = try requireControl("page.history.redo")
        try check(!firstBlankUndo.isEnabled && !firstBlankRedo.isEnabled,
                  "the actual Undo and Redo toolbar controls are disabled on a new blank page")
        store.rename(firstSheet, to: "First")
        store.update(firstSheet) { $0.body = "Switch fixture A" }
        presentation.sheetsVisible = true
        settle() // Content is fixture setup, outside switch sampling.
        try pressControl("page-carousel-add")
        waitPassively(until: { store.sheetID != firstSheet && findPage(host.view) != nil }, timeout: 3)
        let secondSheet = try require(store.sheetID, "second switch fixture sheet")
        try check(store.selectedSheet?.title == "" && store.selectedSheet?.sheetNumber == 2
                  && store.library.node(id: firstSheet)?.body == "Switch fixture A",
                  "carousel Add appends the next blank numbered page and preserves the previous page")
        store.rename(secondSheet, to: "Second")
        store.update(secondSheet) { $0.body = "Switch fixture B" }
        store.folderID = nil
        store.sheetID = firstSheet
        settle()
        try pressControl("page-carousel-add")
        waitPassively(until: { store.sheetID != firstSheet && store.sheetID != secondSheet }, timeout: 3)
        let extraSheet = try require(store.sheetID, "All sheets carousel new page")
        try check(store.selectedSheet?.parentID == switchChapter && store.selectedSheet?.title == ""
                  && store.selectedSheet?.sheetNumber == 3,
                  "carousel Add in All sheets appends to the viewed page's immediate parent")
        store.trash(extraSheet)
        store.create(.chapter, title: "Other chapter", parent: switchWorkbook)
        let otherChapter = try require(store.folderID, "other reorder fixture chapter")
        store.create(.topic, title: "Unrelated folder", parent: otherChapter)
        store.create(.sheet, title: "Other", parent: otherChapter)
        let otherSheet = try require(store.sheetID, "interleaved reorder fixture page")
        store.update(otherSheet) { $0.body = "Other parent content" }
        store.folderID = nil
        store.sheetID = firstSheet
        settle()
        let reorderIDs: Set<UUID> = [firstSheet, secondSheet, otherSheet]
        try check(store.visibleSheets.filter { reorderIDs.contains($0.id) }.map(\.id) == [firstSheet, otherSheet, secondSheet],
                  "All sheets fixture interleaves different parents' local page orders")
        let firstBeforeReorder = try require(store.library.node(id: firstSheet), "reorder original page")
        let otherBeforeReorder = try require(store.library.node(id: otherSheet), "reorder unrelated page")
        let reorderPage = try require(findPage(host.view), "reorder mounted editor")
        let reorderHistory = reorderPage.textView.undoManager
        try check(store.reorderSheet(firstSheet, before: nil), "actual carousel reorder action accepts an immediate sibling move in All sheets")
        waitPassively(until: { store.sheetNumber(firstSheet) == 2 })
        try check(store.library.children(of: switchChapter).filter { $0.kind == .sheet }.map(\.id) == [secondSheet, firstSheet]
                  && store.sheetNumber(secondSheet) == 1 && store.sheetNumber(firstSheet) == 2
                  && store.sheetID == firstSheet && store.library.node(id: firstSheet)?.pageContent == firstBeforeReorder.pageContent
                  && store.library.node(id: firstSheet)?.createdAt == firstBeforeReorder.createdAt
                  && store.library.node(id: otherSheet) == otherBeforeReorder
                  && findPage(host.view) === reorderPage && reorderPage.textView.undoManager === reorderHistory,
                  "reordering uses siblings rather than mixed visible offsets and preserves identity, content, metadata and native editor")
        let beforeRejectedReorder = store.library
        try check(!store.reorderSheet(firstSheet, before: otherSheet) && store.library == beforeRejectedReorder && store.sheetID == firstSheet,
                  "a cross-parent carousel reorder target is rejected atomically")
        try check(store.reorderSheet(firstSheet, before: secondSheet), "carousel reorder restores the original sibling order")
        store.folderID = switchChapter
        settle()
        try pressControl("page-carousel-\(secondSheet.uuidString)")
        waitPassively(until: { store.sheetID == secondSheet && findPage(host.view)?.textView.string == "Switch fixture B" }, timeout: 3)
        let selectedDot = try requireControl("page-carousel-\(secondSheet.uuidString)")
        let unselectedDot = try requireControl("page-carousel-\(firstSheet.uuidString)")
        let selectedDotFrame = try require(selectedDot.frame(in: host.view), "selected carousel native frame")
        try check(selectedDot.value == "Current page" && unselectedDot.value == "Not selected"
                  && selectedDotFrame.width >= 43.5 && selectedDotFrame.height >= 43.5,
                  "actual carousel buttons supply selected semantics and allocate a full-sized native button background")
        try pressControl("page-carousel-\(firstSheet.uuidString)")
        waitPassively(until: { store.sheetID == firstSheet && findPage(host.view)?.textView.string == "Switch fixture A" }, timeout: 3)

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
        func switchSnapshot(_ phase: String, page activePage: UnifiedMacPageView?, frames: [NSRect]?, includeFonts: Bool = false) -> String {
            var snapshot = "Sheet switch snapshot [\(phase)] window=\(NSStringFromRect(window.frame))"
                + " contentLayout=\(NSStringFromRect(window.contentLayoutRect)) hostFrame=\(NSStringFromRect(host.view.frame)) hostBounds=\(NSStringFromRect(host.view.bounds))"
                + " selectedSheet=\(String(describing: store.sheetID))"
            if let frames {
                snapshot += " detail=\(NSStringFromRect(frames[0])) chrome=\(NSStringFromRect(frames[1])) viewport=\(NSStringFromRect(frames[2]))"
            } else { snapshot += " frames=unavailable" }
            if let activePage, let activeScroll = activePage.enclosingScrollView {
                snapshot += " pageID=\(ObjectIdentifier(activePage)) pageFrame=\(NSStringFromRect(activePage.frame)) pageBounds=\(NSStringFromRect(activePage.bounds))"
                    + " scrollFrame=\(NSStringFromRect(activeScroll.frame)) scrollBounds=\(NSStringFromRect(activeScroll.bounds))"
                    + " clipFrame=\(NSStringFromRect(activeScroll.contentView.frame)) clipBounds=\(NSStringFromRect(activeScroll.contentView.bounds))"
                    + " magnification=\(activeScroll.magnification) fitsPageWidth=\(String(describing: (activeScroll as? PageZoomScrollView)?.fitsPageWidth))"
            } else { snapshot += " page=unavailable" }
            // Capture every field frame before any optional font read. Healthy
            // observations never ask for fonts or intrinsic/fitting measures.
            func nativeFields(in view: NSView) -> [NSTextField] {
                let own = (view as? NSTextField).map { [$0] } ?? []
                return own + view.subviews.flatMap { nativeFields(in: $0) }
            }
            if let activeDetail = navigation.splitViewItems.last?.viewController.view {
                let fields = nativeFields(in: activeDetail)
                snapshot += " nativeFieldCount=\(fields.count)"
                for (index, field) in fields.enumerated() {
                    snapshot += " field\(index)={id:\(ObjectIdentifier(field)),placeholder:\(field.placeholderString ?? "nil"),frame:\(NSStringFromRect(field.frame)),bounds:\(NSStringFromRect(field.bounds)),inHost:\(NSStringFromRect(field.convert(field.bounds, to: host.view)))}"
                }
                if includeFonts {
                    for (index, field) in fields.enumerated() {
                        snapshot += " observedDriftFieldFont\(index)={id:\(ObjectIdentifier(field)),font:\(field.font?.fontName ?? "nil"),pointSize:\(field.font?.pointSize ?? 0)}"
                    }
                }
            }
            return snapshot
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
        for mode in ["sidebar hidden", "sidebar and carousel hidden", "full page"] {
            store.sheetID = firstSheet
            settle() // Mounting the separate sheet is fixture setup.
            try navigatePassively("\(mode) switch fixture initial panes") {
                presentation.fullPage = false
                presentation.sheetsVisible = true
                sidebarItem.isCollapsed = true
            }
            let expandedWidth = sidebarItem.viewController.view.convert(sidebarItem.viewController.view.bounds, to: split).width
            try navigatePassively("\(mode) switch fixture requested panes") {
                if mode == "sidebar and carousel hidden" { presentation.sheetsVisible = false }
                if mode == "full page" { presentation.fullPage = true }
            }
            let firstPage = try require(findPage(host.view), "first mounted switch page")
            let firstTextBeforeTyping = firstPage.textView.string
            try typeFixture(" a", in: firstPage)
            let firstHistory = try require(firstPage.textView.undoManager, "first sheet undo")
            let expectedFirstText = firstPage.textView.string
            if mode == "sidebar hidden" {
                func pressHistory(_ identifier: String) throws {
                    // Native text and history can already have changed while the
                    // published enablement is still travelling to the docked button.
                    let ready = observeCallbackCompletion(start: ProcessInfo.processInfo.systemUptime,
                        snapshot: { diagnosticControls.control(identifier) },
                        isReady: { control in
                            control?.isEnabled == true && control?.frame(in: host.view)?.isEmpty == false
                        }, observe: { _, _, _, _ in })
                    try check(ready.completed, "\(identifier) must mount and enable within five seconds; "
                              + "elapsed=\(ready.elapsed) enabled=\(String(describing: ready.snapshot?.isEnabled)) "
                              + "frame=\(String(describing: ready.snapshot?.frame(in: host.view))) "
                              + "canUndo=\(firstHistory.canUndo) canRedo=\(firstHistory.canRedo)")
                    try pressControl(identifier)
                }
                try pressHistory("page.history.undo")
                waitPassively(until: { store.library.node(id: firstSheet)?.body == firstTextBeforeTyping })
                try check(firstPage.textView.string == firstTextBeforeTyping && firstHistory.canRedo
                          && store.library.node(id: firstSheet)?.body == firstTextBeforeTyping
                          && store.library.node(id: secondSheet)?.body == "Switch fixture B",
                          "the actual toolbar Undo restores only its bound page's native text")
                try pressHistory("page.history.redo")
                waitPassively(until: { store.library.node(id: firstSheet)?.body == expectedFirstText })
                try check(firstPage.textView.string == expectedFirstText && firstHistory.canUndo
                          && store.library.node(id: firstSheet)?.body == expectedFirstText
                          && store.library.node(id: secondSheet)?.body == "Switch fixture B",
                          "the actual toolbar Redo synchronizes the same page and native undo manager")
            }
            let baselineProbes = probes(in: host.view)
            try check(baselineProbes.count == 1, "\(mode) starts with one navigation probe")
            let stableProbe = try require(baselineProbes.first, "stable navigation probe")
            let expectedFrames = try require(switchFrames(firstPage), "switch fixture geometry")
            let expectedSnapshot = switchSnapshot("\(mode) original baseline", page: firstPage, frames: expectedFrames)
            let expectedCollapsed = sidebarItem.isCollapsed
            let expectedPresentation = [presentation.fullPage, presentation.sheetsVisible,
                                        presentation.headingVisible, presentation.toolsVisible]

            func switchPassively(to target: UUID, text: String) throws -> UnifiedMacPageView {
                let carouselControl: WorkspaceDiagnosticControls.Control?
                if mode == "sidebar hidden" {
                    carouselControl = try requireControl("page-carousel-\(target.uuidString)")
                } else { carouselControl = nil }
                var collapseChanges: [String] = []
                let observations = [sidebarItem].enumerated().map { index, item in
                    item.observe(\.isCollapsed, options: [.new]) { item, _ in
                        MainActor.assumeIsolated {
                            collapseChanges.append("pane\(index)=\(item.isCollapsed)")
                        }
                    }
                }
                defer { observations.forEach { $0.invalidate() } }
                var stableIdentity = true, maximumFrameDrift: CGFloat = 0, samples = 0
                var maximumTagHeightDrift: CGFloat = 0
                var maximumTitleHeightDrift: CGFloat = 0
                var turns = 0, postTurnSamples = 0
                let start = ProcessInfo.processInfo.systemUptime
                let deadline = start + 5
                var previousSampleTime = start, maximumSampleGap: TimeInterval = 0
                var firstPostTurnSampleDelay: TimeInterval?
                var snapshotTrace = [expectedSnapshot]
                var capturedFirstDrift = false
                let injectStall = !didInjectSwitchStall
                var injectedStallDuration: TimeInterval = 0
                var injectedStallTurn: Int?
                func sample(afterTurn: Bool) {
                    let now = ProcessInfo.processInfo.systemUptime
                    let sampleGap = now - previousSampleTime
                    maximumSampleGap = max(maximumSampleGap, sampleGap)
                    previousSampleTime = now
                    let currentProbes = probes(in: host.view)
                    stableIdentity = stableIdentity && currentProbes.count == 1 && currentProbes.first === stableProbe
                    if let activePage = findPage(host.view), let frames = switchFrames(activePage) {
                        samples += 1
                        if afterTurn {
                            postTurnSamples += 1
                            if firstPostTurnSampleDelay == nil { firstPostTurnSampleDelay = now - start }
                        }
                        var frameDrift: CGFloat = 0
                        for (actual, expected) in zip(frames, expectedFrames) {
                            frameDrift = max(frameDrift, [abs(actual.minX - expected.minX),
                                abs(actual.minY - expected.minY), abs(actual.width - expected.width),
                                abs(actual.height - expected.height)].max() ?? 0)
                        }
                        maximumFrameDrift = max(maximumFrameDrift, frameDrift)
                        if expectedPresentation[2] && !expectedPresentation[0],
                           let activeDetail = navigation.splitViewItems.last?.viewController.view {
                            for field in headingNativeFields(in: activeDetail) where !field.isHiddenOrHasHiddenAncestor {
                                if field.placeholderString == "Add tags, separated by commas" {
                                    maximumTagHeightDrift = max(maximumTagHeightDrift, abs(field.frame.height - expectedTagHeight))
                                } else if field.placeholderString == "Page title" {
                                    maximumTitleHeightDrift = max(maximumTitleHeightDrift, abs(field.frame.height - expectedTitleHeight))
                                }
                            }
                        }
                        let phase = "\(mode) target=\(target) sample\(samples) postTurn=\(afterTurn) turn=\(turns) elapsed=\(now - start) gap=\(sampleGap) drift=\(frameDrift)"
                        if frameDrift > 0 && !capturedFirstDrift {
                            capturedFirstDrift = true
                            snapshotTrace.append("Sheet switch first observed drift [\(phase)]")
                        }
                        snapshotTrace.append(switchSnapshot(phase, page: activePage, frames: frames, includeFonts: frameDrift > 0))
                    } else {
                        snapshotTrace.append(switchSnapshot("\(mode) target=\(target) unavailable postTurn=\(afterTurn) turn=\(turns) elapsed=\(now - start) gap=\(sampleGap)", page: nil, frames: nil))
                    }
                }
                if let carouselControl {
                    try check(carouselControl.perform(), "visible page carousel executes the mounted target button's production action")
                } else {
                    // Hidden/full-page chrome still receives selection changes
                    // through commands and the store; retain that lifecycle case.
                    store.sheetID = target
                }
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
                // Emit after observing the complete original sampling window so
                // stdout backpressure cannot alter individual sampling turns.
                geometryHistory.append(contentsOf: snapshotTrace)
                snapshotTrace.forEach { print($0) }
                // No forced layout/display, focus changes, or page clicks above.
                // Later samples do not establish continuous geometry during a
                // stalled source; report the actual gaps without discarding any
                // observed drift or native collapse events.
                let sampleLog = "Sheet switch [\(mode)] target=\(target) samples=\(samples) postTurnSamples=\(postTurnSamples)"
                    + " turns=\(turns) elapsed=\(elapsed) firstPostTurnSampleDelay=\(firstPostTurnSampleDelay.map { String($0) } ?? "none")"
                    + " maximumSampleGap=\(maximumSampleGap) injectedStallDuration=\(injectedStallDuration)"
                    + " injectedStallTurn=\(injectedStallTurn.map { String($0) } ?? "none") probeStable=\(stableIdentity)"
                    + " frameDrift=\(maximumFrameDrift) tagHeightDrift=\(maximumTagHeightDrift) titleHeightDrift=\(maximumTitleHeightDrift) nativeCollapseChanges=\(collapseChanges)"
                geometryHistory.append(sampleLog)
                print(sampleLog)
                try check(postTurnSamples >= 12 && elapsed >= 0.6 && elapsed < 5,
                          "\(mode) sheet switch obtains enough passive geometry samples within its timeout")
                if injectStall {
                    try check(injectedStallTurn == 0 && injectedStallDuration >= 0.6 && maximumSampleGap >= 0.6,
                              "sheet switch sampling continues after an injected first-turn run-loop stall")
                }
                try check(stableIdentity, "\(mode) sheet switch retains one window-level navigation probe throughout")
                try check(collapseChanges.isEmpty && sidebarItem.isCollapsed == expectedCollapsed,
                          "\(mode) sheet switch never transiently reopens the native sidebar")
                try check([presentation.fullPage, presentation.sheetsVisible, presentation.headingVisible,
                           presentation.toolsVisible] == expectedPresentation,
                          "\(mode) sheet switch preserves independent chrome preferences")
                try check(samples > 1 && maximumFrameDrift <= 2,
                          "\(mode) sheet switch keeps detail, heading/tools region, and viewport steady in every sample")
                if expectedPresentation[2] && !expectedPresentation[0] {
                    try check(maximumTagHeightDrift < 0.5,
                              "\(mode) sheet switch keeps every observed tag allocation at the native caption height (drift=\(maximumTagHeightDrift))")
                    try check(maximumTitleHeightDrift < 0.5,
                              "\(mode) sheet switch keeps every observed title allocation at the native title height (drift=\(maximumTitleHeightDrift))")
                    try checkHeadingFieldAllocations("\(mode) switched heading")
                }
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
            if mode == "sidebar hidden" {
                let undoControl = try requireControl("page.history.undo")
                let redoControl = try requireControl("page.history.redo")
                try check(!undoControl.isEnabled && !redoControl.isEnabled,
                          "switching through the carousel disables history controls instead of inheriting the previous page's actions")
            }
            try typeFixture(" b", in: secondPage)
            secondHistory.undo()
            settle()
            try check(store.library.node(id: secondSheet)?.body == secondText
                      && store.library.node(id: firstSheet)?.body == expectedFirstText,
                      "\(mode) undo changes only the edited second sheet")
            let returnedPage = try switchPassively(to: firstSheet, text: expectedFirstText)
            try check(returnedPage.textView.undoManager !== secondHistory && returnedPage.textView.undoManager?.canUndo == false,
                      "\(mode) returning to the first sheet cannot undo a second-sheet edit")
            if mode == "sidebar hidden" {
                let undoControl = try requireControl("page.history.undo")
                try check(!undoControl.isEnabled, "the restored page's toolbar cannot undo another page's edit")
            }
            try navigatePassively("\(mode) restore panes after sheet switching") {
                presentation.fullPage = false
                presentation.sheetsVisible = true
            }
            let restoredWidth = sidebarItem.viewController.view.convert(sidebarItem.viewController.view.bounds, to: split).width
            try check(abs(restoredWidth - expandedWidth) < 5,
                      "\(mode) sheet changes preserve the retained sidebar width")
        }

        preferences.set("pen", forKey: "inkTool")
        settle() // Establish the pen input fixture before pane actions.
        try navigatePassively("establish pane motion fixture") {
            presentation.fullPage = false
            presentation.sheetsVisible = true
            presentation.headingVisible = true
            presentation.toolsVisible = true
            sidebarItem.isCollapsed = false
        }
        let motionPage = try require(findPage(host.view), "pane-motion page")
        let motionScroll = try require(motionPage.enclosingScrollView, "pane-motion viewport")
        let motionProbe = try require(probes(in: host.view).first, "pane-motion probe")
        let motionContent = store.selectedSheet?.pageContent
        let motionUndo = motionPage.textView.undoManager
        let motionCursor = motionPage.inkView.tipCursor()
        var missingMotionInterpolation: [String] = []

        func samplePaneMotion(_ label: String, actions: [(TimeInterval, () -> Void)],
                              sidebarHidden: Bool, sheetsVisible: Bool, fullPage: Bool,
                              monotonic: Bool = false, preservesSidebar: Bool = false) throws {
            let start = ProcessInfo.processInfo.systemUptime, deadline = start + 5
            var actionIndex = 0, samples = 0, stableIdentity = true, boundedViewport = true
            var presentationX: [CGFloat] = []
            var trace: [String] = [], collapseChanges: [String] = []
            var firstCompletedGeometryValid: Bool?
            var firstCompletedIntentValid: Bool?
            var originalWindowObservation: String?
            var previousSample = start
            var completed = false
            let observations = [sidebarItem].enumerated().map { index, item in
                item.observe(\.isCollapsed, options: [.new]) { item, _ in
                    MainActor.assumeIsolated {
                        collapseChanges.append("elapsed=\(ProcessInfo.processInfo.systemUptime - start) pane\(index)=\(item.isCollapsed)")
                    }
                }
            }
            defer { observations.forEach { $0.invalidate() } }
            func sample(afterTurn: Bool) {
                let now = ProcessInfo.processInfo.systemUptime
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
                let state = motionProbe.diagnosticsSnapshot()
                stableIdentity = stableIdentity && state.controllerID == ObjectIdentifier(navigation)
                let idle = state.isQuiescent(expectedFullPage: fullPage, expectedSheetsVisible: sheetsVisible)
                let entry = "Pane motion sample [\(label)] uptime=\(now) elapsed=\(now - start) gap=\(now - previousSample) postTurn=\(afterTurn) generation=\(state.generation) completedGeneration=\(String(describing: state.completedGeneration)) idle=\(idle) viewport=\(NSStringFromRect(viewport)) sidebarCollapsed=\(sidebarItem.isCollapsed) pageNavigationVisible=\(presentation.sheetsVisible)"
                previousSample = now
                trace.append(entry)
                if afterTurn && now - start >= 0.8 && originalWindowObservation == nil { originalWindowObservation = entry }
                completed = afterTurn && actionIndex == actions.count && idle
                if completed && firstCompletedGeometryValid == nil {
                    let detail = navigation.splitViewItems.last!.viewController.view.convert(
                        navigation.splitViewItems.last!.viewController.view.bounds, to: host.view)
                    let navigationRight = navigation.splitViewItems.dropLast().filter { !$0.isCollapsed }
                        .map { $0.viewController.view.convert($0.viewController.view.bounds, to: host.view).maxX }
                        .max() ?? splitRect.minX
                    firstCompletedGeometryValid = abs(viewport.minX - max(detail.minX, navigationRight)) < 2
                        && abs(viewport.maxX - detail.maxX) < 2
                    firstCompletedIntentValid = sidebarItem.isCollapsed == sidebarHidden
                        && presentation.sheetsVisible == sheetsVisible && presentation.fullPage == fullPage
                    trace.append("Pane motion first completed [\(label)] \(entry) geometryValid=\(firstCompletedGeometryValid!) intentValid=\(firstCompletedIntentValid!)")
                }
            }
            sample(afterTurn: false)
            repeat {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                while actionIndex < actions.count, elapsed >= actions[actionIndex].0 {
                    let deliveredAt = ProcessInfo.processInfo.systemUptime
                    actions[actionIndex].1()
                    trace.append("Pane motion action [\(label)] index=\(actionIndex) plannedOffset=\(actions[actionIndex].0) deliveredUptime=\(deliveredAt) actualElapsed=\(deliveredAt - start) completedTurns=\(max(0, samples - 1))")
                    actionIndex += 1
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                RunLoop.main.run(until: Date(timeIntervalSinceNow: min(0.016, max(0, remaining))))
                sample(afterTurn: true)
            } while ProcessInfo.processInfo.systemUptime < deadline
                && (ProcessInfo.processInfo.systemUptime - start < 0.8 || !completed)
            let observationElapsed = ProcessInfo.processInfo.systemUptime - start
            geometryHistory.append(contentsOf: trace)
            let completionLog = "Pane motion completion [\(label)] elapsed=\(observationElapsed) completed=\(completed) original0.8=\(originalWindowObservation ?? "none") nativeCollapseChanges=\(collapseChanges) firstCompletedGeometryValid=\(String(describing: firstCompletedGeometryValid)) firstCompletedIntentValid=\(String(describing: firstCompletedIntentValid))"
            geometryHistory.append(completionLog)
            print(completionLog)
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
            try check(actionIndex == actions.count && samples > 2 && stableIdentity && completed
                      && observationElapsed < 5,
                      "\(label) processes every requested action without replacing chrome or editor")
            try check(firstCompletedGeometryValid == true && boundedViewport && abs(finalViewport.minX - max(detailRect.minX, navigationRight)) < 2
                      && abs(finalViewport.maxX - detailRect.maxX) < 2,
                      "\(label) keeps sampled viewports bounded and settles without clipping or a blank gutter")
            try check(firstCompletedIntentValid == true && sidebarItem.isCollapsed == sidebarHidden
                      && presentation.sheetsVisible == sheetsVisible && presentation.fullPage == fullPage,
                      "\(label) honors the latest pane intent after interrupted animations finish")
            if preservesSidebar {
                try check(collapseChanges.isEmpty,
                          "\(label) never transiently collapses or reopens the native sidebar")
            }
            try check(backtrack <= 2.5, "\(label) has no backward bounce in available presentation-layer samples")
            if requiresInterpolation && intermediatePositions.count < 2 { missingMotionInterpolation.append(label) }
            try check(store.selectedSheet?.pageContent == motionContent && motionPage.textView.undoManager === motionUndo
                      && motionPage.activeTool == .pen && !motionPage.textView.isEditable
                      && motionScroll.documentCursor === motionCursor && motionPage.activePageCursor === motionCursor,
                      "\(label) retains page content, undo isolation, and the pen cursor")
        }

        try samplePaneMotion("animated full-page sidebar hide", actions: [(0, { presentation.fullPage = true })],
                             sidebarHidden: true, sheetsVisible: true, fullPage: true, monotonic: true)
        try samplePaneMotion("animated full-page sidebar restore", actions: [(0, { presentation.fullPage = false })],
                             sidebarHidden: false, sheetsVisible: true, fullPage: false, monotonic: true)
        try navigatePassively("hide sidebar before carousel-only motion checks") { sidebarItem.isCollapsed = true }
        try samplePaneMotion("bottom page navigation hide", actions: [(0, { presentation.toggleSheets() })],
                             sidebarHidden: true, sheetsVisible: false, fullPage: false, preservesSidebar: true)
        try samplePaneMotion("bottom page navigation show", actions: [(0, { presentation.toggleSheets() })],
                             sidebarHidden: true, sheetsVisible: true, fullPage: false, preservesSidebar: true)
        try samplePaneMotion("rapid bottom navigation reversal", actions: [
            (0, { presentation.toggleSheets() }), (0.06, { presentation.toggleSheets() }),
            (0.12, { presentation.toggleSheets() })],
            sidebarHidden: true, sheetsVisible: false, fullPage: false, preservesSidebar: true)
        try navigatePassively("establish rapid reversal fixture") {
            presentation.headingVisible = false
            presentation.toolsVisible = false
            sidebarItem.isCollapsed = false
        }
        try samplePaneMotion("rapid full-page reversal", actions: [
            (0, { presentation.fullPage.toggle() }), (0.06, { presentation.fullPage.toggle() }),
            (0.12, { presentation.fullPage.toggle() }), (0.18, { presentation.fullPage.toggle() })],
            sidebarHidden: false, sheetsVisible: false, fullPage: false)
        try check(!presentation.headingVisible && !presentation.toolsVisible,
                  "rapid full-page reversal preserves independently hidden heading and tools")

        // Finish an earlier full-page session with the sidebar visible. A
        // subsequent sheets animation must not reuse that session's snapshot
        // after the user independently hides the sidebar.
        try navigatePassively("establish earlier full page session") {
            presentation.sheetsVisible = true
            presentation.fullPage = true
        }
        try navigatePassively("complete earlier full page session") { presentation.fullPage = false }
        try navigatePassively("hide sidebar before mixed transitions") { sidebarItem.isCollapsed = true }
        try check(sidebarItem.isCollapsed && presentation.sheetsVisible && !presentation.fullPage,
                  "mixed-transition fixture starts with a newly hidden sidebar after an older full-page session")
        var mixedTransitionReopenedSidebar = false
        let mixedSidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { item, _ in
            MainActor.assumeIsolated {
                if !item.isCollapsed { mixedTransitionReopenedSidebar = true }
            }
        }
        defer { mixedSidebarObservation.invalidate() }
        try samplePaneMotion("full page entered during a later carousel visibility change", actions: [
            (0, { presentation.toggleSheets() }),
            (0.06, { presentation.fullPage = true }),
            (0.38, { presentation.fullPage = false })],
            sidebarHidden: true, sheetsVisible: false, fullPage: false)
        mixedSidebarObservation.invalidate()
        try check(!mixedTransitionReopenedSidebar,
                  "entering and leaving full page during a carousel visibility change never reopens the independently hidden sidebar")

        try navigatePassively("establish full page before empty selection") {
            sidebarItem.isCollapsed = true
            presentation.fullPage = true
        }
        var emptySelectionCollapseChanges: [String] = []
        let emptySelectionObservers = [sidebarItem].enumerated().map { index, item in
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
                  && sidebarItem.isCollapsed && emptySelectionCollapseChanges.isEmpty,
                  "nil selection exits full page without transiently reopening the independently hidden sidebar")
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
        let detachedControllers = (0..<2).map { index -> NSViewController in
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: index == 1 ? 780 : 220, height: 600))
            controller.view.wantsLayer = true
            return controller
        }
        let detachedItems = [NSSplitViewItem(sidebarWithViewController: detachedControllers[0]),
                             NSSplitViewItem(viewController: detachedControllers[1])]
        detachedItems[0].minimumThickness = 140
        detachedItems[0].maximumThickness = 280
        detachedItems[1].minimumThickness = 300
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
        let detachedProbe = WorkspaceNavigationProbe(frame: detachedControllers[1].view.bounds)
        var detachedCallbacks = 0
        detachedProbe.onLeadingInsetChange = { _ in detachedCallbacks += 1 }
        detachedControllers[1].view.addSubview(detachedProbe)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        try check(detachedProbe.diagnosticsSnapshot().controllerID == ObjectIdentifier(detachedNavigation)
                  && detachedProbe.diagnosticsSnapshot().savedControllerID == ObjectIdentifier(detachedNavigation),
                  "two-column detachment fixture mounts the real navigation owner before its transition")
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
            let outgoing = WorkspaceNavigationProbe(frame: detachedControllers[1].view.bounds)
            detachedControllers[1].view.addSubview(outgoing)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let successor = WorkspaceNavigationProbe(frame: detachedControllers[1].view.bounds)
            successor.fullPage = successorFullPage
            successor.sheetsVisible = true
            outgoing.fullPage = true
            outgoing.scheduleSynchronization()
            var replaced = false
            DispatchQueue.main.async {
                if successorFullPage {
                    // Exercise SwiftUI's possible attach-before-dismantle order.
                    // Give the successor a main turn to attempt ownership first.
                    detachedControllers[1].view.addSubview(successor)
                    DispatchQueue.main.async {
                        outgoing.dismantle()
                        outgoing.removeFromSuperview()
                        replaced = true
                    }
                } else {
                    outgoing.dismantle()
                    outgoing.removeFromSuperview()
                    detachedControllers[1].view.addSubview(successor)
                    replaced = true
                }
            }
            let replacementDeadline = Date(timeIntervalSinceNow: 0.8)
            repeat {
                RunLoop.main.run(until: min(replacementDeadline, Date(timeIntervalSinceNow: 0.016)))
            } while Date() < replacementDeadline
            geometryHistory.append("Replacement probe fullPage=\(successorFullPage) collapsed=\(detachedItems.map(\.isCollapsed)) pageNavigationVisible=\(successor.sheetsVisible) state={\(successor.diagnosticsState())}")
            try check(replaced && successor.fullPage == successorFullPage && successor.sheetsVisible
                      && detachedItems.dropLast().allSatisfy { $0.isCollapsed == successorFullPage },
                      "the replacement two-column owner keeps its sidebar and carousel intent after outgoing animations")
            successor.dismantle()
            successor.removeFromSuperview()
            let successorDetachDeadline = Date(timeIntervalSinceNow: 0.4)
            repeat {
                RunLoop.main.run(until: min(successorDetachDeadline, Date(timeIntervalSinceNow: 0.016)))
            } while Date() < successorDetachDeadline
            try check(detachedItems.map(NativePaneSnapshot.init) == originalPaneStates,
                      "detaching a replacement owner restores the original native pane policies and state")
        }
        return "\(checks) workspace integration checks passed (two-column sidebar/detail, bottom page carousel, photographic resources, light/dark scenery, independent heading/navigation, passive sidebar geometry, narrow-window and floating restores, full-page ownership, toolbar restoration, native editor identity, typing undo/redo, caret, zoom, pen cursor, Trash, and empty selection)."
    }

}
#endif
